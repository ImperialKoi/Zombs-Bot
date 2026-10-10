import Foundation

/// Tunable combat and loot behavior, shared by the coordinator and the input guard.
public struct CombatSettings: Codable, Equatable, Sendable {
    /// Distance bands in viewport widths: shotgun range below `closeCutoff`, sniper range above `longCutoff`.
    public var closeCutoff = 0.13
    public var longCutoff = 0.33
    /// The current band extends this far before a range change switches weapons.
    public var bandHysteresis = 0.02
    /// Minimum seconds between distance-driven weapon switches.
    public var switchDwell = 0.6
    /// Detection confidence for a confirmed player track (the detector also applies per-class thresholds).
    public var minPlayerConfidence = 0.45
    public var minAffiliationConfidence = 0.9
    /// Inventory slots kept for consumables while a weapon role is still missing.
    public var minHealSlots = 2
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CombatSettings()
        closeCutoff = try c.decodeIfPresent(Double.self, forKey: .closeCutoff) ?? d.closeCutoff
        longCutoff = try c.decodeIfPresent(Double.self, forKey: .longCutoff) ?? d.longCutoff
        bandHysteresis = try c.decodeIfPresent(Double.self, forKey: .bandHysteresis) ?? d.bandHysteresis
        switchDwell = try c.decodeIfPresent(Double.self, forKey: .switchDwell) ?? d.switchDwell
        minPlayerConfidence = try c.decodeIfPresent(Double.self, forKey: .minPlayerConfidence) ?? d.minPlayerConfidence
        minAffiliationConfidence = try c.decodeIfPresent(Double.self, forKey: .minAffiliationConfidence) ?? d.minAffiliationConfidence
        minHealSlots = try c.decodeIfPresent(Int.self, forKey: .minHealSlots) ?? d.minHealSlots
    }
    public var isValid: Bool {
        [closeCutoff, longCutoff, bandHysteresis, switchDwell, minPlayerConfidence, minAffiliationConfidence].allSatisfy(\.isFinite)
        && closeCutoff > 0 && longCutoff > closeCutoff + 2 * bandHysteresis && bandHysteresis >= 0 && switchDwell >= 0
        && (0...1).contains(minPlayerConfidence) && (0...1).contains(minAffiliationConfidence) && (0...5).contains(minHealSlots)
    }
}

public enum Policy {
    public static let maxFrameAge = 0.15
    /// Player body radius in viewport widths; reviewed silhouettes, which include the weapon, span about 0.039.
    public static let playerHitRadius = 0.015
    /// Default chance the bullet passes within the body radius before firing; weapons may set their own.
    public static let minHitProbability = 0.5
    /// Healing starts only for at least this many points, so bar-reading noise never triggers it.
    public static let minHealingBenefit = 5.0
    public static func haltReason(_ o: Observation, now: Double) -> String? {
        guard now.isFinite, o.timestamp.isFinite, now >= o.timestamp - 0.01, now - o.timestamp <= maxFrameAge else { return "Observation is stale" }
        guard o.captureHealthy else { return "Capture unavailable" }
        guard o.focused else { return "Paused: Chrome is not in front" }
        guard !o.manualOverride else { return "Manual control" }
        guard o.perceptionReady else { return "Recognition is not ready" }
        guard o.phase == .alive, o.phaseConfidence >= 0.98 else { return "No confirmed live match" }
        guard o.player.isInViewport, o.playerConfidence >= 0.98, o.aspect.isFinite, o.aspect > 0 else { return "Player position uncertain" }
        return nil
    }
    public static func clearShot(_ o: Observation, at p: Point) -> Bool {
        p.isInViewport && !o.obstacles.contains { $0.blocks(from: o.player, to: p) }
        && !o.players.contains { $0.affiliation != .enemy && Rect($0.position.x - 0.018, $0.position.y - 0.025, 0.036, 0.05).intersectsSegment(from: o.player, to: p) }
    }
    public static func canFireToward(_ o: Observation, at p: Point) -> Bool {
        p.isInViewport && !o.obstacles.contains { $0.preventsEngagement && $0.blocks(from: o.player, to: p) }
        && !o.players.contains { $0.affiliation != .enemy && Rect($0.position.x - 0.018, $0.position.y - 0.025, 0.036, 0.05).intersectsSegment(from: o.player, to: p) }
    }
    public static func validEnemy(_ p: PlayerTrack, _ s: CombatSettings = .init()) -> Bool {
        p.affiliation == .enemy && p.confirmed && p.confidence >= s.minPlayerConfidence && p.affiliationConfidence >= s.minAffiliationConfidence
        && p.position.isInViewport && p.velocity.isFinite
    }
    /// Any confirmed non-teammate in view and not behind a wall/door/chest. Unknown players count.
    public static func immediateThreat(_ o: Observation, _ s: CombatSettings = .init()) -> Bool {
        o.players.contains { p in
            p.affiliation != .teammate && p.confirmed && p.confidence >= s.minPlayerConfidence && p.position.isInViewport
            && !o.obstacles.contains { $0.preventsEngagement && $0.blocks(from: o.player, to: p.position) }
        }
    }
    /// Any confirmed non-teammate in view, even behind a wall: enough to delay the next heal.
    public static func playerInView(_ o: Observation) -> Bool {
        o.players.contains { $0.affiliation != .teammate && $0.confirmed && $0.position.isInViewport }
    }
    /// The interaction prompt, when it names a known weapon or consumable read from the current panel.
    public static func pickupPrompt(_ o: Observation) -> InteractionPrompt? {
        guard let prompt = o.prompt, prompt.stable, prompt.isItem, prompt.confidence >= 0.8 else { return nil }
        return prompt
    }
    public static func healingBenefit(_ profile: ItemProfile, in o: Observation) -> Double {
        guard let hp = o.health, let shield = o.shield, o.hudConfidence >= 0.98,
              (0...100).contains(hp), (0...100).contains(shield) else { return 0 }
        return min(profile.healthGain, max(0, profile.healthCap - hp)) + min(profile.shieldGain, max(0, profile.shieldCap - shield))
    }
}

/// Revalidates each action at the input boundary, independently of the planner.
public struct ActionGuard {
    public var profiles: [String: ItemProfile]
    public var settings: CombatSettings
    public init(profiles: [String: ItemProfile], settings: CombatSettings = .init()) { self.profiles = profiles; self.settings = settings }
    public func permits(_ intent: InputIntent, observation o: Observation, now: Double, aim: Point?) -> Bool {
        if intent == .releaseAll { return true }
        guard Policy.haltReason(o, now: now) == nil else { return false }
        switch intent {
        case .releaseAll: return true
        case .aim(let p): return p.isInViewport
        case .selectSlot(let index): return (1...6).contains(index) && (o.slot(index)?.confidence ?? 0) >= 0.98
        case .pickup(let name):
            guard !Policy.immediateThreat(o, settings), let prompt = Policy.pickupPrompt(o), prompt.name == name,
                  let id = prompt.itemID, let p = profiles[id], p.verified, p.isValid, [.weapon, .healing].contains(p.kind) else { return false }
            return p.kind != .weapon || p.role != nil
        case .fire:
            guard let selected = o.selected, selected.confidence >= 0.98, o.selectedSlotConfidence >= 0.98,
                  let item = selected.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .weapon, item.role != nil,
                  selected.hasAnyAmmo, (selected.ammo ?? 1) > 0, let aim, Policy.canFireToward(o, at: aim) else { return false }
            return o.players.contains {
                guard let predicted = Targeting.aim(at: $0, in: o, weapon: item, now: now, settings: settings) else { return false }
                // Allow small planner-to-input delay; compare to the intercept, not the old target position.
                return predicted.distance(to: aim, aspect: o.aspect) <= 0.01
            }
        case .useConsumable:
            guard let selected = o.selected, selected.confidence >= 0.98, selected.count > 0, o.selectedSlotConfidence >= 0.98,
                  let item = selected.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .healing else { return false }
            return Policy.healingBenefit(item, in: o) > 0 && !Policy.immediateThreat(o, settings)
        case .reload:
            guard let slot = o.selected, slot.confidence >= 0.98, o.selectedSlotConfidence >= 0.98,
                  let item = slot.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .weapon else { return false }
            return slot.ammo == 0 && (slot.reserveAmmo ?? 0) > 0
        }
    }
}
