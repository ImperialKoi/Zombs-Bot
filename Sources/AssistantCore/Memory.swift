import Foundation

/// What the assistant remembers of opponents out of sight, so a fight does not stop where the view ends:
/// - an opponent that walked out of view, from its last position and course (`Source.left`);
/// - an opponent shooting at you from out of view, located from its rounds (`Source.bullets`). A round flies straight from
///   the gun, so its shooter stands somewhere back along its path, no farther than its ammunition flies; rounds from other
///   angles, as you or they move, narrow down where.
///
/// Each opponent is a Kalman filter over position and velocity. The velocity fades over `CombatSettings.leadPersistence`,
/// as the aim's lead does: players strafe and turn. Positions are kept as the view stands now, on screen or beyond its
/// edges: they move with the scenery as you move, and with the view's zoom. The arithmetic is in view widths (screen y
/// divided by the aspect), so distances are alike in every direction.
public struct EnemyMemory: Sendable {
    public enum Source: String, Codable, Sendable {
        /// Walked out of view.
        case left
        /// Located from its rounds.
        case bullets
    }
    public struct Entry: Equatable, Sendable {
        /// The track of an opponent that walked out of view; negative for one located from its rounds.
        public var id: Int
        public var source: Source
        /// Where it is estimated now, on screen as the view stands, possibly beyond its edges.
        public var position: Point
        /// Its ground velocity, viewport fractions per second like `PlayerTrack.velocity`.
        public var velocity: Point
        /// When it was last seen, or last located from a round.
        public var lastSeen: Double
        /// When a round of its last flew at you; nil when none has.
        public var lastBullet: Double?
        /// Its rounds' ammunition family, from the last that showed one.
        public var ammo: AmmoFamily?
        /// Rounds that located it.
        public var bullets: Int
        /// How far off the estimate may be across the line from you to it, in view widths (one standard deviation).
        public var spread: Double
        var filter: Filter
        /// Since when it has been predicted in plain view without being seen there.
        var hiddenSince: Double?
    }

    /// A round whose path passes this close to you, ahead of it, flies at you (view widths).
    public static let incomingReach = 0.06
    /// A player this close to a round's path, behind it, fired it.
    public static let shooterReach = 0.05
    /// An opponent last seen this close to the view's edge (view widths), or predicted beyond it, walked out of view.
    public static let edgeBand = 0.04
    /// How long an opponent out of sight is remembered after it was last seen or located.
    public static let rememberFor = 4.0
    /// An opponent that walked out of view but is predicted back in plain view (`plainView` inside its edges) and not seen
    /// there for this long went elsewhere.
    public static let hiddenLimit = 0.6, plainView = 0.08
    /// Spread of an opponent's velocity, view widths a second: players run at about 0.18.
    static let velocitySpread = 0.12
    /// A gap without frames this long loses track of the view's movement, and so of everything remembered.
    static let maxGap = 0.5
    /// How far a round flies before it vanishes, in widths of the default view, by ammunition family: the catalog's ranges
    /// for its guns with a margin, and the most for a round of unknown family.
    public static func reach(_ ammo: AmmoFamily?) -> Double {
        switch ammo {
        case .small?: return 0.45
        case .medium?: return 0.65
        case .shells?: return 0.3
        case .large?, nil: return 0.9
        }
    }
    /// How far from you, in widths of the default view, a gun of an ammunition family is usually fired from: where a
    /// shooter first located from one round is placed along its path, out of sight.
    public static func typicalDistance(_ ammo: AmmoFamily?) -> Double {
        switch ammo {
        case .small?: return 0.25
        case .medium?, nil: return 0.4
        case .shells?: return 0.15
        case .large?: return 0.6
        }
    }

    public private(set) var entries: [Entry] = []
    /// When a round last flew at you from an opponent out of sight.
    public private(set) var lastIncoming = -Double.infinity
    /// When a round of an opponent in view last flew at you.
    public private(set) var lastShotFromView = -Double.infinity
    /// The view's zoom when it last moved (the item in hand's).
    public private(set) var zoom = 1.0
    private var time: Double?
    /// Opponents in view in the last frame, as their tracks showed them, with whether each was at the view's edge.
    private var visible: [Int: (filter: Filter, edge: Bool)] = [:]
    /// Rounds already used, by `Bullet.id`: each locates its shooter once.
    private var used: [Int: Double] = [:]
    private var nextID = -1
    public init() {}
    public mutating func reset() {
        entries = []; lastIncoming = -.infinity; lastShotFromView = -.infinity; zoom = 1; time = nil; visible = [:]; used = [:]
    }

    /// Whether `p` lies inside the view, at least `margin` view widths from every edge.
    static func inside(_ p: Point, by margin: Double, aspect: Double) -> Bool {
        p.isFinite && (margin...(1 - margin)).contains(p.x) && (margin * aspect...(1 - margin * aspect)).contains(p.y)
    }
    /// How far from `origin` (view widths) along unit `u` the view ends; 0 from outside it.
    static func exit(from origin: Point, along u: Point, aspect: Double) -> Double {
        var s = Double.infinity
        let bottom = 1 / aspect
        if u.x > 1e-9 { s = min(s, (1 - origin.x) / u.x) } else if u.x < -1e-9 { s = min(s, -origin.x / u.x) }
        if u.y > 1e-9 { s = min(s, (bottom - origin.y) / u.y) } else if u.y < -1e-9 { s = min(s, -origin.y / u.y) }
        return s.isFinite ? max(0, s) : 0
    }

    /// Takes in a frame: follows the view, carries every opponent on along its course, remembers the ones that walked out of
    /// view, locates shooters from rounds flying at you, and forgets what was seen again or went stale. `zoom` is the view's
    /// (the item in hand's).
    public mutating func update(_ o: Observation, zoom newZoom: Double, settings: CombatSettings) {
        guard o.timestamp.isFinite, o.aspect.isFinite, o.aspect > 0, o.player.isInViewport else { return }
        if let last = time {
            guard o.timestamp > last else { return }
            if o.timestamp - last > Self.maxGap { reset() }
        }
        guard o.phase == .alive else {
            if o.phase == .menu || o.phase == .dead { reset() }
            return
        }
        let t = o.timestamp, aspect = o.aspect, dt = time.map { t - $0 } ?? 0
        func iso(_ p: Point) -> Point { Point(p.x, p.y / aspect) }
        func screen(_ p: Point) -> Point { Point(p.x, p.y * aspect) }
        let me = iso(o.player)
        // The view zoomed, or moved with you: the scenery's shift this frame is the zoom when it changed.
        var follow: (inout Filter) -> Void = { _ in }
        if newZoom.isFinite, newZoom > 0, abs(newZoom - zoom) > 1e-9 {
            let k = zoom / newZoom
            follow = { $0.scale(k, about: me) }
            zoom = newZoom
        } else if let shift = o.sceneryShift, shift.isFinite {
            let d = iso(shift); follow = { $0.move(by: d) }
        } else if let v = o.ownVelocity, v.isFinite {
            let d = iso(v * -dt); follow = { $0.move(by: d) }
        }
        time = t
        let tau = settings.leadPersistence
        for i in entries.indices { follow(&entries[i].filter); entries[i].filter.predict(dt, persistence: tau) }
        for id in Array(visible.keys) { follow(&visible[id]!.filter); visible[id]!.filter.predict(dt, persistence: tau) }

        // An opponent seen again: its track takes over.
        let enemies = o.players.filter { Policy.validEnemy($0, settings) }
        entries.removeAll { e in
            let gate = min(0.3, 0.06 + 2 * ((e.filter.p[0] + e.filter.p[5]) / 2).squareRoot())
            return enemies.contains { $0.id == e.id || (iso($0.position) - e.filter.position).length <= gate }
        }
        // One gone from view since the last frame walked out of it when it was at the edge or is predicted beyond it. One
        // lost in the middle of the view went under a roof or was missed by the detector, and is not followed.
        let ids = Set(enemies.map(\.id))
        for (id, seen) in visible where !ids.contains(id) && !entries.contains(where: { $0.id == id }) {
            guard seen.edge || !Self.inside(screen(seen.filter.position), by: Self.edgeBand, aspect: aspect) else { continue }
            entries.append(Entry(id: id, source: .left, position: screen(seen.filter.position), velocity: screen(seen.filter.velocity),
                                 lastSeen: t - dt, lastBullet: nil, ammo: nil, bullets: 0, spread: 0, filter: seen.filter))
        }
        visible = [:]
        for p in enemies {
            let m = p.motion.flatMap { $0.isValid ? $0 : nil }
            let filter = Filter(position: iso(p.position), velocity: iso(m?.groundVelocity ?? Point()), positionVariance: m?.positionVariance ?? 1e-5,
                                covariance: m?.positionVelocityCovariance ?? 0, velocityVariance: m?.velocityVariance ?? Self.velocitySpread * Self.velocitySpread)
            visible[p.id] = (filter, !Self.inside(p.position, by: Self.edgeBand, aspect: aspect))
        }

        used = used.filter { t - $0.value < 2 }
        for b in o.bullets where b.confirmed && used[b.id] == nil {
            used[b.id] = t
            locate(b, in: o, settings: settings)
        }

        entries.removeAll { t - $0.lastSeen > Self.rememberFor }
        for i in entries.indices {
            let f = entries[i].filter
            entries[i].position = screen(f.position); entries[i].velocity = screen(f.velocity)
            let r = f.position - me, l = r.length
            entries[i].spread = f.variance(along: l > 1e-9 ? Point(-r.y / l, r.x / l) : Point(1, 0)).squareRoot()
            // One that walked out of view and is predicted back in plain view should be seen there.
            if entries[i].source == .left, Self.inside(entries[i].position, by: Self.plainView, aspect: aspect) {
                entries[i].hiddenSince = entries[i].hiddenSince ?? t
            } else { entries[i].hiddenSince = nil }
        }
        entries.removeAll { $0.hiddenSince.map { t - $0 > Self.hiddenLimit } ?? false }
    }

    /// Locates the shooter of a round flying at you: the opponent the round's path fits, else a new one out of sight back
    /// along it. A round fired by a player in view is not located: a teammate's or an unknown player's is no opponent's, and
    /// an opponent in view is fought already.
    private mutating func locate(_ b: Bullet, in o: Observation, settings: CombatSettings) {
        let aspect = o.aspect
        func iso(_ p: Point) -> Point { Point(p.x, p.y / aspect) }
        func dot(_ a: Point, _ c: Point) -> Double { a.x * c.x + a.y * c.y }
        func cross(_ a: Point, _ c: Point) -> Double { a.x * c.y - a.y * c.x }
        let length = b.direction.length
        guard b.position.isFinite, b.direction.isFinite, length > 1e-6 else { return }
        let d = b.direction * (1 / length), head = iso(b.position), me = iso(o.player)
        // Flying at you: its path passes close to you, ahead of it.
        let toMe = me - head
        guard dot(toMe, d) > 0, abs(cross(d, toMe)) <= Self.incomingReach else { return }
        // Its gun is back along its path, behind its trail, no farther than its ammunition flies.
        let back = d * -1
        let trail = b.tail.map { max(0, dot(iso($0) - head, back)) } ?? 0
        let origin = head + back * trail
        let reach = max(0.05, Self.reach(b.ammo) / zoom - trail)
        func behind(_ p: Point) -> Bool {
            let q = iso(p) - origin, s = dot(q, back)
            return s >= -Self.shooterReach && s <= reach + Self.shooterReach && abs(cross(back, q)) <= Self.shooterReach
        }
        if let shooter = o.players.first(where: { $0.position.isInViewport && behind($0.position) }) {
            if Policy.validEnemy(shooter, settings) { lastShotFromView = o.timestamp }
            return
        }
        // In Duo and Squad, a round flying past you at an opponent in view is your teammate's.
        if o.teamMode, o.players.contains(where: { p in
            guard Policy.validEnemy(p, settings) else { return false }
            let q = iso(p.position) - head
            return dot(q, d) > 0 && abs(cross(d, q)) <= Self.shooterReach
        }) { return }
        lastIncoming = o.timestamp
        // About 3° of error in a round's direction.
        func sigma(_ s: Double) -> Double { 0.01 + 0.05 * max(0, s) }
        var best: (index: Int, score: Double)?
        for (i, e) in entries.enumerated() {
            let s = dot(e.filter.position - origin, back)
            guard s >= -0.05, s <= reach + 0.1 else { continue }
            let score = e.filter.distance(toLineThrough: origin, along: back, sigma: sigma(s))
            if score <= 3, score < best?.score ?? .infinity { best = (i, score) }
        }
        let index: Int
        if let best { index = best.index }
        else {
            // A new opponent, out of sight: beyond the view's edge along the path, about as far from you as its kind of gun
            // is usually fired from; or halfway along what its ammunition flies when that ends in view (hidden in a bush,
            // say).
            let edge = Self.exit(from: origin, along: back, aspect: aspect)
            let typical = Self.typicalDistance(b.ammo) / zoom - (me - origin).length
            let s = edge + Self.edgeBand <= reach ? min(reach, max(edge + Self.edgeBand, typical)) : reach / 2
            let along = 0.12, across = sigma(s) + 0.01
            var filter = Filter(position: origin + back * s, velocity: Point(), positionVariance: 0,
                                velocityVariance: Self.velocitySpread * Self.velocitySpread)
            filter.p[0] = along * along * back.x * back.x + across * across * back.y * back.y
            filter.p[5] = along * along * back.y * back.y + across * across * back.x * back.x
            filter.p[1] = (along * along - across * across) * back.x * back.y; filter.p[4] = filter.p[1]
            entries.append(Entry(id: nextID, source: .bullets, position: Point(), velocity: Point(), lastSeen: o.timestamp, lastBullet: nil,
                                 ammo: nil, bullets: 0, spread: 0, filter: filter))
            nextID -= 1
            index = entries.count - 1
        }
        var e = entries[index]
        e.filter.onLine(through: origin, along: back, sigma: sigma(dot(e.filter.position - origin, back)))
        // Neither ahead of its round nor farther back than it flies.
        let s = dot(e.filter.position - origin, back)
        e.filter.move(by: back * (min(max(s, 0), reach) - s))
        e.lastSeen = o.timestamp; e.lastBullet = o.timestamp; e.ammo = b.ammo ?? e.ammo; e.bullets += 1
        entries[index] = e
    }

    /// Position and velocity in view widths, as the view stands now, with their covariance (4 × 4, row-major).
    struct Filter: Equatable, Sendable {
        var x: [Double]
        var p: [Double]
        init(position: Point, velocity: Point, positionVariance: Double, covariance: Double = 0, velocityVariance: Double) {
            x = [position.x, position.y, velocity.x, velocity.y]
            p = [Double](repeating: 0, count: 16)
            p[0] = positionVariance; p[5] = positionVariance; p[10] = velocityVariance; p[15] = velocityVariance
            p[2] = covariance; p[8] = covariance; p[7] = covariance; p[13] = covariance
        }
        var position: Point { Point(x[0], x[1]) }
        var velocity: Point { Point(x[2], x[3]) }
        /// Variance of the position along unit `n`.
        func variance(along n: Point) -> Double { max(0, n.x * n.x * p[0] + 2 * n.x * n.y * p[1] + n.y * n.y * p[5]) }
        mutating func move(by d: Point) { x[0] += d.x; x[1] += d.y }
        /// The view zoomed: distances from `center`, and speeds, scale by `k`.
        mutating func scale(_ k: Double, about center: Point) {
            x[0] = center.x + (x[0] - center.x) * k; x[1] = center.y + (x[1] - center.y) * k; x[2] *= k; x[3] *= k
            for i in 0..<16 { p[i] *= k * k }
        }
        /// `dt` seconds on. The velocity fades over `persistence` seconds, and the uncertainty grows as an opponent may turn
        /// (`velocitySpread`); with no persistence the velocity holds, with `PlayerMotionTracker.accelerationNoise`.
        mutating func predict(_ dt: Double, persistence tau: Double) {
            guard dt > 0 else { return }
            let a: Double, b: Double, qpp: Double, qpv: Double, qvv: Double
            if tau > 0 {
                a = exp(-dt / tau); b = tau * (1 - a)
                let s2 = EnemyMemory.velocitySpread * EnemyMemory.velocitySpread
                qvv = s2 * (1 - a * a); qpv = s2 * tau * (1 - a) * (1 - a); qpp = s2 * tau * tau * (2 * dt / tau - 3 + 4 * a - a * a)
            } else {
                a = 1; b = dt
                let q = PlayerMotionTracker.accelerationNoise
                qpp = q * dt * dt * dt / 3; qpv = q * dt * dt / 2; qvv = q * dt
            }
            x[0] += b * x[2]; x[1] += b * x[3]; x[2] *= a; x[3] *= a
            var f = [Double](repeating: 0, count: 16)
            f[0] = 1; f[5] = 1; f[2] = b; f[7] = b; f[10] = a; f[15] = a
            p = Self.multiply(Self.multiply(f, p), Self.transpose(f))
            p[0] += qpp; p[5] += qpp; p[10] += qvv; p[15] += qvv
            p[2] += qpv; p[8] += qpv; p[7] += qpv; p[13] += qpv
        }
        /// Learns that the opponent stood on the line through `origin` along unit `u`, give or take `sigma`.
        mutating func onLine(through origin: Point, along u: Point, sigma: Double) {
            let n = Point(-u.y, u.x)
            let residual = n.x * (origin.x - x[0]) + n.y * (origin.y - x[1])
            let ph = (0..<4).map { p[$0 * 4] * n.x + p[$0 * 4 + 1] * n.y }
            let s = n.x * ph[0] + n.y * ph[1] + sigma * sigma
            guard s > 0, s.isFinite else { return }
            for i in 0..<4 { x[i] += ph[i] / s * residual }
            for i in 0..<4 { for j in 0..<4 { p[i * 4 + j] -= ph[i] * ph[j] / s } }
        }
        /// How many standard deviations the estimate lies from the line through `origin` along unit `u`.
        func distance(toLineThrough origin: Point, along u: Point, sigma: Double) -> Double {
            let n = Point(-u.y, u.x)
            let residual = n.x * (origin.x - x[0]) + n.y * (origin.y - x[1])
            return abs(residual) / (variance(along: n) + sigma * sigma).squareRoot()
        }
        static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
            var c = [Double](repeating: 0, count: 16)
            for i in 0..<4 { for k in 0..<4 where a[i * 4 + k] != 0 { for j in 0..<4 { c[i * 4 + j] += a[i * 4 + k] * b[k * 4 + j] } } }
            return c
        }
        static func transpose(_ a: [Double]) -> [Double] { (0..<16).map { a[($0 % 4) * 4 + $0 / 4] } }
    }
}
