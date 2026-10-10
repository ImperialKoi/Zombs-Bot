import Foundation

/// A player's motion over the ground, excluding your own movement. Bullets do not inherit the
/// shooter's movement (user-confirmed), so the bullet-flight lead uses this ground velocity.
/// Variances are per axis, in viewport widths (squared), and cover estimation error only.
public struct MotionEstimate: Codable, Equatable, Sendable {
    /// Normalized viewport displacement per second, in the same units as `PlayerTrack.velocity`.
    public var groundVelocity: Point
    public var positionVariance: Double
    public var positionVelocityCovariance: Double
    public var velocityVariance: Double
    /// Uncertainty of your own velocity, which moves the target on screen until the shot.
    public var ownVelocityVariance: Double
    public init(groundVelocity: Point, positionVariance: Double = 0, positionVelocityCovariance: Double = 0,
                velocityVariance: Double = 0, ownVelocityVariance: Double = 0) {
        self.groundVelocity = groundVelocity; self.positionVariance = positionVariance
        self.positionVelocityCovariance = positionVelocityCovariance; self.velocityVariance = velocityVariance
        self.ownVelocityVariance = ownVelocityVariance
    }
    public var isValid: Bool {
        groundVelocity.isFinite && [positionVariance, positionVelocityCovariance, velocityVariance, ownVelocityVariance].allSatisfy(\.isFinite)
        && positionVariance >= 0 && velocityVariance >= 0 && ownVelocityVariance >= 0
    }
    /// Per-axis variance of the impact point after `age` seconds of frame delay and `flight` seconds
    /// of bullet travel, if the target holds its estimated course.
    public func predictionVariance(age: Double, flight: Double) -> Double {
        let horizon = age + flight
        return max(0, positionVariance + 2 * horizon * positionVelocityCovariance + horizon * horizon * velocityVariance
                   + age * age * ownVelocityVariance)
    }
}

/// Constant-velocity Kalman filter in viewport-width units. Both axes share one covariance
/// because they receive identical noise and measurement timing.
public struct MotionFilter: Equatable, Sendable {
    public private(set) var position: Point
    public private(set) var velocity: Point
    public private(set) var positionVariance: Double
    public private(set) var covariance: Double
    public private(set) var velocityVariance: Double
    public private(set) var time: Double
    public let accelerationNoise: Double
    public init(position: Point, time: Double, positionVariance: Double, velocityVariance: Double, accelerationNoise: Double) {
        self.position = position; self.velocity = Point(); self.time = time
        self.positionVariance = positionVariance; self.covariance = 0; self.velocityVariance = velocityVariance
        self.accelerationNoise = accelerationNoise
    }
    public mutating func predict(to t: Double) {
        let dt = t - time
        guard dt > 0 else { return }
        let q = accelerationNoise
        position = position + velocity * dt
        positionVariance += dt * (2 * covariance + dt * velocityVariance) + q * dt * dt * dt / 3
        covariance += dt * velocityVariance + q * dt * dt / 2
        velocityVariance += q * dt
        time = t
    }
    public mutating func update(_ measurement: Point, variance: Double) {
        let innovation = positionVariance + variance
        guard innovation > 0 else { return }
        let gainPosition = positionVariance / innovation, gainVelocity = covariance / innovation
        let residual = measurement - position
        position = position + residual * gainPosition
        velocity = velocity + residual * gainVelocity
        velocityVariance -= gainVelocity * covariance
        positionVariance *= 1 - gainPosition
        covariance *= 1 - gainPosition
    }
}

/// Associates player detections across frames and estimates their ground motion. Your own
/// movement is the opposite of the static scenery's shift on screen.
public struct PlayerMotionTracker: Sendable {
    /// Initial values, to be recalibrated from labeled opponent tracks. Players can reverse within
    /// about 0.2 s; full movement speed measured from scenery shifts is about 0.18 viewport widths/s.
    public static let accelerationNoise = 0.1
    public static let measurementVariance = 0.003 * 0.003
    public static let initialVelocityVariance = 0.18 * 0.18
    public static let gate = 0.06
    public static let coast = 0.3
    /// A confirmed player the detector misses is still reported at its predicted position this long, so a
    /// fight does not stop for a few missed frames.
    public static let hold = 0.25
    /// Detections needed before a track counts as a real player rather than a one-frame false positive.
    public static let confirmHits = 3

    public struct Track: Equatable, Sendable {
        public var id: Int
        /// Normalized viewport displacement per second relative to you, as the target moves on screen.
        public var velocity: Point
        public var motion: MotionEstimate
        public var confirmed: Bool
    }

    private var time: Double?
    /// Your ground position integrated from scenery shifts, in viewport widths.
    private var camera = Point()
    private var own: MotionFilter?
    private var tracks: [Int: MotionFilter] = [:]
    private var lastSeen: [Int: Double] = [:]
    private var hits: [Int: Int] = [:]
    private var nextID = 1
    /// Confirmed tracks the latest update did not detect, with their predicted screen positions.
    public private(set) var held: [(track: Track, position: Point)] = []
    public init() {}

    public mutating func reset() { time = nil; camera = Point(); own = nil; tracks = [:]; lastSeen = [:]; hits = [:]; held = [] }

    /// `sceneryShift` is the median normalized screen displacement of static objects since the
    /// previous call, or nil when none were matched. Results follow the order of `players`.
    public mutating func update(time t: Double, aspect: Double, sceneryShift: Point?, players: [Point]) -> [Track] {
        guard t.isFinite, aspect.isFinite, aspect > 0 else { reset(); return [] }
        if let last = time, !(t > last && t - last < 0.3) { reset() }
        let filter = { (p: Point, variance: Double) in
            MotionFilter(position: p, time: t, positionVariance: Self.measurementVariance, velocityVariance: variance,
                         accelerationNoise: Self.accelerationNoise)
        }
        // Scenery shifts measure your displacement directly; without them, dead-reckon and widen
        // this frame's measurement noise by the drift that your uncertain velocity allows.
        var extraVariance = 0.0
        if var own, let last = time {
            own.predict(to: t)
            if let shift = sceneryShift, shift.isFinite {
                camera = camera - Point(shift.x, shift.y / aspect)
                own.update(camera, variance: Self.measurementVariance)
            } else {
                camera = own.position
                extraVariance = own.velocityVariance * (t - last) * (t - last)
            }
            self.own = own
        } else {
            own = filter(camera, Self.initialVelocityVariance)
        }
        for id in tracks.keys { tracks[id]?.predict(to: t) }
        let ground = players.map { Point($0.x, $0.y / aspect) + camera }
        var candidates: [(distance: Double, index: Int, id: Int)] = []
        for (index, z) in ground.enumerated() {
            for (id, track) in tracks {
                let distance = (track.position - z).length
                if distance < Self.gate { candidates.append((distance, index, id)) }
            }
        }
        var assigned: [Int: Int] = [:], used = Set<Int>()
        for candidate in candidates.sorted(by: { ($0.distance, $0.id) < ($1.distance, $1.id) })
        where assigned[candidate.index] == nil && !used.contains(candidate.id) {
            assigned[candidate.index] = candidate.id; used.insert(candidate.id)
        }
        let ownVelocity = own?.velocity ?? Point(), ownVariance = own?.velocityVariance ?? Self.initialVelocityVariance
        func report(_ id: Int, _ track: MotionFilter) -> Track {
            let relative = track.velocity - ownVelocity
            return Track(id: id, velocity: Point(relative.x, relative.y * aspect), motion: MotionEstimate(
                groundVelocity: Point(track.velocity.x, track.velocity.y * aspect), positionVariance: track.positionVariance,
                positionVelocityCovariance: track.covariance, velocityVariance: track.velocityVariance,
                ownVelocityVariance: ownVariance), confirmed: (hits[id] ?? 0) >= Self.confirmHits)
        }
        var result: [Track] = []
        for (index, z) in ground.enumerated() {
            let id: Int
            if let match = assigned[index] {
                id = match
                tracks[id]?.update(z, variance: Self.measurementVariance + extraVariance)
                hits[id, default: 0] += 1
            } else {
                id = nextID; nextID += 1
                tracks[id] = filter(z, Self.initialVelocityVariance)
                hits[id] = 1
            }
            lastSeen[id] = t
            result.append(report(id, tracks[id]!))
        }
        let detected = Set(result.map(\.id))
        held = tracks.compactMap { id, track -> (track: Track, position: Point)? in
            guard !detected.contains(id), let seen = lastSeen[id], t - seen <= Self.hold, (hits[id] ?? 0) >= Self.confirmHits else { return nil }
            let screen = track.position - camera
            return (report(id, track), Point(screen.x, screen.y * aspect))
        }.sorted { $0.track.id < $1.track.id }
        for (id, seen) in lastSeen where t - seen > Self.coast { tracks[id] = nil; lastSeen[id] = nil; hits[id] = nil }
        time = t
        return result
    }
}
