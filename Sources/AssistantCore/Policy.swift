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
    /// Inventory slots kept for consumables and your one utility item (grenades, Reverse Impulses, a Grappling Hook) when
    /// a gun for a missing range would need one of them: the loadout is a sniper, an AR and an SMG, then two slots for
    /// heals, one of which may hold the utility.
    public var minHealSlots = 2
    /// Seconds from your click to the game acting on it; aim leads the opponent by this on top of the frame's age.
    public var leadLatency = 0.06
    /// Seconds over which an opponent's current velocity is expected to last: players strafe and turn, so a full
    /// constant-velocity lead overshoots them on long shots. 0 keeps the full lead.
    public var leadPersistence = 1.0
    /// The long-range gun is taken after this many seconds without a threat or a player in view…
    public var idleQuiet = 2.5
    /// …and this many seconds after the last fight.
    public var idleAfterFight = 8.0
    /// Seconds a slot you pick yourself is left alone by the idle weapon.
    public var idleUserRespect = 30.0
    /// The cursor stays within this many view heights of your character (see `Targeting.cursor`); the aim keeps its
    /// direction, and clicks stay away from the window's edges.
    public var aimRadius = 0.35
    /// Low on health: below this much health, or below twice this in health and shield together. A potion that helps
    /// then comes first: one on the panel is picked up, even into a slot kept for a missing gun, and drinking goes
    /// before other loot.
    public var lowHealth = 50.0
    /// Grenades land where you click, so a throw lands within this many view heights of your character: the grenade
    /// circle, separate from the crosshair's. Clicks also stay off the HUD and away from the view's edges
    /// (`Policy.clickable`); at 1.25 the circle covers every corner of a wide view, leaving only those limits.
    public var throwRadius = 0.6
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
        leadLatency = try c.decodeIfPresent(Double.self, forKey: .leadLatency) ?? d.leadLatency
        leadPersistence = try c.decodeIfPresent(Double.self, forKey: .leadPersistence) ?? d.leadPersistence
        idleQuiet = try c.decodeIfPresent(Double.self, forKey: .idleQuiet) ?? d.idleQuiet
        idleAfterFight = try c.decodeIfPresent(Double.self, forKey: .idleAfterFight) ?? d.idleAfterFight
        idleUserRespect = try c.decodeIfPresent(Double.self, forKey: .idleUserRespect) ?? d.idleUserRespect
        aimRadius = try c.decodeIfPresent(Double.self, forKey: .aimRadius) ?? d.aimRadius
        lowHealth = try c.decodeIfPresent(Double.self, forKey: .lowHealth) ?? d.lowHealth
        throwRadius = try c.decodeIfPresent(Double.self, forKey: .throwRadius) ?? d.throwRadius
    }
    public var isValid: Bool {
        [closeCutoff, longCutoff, bandHysteresis, switchDwell, minPlayerConfidence, minAffiliationConfidence].allSatisfy(\.isFinite)
        && closeCutoff > 0 && longCutoff > closeCutoff + 2 * bandHysteresis && bandHysteresis >= 0 && switchDwell >= 0
        && (0...1).contains(minPlayerConfidence) && (0...1).contains(minAffiliationConfidence) && (0...5).contains(minHealSlots)
        && (0...0.3).contains(leadLatency) && (0...10).contains(leadPersistence) && (0.5...30).contains(idleQuiet) && (0...60).contains(idleAfterFight) && (0...600).contains(idleUserRespect)
        && (0.1...0.45).contains(aimRadius) && (0...100).contains(lowHealth) && (0.1...1.25).contains(throwRadius)
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
    /// View widths added to an explosion's or a pull's radius before you count as clear of it: the radii are estimates,
    /// and you may move meanwhile.
    public static let blastMargin = 0.04
    /// A pull landing this close to you leaves you where you are and brings players near you to you.
    public static let feetRadius = 0.03
    /// Clicks that must land on a spot, throws, stay this share of the view's height away from every edge of the game
    /// view: well inside it, so none can reach the window's border or Chrome's toolbar.
    public static let edgeMargin = 0.06
    /// Whether a click at `p` is safe: inside the view by `edgeMargin`, and on none of the HUD areas, where it could
    /// press a button or an inventory slot.
    public static func clickable(_ p: Point, in o: Observation) -> Bool {
        let mx = edgeMargin / o.aspect
        return p.isFinite && (mx...(1 - mx)).contains(p.x) && (edgeMargin...(1 - edgeMargin)).contains(p.y) && !o.hudAreas.contains { $0.contains(p) }
    }
    /// Whether a throw may land at `p`: within the grenade circle (`CombatSettings.throwRadius`) and clickable. The game
    /// throws to where you click, so the click is the landing spot.
    public static func throwClickable(_ p: Point, in o: Observation, settings: CombatSettings) -> Bool {
        clickable(p, in: o) && p.distance(to: o.player, aspect: o.aspect) * o.aspect <= settings.throwRadius
    }
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
    /// Whether an exploding round fired toward `aim` stays clear of you. It goes off on the first thing it hits, so
    /// neither the target nor anything on the way within the weapon's radius plus `blastMargin` of you may be there:
    /// walls, trees and rocks count here, and so does any player. `zoom` is the view's (the item in hand): screen
    /// distances times it are default-view widths. Weapons without an explosion are always safe.
    public static func explosiveSafe(_ o: Observation, weapon: ItemProfile, toward aim: Point, zoom: Double) -> Bool {
        guard weapon.radius > 0 else { return true }
        guard aim.isFinite, zoom.isFinite, zoom > 0 else { return false }
        let safe = (weapon.radius + blastMargin) / zoom, distance = aim.distance(to: o.player, aspect: o.aspect)
        guard distance >= safe else { return false }
        let near = o.player + (aim - o.player) * (safe / distance) // The stretch of the line of fire within `safe` of you.
        return !o.obstacles.contains { $0.blocks(from: o.player, to: near) }
            && !o.players.contains { Rect($0.position.x - 0.018, $0.position.y - 0.025, 0.036, 0.05).intersectsSegment(from: o.player, to: near) }
    }
    /// Whether throwing `item` (in hand, so the view is the default one) to `p` is safe and lands where clicked:
    /// - only a pull or a blast, within its throw range, where a throw may be clicked (`throwClickable`: inside the
    ///   grenade circle, away from the view's edges, off the HUD);
    /// - nothing solid on the way, where it would stop, or bounce back at you (`clearShot`);
    /// - a blast lands farther than its radius plus `blastMargin` from you;
    /// - a pull lands at your feet, which leaves you in place, or out of reach of you, so it never drags you along
    ///   (perhaps into your own blast), and it catches no teammate or player not known to be an enemy.
    public static func throwSafe(_ o: Observation, item: ItemProfile, at p: Point, settings: CombatSettings) -> Bool {
        guard item.kind == .throwable, let effect = item.effect, effect == .pull || effect == .blast, throwClickable(p, in: o, settings: settings)
        else { return false }
        let distance = p.distance(to: o.player, aspect: o.aspect)
        guard distance <= item.throwRange, clearShot(o, at: p) else { return false }
        if effect == .blast { return distance >= item.radius + blastMargin }
        guard distance <= feetRadius || distance >= item.radius + blastMargin else { return false }
        return !o.players.contains { $0.affiliation != .enemy && $0.position.distance(to: p, aspect: o.aspect) <= item.radius + blastMargin }
    }
    /// How far from a pull's landing spot an opponent still counts as caught by it: the largest pull radius among these
    /// items, plus a little for moving meanwhile.
    public static func pullReach(_ profiles: some Collection<ItemProfile>) -> Double {
        (profiles.filter { $0.kind == .throwable && $0.effect == .pull }.map(\.radius).max() ?? 0) + 0.06
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
    /// The interaction prompt, when it names a chest or crate read from the current panel.
    public static func chestPrompt(_ o: Observation) -> InteractionPrompt? {
        guard let prompt = o.prompt, prompt.stable, prompt.kind == .chest, prompt.confidence >= 0.8 else { return nil }
        return prompt
    }
    /// Air drops open after about 5 s at the chest, with a countdown under your character; other chests open at once.
    public static func chestNeedsHold(_ prompt: InteractionPrompt) -> Bool { ItemCatalog.letters(prompt.name).contains("airdrop") }
    /// Health under `CombatSettings.lowHealth`, or health and shield together under twice that, read clearly.
    public static func lowOnHealth(_ o: Observation, _ s: CombatSettings = .init()) -> Bool {
        guard let hp = o.health, let shield = o.shield, o.hudConfidence >= 0.98 else { return false }
        return hp < s.lowHealth || hp + shield < 2 * s.lowHealth
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
                  let id = prompt.itemID, let p = profiles[id], p.verified, p.isValid else { return false }
            // Guns with a range, consumables, and throwables the catalog names: never a launcher or a bow.
            switch p.kind {
            case .weapon: return p.role != nil
            case .healing: return true
            case .throwable: return p.effect != nil
            case .melee: return false
            }
        case .open(let name):
            // Only a chest or crate: the same key opens doors, enters vehicles and revives.
            guard !Policy.immediateThreat(o, settings), let prompt = Policy.chestPrompt(o) else { return false }
            return prompt.name == name
        case .holdOpen(let name):
            // A frame without a readable panel keeps the hold (interact with nothing in front does nothing);
            // any other prompt, such as a door or a vehicle, ends it.
            guard !Policy.immediateThreat(o, settings) else { return false }
            guard let prompt = o.prompt else { return !o.promptVisible } // A panel not read yet may show anything.
            return prompt.kind == .chest && prompt.name == name
        case .fire:
            guard let selected = o.selected, selected.confidence >= 0.98, o.selectedSlotConfidence >= 0.98,
                  let item = selected.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .weapon, item.role != nil,
                  selected.hasAnyAmmo, (selected.ammo ?? 1) > 0, let aim, Policy.canFireToward(o, at: aim),
                  Policy.explosiveSafe(o, weapon: item, toward: aim, zoom: item.zoom) else { return false }
            return o.players.contains {
                guard let predicted = Targeting.aim(at: $0, in: o, weapon: item, now: now, settings: settings) else { return false }
                // Allow small planner-to-input delay; compare to the intercept, not the old target position.
                return predicted.distance(to: aim, aspect: o.aspect) <= 0.01
            }
        case .fireAtPull:
            // Launchers and bows too, but never a weapon whose rounds bounce around before going off.
            guard let selected = o.selected, selected.confidence >= 0.98, o.selectedSlotConfidence >= 0.98,
                  let item = selected.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .weapon, item.fuse == 0,
                  selected.hasAnyAmmo, (selected.ammo ?? 1) > 0, let aim, Policy.canFireToward(o, at: aim),
                  aim.distance(to: o.player, aspect: o.aspect) * item.zoom <= item.maxRange,
                  Policy.explosiveSafe(o, weapon: item, toward: aim, zoom: item.zoom) else { return false }
            // The opponent the pull brings there: a player already counted as an enemy, near the spot or on the way to it.
            let reach = Policy.pullReach(profiles.values)
            return o.players.contains {
                $0.affiliation == .enemy && $0.affiliationConfidence >= settings.minAffiliationConfidence && $0.position.distance(to: aim, aspect: o.aspect) <= reach
            }
        case .throwAt(let p):
            // A readout showing rounds means a gun is in hand, whatever the slot is labeled: the click would fire it.
            guard o.gunInHand != true, let selected = o.selected, selected.confidence >= 0.98, selected.count > 0, o.selectedSlotConfidence >= 0.98,
                  let item = selected.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid,
                  Policy.throwSafe(o, item: item, at: p, settings: settings) else { return false }
            // Something to throw it at: an enemy near where it lands, or near enough for a pull to bring there.
            let reach = max(item.radius + 0.06, Policy.pullReach(profiles.values))
            return o.players.contains { Policy.validEnemy($0, settings) && $0.position.distance(to: p, aspect: o.aspect) <= reach }
        case .useConsumable:
            // A readout showing rounds means a gun is in hand, whatever the slot is labeled: clicking would fire it.
            guard o.gunInHand != true, let selected = o.selected, selected.confidence >= 0.98, selected.count > 0, o.selectedSlotConfidence >= 0.98,
                  let item = selected.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .healing else { return false }
            return Policy.healingBenefit(item, in: o) > 0 && !Policy.immediateThreat(o, settings)
        case .reload:
            guard let slot = o.selected, slot.confidence >= 0.98, o.selectedSlotConfidence >= 0.98,
                  let item = slot.itemID.flatMap({ profiles[$0] }), item.verified, item.isValid, item.kind == .weapon else { return false }
            return slot.ammo == 0 && (slot.reserveAmmo ?? 0) > 0
        }
    }
}
