import Foundation

/// One round as a single frame shows it, before `BulletTracker` follows it: Perception's bullet detector finds the round's
/// sprite and the faint trail it leaves.
public struct BulletSighting: Equatable, Sendable {
    /// Where the round is (its middle), view-normalized.
    public var position: Point
    /// Unit direction in view widths (screen y divided by the aspect): of travel when `oriented`, else only the round's axis.
    public var direction: Point
    /// The trail, behind the round, showed which way it flies.
    public var oriented: Bool
    /// Where the trail fades out, view-normalized; nil when not seen.
    public var tail: Point?
    public var ammo: AmmoFamily?
    public var confidence: Double
    public init(position: Point, direction: Point, oriented: Bool, tail: Point? = nil, ammo: AmmoFamily? = nil, confidence: Double = 1) {
        self.position = position; self.direction = direction; self.oriented = oriented; self.tail = tail; self.ammo = ammo
        self.confidence = confidence
    }
}

/// Follows rounds across frames. A round flies straight at about 1.1 view widths a second and does not take on its
/// shooter's movement, while the view follows you: on screen it moves by its own flight plus the scenery's shift. A
/// sighting is matched to the round predicted nearest to it, along the same axis; at 55 frames a second a round moves
/// about 0.02 view widths between frames, at 5 a second about 0.22. Its speed over the ground, measured once it has been
/// seen twice, tells rounds from look-alikes, and its motion settles which way a round without a visible trail flies.
public struct BulletTracker: Sendable {
    /// Ground speeds of rounds in view widths a second: about 1.1 measured for pistols, miniguns and snipers, 0.9 to 1.3 for
    /// SMG and AR rounds on a 30 fps recording, and about 0.9 on screen while a sniper's zoom-out shrinks the view.
    public static let speeds = 0.75...1.6
    /// Frames a round must be seen in, each time where its course took it, before it counts: two sightings of look-alikes
    /// (red flowers, ammunition boxes) can line up by chance, three rarely do.
    public static let confirmFrames = 3
    /// A round moves along its axis: between sightings, within this angle of it (radians).
    static let courseTolerance = 0.26
    /// The speed assumed for a round seen once.
    static let typicalSpeed = 1.1
    /// A round not seen for this long is gone: it hit something or flew its range.
    static let lifetime = 0.3
    /// Rounds agree on their axis within this angle, in radians.
    static let axisTolerance = 0.45
    /// How far from its predicted position a round may be seen: this, plus `gateShare` of the way it should have flown.
    static let gate = 0.015, gateShare = 0.35

    private struct Track {
        var id: Int
        /// Where it was last seen, on screen as the view stands now: carried along with the ground since.
        var position: Point
        /// Unit, in view widths.
        var direction: Point
        var oriented: Bool
        /// Over the ground, in view widths a second; nil until seen twice.
        var velocity: Point?
        var tail: Point?
        var votes: [AmmoFamily: Int] = [:]
        var frames = 1
        var lastSeen: Double
        var confidence: Double
    }
    private var tracks: [Track] = []
    private var nextID = 1
    private var time: Double?
    public init() {}
    public mutating func reset() { tracks = []; time = nil }

    /// The rounds this frame shows, followed from earlier frames. `sceneryShift` is how far static scenery moved on screen
    /// since the previous call (`Observation.sceneryShift`); without it your own velocity (`ownVelocity`, viewport fractions
    /// a second) stands in.
    public mutating func update(time t: Double, aspect: Double, sceneryShift: Point?, ownVelocity: Point?, sightings: [BulletSighting]) -> [Bullet] {
        guard t.isFinite, aspect.isFinite, aspect > 0 else { reset(); return [] }
        if let last = time, !(t > last && t - last <= 0.5) { tracks = [] }
        let dt = time.map { t - $0 } ?? 0
        time = t
        // How far the ground moved on screen since the last frame.
        let shift = sceneryShift.flatMap { $0.isFinite ? $0 : nil } ?? (ownVelocity.flatMap { $0.isFinite ? $0 * -dt : nil } ?? Point())
        func screen(_ v: Point) -> Point { Point(v.x, v.y * aspect) }
        func ground(_ p: Point) -> Point { Point(p.x, p.y / aspect) }
        func unit(_ v: Point) -> Point? { let l = v.length; return l > 1e-9 ? v * (1 / l) : nil }
        func dot(_ a: Point, _ b: Point) -> Double { a.x * b.x + a.y * b.y }
        tracks.removeAll { t - $0.lastSeen > Self.lifetime }
        // Where each round was last seen moves with the ground; its own flight since comes on top.
        for i in tracks.indices {
            tracks[i].position = tracks[i].position + shift
            tracks[i].tail = tracks[i].tail.map { $0 + shift }
        }
        let cosTolerance = cos(Self.axisTolerance)
        // Each round's possible positions now: along its known course, or either way along its axis before it is.
        var candidates: [(cost: Double, track: Int, sighting: Int)] = []
        for (i, track) in tracks.enumerated() {
            let elapsed = t - track.lastSeen
            let steps: [Point]
            if let v = track.velocity { steps = [v * elapsed] }
            else if track.oriented { steps = [track.direction * (Self.typicalSpeed * elapsed)] }
            else { steps = [track.direction * (Self.typicalSpeed * elapsed), track.direction * (-Self.typicalSpeed * elapsed)] }
            for (j, s) in sightings.enumerated() {
                let along = dot(track.direction, s.direction)
                guard abs(along) >= cosTolerance, !(track.oriented && s.oriented && along < 0) else { continue }
                // It flew along its axis, and forward when which way it points is known.
                let flown = ground(s.position - track.position)
                if flown.length > Self.gate {
                    let course = dot(flown * (1 / flown.length), track.direction)
                    guard abs(course) >= cos(Self.courseTolerance), !(track.oriented && course < 0) else { continue }
                }
                for step in steps {
                    let distance = ground(s.position - track.position - screen(step)).length
                    guard distance <= Self.gate + Self.gateShare * step.length else { continue }
                    candidates.append((distance, i, j))
                }
            }
        }
        var matchedTracks = Set<Int>(), matchedSightings = Set<Int>()
        for c in candidates.sorted(by: { $0.cost < $1.cost }) where !matchedTracks.contains(c.track) && !matchedSightings.contains(c.sighting) {
            matchedTracks.insert(c.track); matchedSightings.insert(c.sighting)
            let s = sightings[c.sighting]
            var track = tracks[c.track]
            let elapsed = max(1e-3, t - track.lastSeen)
            // Its own flight: where it is now, less where the ground has carried its last position.
            let flown = ground(s.position - track.position)
            let measured = flown * (1 / elapsed)
            track.velocity = track.velocity.map { $0 * 0.5 + measured * 0.5 } ?? measured
            if let course = unit(track.velocity!), flown.length > 0.004 {
                track.direction = course; track.oriented = true
            } else if s.oriented {
                track.direction = s.direction; track.oriented = true
            }
            track.position = s.position
            track.tail = s.tail ?? track.tail
            if let ammo = s.ammo { track.votes[ammo, default: 0] += 1 }
            track.frames += 1; track.lastSeen = t; track.confidence = max(track.confidence, s.confidence)
            tracks[c.track] = track
        }
        for (j, s) in sightings.enumerated() where !matchedSightings.contains(j) {
            var track = Track(id: nextID, position: s.position, direction: s.direction, oriented: s.oriented, tail: s.tail, lastSeen: t,
                              confidence: s.confidence)
            if let ammo = s.ammo { track.votes[ammo] = 1 }
            nextID += 1
            tracks.append(track)
        }
        // Rounds not seen this frame keep moving with the ground until they are seen again or are gone.
        for i in tracks.indices where tracks[i].lastSeen < t { tracks[i].position = tracks[i].position + shift }
        if tracks.count > 64 { tracks = Array(tracks.sorted { $0.lastSeen > $1.lastSeen }.prefix(64)) }
        return tracks.filter { $0.lastSeen == t }.map { track in
            let ammo = track.votes.max { $0.value < $1.value || $0.value == $1.value && $0.key.rawValue < $1.key.rawValue }?.key
            return Bullet(id: track.id, position: track.position, direction: track.direction, tail: track.tail, ammo: ammo,
                          speed: track.frames >= 2 ? track.velocity?.length : nil, frames: track.frames, confidence: track.confidence)
        }
    }
}
