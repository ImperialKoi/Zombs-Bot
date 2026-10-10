import Foundation

/// Deterministic, single-owner state machine. It never sleeps or generates OS events.
public final class Coordinator {
    public var features = Features()
    public var settings: CombatSettings
    public let profiles: [String: ItemProfile]
    private enum Pending {
        case selection(slot: Int, settle: Double, deadline: Double)
        case pickup(name: String, before: [InventorySlot], deadline: Double)
        case reload(slot: Int, deadline: Double)
    }
    private struct Heal {
        var slot: Int; var item: String; var count: Int; var health: Double; var shield: Double
        var started: Double; var duration: Double
        /// When the HUD stopped reading clearly during this heal.
        var uncertainSince: Double?
    }
    /// A weapon swapped out for a consumable, to be picked up again after healing.
    private struct Recovery {
        var slot: Int; var weapon: String; var consumable: String
        var created: Double; var consumed: Double?
    }
    private var pending: Pending?
    private var heal: Heal?
    /// The healing item the assistant committed to: chosen in a safe gap, then kept through selecting, using and
    /// further doses while they still help. Only a threat in the open, damage or your own slot change ends it early.
    private var healPlan: String?
    private var recovery: Recovery?
    private var lastThreat: Double?
    /// Last frame with a confirmed non-teammate player in view, even behind a wall.
    private var lastPlayerSeen = -Double.infinity
    private var lastHealth: Double?
    private var lastFrame = -Double.infinity
    private var lastShot = -Double.infinity
    private var targetID: Int?
    private var cooldownUntil = -Double.infinity
    /// Prompt names with a recent interact press, and when they may be tried again.
    private var pickupBlockedUntil: [String: Double] = [:]
    private var priorWeaponSlot: Int?
    private var band: WeaponRole?
    private var lastRangeSwitch = -Double.infinity

    public init(profiles: [ItemProfile], settings: CombatSettings = .init()) {
        self.profiles = Dictionary(profiles.filter(\.isValid).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.settings = settings
    }
    public convenience init(catalog: ItemCatalog, settings: CombatSettings = .init()) {
        self.init(profiles: catalog.profiles, settings: settings)
    }
    public func reset() {
        pending = nil; heal = nil; healPlan = nil; recovery = nil; targetID = nil
        lastThreat = nil; lastPlayerSeen = -.infinity; lastHealth = nil; lastFrame = -.infinity; lastShot = -.infinity
        cooldownUntil = -.infinity; pickupBlockedUntil = [:]; priorWeaponSlot = nil
        band = nil; lastRangeSwitch = -.infinity
    }
    /// The distance band chosen for the current target, for diagnostics.
    public var currentBand: WeaponRole? { band }
    /// The healing item being selected or used, nil otherwise. The app asks you to stand still meanwhile.
    public var healingItem: String? {
        guard let id = heal?.item ?? healPlan else { return nil }
        return profiles[id]?.name ?? id
    }

    private func profile(_ slot: InventorySlot) -> ItemProfile? {
        guard slot.confidence >= 0.98, let id = slot.itemID, let p = profiles[id], p.verified else { return nil }
        return p
    }
    private func idle(_ t: Double, _ reason: String) -> Decision { Decision(t, [.releaseAll], reason) }
    private func select(_ slot: InventorySlot, in o: Observation, now t: Double, reason: String) -> Decision {
        pending = .selection(slot: slot.index, settle: t + (profile(slot)?.switchDelay ?? 0.2), deadline: t + 1)
        return Decision(o.timestamp, [.releaseAll, .selectSlot(slot.index)], reason)
    }

    /// Class preference inside a distance band; nil when the weapon is never used there.
    /// The close band prefers shotguns, the medium band assault rifles, the long band snipers.
    public static func preference(_ p: ItemProfile, band: WeaponRole) -> Double? {
        guard p.kind == .weapon, let role = p.role else { return nil }
        let weaponClass = p.weaponClass ?? (role == .close ? .shotgun : role == .long ? .sniper : .ar)
        let table: [WeaponClass: Double]
        switch band {
        case .close: table = [.shotgun: 100, .smg: 90, .ar: 70, .lmg: 66, .minigun: 66, .pistol: 60, .dmr: 40, .sniper: 30]
        case .medium: table = [.ar: 100, .lmg: 92, .minigun: 90, .smg: 85, .dmr: 80, .pistol: 60, .sniper: 50, .shotgun: 40]
        case .long: table = [.sniper: 100, .dmr: 92, .ar: 70, .lmg: 60, .minigun: 55, .pistol: 45, .smg: 40]
        }
        return table[weaponClass]
    }
    /// Worth of a weapon in its own role: class preference first, then rarity.
    static func value(_ p: ItemProfile) -> Double {
        (p.role.flatMap { preference(p, band: $0) } ?? 0) + Double(p.tier) * 2
    }
    /// The band for a target distance; the current band extends by the hysteresis margin.
    func band(for distance: Double) -> WeaponRole {
        var close = settings.closeCutoff, long = settings.longCutoff
        let h = settings.bandHysteresis
        switch band {
        case .close?: close += h
        case .medium?: close -= h; long += h
        case .long?: long -= h
        case nil: break
        }
        return distance < close ? .close : distance > long ? .long : .medium
    }

    public func step(_ o: Observation, now t: Double) -> Decision {
        if let reason = Policy.haltReason(o, now: t) {
            pending = nil; heal = nil; healPlan = nil; recovery = nil; targetID = nil; lastThreat = t; priorWeaponSlot = nil; band = nil
            return idle(o.timestamp, reason)
        }
        guard o.timestamp > lastFrame else { return idle(o.timestamp, "Awaiting a new frame") }
        lastFrame = o.timestamp
        if lastThreat == nil { lastThreat = t }
        let damaged = o.hudConfidence >= 0.98 && (o.health ?? 100) < (lastHealth ?? 0) - 0.5
        if o.hudConfidence >= 0.98 { lastHealth = o.health }
        let threatened = Policy.immediateThreat(o, settings) || damaged
        if threatened { lastThreat = t }
        // A confirmed player anywhere in view delays the next heal. A real player is confirmed within a few frames;
        // counting unconfirmed one-frame detections made heals start and stop over and over.
        if Policy.playerInView(o) { lastPlayerSeen = t }
        if threatened, case .pickup = pending {
            // A sent interaction cannot be undone; use the next observed inventory
            // for combat instead of waiting out the pickup acknowledgment timeout.
            pending = nil; recovery = nil
        }
        // Healing starts only after two seconds without a threat or a confirmed player in view.
        let safeToHeal = !threatened && t - (lastThreat ?? t) >= 2 && t - lastPlayerSeen >= 2
        pickupBlockedUntil = pickupBlockedUntil.filter { $0.value > t }

        if var r = recovery {
            // The player must return manually if the item is left behind.
            if t - r.created > 30 || (r.consumed.map { t - $0 > 3 } ?? false) {
                recovery = nil
            } else if r.consumed == nil, o.slot(r.slot)?.isKnownEmpty == true {
                r.consumed = t; recovery = r
            }
        }
        if (heal != nil || healPlan != nil) && (!features.healing || threatened) {
            heal = nil; healPlan = nil; pending = nil
            // Fight first: combat takes the weapon that suits the opponent's range.
            if threatened, features.combat, let decision = combat(o, now: t) { priorWeaponSlot = nil; return decision }
            if let i = priorWeaponSlot, let slot = o.slot(i), profile(slot)?.kind == .weapon {
                priorWeaponSlot = nil
                return select(slot, in: o, now: t, reason: "Interrupt healing and restore weapon")
            }
            return idle(o.timestamp, "Interrupt healing")
        }
        if let h = heal {
            // Effects can hide the HUD for a frame or two; that must not cut the heal short. Half a second is too long.
            guard let slot = o.slot(h.slot), slot.confidence >= 0.98, o.hudConfidence >= 0.98, o.selectedSlot != nil else {
                if t - (h.uncertainSince ?? t) > 0.5 { heal = nil; healPlan = nil; return idle(o.timestamp, "Healing state became uncertain") }
                heal?.uncertainSince = h.uncertainSince ?? t
                return Decision(o.timestamp, [], "Using healing item; HUD briefly unreadable")
            }
            heal?.uncertainSince = nil
            let consumed = slot.isKnownEmpty || (slot.itemID == h.item && slot.count < h.count)
            let improved = (o.health ?? h.health) > h.health || (o.shield ?? h.shield) > h.shield
            if consumed && improved {
                heal = nil; cooldownUntil = t + 0.2
                if !slot.isKnownEmpty { recovery = nil } // Retain the remaining stack.
                return idle(o.timestamp, "Healing confirmed")
            }
            if consumed && t-h.started <= h.duration+1.5 {
                return idle(o.timestamp,"Consumable spent; waiting for health or shield confirmation")
            }
            guard o.selectedSlot == h.slot, slot.itemID == h.item, t - h.started <= h.duration + 1.5 else {
                heal = nil; healPlan = nil; recovery = nil; cooldownUntil = t + 1
                return idle(o.timestamp, "Healing interrupted or timed out")
            }
            return Decision(o.timestamp, [.useConsumable], "Using healing item")
        }

        if let p = pending {
            switch p {
            case let .selection(slot, settle, deadline):
                if o.selectedSlot == slot && o.selectedSlotConfidence >= 0.98 && t >= settle { pending = nil }
                else if t >= deadline { pending = nil; recovery = nil; cooldownUntil = t + 1; return idle(o.timestamp, "Slot selection timed out") }
                else { return idle(o.timestamp, "Waiting for selected slot") }
            case let .pickup(name, before, deadline):
                if Self.inventoryGained(from: before, to: o.inventory) {
                    pending = nil; cooldownUntil = t + 0.2
                    pickupBlockedUntil[name] = t + 0.6 // Another stack of the same item may follow.
                    if recovery?.consumed != nil { recovery = nil }
                    return idle(o.timestamp, "Pickup confirmed")
                }
                if t >= deadline {
                    pending = nil; recovery = nil; cooldownUntil = t + 0.5
                    pickupBlockedUntil[name] = t + 3
                    return idle(o.timestamp, "Pickup not confirmed; no repeated interact press")
                }
                return idle(o.timestamp, "Waiting for pickup confirmation")
            case let .reload(slot, deadline):
                if (o.slot(slot)?.ammo ?? 0) > 0 || o.selectedSlot != slot { pending = nil }
                else if t >= deadline { pending = nil; cooldownUntil = t + 1; return idle(o.timestamp, "Reload not confirmed") }
                else { return idle(o.timestamp, "Reloading") }
            }
        }
        // An opponent in the open is engaged at once, without waiting out a settling period.
        if features.combat, let decision = combat(o, now: t) { return decision }
        guard t >= cooldownUntil else { return idle(o.timestamp, "Waiting for the game to settle") }
        if threatened { return idle(o.timestamp, holdReason(o) ?? "Threat visible; withholding looting and healing") }

        if let r = recovery, r.consumed != nil {
            guard let slot = o.slot(r.slot), slot.isKnownEmpty else { recovery = nil; return idle(o.timestamp, "Recovery slot is no longer empty") }
            if features.loot, let prompt = Policy.pickupPrompt(o), prompt.itemID == r.weapon {
                return pickup(prompt, replacing: nil, in: o, now: t)
            }
        }

        if features.healing, let decision = healing(o, now: t, safeToHeal: safeToHeal) { return decision }
        if let slotID = priorWeaponSlot, let slot = o.slot(slotID), profile(slot)?.kind == .weapon {
            priorWeaponSlot = nil
            if o.selectedSlot != slotID { return select(slot, in: o, now: t, reason: "Restore weapon after healing") }
        }
        if features.loot, let decision = loot(o, now: t, safeToHeal: safeToHeal) { return decision }
        // Reload an empty selected firearm when there is a quiet opportunity.
        if features.combat, let slot = o.selected, let p = profile(slot), p.kind == .weapon,
           slot.ammo == 0, (slot.reserveAmmo ?? 0) > 0 {
            pending = .reload(slot: slot.index, deadline: t + p.reloadDuration + 1)
            return Decision(o.timestamp, [.releaseAll,.reload], "Reload empty weapon")
        }
        return idle(o.timestamp, holdReason(o) ?? "Observing")
    }

    /// Chooses a heal in a safe gap, then carries it through. A committed heal ignores the safe-gap rule, so
    /// stray detections cannot make the assistant flip between the healing item and the gun.
    private func healing(_ o: Observation, now t: Double, safeToHeal: Bool) -> Decision? {
        var choice: (slot: InventorySlot, item: ItemProfile)?
        if let planned = healPlan {
            guard o.hudConfidence >= 0.98 else { return idle(o.timestamp, "Waiting for a clear health reading") }
            let stacks = o.inventory.filter { $0.itemID == planned && $0.count > 0 }
            if let slot = stacks.first(where: { $0.index == o.selectedSlot }) ?? stacks.first, let item = profile(slot),
               Policy.healingBenefit(item, in: o) > 0 {
                choice = (slot, item)
            } else { healPlan = nil }
        }
        if choice == nil && safeToHeal {
            choice = o.inventory.compactMap { slot -> (InventorySlot, ItemProfile, Double)? in
                guard let p = profile(slot), p.kind == .healing, slot.count > 0 else { return nil }
                let benefit = Policy.healingBenefit(p, in: o)
                guard benefit >= Policy.minHealingBenefit else { return nil }
                return (slot, p, benefit / max(0.5, p.useDuration))
            }.sorted { $0.2 > $1.2 }.first.map { ($0.0, $0.1) }
        }
        guard let (slot, item) = choice else { return nil }
        healPlan = item.id
        if o.selectedSlot != slot.index || o.selectedSlotConfidence < 0.98 {
            if let current = o.selected, profile(current)?.kind == .weapon { priorWeaponSlot = current.index }
            return select(slot, in: o, now: t, reason: "Select \(item.name) to heal")
        }
        heal = Heal(slot: slot.index, item: item.id, count: slot.count, health: o.health ?? 0, shield: o.shield ?? 0, started: t, duration: item.useDuration)
        return Decision(o.timestamp, [.releaseAll,.useConsumable], "Start healing during a safe gap")
    }

    /// Why players in view are not engaged, for the status line.
    private func holdReason(_ o: Observation) -> String? {
        let others = o.players.filter { $0.affiliation != .teammate && $0.position.isInViewport }
        guard !others.isEmpty else { return nil }
        if others.contains(where: { !$0.confirmed }) { return "Player spotted; confirming it is real" }
        if others.contains(where: { $0.affiliation != .enemy || $0.affiliationConfidence < settings.minAffiliationConfidence }) {
            return "Player in view; checking for a teammate name tag"
        }
        if others.contains(where: { !Policy.canFireToward(o, at: $0.position) }) { return "Enemy behind cover; holding fire" }
        return "Player in view; not engaged"
    }

    /// A slot from 2 to 6 now holds a different item or a larger stack.
    static func inventoryGained(from before: [InventorySlot], to after: [InventorySlot]) -> Bool {
        after.contains { slot in
            guard (2...6).contains(slot.index), slot.confidence >= 0.98, slot.itemID != nil else { return false }
            guard let old = before.first(where: { $0.index == slot.index }) else { return true }
            return old.itemID != slot.itemID || slot.count > old.count
        }
    }

    private func combat(_ o: Observation, now t: Double) -> Decision? {
        let targets = o.players.filter { Policy.validEnemy($0, settings) && Policy.canFireToward(o, at: $0.position) }
            .sorted { $0.position.distance(to: o.player, aspect: o.aspect) < $1.position.distance(to: o.player, aspect: o.aspect) }
        guard var target = targets.first else { targetID = nil; band = nil; return nil }
        if let old = targets.first(where: { $0.id == targetID }), old.position.distance(to: o.player, aspect: o.aspect) < target.position.distance(to: o.player, aspect: o.aspect) * 1.5 { target = old }
        targetID = target.id
        let distance = target.position.distance(to: o.player, aspect: o.aspect)
        let band = band(for: distance)
        self.band = band
        let armed = o.inventory.compactMap { slot -> (InventorySlot, ItemProfile)? in
            guard let p = profile(slot), p.kind == .weapon, p.role != nil, slot.hasAnyAmmo else { return nil }
            return (slot, p)
        }
        var weapons = armed.compactMap { slot, p -> (InventorySlot, ItemProfile, Double)? in
            guard distance <= p.maxRange, var score = Self.preference(p, band: band) else { return nil }
            score += Double(p.tier) * 2
            if slot.index == o.selectedSlot {
                score += 4 // Avoid trading a weapon for a near-equal one.
                if slot.ammo == 0 { score -= 30 } // Switching to a loaded weapon beats reloading mid-fight.
            }
            return (slot, p, score)
        }.sorted { $0.2 > $1.2 }
        if weapons.isEmpty {
            // No weapon suits this range: still hold a firearm, the one that reaches farthest, on the opponent.
            weapons = armed.map { slot, p in (slot, p, p.maxRange + (slot.index == o.selectedSlot ? 0.01 : 0) - (slot.ammo == 0 ? 1 : 0)) }
                .sorted { $0.2 > $1.2 }
        }
        guard var (slot, p, _) = weapons.first else { return idle(o.timestamp, "No identified firearm with ammunition") }
        if o.selectedSlot != slot.index || o.selectedSlotConfidence < 0.98 {
            // A held weapon that still works keeps firing until the dwell time has passed.
            if o.selectedSlotConfidence >= 0.98, let held = weapons.first(where: { $0.0.index == o.selectedSlot }),
               (held.0.ammo ?? 1) > 0, t - lastRangeSwitch < settings.switchDwell {
                (slot, p) = (held.0, held.1)
            } else {
                lastRangeSwitch = t
                return select(slot, in: o, now: t, reason: "Select \(p.name) for \(band.rawValue) range")
            }
        }
        // Unread ammunition does not hold fire: the readout changes with every shot, so mid-fight it is often
        // between reads. Only a read empty magazine stops firing.
        if slot.ammo == 0 {
            guard (slot.reserveAmmo ?? 0) > 0 else { return idle(o.timestamp, "Selected weapon is out of ammunition") }
            pending = .reload(slot: slot.index, deadline: t + p.reloadDuration + 1)
            return Decision(o.timestamp, [.releaseAll,.reload], "Reload selected weapon")
        }
        guard target.motion != nil else { return idle(o.timestamp, "Opponent motion unknown") }
        if distance > p.maxRange {
            return Decision(o.timestamp, [.releaseAll, .aim(target.position)], "Opponent beyond \(p.name) range; tracking")
        }
        guard let intercept = Targeting.intercept(target, in: o, weapon: p, now: t, settings: settings) else {
            return idle(o.timestamp, "No reachable target intercept")
        }
        // Keep the crosshair on the predicted intercept while the course estimate settles.
        guard intercept.hitProbability >= (p.minHitProbability ?? Policy.minHitProbability) else {
            return Decision(o.timestamp, [.releaseAll,.aim(intercept.point)], "Opponent motion still uncertain")
        }
        let aim = intercept.point
        guard Policy.canFireToward(o, at: aim) else { return idle(o.timestamp, "Predicted firing path blocked") }
        if !p.automatic && t - lastShot < p.shotInterval { return Decision(o.timestamp, [.releaseAll,.aim(aim)], "Weapon cooldown") }
        lastShot = t
        return Decision(o.timestamp, [.aim(aim),.fire], "Engage enemy at \(band.rawValue) range with \(p.name)")
    }

    /// Presses interact for the prompt's item. With a free slot the game fills it; a full
    /// inventory swaps out the selected slot, so the slot to replace is selected first.
    private func pickup(_ prompt: InteractionPrompt, replacing slot: InventorySlot?, in o: Observation, now t: Double) -> Decision {
        if let slot, o.selectedSlot != slot.index || o.selectedSlotConfidence < 0.98 {
            return select(slot, in: o, now: t, reason: "Select slot \(slot.index) to swap for \(prompt.name)")
        }
        pending = .pickup(name: prompt.name, before: o.inventory, deadline: t + 1.2)
        pickupBlockedUntil[prompt.name] = t + 3
        return Decision(o.timestamp, [.releaseAll, .pickup(prompt.name)], "Pick up \(prompt.name) (\(prompt.subtitle)); awaiting inventory confirmation")
    }

    private func loot(_ o: Observation, now t: Double, safeToHeal: Bool) -> Decision? {
        guard let prompt = Policy.pickupPrompt(o), pickupBlockedUntil[prompt.name] == nil,
              let id = prompt.itemID, let incoming = profiles[id], incoming.verified else { return nil }
        let slots = o.inventory.filter { (2...6).contains($0.index) }
        guard slots.count == 5 else { return nil }
        let empty = slots.filter(\.isKnownEmpty)
        let weapons = slots.filter { profile($0).map { $0.kind == .weapon && $0.role != nil } ?? false }
        let heals = slots.filter { profile($0)?.kind == .healing }
        let missingRoles = WeaponRole.allCases.filter { role in !weapons.contains { profile($0)?.role == role } }
        switch incoming.kind {
        case .weapon:
            guard let role = incoming.role else { return nil } // Launchers and special weapons stay manual.
            let sameRole = weapons.filter { profile($0)?.role == role }
            if let worst = sameRole.min(by: { Self.value(profile($0)!) < Self.value(profile($1)!) }) {
                guard Self.value(incoming) > Self.value(profile(worst)!) + 0.5 else { return nil }
                return pickup(prompt, replacing: empty.isEmpty ? worst : nil, in: o, now: t)
            }
            if !empty.isEmpty { return pickup(prompt, replacing: nil, in: o, now: t) }
            // Full: give up a duplicate-role weapon, then a consumable beyond the kept minimum.
            let duplicates = weapons.filter { slot in weapons.filter { profile($0)?.role == profile(slot)?.role }.count > 1 }
            if let victim = duplicates.min(by: { Self.value(profile($0)!) < Self.value(profile($1)!) }) {
                return pickup(prompt, replacing: victim, in: o, now: t)
            }
            if heals.count > settings.minHealSlots,
               let victim = heals.min(by: { Policy.healingBenefit(profile($0)!, in: o) < Policy.healingBenefit(profile($1)!, in: o) }) {
                return pickup(prompt, replacing: victim, in: o, now: t)
            }
            return nil
        case .healing:
            if heals.contains(where: { $0.itemID == id }) { return pickup(prompt, replacing: nil, in: o, now: t) } // Stacks.
            // Keep enough free slots for the weapon roles still missing.
            if empty.count > missingRoles.count { return pickup(prompt, replacing: nil, in: o, now: t) }
            // A temporary swap is restricted to an observed singleton. An unknown stack must not displace a weapon.
            if features.healing, safeToHeal, empty.isEmpty, prompt.count ?? 1 == 1, Policy.healingBenefit(incoming, in: o) >= Policy.minHealingBenefit,
               !heals.contains(where: { Policy.healingBenefit(profile($0)!, in: o) >= Policy.minHealingBenefit }),
               let slot = weapons.min(by: { Self.value(profile($0)!) < Self.value(profile($1)!) }), let weapon = slot.itemID {
                if recovery == nil { recovery = Recovery(slot: slot.index, weapon: weapon, consumable: id, created: t) }
                return pickup(prompt, replacing: slot, in: o, now: t)
            }
            return nil
        default:
            return nil
        }
    }
}
