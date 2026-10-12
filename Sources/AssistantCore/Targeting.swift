import Foundation

/// Interception in viewport-width units, recomputed for each observation. Until the game fires, you and the target
/// both keep moving, so the frame's age plus the click's latency use the target's on-screen velocity. Bullets do not
/// inherit your movement, so their flight (about 1.1 view widths a second) uses its ground velocity, with a lead that
/// fades over `CombatSettings.leadPersistence`: players strafe and turn, and a full constant-velocity lead overshoots.
public enum Targeting {
    public struct Intercept: Equatable, Sendable {
        public var point: Point
        /// Chance that the bullet passes within `Policy.playerHitRadius` if the target holds its estimated course.
        public var hitProbability: Double
    }

    /// How far a target moving at unit velocity is expected to get in `seconds` when its velocity lasts about `persistence`.
    static func lead(_ seconds: Double, persistence: Double) -> Double {
        persistence > 0 ? -persistence * expm1(-seconds / persistence) : seconds
    }

    public static func aim(at target: PlayerTrack, in o: Observation, weapon: ItemProfile, now: Double,
                           settings: CombatSettings = .init()) -> Point? {
        guard let intercept = intercept(target, in: o, weapon: weapon, now: now, settings: settings),
              intercept.hitProbability >= (weapon.minHitProbability ?? Policy.minHitProbability) else { return nil }
        return intercept.point
    }

    /// `weapon` is the gun in hand: its zoom sets the view scale, and its bullet speed is in that view's widths per second.
    public static func intercept(_ target: PlayerTrack, in o: Observation, weapon: ItemProfile, now: Double,
                                 settings: CombatSettings = .init()) -> Intercept? {
        guard Policy.validEnemy(target, settings), let motion = target.motion, motion.isValid, o.player.isInViewport,
              o.aspect.isFinite, o.aspect > 0, now.isFinite, o.timestamp.isFinite, now >= o.timestamp - 0.01,
              now - o.timestamp <= Policy.maxFrameAge, weapon.isValid, weapon.kind == .weapon else { return nil }
        let delay = max(0, now - o.timestamp) + settings.leadLatency
        let current = target.position + target.velocity * delay
        guard current.isInViewport else { return nil }
        let ground = motion.groundVelocity
        var travelTime = 0.0
        if weapon.projectileSpeed > 0 {
            let delta = current - o.player
            let r = Point(delta.x, delta.y / o.aspect)
            let v = Point(ground.x, ground.y / o.aspect)
            let speedSquared = weapon.projectileSpeed * weapon.projectileSpeed
            let velocitySquared = v.x * v.x + v.y * v.y
            // |r + v*t|² = (bulletSpeed*t)²; choose the earliest future intercept.
            let a = velocitySquared - speedSquared
            let b = 2 * (r.x * v.x + r.y * v.y)
            let c = r.x * r.x + r.y * r.y
            guard [a,b,c,speedSquared,velocitySquared].allSatisfy(\.isFinite) else { return nil }
            if c > 0 {
                if abs(a) <= 1e-12 * max(velocitySquared, speedSquared) {
                    guard b < 0 else { return nil }
                    travelTime = -c / b
                } else {
                    let discriminant = b * b - 4 * a * c
                    guard discriminant.isFinite, discriminant >= 0 else { return nil }
                    // Stable quadratic roots avoid cancellation for approaching targets.
                    let q = -0.5 * (b + (b >= 0 ? 1 : -1) * sqrt(discriminant))
                    guard let first = [q / a, c / q].filter({ $0.isFinite && $0 >= 0 }).min() else { return nil }
                    travelTime = first
                }
            }
            // With a fading lead the target gets less far, so the flight is re-solved from the constant-velocity time.
            // Bullets are about six times faster than players, so a few steps settle it.
            if settings.leadPersistence > 0 {
                for _ in 0..<4 {
                    let d = current + ground * lead(travelTime, persistence: settings.leadPersistence) - o.player
                    let time = Point(d.x, d.y / o.aspect).length / weapon.projectileSpeed
                    guard time.isFinite else { return nil }
                    travelTime = time
                }
            }
        }
        // A zero speed means uncalibrated: compensate the delay only, without inventing flight time.
        let predicted = current + ground * lead(travelTime, persistence: settings.leadPersistence)
        guard predicted.isInViewport,
              predicted.distance(to: o.player, aspect: o.aspect) * weapon.zoom <= weapon.maxRange else { return nil }
        let variance = motion.predictionVariance(age: delay, flight: travelTime)
        let radius = Policy.playerHitRadius
        return Intercept(point: predicted, hitProbability: variance > 0 ? 1 - exp(-radius * radius / (2 * variance)) : 1)
    }
}
