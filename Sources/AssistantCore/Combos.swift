import Foundation

/// Reverse Impulse combos. A Reverse Impulse Grenade goes off about half a second after the throw and pulls every player
/// near it, through walls too, to where it landed: an opponent arrives at a known spot at a known time. Waiting there is
/// - a lethal grenade thrown to the same spot: a Frag, whose fuse is about 2 s, goes first and the pull is timed to go
///   off just before it (the "rev-nade"); an RGD-5, quick like the pull, follows it;
/// - a shot timed to arrive with the opponent: a rocket, a present burst, an XBow, crossbow, sniper or DMR shot, or, for
///   an opponent behind cover that the pull brings into the open, any gun;
/// - your shotgun or SMG: the pull lands at your feet and brings an opponent round a corner or through a door to you.
///
/// Explosions hurt you too, and a pull takes you along when you are inside it. So a blast never lands near you, and a
/// pull lands either at your feet (where it leaves you in place, and no blast follows) or out of your reach; your own
/// movement until it all goes off counts. A grenade is never thrown through anything solid, where it would bounce back.
/// Fuses come from the wiki; radii, throw ranges and how long a pull takes are the catalog's estimates.
public enum Combos {
    public enum Finisher: String, Codable, Sendable {
        /// A lethal grenade thrown to the same spot.
        case grenade
        /// A shot timed to arrive as the opponent does.
        case gun
        /// The pull at your feet, then your shotgun or SMG as the opponent arrives.
        case close
    }
    public struct Plan: Equatable, Sendable {
        public var finisher: Finisher
        /// The opponent's track.
        public var target: Int
        public var pullSlot: Int
        public var pull: String
        /// The lethal grenade or the gun that finishes the combo.
        public var followSlot: Int
        public var follow: String
        /// Grenades: seconds from the pull's throw to the lethal grenade's. Negative: the grenade goes that much before
        /// the pull, as a Frag's fuse is longer than the pull's.
        public var gap: Double
        /// Where the pull (and the grenade) land, on screen when planned.
        public var point: Point
        /// The first item to throw: the lethal grenade when it goes first, else the pull.
        public var firstSlot: Int { finisher == .grenade && gap < 0 ? followSlot : pullSlot }
        public var first: String { finisher == .grenade && gap < 0 ? follow : pull }
    }
    /// An inventory item, with what the catalog says about it.
    public struct Held: Sendable {
        public var slot: InventorySlot
        public var item: ItemProfile
        public init(slot: InventorySlot, item: ItemProfile) { self.slot = slot; self.item = item }
    }

    /// An opponent predicted within this share of the pull's radius from where it lands is caught.
    public static let reach = 0.75
    /// The blast or the shot comes this many seconds after the opponent arrives at the spot.
    public static let settle = 0.05
    /// Seconds after the opponent arrives that a gun keeps firing at the spot.
    public static let window = 0.4
    /// A pull at your feet lands this far toward the opponent, so the click has a direction.
    public static let feetOffset = 0.02
    /// Seconds after a combo before the next one may start, and the most one may take.
    public static let cooldown = 3.0, maxDuration = 4.0
    /// The first throw must come this soon after the combo starts.
    public static let startLimit = 1.5
    /// A second grenade this many seconds late is no longer thrown.
    public static let lateLimit = 0.25
    /// Seconds after a throw before the next key: the click must be let go where it was made.
    public static let throwHold = 0.12
    /// Time a slot switch takes until the item is in hand, when planning before it.
    static let switchTime = 0.35

    /// Whether this item is a pull that can be thrown to a spot.
    public static func isPull(_ p: ItemProfile) -> Bool { p.kind == .throwable && p.effect == .pull && p.throwRange > 0 }
    /// Whether this item is a lethal grenade that lands where you click.
    public static func isBlast(_ p: ItemProfile) -> Bool { p.kind == .throwable && p.effect == .blast && p.throwRange > 0 }

    /// When an opponent caught by a pull thrown at `thrown` arrives at its center.
    public static func arrival(thrown: Double, pull: ItemProfile, settings: CombatSettings) -> Double {
        thrown + settings.leadLatency + pull.fuse + pull.pullDuration
    }
    /// Where an opponent is expected `seconds` from now, on screen as the view stands now: its ground motion, with the
    /// lead fading like a bullet's (`Targeting`), from where the frame's age has carried it.
    public static func predicted(_ target: PlayerTrack, in o: Observation, after seconds: Double, now t: Double, settings: CombatSettings) -> Point {
        let age = max(0, t - o.timestamp)
        let ground = target.motion?.groundVelocity ?? Point()
        return target.position + target.velocity * age + ground * Targeting.lead(max(0, seconds), persistence: settings.leadPersistence)
    }
    /// How far your own movement carries a spot on the ground across the screen in `seconds`: the other way from you.
    public static func drift(_ o: Observation, after seconds: Double, settings: CombatSettings) -> Point {
        (o.ownVelocity ?? Point()) * -Targeting.lead(max(0, seconds), persistence: settings.leadPersistence)
    }
    /// How far from you a throw toward `p` can land: within the grenade circle, away from the view's edges, short of the
    /// first HUD area on the way (`Policy.throwClickable`), and short of the first thing it would hit (`Policy.clearShot`),
    /// so an opponent behind a wall is pulled through it to your side.
    static func throwReach(_ o: Observation, toward p: Point, settings: CombatSettings) -> Double {
        let d = p.distance(to: o.player, aspect: o.aspect)
        guard d > 1e-9 else { return 0 }
        func at(_ s: Double) -> Point { o.player + (p - o.player) * (s / d) }
        let step = 0.0025
        var s = 0.0
        while s < 2, Policy.throwClickable(at(s + step), in: o, settings: settings) { s += step }
        // Once something is in the way, it stays in the way farther out: halve the distance to it.
        guard s > 0, !Policy.clearShot(o, at: at(s)) else { return s }
        var (lo, hi) = (0.0, s)
        while hi - lo > step { let mid = (lo + hi) / 2; if Policy.clearShot(o, at: at(mid)) { lo = mid } else { hi = mid } }
        return lo
    }
    /// The spot on the line from you toward `e` (where the opponent will be), between `nearest` and `farthest` from you,
    /// closest to `e`; nil when even that is farther than `catchRadius` from it.
    static func spot(toward e: Point, in o: Observation, nearest: Double, farthest: Double, catchRadius: Double) -> Point? {
        let d = e.distance(to: o.player, aspect: o.aspect)
        guard d > 1e-6, nearest <= farthest else { return nil }
        let p = o.player + (e - o.player) * (min(max(d, nearest), farthest) / d)
        return p.distance(to: e, aspect: o.aspect) <= catchRadius ? p : nil
    }
    /// The observation as the default view shows it. A sniper or a bow in hand zooms the view out, and a throwable in hand
    /// brings the default view back, which spreads everything out from you by the zoom.
    public static func unzoomed(_ o: Observation, zoom: Double) -> Observation {
        guard zoom.isFinite, zoom > 0, abs(zoom - 1) > 1e-9 else { return o }
        var u = o
        func at(_ p: Point) -> Point { o.player + (p - o.player) * zoom }
        func rect(_ r: Rect) -> Rect { let c = at(Point(r.x, r.y)); return Rect(c.x, c.y, r.width * zoom, r.height * zoom) }
        u.players = o.players.map { p in
            var q = p; q.position = at(p.position); q.velocity = p.velocity * zoom
            q.motion?.groundVelocity = (p.motion?.groundVelocity ?? Point()) * zoom
            return q
        }
        u.obstacles = o.obstacles.map { var q = $0; q.bounds = rect($0.bounds); q.maskCells = $0.maskCells.map(rect); return q }
        u.ownVelocity = o.ownVelocity.map { $0 * zoom }
        u.sceneryShift = o.sceneryShift.map { $0 * zoom }
        return u
    }

    /// How a gun finishes a combo, best first: a rocket or present burst, then one big shot (XBow, crossbow, sniper,
    /// DMR), then any other gun, which is only worth it on an opponent behind cover. Never a gun whose rounds bounce around
    /// first, and a shotgun only right at your feet (`closeRank`).
    static func gunRank(_ p: ItemProfile) -> Double? {
        guard p.kind == .weapon, p.fuse == 0, let c = p.weaponClass else { return nil }
        switch c {
        case .launcher: return 1
        case .special, .sniper, .dmr: return 2
        case .ar, .lmg, .minigun, .smg, .pistol: return 4
        case .shotgun: return nil
        }
    }
    /// How a gun finishes a pull at your feet: a shotgun, else an SMG; nil for anything else.
    static func closeRank(_ p: ItemProfile) -> Double? {
        guard p.kind == .weapon, p.fuse == 0, p.radius == 0 else { return nil }
        return p.weaponClass == .shotgun ? 3 : p.weaponClass == .smg ? 3.5 : nil
    }

    /// Every combo that works on `target` now, best first: a lethal grenade, then a rocket or presents, one big shot, the
    /// shotgun or SMG at your feet, any other gun; within each, the stronger item. `zoom` is the view's now (the item in hand).
    /// - Parameter inHand: the slot in hand; a throw from any other slot waits for its switch first.
    public static func plans(on target: PlayerTrack, in view: Observation, holding held: [Held], inHand: Int?, zoom: Double,
                             settings: CombatSettings, now t: Double) -> [Plan] {
        let o = unzoomed(view, zoom: zoom)
        guard let target = o.players.first(where: { $0.id == target.id }), target.motion?.isValid == true,
              let pull = held.first(where: { isPull($0.item) && $0.slot.count > 0 }) else { return [] }
        let latency = settings.leadLatency, margin = Policy.blastMargin
        let catchRadius = pull.item.radius * reach
        // Behind a wall or door: only a pull brings this opponent into your line of fire.
        let covered = !Policy.canFireToward(o, at: target.position)
        func ready(_ slot: Int) -> Double { slot == inHand ? 0 : switchTime }
        // Nobody but the opponent may be caught: teammates, and players not yet known to be enemies.
        func catchesOthers(_ p: Point) -> Bool {
            o.players.contains { $0.id != target.id && $0.affiliation != .enemy && $0.position.distance(to: p, aspect: o.aspect) <= pull.item.radius + margin }
        }
        // Clear of you then: the spot as your movement will have carried it on screen, `seconds` from now.
        func clear(_ p: Point, by distance: Double, after seconds: Double) -> Bool {
            (p + drift(o, after: seconds, settings: settings)).distance(to: o.player, aspect: o.aspect) >= distance
        }
        // The input guard throws only at a spot with an enemy near it now (`Policy.pullReach`).
        func near(_ p: Point, _ radius: Double) -> Bool { target.position.distance(to: p, aspect: o.aspect) <= radius + 0.06 }
        // A lethal grenade on the same spot. A Frag goes first and the pull follows `gap` later; a grenade as quick as the
        // pull goes after it.
        func bomb(_ follow: Held) -> Plan? {
            let item = follow.item
            let gap = (pull.item.fuse + pull.item.pullDuration + settle) - item.fuse
            let pullOff = ready(gap < 0 ? follow.slot.index : pull.slot.index) + latency + max(0, -gap) + pull.item.fuse
            let blast = pullOff + pull.item.pullDuration + settle
            let e = predicted(target, in: o, after: pullOff, now: t, settings: settings)
            // You stay out of the pull, or it would drag you into the blast, and out of the blast.
            let nearest = max(item.radius, pull.item.radius) + margin
            let farthest = min(pull.item.throwRange, item.throwRange, throwReach(o, toward: e, settings: settings))
            guard let p = spot(toward: e, in: o, nearest: nearest, farthest: farthest, catchRadius: catchRadius),
                  Policy.clearShot(o, at: p), !catchesOthers(p), near(p, max(item.radius, pull.item.radius)),
                  clear(p, by: pull.item.radius + margin, after: pullOff), clear(p, by: item.radius + margin, after: blast) else { return nil }
            return Plan(finisher: .grenade, target: target.id, pullSlot: pull.slot.index, pull: pull.item.id,
                        followSlot: follow.slot.index, follow: item.id, gap: gap, point: p)
        }
        // A shot at the spot, timed to arrive with the opponent.
        func shot(_ follow: Held) -> Plan? {
            let item = follow.item
            let pullOff = ready(pull.slot.index) + latency + pull.item.fuse
            let e = predicted(target, in: o, after: pullOff, now: t, settings: settings)
            // You stay out of the pull, which would drag you off your aim, and out of the gun's own explosion.
            let nearest = max(pull.item.radius, item.radius) + margin
            let farthest = min(pull.item.throwRange, item.maxRange, throwReach(o, toward: e, settings: settings))
            guard let p = spot(toward: e, in: o, nearest: nearest, farthest: farthest, catchRadius: catchRadius),
                  Policy.clearShot(o, at: p), !catchesOthers(p), near(p, pull.item.radius),
                  clear(p, by: nearest, after: pullOff + pull.item.pullDuration), Policy.explosiveSafe(o, weapon: item, toward: p, zoom: 1)
            else { return nil }
            return Plan(finisher: .gun, target: target.id, pullSlot: pull.slot.index, pull: pull.item.id,
                        followSlot: follow.slot.index, follow: item.id, gap: 0, point: p)
        }
        // Tight quarters: the opponent is round a corner or behind a door, near enough for a pull at your feet.
        func close(_ follow: Held) -> Plan? {
            let pullOff = ready(pull.slot.index) + latency + pull.item.fuse
            let e = predicted(target, in: o, after: pullOff, now: t, settings: settings)
            let d = target.position.distance(to: o.player, aspect: o.aspect)
            guard d > 1e-6, e.distance(to: o.player, aspect: o.aspect) <= catchRadius else { return nil }
            let p = o.player + (target.position - o.player) * (feetOffset / d)
            guard Policy.clearShot(o, at: p), !catchesOthers(p), near(p, pull.item.radius) else { return nil }
            return Plan(finisher: .close, target: target.id, pullSlot: pull.slot.index, pull: pull.item.id,
                        followSlot: follow.slot.index, follow: follow.item.id, gap: 0, point: p)
        }
        var found: [(rank: Double, plan: Plan)] = []
        for follow in held where follow.slot.index != pull.slot.index {
            let item = follow.item, strength = (item.power ?? 0) / 1000
            let loaded = item.kind == .weapon && follow.slot.hasAnyAmmo && (follow.slot.ammo ?? 1) > 0
            if isBlast(item), follow.slot.count > 0, let plan = bomb(follow) { found.append((-item.damage / 1000, plan)) }
            if let rank = gunRank(item), loaded, rank < 4 || covered, let plan = shot(follow) { found.append((rank - strength, plan)) }
            if let rank = closeRank(item), loaded, covered, let plan = close(follow) { found.append((rank - strength, plan)) }
        }
        // Screen positions back in the view as it is now.
        let scale = zoom.isFinite && zoom > 0 ? 1 / zoom : 1
        return found.sorted { $0.rank < $1.rank }.map { entry in
            var plan = entry.plan; plan.point = view.player + (plan.point - view.player) * scale; return plan
        }
    }
}

/// A spot on the ground, followed on screen: static scenery moves by your movement each frame (`Observation.sceneryShift`,
/// else your last known velocity), and a weapon's zoom scales the view around you.
public struct GroundMark: Equatable, Sendable {
    public private(set) var point: Point
    public private(set) var zoom: Double
    private var time: Double
    public init(_ point: Point, zoom: Double, time: Double) { self.point = point; self.zoom = zoom; self.time = time }
    /// Moves the spot to where this frame shows it; `zoom` is the view's now.
    public mutating func follow(_ o: Observation, zoom newZoom: Double) {
        guard o.timestamp > time else { return }
        if newZoom.isFinite, newZoom > 0, abs(newZoom - zoom) > 1e-9 {
            // Screen distances shrink as the view zooms out. The scenery's shift this frame is the zoom, not your movement.
            point = o.player + (point - o.player) * (zoom / newZoom); zoom = newZoom
        } else if let shift = o.sceneryShift, shift.isFinite {
            point = point + shift
        } else if let v = o.ownVelocity, v.isFinite {
            point = point - v * (o.timestamp - time)
        }
        time = o.timestamp
    }
}
