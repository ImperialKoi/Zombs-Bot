import Foundation

/// Plans consumable use over the whole sequence of doses, so each choice respects what comes after it: a small
/// shield (it only fills up to 50) goes before a hybrid that would lift the shield past 50, and a big shield is not
/// spent on a few points. A dose earns the points it restores, minus what the item is worth keeping for later and a
/// small charge for the time spent standing still.
public enum HealPlanner {
    public struct Stack: Equatable, Sendable {
        public var item: ItemProfile
        public var count: Int
        public init(_ item: ItemProfile, count: Int) { self.item = item; self.count = count }
    }
    /// Value, in health/shield points, of one second spent drinking.
    public static let timeCost = 0.5
    /// Doses of one item considered in a plan; later doses are planned once the first ones are used.
    static let maxDosesPerItem = 8

    /// Health and shield one dose restores from this state, never past the item's caps.
    public static func restored(_ item: ItemProfile, health: Double, shield: Double) -> (health: Double, shield: Double) {
        (min(item.healthGain, max(0, item.healthCap - health)), min(item.shieldGain, max(0, item.shieldCap - shield)))
    }

    /// What one dose is worth from this state; nil when it restores less than `minimumBenefit` points.
    public static func value(_ item: ItemProfile, health: Double, shield: Double, minimumBenefit: Double = Policy.minHealingBenefit) -> Double? {
        let r = restored(item, health: health, shield: shield)
        guard r.health + r.shield >= minimumBenefit else { return nil }
        return r.health + r.shield - item.keepValue - timeCost * item.useDuration
    }

    /// Thresholds that keep a heal going once it has started, so a bar reading that wobbles across a threshold does not
    /// start and stop it: any dose restoring a point, worth up to `slack` points less than starting one would need.
    public static let continuing = (minimumBenefit: 1.0, slack: 4.0)

    /// The doses to take from this state, best first; empty when nothing is worth using.
    public static func plan(health: Double, shield: Double, stacks: [Stack], minimumBenefit: Double = Policy.minHealingBenefit,
                            slack: Double = 0) -> [ItemProfile] {
        guard health.isFinite, shield.isFinite, (0...100).contains(health), (0...100).contains(shield) else { return [] }
        // One entry per item; stacks of the same item in two slots add up.
        var totals: [String: (item: ItemProfile, count: Int)] = [:]
        for stack in stacks where stack.count > 0 && stack.item.kind == .healing && stack.item.isValid {
            totals[stack.item.id, default: (stack.item, 0)].count += stack.count
        }
        let items = totals.values.sorted { $0.item.id < $1.item.id }.map(\.item)
        guard !items.isEmpty else { return [] }
        let start = items.map { min(maxDosesPerItem, totals[$0.id]!.count) }

        struct State: Hashable { var health: Int; var shield: Int; var counts: [Int] }
        var memo: [State: (score: Double, doses: [Int])] = [:]
        func best(_ health: Double, _ shield: Double, _ counts: [Int]) -> (score: Double, doses: [Int]) {
            let key = State(health: Int((health * 100).rounded()), shield: Int((shield * 100).rounded()), counts: counts)
            if let known = memo[key] { return known }
            var result: (score: Double, doses: [Int]) = (0, [])
            for i in items.indices where counts[i] > 0 {
                // Restoring only adds, which can only shrink later doses, so a dose that is not worth it now never pays off later.
                guard let worth = value(items[i], health: health, shield: shield, minimumBenefit: minimumBenefit), worth + slack > 0 else { continue }
                let gain = worth + slack
                let r = restored(items[i], health: health, shield: shield)
                var rest = counts; rest[i] -= 1
                let tail = best(health + r.health, shield + r.shield, rest)
                let score = gain + tail.score
                // Ties go to fewer doses, then to the item listed first, so the plan never alternates.
                if score > result.score + 1e-9 || (abs(score - result.score) <= 1e-9 && !result.doses.isEmpty && tail.doses.count + 1 < result.doses.count) {
                    result = (score, [i] + tail.doses)
                }
            }
            memo[key] = result
            return result
        }
        return best(health, shield, start).doses.map { items[$0] }
    }
}
