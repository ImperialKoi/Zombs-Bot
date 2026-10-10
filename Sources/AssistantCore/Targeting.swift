import Foundation

/// Constant-velocity interception in viewport-width units. Recomputed for each observation.
/// Frame delay uses the target's on-screen velocity because you and the target both keep moving
/// until the shot. Bullets do not inherit your movement, so their flight uses its ground velocity.
public enum Targeting {
    public struct Intercept: Equatable, Sendable {
        public var point: Point
        /// Chance that the bullet passes within `Policy.playerHitRadius` if the target holds its estimated course.
        public var hitProbability: Double
    }

    public static func aim(at target: PlayerTrack, in o: Observation, weapon: ItemProfile, now: Double,
                           settings: CombatSettings = .init()) -> Point? {
        guard let intercept = intercept(target, in: o, weapon: weapon, now: now, settings: settings),
              intercept.hitProbability >= (weapon.minHitProbability ?? Policy.minHitProbability) else { return nil }
        return intercept.point
    }

    public static func intercept(_ target: PlayerTrack, in o: Observation, weapon: ItemProfile, now: Double,
                                 settings: CombatSettings = .init()) -> Intercept? {
        guard Policy.validEnemy(target, settings), let motion = target.motion, motion.isValid, o.player.isInViewport,
              o.aspect.isFinite, o.aspect > 0, now.isFinite, o.timestamp.isFinite, now >= o.timestamp - 0.01,
              now - o.timestamp <= Policy.maxFrameAge, weapon.isValid, weapon.kind == .weapon else { return nil }
        let age = max(0, now - o.timestamp)
        let current = target.position + target.velocity * age
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
        }
        // A zero speed means uncalibrated: compensate frame age only, without inventing flight time.
        let predicted = current + ground * travelTime
        guard predicted.isInViewport,
              predicted.distance(to: o.player, aspect: o.aspect) <= weapon.maxRange else { return nil }
        let variance = motion.predictionVariance(age: age, flight: travelTime)
        let radius = Policy.playerHitRadius
        return Intercept(point: predicted, hitProbability: variance > 0 ? 1 - exp(-radius * radius / (2 * variance)) : 1)
    }
}
