import Foundation

/// Deterministic, single-owner state machine. It never sleeps or generates OS events.
public final class Coordinator {
    public var features = Features()
    public var settings: CombatSettings
    public let profiles: [String: ItemProfile]
    private enum Pending {
        case selection(slot: Int, settle: Double, deadline: Double)
        /// Interact was pressed for an item (`amount` of it, as the panel's badge or the ground stack says); it is taken
        /// once the inventory gains it or the panel moves on.
        case pickup(name: String, item: String?, amount: Int, before: [InventorySlot], deadline: Double)
        case reload(slot: Int, deadline: Double)
        /// Interact was pressed at a chest; it is open once its prompt goes away.
        case opening(name: String, deadline: Double)
        /// Interact is held at an air drop until its prompt goes away.
        case holding(name: String, lastSeen: Double, deadline: Double)
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
    /// Recent confident health and shield readings, to tell gunfire from storm ticks and bar noise.
    private var vitals: [(time: Double, health: Double, shield: Double)] = []
    /// Health and shield still to arrive from doses that heal over time (hybrids), each spread evenly until `until`.
    private var arriving: [(item: String, health: Double, shield: Double, from: Double, until: Double)] = []
    /// How many of its consumable each slot holds. The slot's digits are rarely readable, so the assistant counts its own
    /// pickups and drinks. A stack it did not see arrive counts as one ground stack and is not `known`.
    private struct StackCount { var item: String; var count: Int; var known: Bool }
    private var stacks: [Int: StackCount] = [:]
    /// A consumable just picked up whose slot has not shown yet: the slot it appears in gets this count.
    private var arrivingStack: (item: String, amount: Int, until: Double)?
    /// Slots last read as empty: a consumable that then appears in one is a single ground stack, picked up by either of you.
    private var seenEmpty: Set<Int> = []
    /// The stack badge last read for the item on the panel ("x4"): it is not readable in every frame.
    private var badge: (name: String, count: Int)?
    /// Since when the HUD has been unreadable while a heal plan waits, and when the planned item has been selected
    /// without the potion showing in hand yet.
    private var unclearSince: Double?
    private var inHandSince: Double?
    /// Guns read as having no rounds at all while selected, left out of the idle choice until this time.
    private var noAmmoUntil: [Int: Double] = [:]
    /// When heal selections were sent since the last completed dose; a run of them means the heal never starts.
    private var healAttempts: [Double] = []
    private var healPausedUntil = -Double.infinity
    /// Last frame with a target for combat; a target lost for less than `targetMemory` keeps its distance band.
    private var lastTargetSeen = -Double.infinity
    /// The slot this coordinator last asked for, and the last confidently read selection: a change it did not ask for is yours.
    private var lastRequested: (slot: Int, time: Double)?
    private var lastSelection: Int?
    /// Until when the idle weapon leaves your own slot choice alone.
    private var userChoiceUntil = -Double.infinity
    /// When the idle weapon last asked for a slot; a selection that does not take is not pressed again at once.
    private var lastIdleRequest = -Double.infinity
    /// Why the item prompt on screen is not being picked up, for the status line.
    private var lootNote: String?
    private var lastFrame = -Double.infinity
    private var lastShot = -Double.infinity
    private var targetID: Int?
    private var cooldownUntil = -Double.infinity
    /// Prompt names with a recent interact press, and when they may be tried again.
    private var pickupBlockedUntil: [String: Double] = [:]
    /// Chest names with a recent interact press, and when they may be tried again.
    private var chestBlockedUntil: [String: Double] = [:]
    /// Interact presses for the item or chest on screen that showed no effect yet.
    private var interactPresses: [String: Int] = [:]
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
        lastThreat = nil; lastPlayerSeen = -.infinity; vitals = []; arriving = []; lastFrame = -.infinity; lastShot = -.infinity
        unclearSince = nil; inHandSince = nil; noAmmoUntil = [:]; stacks = [:]; arrivingStack = nil; seenEmpty = []; badge = nil
        cooldownUntil = -.infinity; pickupBlockedUntil = [:]; chestBlockedUntil = [:]; interactPresses = [:]; priorWeaponSlot = nil
        band = nil; lastRangeSwitch = -.infinity; lastTargetSeen = -.infinity; healAttempts = []; healPausedUntil = -.infinity
        lastRequested = nil; lastSelection = nil; userChoiceUntil = -.infinity; lootNote = nil; lastIdleRequest = -.infinity
    }
    /// A target missed for less than this keeps its distance band and identity.
    static let targetMemory = 1.0
    /// Health lost within `damageWindow` that counts as being hit. Storm ticks take a few points at a time and bar
    /// readings agree within a fraction of a point; gunfire takes chunks, and shield first.
    static let healthHit = 5.0, shieldHit = 1.5, damageWindow = 0.3
    /// Heal selections without a completed dose before healing pauses, and for how long.
    static let healAttemptLimit = 4, healPause = 8.0
    /// The game answers interact within a few frames: an item or chest still on screen this long after a press is
    /// pressed again, up to `interactTries` presses, then left alone for `interactBlock`.
    static let interactRetry = 0.6, interactTries = 3, interactBlock = 3.0
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
    /// - Parameter settle: seconds to wait once the slot shows as selected; a weapon's switch delay by default.
    private func select(_ slot: InventorySlot, in o: Observation, now t: Double, reason: String, settle: Double? = nil) -> Decision {
        pending = .selection(slot: slot.index, settle: t + (settle ?? profile(slot)?.switchDelay ?? 0.2), deadline: t + 1)
        lastRequested = (slot.index, t)
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
    /// Worth of a weapon in its own role: its power on the gun ranking's scale, or for profiles without one, class
    /// preference first, then rarity.
    static func value(_ p: ItemProfile) -> Double {
        p.power ?? ((p.role.flatMap { preference(p, band: $0) } ?? 0) + Double(p.tier) * 2)
    }
    /// A gun replaces one of its role only when it is worth this much more: two rank places, or any rarity step.
    static let upgradeMargin = 1.5
    /// Score of a weapon for a distance band: class preference, then rarity and how good the gun is for its class.
    static func bandScore(_ p: ItemProfile, band: WeaponRole) -> Double? {
        preference(p, band: band).map { $0 + Double(p.tier) * 2 + p.edge }
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
            healAttempts = []; inHandSince = nil // A halted heal did not fail.
            // A slot you press while taking over shows as a change afterwards; a new match does not.
            if !o.manualOverride { lastSelection = nil }
            // A key you press yourself may have added to a stack or drunk from one.
            else { for slot in stacks.keys { stacks[slot]?.known = false } }
            return idle(o.timestamp, reason)
        }
        guard o.timestamp > lastFrame else { return idle(o.timestamp, "Awaiting a new frame") }
        lastFrame = o.timestamp
        if lastThreat == nil { lastThreat = t }
        lootNote = nil
        if o.selectedSlotConfidence >= 0.98, let current = o.selectedSlot {
            if let previous = lastSelection, previous != current, !(lastRequested.map { $0.slot == current && t - $0.time <= 2 } ?? false) {
                userChoiceUntil = t + settings.idleUserRespect
            }
            lastSelection = current
        }
        let damaged = hit(o, now: t)
        let threatened = Policy.immediateThreat(o, settings) || damaged
        if threatened { lastThreat = t }
        // A confirmed player anywhere in view delays the next heal. A real player is confirmed within a few frames;
        // counting unconfirmed one-frame detections made heals start and stop over and over.
        if Policy.playerInView(o) { lastPlayerSeen = t }
        if threatened {
            // A sent interaction cannot be undone; use the next observed inventory
            // for combat instead of waiting out the pickup acknowledgment timeout.
            switch pending {
            case .pickup?: pending = nil; recovery = nil
            case .opening?, .holding?: pending = nil
            default: break
            }
        }
        // Healing starts only after two seconds without a threat or a confirmed player in view.
        let safeToHeal = !threatened && t - (lastThreat ?? t) >= 2 && t - lastPlayerSeen >= 2 && t >= healPausedUntil
        pickupBlockedUntil = pickupBlockedUntil.filter { $0.value > t }
        chestBlockedUntil = chestBlockedUntil.filter { $0.value > t }
        // Presses count toward one item or chest; once the panel names something else, that one is over.
        if let name = o.prompt?.name { interactPresses = interactPresses.filter { $0.key == name } }
        arriving.removeAll { t >= $0.until }
        countStacks(o, now: t)
        if let p = o.prompt { if let count = p.count { badge = (p.name, count) } else if badge?.name != p.name { badge = nil } }
        noAmmoUntil = noAmmoUntil.filter { $0.value > t }
        // A gun read as out of rounds while in hand stays out of the idle choice; unselected, its rounds are never read.
        if let slot = o.selected, profile(slot)?.kind == .weapon, slot.ammo == 0, slot.reserveAmmo == 0 { noAmmoUntil[slot.index] = t + 60 }

        if var r = recovery {
            // The player must return manually if the item is left behind.
            if t - r.created > 30 || (r.consumed.map { t - $0 > 3 } ?? false) {
                recovery = nil
            } else if r.consumed == nil, o.slot(r.slot)?.isKnownEmpty == true {
                r.consumed = t; recovery = r
            }
        }
        if !features.chests, let p = pending {
            switch p { case .opening, .holding: pending = nil; default: break } // Turning chests off lets go of E at once.
        }
        if (heal != nil || healPlan != nil) && (!features.healing || threatened) {
            heal = nil; healPlan = nil; pending = nil; healAttempts = []; inHandSince = nil
            // Fight first: combat takes the weapon that suits the opponent's range.
            if threatened, features.combat, let decision = combat(o, now: t) { priorWeaponSlot = nil; return decision }
            if let i = priorWeaponSlot, let slot = o.slot(i), profile(slot)?.kind == .weapon {
                priorWeaponSlot = nil
                return select(slot, in: o, now: t, reason: "Interrupt healing and restore weapon")
            }
            return idle(o.timestamp, "Interrupt healing")
        }
        if let h = heal {
            // Effects can hide the HUD or blur the selected tile for a frame or two; that must not cut the heal short, and
            // the potion stays held through it (an intent the input guard would refuse lets go of the mouse).
            let slot = o.slot(h.slot)
            let recognized = slot.map { $0.confidence >= 0.98 && profiles[$0.itemID ?? ""]?.kind == .healing || $0.isKnownEmpty } ?? false
            guard slot != nil, o.hudConfidence >= 0.98, o.selectedSlot != nil, recognized, o.gunInHand != true else {
                if t - (h.uncertainSince ?? t) > 0.5 {
                    heal = nil; healPlan = nil; cooldownUntil = t + 0.3
                    return idle(o.timestamp, o.gunInHand == true ? "A gun is in hand, not a consumable; healing stopped" : "Healing state became uncertain")
                }
                heal?.uncertainSince = h.uncertainSince ?? t
                return Decision(o.timestamp, [], "Using healing item; HUD briefly unreadable")
            }
            heal?.uncertainSince = nil
            // Your own slot change ends the heal.
            guard o.selectedSlot == h.slot || o.selectedSlotConfidence < 0.98 else {
                heal = nil; healPlan = nil; healAttempts = []; return idle(o.timestamp, "Slot changed; healing stopped")
            }
            let elapsed = t - h.started
            // Gains from an earlier hybrid keep arriving during this dose; only what this dose adds counts.
            let earlier = arrivingTotal(at: h.started), now = arrivingTotal(at: t)
            let gained = max(0, (o.health ?? h.health) - h.health - (earlier.health - now.health))
                + max(0, (o.shield ?? h.shield) - h.shield - (earlier.shield - now.shield))
            // An emptied slot means the drink is done. Otherwise, as stack counts are rarely readable, a dose is done once
            // its drink time has passed and health or shield rose (a hybrid's gains start a moment later).
            if slot!.isKnownEmpty || elapsed >= h.duration + 0.15 && (gained >= 1 || (slot!.count < h.count && slot!.confidence >= 0.98)) {
                heal = nil; cooldownUntil = t + 0.2; healAttempts = []
                if let held = stacks[h.slot], held.item == h.item {
                    stacks[h.slot] = StackCount(item: h.item, count: max(1, held.count - 1), known: held.known && held.count > 1)
                }
                if let item = profiles[h.item], item.overTime > 0 {
                    let gain = HealPlanner.restored(item, health: min(100, h.health + earlier.health), shield: min(100, h.shield + earlier.shield))
                    let seen = min(gained, gain.health + gain.shield)
                    let share = gain.health + gain.shield > 0 ? gain.health / (gain.health + gain.shield) : 0.5
                    arriving.append((h.item, max(0, gain.health - seen * share), max(0, gain.shield - seen * (1 - share)), t, t + item.overTime))
                }
                if !slot!.isKnownEmpty { recovery = nil } // Retain the remaining stack.
                return idle(o.timestamp, "Healing confirmed")
            }
            if elapsed > h.duration + 1.5 {
                heal = nil; healPlan = nil; recovery = nil; cooldownUntil = t + 1
                return idle(o.timestamp, "Heal did not take; stopping")
            }
            return Decision(o.timestamp, [.useConsumable], "Using \(profiles[h.item]?.name ?? "healing item")")
        }

        if let p = pending {
            switch p {
            case let .selection(slot, settle, deadline):
                if o.selectedSlot == slot && o.selectedSlotConfidence >= 0.98 && t >= settle { pending = nil }
                else if t >= deadline { pending = nil; recovery = nil; cooldownUntil = t + 1; return idle(o.timestamp, "Slot selection timed out") }
                // A slot switch on its way does not hold up a chest or an item for a free slot; while it brings a potion to
                // you low on health, only another potion.
                else if !threatened, let decision = takeLoot(o, now: t, safeToHeal: safeToHeal, swapWait: "waiting for slot \(slot)",
                                                             potionsOnly: healPlan != nil && Policy.lowOnHealth(o, settings)) { return decision }
                else { return idle(o.timestamp, "Waiting for selected slot") }
            case let .pickup(name, item, amount, before, deadline):
                let gained = Self.inventoryGained(from: before, to: o.inventory)
                // Stack counts are rarely readable, so the item leaving the panel also means it was taken (or you walked on).
                if gained || o.prompt.map({ $0.name != name }) ?? !o.promptVisible {
                    pending = nil; interactPresses[name] = nil
                    if let item { countPickup(item, amount: amount, before: before, in: o, now: t) }
                    if gained { cooldownUntil = t + 0.2 } // Only a swap waits for the inventory to settle; see `takeLoot`.
                    pickupBlockedUntil[name] = t + 0.6 // Another stack of the same item may follow.
                    if gained, recovery?.consumed != nil { recovery = nil }
                    // The next item or chest on the panel is dealt with in this very frame.
                    if !Self.lootShowing(o) { return idle(o.timestamp, gained ? "Pickup confirmed" : "\(name) taken or left behind") }
                } else if t >= deadline {
                    pending = nil
                    if interactPresses[name] ?? 0 >= Self.interactTries {
                        interactPresses[name] = nil; recovery = nil; pickupBlockedUntil[name] = t + Self.interactBlock
                        return idle(o.timestamp, "\(name) not picked up after \(Self.interactTries) presses; not pressing again for \(Int(Self.interactBlock)) s")
                    }
                    // Still showing: the game may have missed the press, and the item is pressed for again below.
                } else {
                    return idle(o.timestamp, "Waiting for pickup confirmation")
                }
            case let .reload(slot, deadline):
                if (o.slot(slot)?.ammo ?? 0) > 0 || o.selectedSlot != slot { pending = nil }
                else if t >= deadline { pending = nil; cooldownUntil = t + 1; return idle(o.timestamp, "Reload not confirmed") }
                else { return idle(o.timestamp, "Reloading") }
            case let .opening(name, deadline):
                if o.prompt?.kind != .chest || o.prompt?.name != name {
                    // Opened (its loot or nothing is under you now), or you walked on. Its loot is taken in this very frame.
                    pending = nil; interactPresses[name] = nil
                    if !Self.lootShowing(o) { return idle(o.timestamp, "Chest prompt gone; \(name) opened or left behind") }
                } else if t >= deadline {
                    pending = nil
                    if interactPresses[name] ?? 0 >= Self.interactTries {
                        interactPresses[name] = nil; chestBlockedUntil[name] = t + Self.interactBlock
                        return idle(o.timestamp, "\(name) did not open; not pressing again for \(Int(Self.interactBlock)) s")
                    }
                    // Still closed: the game may have missed the press, and the chest is pressed again below.
                } else {
                    return idle(o.timestamp, "Opening \(name)")
                }
            case let .holding(name, lastSeen, deadline):
                let showing = o.prompt?.kind == .chest && o.prompt?.name == name
                // Hold through a frame or two without any panel. A panel showing anything else, even text not read yet
                // (spilled loot, a door), ends the hold at once: interact must not act on it.
                if (o.promptVisible || o.prompt != nil) && !showing || !showing && t - lastSeen > 0.5 {
                    pending = nil
                    if !Self.lootShowing(o) { return idle(o.timestamp, "\(name) opened or left behind") }
                } else if t >= deadline {
                    pending = nil; chestBlockedUntil[name] = t + 5
                    return idle(o.timestamp, "\(name) did not open; not trying again for 5 s")
                } else {
                    pending = .holding(name: name, lastSeen: showing ? t : lastSeen, deadline: deadline)
                    return Decision(o.timestamp, [.holdOpen(name)], "Holding interact at \(name)")
                }
            }
        }
        // An opponent in the open is engaged at once, without waiting out a settling period.
        if features.combat, let decision = combat(o, now: t) { return decision }
        let swapWait = healPlan != nil ? "swapping once healed" : t < cooldownUntil ? "waiting for the game to settle" : nil
        // Low on health, a potion that helps comes first: picking one up, then drinking, then any other loot.
        if !threatened, Policy.lowOnHealth(o, settings) {
            if let decision = takeLoot(o, now: t, safeToHeal: safeToHeal, swapWait: swapWait, potionsOnly: true) { return decision }
            if features.healing, t >= cooldownUntil, let decision = healing(o, now: t, safeToHeal: safeToHeal) { return decision }
        }
        if !threatened, let decision = takeLoot(o, now: t, safeToHeal: safeToHeal, swapWait: swapWait) { return decision }
        guard t >= cooldownUntil else { return idle(o.timestamp, "Waiting for the game to settle") }
        if threatened { return idle(o.timestamp, holdReason(o) ?? "Threat visible; withholding looting and healing") }

        if let r = recovery, r.consumed != nil {
            guard let slot = o.slot(r.slot), slot.isKnownEmpty else { recovery = nil; return idle(o.timestamp, "Recovery slot is no longer empty") }
            if features.loot, let prompt = Policy.pickupPrompt(o), let id = prompt.itemID, Self.sameItem(id, r.weapon), pickupBlockedUntil[prompt.name] == nil {
                return pickup(prompt, replacing: nil, in: o, now: t, reason: "Pick up \(prompt.name) again after healing")
            }
        }

        if features.healing, let decision = healing(o, now: t, safeToHeal: safeToHeal) { return decision }
        if let slotID = priorWeaponSlot, let slot = o.slot(slotID), profile(slot)?.kind == .weapon {
            priorWeaponSlot = nil
            if o.selectedSlot != slotID { return select(slot, in: o, now: t, reason: "Restore weapon after healing") }
        }
        // Reload an empty selected firearm when there is a quiet opportunity.
        if features.combat, let slot = o.selected, let p = profile(slot), p.kind == .weapon,
           slot.ammo == 0, (slot.reserveAmmo ?? 0) > 0 {
            pending = .reload(slot: slot.index, deadline: t + p.reloadDuration + 1)
            return Decision(o.timestamp, [.releaseAll,.reload], "Reload empty weapon")
        }
        if features.combat, features.idleWeapon, let decision = idleWeapon(o, now: t) { return decision }
        return idle(o.timestamp, holdReason(o) ?? lootNote ?? "Observing")
    }

    /// With nothing going on, carry the long-range gun: most fights start at a distance. Waits for a quiet spell and a
    /// while after the last fight, and leaves a slot you picked yourself alone for `idleUserRespect`.
    private func idleWeapon(_ o: Observation, now t: Double) -> Decision? {
        guard t >= userChoiceUntil, heal == nil, healPlan == nil, o.selectedSlotConfidence >= 0.98,
              t - (lastThreat ?? t) >= settings.idleQuiet, t - lastPlayerSeen >= settings.idleQuiet,
              t - lastTargetSeen >= settings.idleAfterFight else { return nil }
        let best = o.inventory.compactMap { slot -> (slot: InventorySlot, item: ItemProfile, score: Double)? in
            guard let p = profile(slot), p.kind == .weapon, slot.hasAnyAmmo, noAmmoUntil[slot.index] == nil,
                  let score = Self.bandScore(p, band: .long) else { return nil }
            return (slot, p, score + (slot.index == o.selectedSlot ? 4 : 0))
        }.max { $0.score < $1.score }
        guard let best, best.slot.index != o.selectedSlot, t - lastIdleRequest >= 5 else { return nil }
        lastIdleRequest = t
        return select(best.slot, in: o, now: t, reason: "Carry \(best.item.name) while nothing is happening")
    }

    /// Combat damage since about `damageWindow` ago: a shield hit, or a health hit too big for a storm tick.
    private func hit(_ o: Observation, now t: Double) -> Bool {
        guard o.hudConfidence >= 0.98, let health = o.health, let shield = o.shield else { return false }
        // The readings of the last `damageWindow`, or the latest one before it when frames are sparse.
        let recent = vitals.filter { t - $0.time <= Self.damageWindow }
        let hit = (recent.isEmpty ? Array(vitals.suffix(1)) : recent).contains { $0.shield - shield > Self.shieldHit || $0.health - health >= Self.healthHit }
        vitals = recent + [(t, health, shield)]
        return hit
    }

    /// Chooses a heal in a safe gap, then carries it through. A committed heal ignores the safe-gap rule, so
    /// stray detections cannot make the assistant flip between the healing item and the gun.
    private func healing(_ o: Observation, now t: Double, safeToHeal: Bool) -> Decision? {
        if healPlan != nil {
            guard t >= healPausedUntil else { healPlan = nil; return nil }
            guard o.hudConfidence >= 0.98 else {
                // A HUD that stays unreadable ends the plan rather than holding everything else up.
                let since = unclearSince ?? t; unclearSince = since
                if t - since > 1.5 { healPlan = nil; unclearSince = nil; return nil }
                return idle(o.timestamp, "Waiting for a clear health reading")
            }
            unclearSince = nil
        } else if !safeToHeal { return nil }
        // Each dose follows the plan for the whole sequence, so the item may change between doses (small shields
        // up to 50 shield, then a hybrid); the plan ends when no dose is worth its item.
        guard let (slot, item) = nextDose(o, now: t, continuing: healPlan != nil) else { healPlan = nil; inHandSince = nil; return nil }
        healPlan = item.id
        let selected = o.selectedSlot == slot.index && o.selectedSlotConfidence >= 0.98
        // Clicking with a gun in hand would fire it: a dose starts only once the panel names the potion in hand or the
        // ammunition readout is seen empty, which over the moving map mostly means once you stand still.
        let confirmed = o.gunInHand == false || o.heldConsumable == item.id
        if selected && !confirmed {
            let since = inHandSince ?? t; inHandSince = since
            if o.gunInHand == true && t - since > 0.3 || t - since > 5 {
                healPlan = nil; inHandSince = nil; cooldownUntil = t + 1
                return idle(o.timestamp, o.gunInHand == true ? "That slot holds a gun, not \(item.name); not healing" : "\(item.name) not confirmed in hand; not healing")
            }
            return idle(o.timestamp, "Stand still: checking that \(item.name) is in hand")
        }
        // Selections or drinks that never complete a dose (a misread slot, a heal the game refuses) must not loop.
        healAttempts = healAttempts.filter { t - $0 < 30 } + [t]
        if healAttempts.count > Self.healAttemptLimit {
            healAttempts = []; healPlan = nil; inHandSince = nil; healPausedUntil = t + Self.healPause
            return idle(o.timestamp, "Healing keeps failing to start; pausing heals for \(Int(Self.healPause)) s")
        }
        inHandSince = nil
        if !selected {
            if let current = o.selected, profile(current)?.kind == .weapon { priorWeaponSlot = current.index }
            return select(slot, in: o, now: t, reason: "Select \(item.name) to heal")
        }
        heal = Heal(slot: slot.index, item: item.id, count: slot.count, health: o.health ?? 0, shield: o.shield ?? 0, started: t, duration: item.useDuration)
        return Decision(o.timestamp, [.releaseAll,.useConsumable], "Start healing with \(item.name)")
    }

    /// Health and shield still to arrive at `t` from hybrids already drunk.
    private func arrivingTotal(at t: Double) -> (health: Double, shield: Double) {
        arriving.reduce((0, 0)) { total, a in
            let left = a.until > a.from ? max(0, min(1, (a.until - t) / (a.until - a.from))) : 0
            return (total.0 + a.health * left, total.1 + a.shield * left)
        }
    }

    /// The first dose of the best heal plan, with the slot holding it: the selected slot when it holds that item.
    /// Health and shield still arriving from a hybrid count as restored already.
    func nextDose(_ o: Observation, now t: Double, continuing: Bool = false) -> (slot: InventorySlot, item: ItemProfile)? {
        guard o.hudConfidence >= 0.98, var health = o.health, var shield = o.shield else { return nil }
        let coming = arrivingTotal(at: t)
        health = min(100, health + coming.health); shield = min(100, shield + coming.shield)
        let held = o.inventory.compactMap { slot -> (slot: InventorySlot, item: ItemProfile)? in
            guard let p = profile(slot), p.kind == .healing, slot.count > 0 else { return nil }
            // A hybrid drunk while the last one's health and shield are still arriving is wasted: the effect does not stack.
            if p.overTime > 0, arriving.contains(where: { $0.item == p.id && t < $0.until }) { return nil }
            return (slot, p)
        }
        let supply = held.map { entry -> HealPlanner.Stack in
            let counted = stacks[entry.slot.index].flatMap { $0.item == entry.item.id ? $0.count : nil }
            return HealPlanner.Stack(entry.item, count: counted ?? entry.slot.count)
        }
        let thresholds = continuing ? HealPlanner.continuing : (Policy.minHealingBenefit, 0)
        guard let first = HealPlanner.plan(health: health, shield: shield, stacks: supply, minimumBenefit: thresholds.0, slack: thresholds.1).first else { return nil }
        let holding = held.filter { $0.item.id == first.id }
        return holding.first { $0.slot.index == o.selectedSlot } ?? holding.first
    }

    /// Keeps `stacks` in step with the inventory. A count read off the slot wins. A stack that appears is the pickup just
    /// made, or else one ground stack (not `known`). An emptied or changed slot starts over.
    private func countStacks(_ o: Observation, now t: Double) {
        if let a = arrivingStack, t > a.until { arrivingStack = nil }
        for slot in o.inventory where (2...6).contains(slot.index) && slot.confidence >= 0.98 {
            let wasEmpty = seenEmpty.contains(slot.index)
            if slot.isKnownEmpty { seenEmpty.insert(slot.index) } else { seenEmpty.remove(slot.index) }
            guard let id = slot.itemID, let p = profiles[id], p.kind == .healing else { stacks[slot.index] = nil; continue }
            let cap = p.maxStack ?? Int.max
            if slot.count > 1 { stacks[slot.index] = StackCount(item: id, count: min(slot.count, cap), known: true); continue }
            guard stacks[slot.index]?.item != id else { continue }
            if let a = arrivingStack, a.item == id {
                stacks[slot.index] = StackCount(item: id, count: min(a.amount, cap), known: true); arrivingStack = nil
            } else {
                stacks[slot.index] = StackCount(item: id, count: min(p.groundStack ?? 1, cap), known: wasEmpty && p.groundStack != nil)
            }
        }
    }

    /// Counts a consumable pickup: into the slot that gained it, else onto the stack of it with room, else into the slot
    /// it shows up in shortly.
    private func countPickup(_ item: String, amount: Int, before: [InventorySlot], in o: Observation, now t: Double) {
        guard let p = profiles[item], p.kind == .healing else { return }
        let cap = p.maxStack ?? Int.max
        if let slot = o.inventory.first(where: { s in (2...6).contains(s.index) && s.itemID == item && before.first { $0.index == s.index }?.itemID != item }) {
            stacks[slot.index] = StackCount(item: item, count: min(amount, cap), known: true)
        } else if let index = stacks.filter({ $0.value.item == item && $0.value.count < cap }).keys.min() {
            stacks[index]!.count = min(cap, stacks[index]!.count + amount)
        } else {
            arrivingStack = (item, amount, t + 1.5)
        }
    }

    /// How many of the item the panel offers: its badge ("x2"), read now or earlier while it was on the panel, else one
    /// ground stack (2 small shields or hybrids, 1 big shield).
    private func stackSize(_ prompt: InteractionPrompt, _ item: ItemProfile) -> Int {
        prompt.count ?? (badge?.name == prompt.name ? badge?.count : nil) ?? item.groundStack ?? 1
    }

    /// Free places in the stack this slot holds; nil when its count is a guess or the item's stack size is unknown.
    private func stackRoom(_ slot: InventorySlot) -> Int? {
        guard let id = slot.itemID, let cap = profiles[id]?.maxStack, let held = stacks[slot.index], held.item == id, held.known else { return nil }
        return cap - held.count
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

    /// The same item: equal IDs, or a gun of the same class and rarity when one of the two was read without its name.
    static func sameItem(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard let x = ItemCatalog.parseWeaponID(a), let y = ItemCatalog.parseWeaponID(b), x == y else { return false }
        return ItemCatalog.modelID(in: a) == nil || ItemCatalog.modelID(in: b) == nil
    }
    /// The panel names a chest or a recognized item to decide on.
    static func lootShowing(_ o: Observation) -> Bool { Policy.pickupPrompt(o) != nil || Policy.chestPrompt(o) != nil }
    /// A slot from 2 to 6 now holds a different item or a larger stack, or anything at all where it was empty.
    static func inventoryGained(from before: [InventorySlot], to after: [InventorySlot]) -> Bool {
        after.contains { slot in
            guard (2...6).contains(slot.index) else { return false }
            let old = before.first { $0.index == slot.index }
            // A new item counts before its icon is recognized.
            if old?.isKnownEmpty == true && !slot.isKnownEmpty && slot.confidence > 0 { return true }
            guard slot.confidence >= 0.98, slot.itemID != nil else { return false }
            guard let old else { return true }
            return old.itemID != slot.itemID || slot.count > old.count
        }
    }

    private func combat(_ o: Observation, now t: Double) -> Decision? {
        let targets = o.players.filter { Policy.validEnemy($0, settings) && Policy.canFireToward(o, at: $0.position) }
            .sorted { $0.position.distance(to: o.player, aspect: o.aspect) < $1.position.distance(to: o.player, aspect: o.aspect) }
        guard var target = targets.first else {
            // A target missed briefly keeps its band, so its return does not count as a new range.
            if t - lastTargetSeen > Self.targetMemory { targetID = nil; band = nil }
            return nil
        }
        lastTargetSeen = t
        if let old = targets.first(where: { $0.id == targetID }), old.position.distance(to: o.player, aspect: o.aspect) < target.position.distance(to: o.player, aspect: o.aspect) * 1.5 { target = old }
        targetID = target.id
        // Distances are in the default view's widths: a sniper zooms out, which shrinks everything on screen, and an
        // opponent must not look closer just because the sniper is in hand.
        let zoom = o.selected.flatMap { profile($0) }?.zoom ?? 1
        let distance = target.position.distance(to: o.player, aspect: o.aspect) * zoom
        let band = band(for: distance)
        self.band = band
        let armed = o.inventory.compactMap { slot -> (InventorySlot, ItemProfile)? in
            guard let p = profile(slot), p.kind == .weapon, p.role != nil, slot.hasAnyAmmo else { return nil }
            return (slot, p)
        }
        var weapons = armed.compactMap { slot, p -> (InventorySlot, ItemProfile, Double)? in
            guard distance <= p.maxRange, var score = Self.bandScore(p, band: band) else { return nil }
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
        if target.position.distance(to: o.player, aspect: o.aspect) * p.zoom > p.maxRange {
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

    /// Opening a chest or taking an item is one key press, and the loot stays behind once you walk on, so it comes before
    /// heals and settling times: it never changes the selected slot. A swap into a full inventory does change it (the game
    /// swaps out the selected item), so it waits while `swapWait` says why.
    /// - Parameter potionsOnly: only a consumable on the panel, for when you are low on health and a heal comes next.
    private func takeLoot(_ o: Observation, now t: Double, safeToHeal: Bool, swapWait: String?, potionsOnly: Bool = false) -> Decision? {
        if features.loot, let decision = loot(o, now: t, safeToHeal: safeToHeal, swapWait: swapWait, potionsOnly: potionsOnly) { return decision }
        if !potionsOnly, features.chests, let decision = openChest(o, now: t) { return decision }
        return nil
    }

    /// Presses interact for the prompt's item. With a free slot the game fills it; a full
    /// inventory swaps out the selected slot, so the slot to replace is selected first.
    private func pickup(_ prompt: InteractionPrompt, replacing slot: InventorySlot?, in o: Observation, now t: Double, reason: String) -> Decision {
        if let slot, o.selectedSlot != slot.index || o.selectedSlotConfidence < 0.98 {
            // Interact needs the slot selected, not the gun ready to fire: no switch delay.
            return select(slot, in: o, now: t, reason: "Select slot \(slot.index) to swap for \(prompt.name)", settle: 0)
        }
        let press = (interactPresses[prompt.name] ?? 0) + 1
        interactPresses[prompt.name] = press
        let amount = prompt.itemID.flatMap { profiles[$0] }.map { stackSize(prompt, $0) } ?? 1
        pending = .pickup(name: prompt.name, item: prompt.itemID, amount: amount, before: o.inventory, deadline: t + Self.interactRetry)
        pickupBlockedUntil[prompt.name] = t + Self.interactRetry
        return Decision(o.timestamp, [.releaseAll, .pickup(prompt.name)], press > 1 ? "\(reason) (press \(press))" : reason)
    }

    /// Presses interact at a chest or crate; its loot then lies around it, where the item prompts take over. A chest
    /// still closed after `interactRetry` is pressed again. An air drop opens after about 5 s at it, so interact is held
    /// until its prompt goes away, for up to 8 s.
    private func openChest(_ o: Observation, now t: Double) -> Decision? {
        guard let prompt = Policy.chestPrompt(o), chestBlockedUntil[prompt.name] == nil else { return nil }
        if Policy.chestNeedsHold(prompt) {
            chestBlockedUntil[prompt.name] = t + 2.5
            pending = .holding(name: prompt.name, lastSeen: t, deadline: t + 8)
            return Decision(o.timestamp, [.releaseAll, .holdOpen(prompt.name)], "Hold interact at \(prompt.name); stand still")
        }
        let press = (interactPresses[prompt.name] ?? 0) + 1
        interactPresses[prompt.name] = press
        chestBlockedUntil[prompt.name] = t + Self.interactRetry
        pending = .opening(name: prompt.name, deadline: t + Self.interactRetry)
        return Decision(o.timestamp, [.releaseAll, .open(prompt.name)], press > 1 ? "Open \(prompt.name) (press \(press))" : "Open \(prompt.name)")
    }

    /// Decides on the item the prompt names, read by text recognition ("M4 / Epic AR"): a gun is weighed by its place in
    /// the gun ranking and its rarity (`ItemProfile.power`) against the gun of its range it would join or replace.
    private func loot(_ o: Observation, now t: Double, safeToHeal: Bool, swapWait: String?, potionsOnly: Bool = false) -> Decision? {
        guard let prompt = Policy.pickupPrompt(o), let id = prompt.itemID, let incoming = profiles[id], incoming.verified,
              !potionsOnly || incoming.kind == .healing else { return nil }
        func skip(_ why: String) -> Decision? { lootNote = "Not picking up \(incoming.name): \(why)"; return nil }
        func take(replacing slot: InventorySlot? = nil, _ reason: String) -> Decision? {
            if slot != nil, let swapWait { return skip(swapWait) }
            return pickup(prompt, replacing: slot, in: o, now: t, reason: reason)
        }
        func name(_ slot: InventorySlot) -> String { profile(slot)?.name ?? "slot \(slot.index)" }
        guard pickupBlockedUntil[prompt.name] == nil else { return skip("just tried") }
        let slots = o.inventory.filter { (2...6).contains($0.index) }
        guard slots.count == 5 else { return skip("inventory not fully read") }
        let empty = slots.filter(\.isKnownEmpty)
        let weapons = slots.filter { profile($0).map { $0.kind == .weapon && $0.role != nil } ?? false }
        let heals = slots.filter { profile($0)?.kind == .healing }
        let missingRoles = WeaponRole.allCases.filter { role in !weapons.contains { profile($0)?.role == role } }
        switch incoming.kind {
        case .weapon:
            guard let role = incoming.role else { return skip("launchers and special weapons stay manual") }
            let sameRole = weapons.filter { profile($0)?.role == role }
            if let worst = sameRole.min(by: { Self.value(profile($0)!) < Self.value(profile($1)!) }) {
                guard Self.value(incoming) > Self.value(profile(worst)!) + Self.upgradeMargin else { return skip("not better than \(name(worst))") }
                return empty.isEmpty ? take(replacing: worst, "Pick up \(incoming.name) in place of \(name(worst))")
                    : take("Pick up \(incoming.name): better than \(name(worst))")
            }
            if !empty.isEmpty { return take("Pick up \(incoming.name) for \(role.rawValue) range") }
            // Full: give up a duplicate-role weapon, then a consumable beyond the kept minimum.
            let duplicates = weapons.filter { slot in weapons.filter { profile($0)?.role == profile(slot)?.role }.count > 1 }
            if let victim = duplicates.min(by: { Self.value(profile($0)!) < Self.value(profile($1)!) }) {
                return take(replacing: victim, "Pick up \(incoming.name) for \(role.rawValue) range in place of \(name(victim))")
            }
            if heals.count > settings.minHealSlots,
               let victim = heals.min(by: { Policy.healingBenefit(profile($0)!, in: o) < Policy.healingBenefit(profile($1)!, in: o) }) {
                return take(replacing: victim, "Pick up \(incoming.name) for \(role.rawValue) range in place of \(name(victim))")
            }
            return skip(slots.contains { $0.confidence < 0.98 } ? "inventory full and some slots unrecognized" : "inventory full")
        case .healing:
            let amount = stackSize(prompt, incoming)
            let helps = Policy.healingBenefit(incoming, in: o) >= Policy.minHealingBenefit
            let urgent = helps && Policy.lowOnHealth(o, settings)
            let same = heals.filter { $0.itemID == id }
            // A stack of it with room takes it without a slot of its own: big shields stack to 2, small shields and hybrids to 4.
            if let stack = same.first(where: { (stackRoom($0) ?? 0) > 0 }), let held = stacks[stack.index] {
                return take("Pick up \(incoming.name): \(held.count) of \(incoming.maxStack ?? held.count) held" + (urgent ? ", low on health" : ""))
            }
            // A stack whose count is a guess may be full. With a free slot the item lands there at worst; with none the game
            // would swap out the selected item instead, perhaps a gun.
            if same.contains(where: { stackRoom($0) == nil }) {
                if !empty.isEmpty { return take("Pick up \(incoming.name)" + (urgent ? ": low on health" : "")) }
                return skip("its stack may be full, and the inventory is full")
            }
            let stacksFull = !same.isEmpty ? "its stack is full; " : ""
            // Keep enough free slots for the weapon roles still missing, unless you are low on health and it helps now.
            if empty.count > missingRoles.count { return take("Pick up \(incoming.name)") }
            if urgent, !empty.isEmpty { return take("Pick up \(incoming.name): low on health") }
            // Full inventory, nothing held that helps now, and a quiet moment to drink it: make room.
            if features.healing, safeToHeal, empty.isEmpty, helps, !heals.contains(where: { Policy.healingBenefit(profile($0)!, in: o) >= Policy.minHealingBenefit }) {
                // Low on health, a consumable that cannot help now goes first; it is not picked up again.
                if urgent, let victim = heals.min(by: { profile($0)!.keepValue < profile($1)!.keepValue }) {
                    return take(replacing: victim, "Swap \(name(victim)) for \(incoming.name): low on health")
                }
                // Otherwise the weakest gun, to be picked up again once the slot is drunk empty: only for a stack that will all
                // be drunk now (a single item, or when low, all the doses the heal plan would take).
                let drunk = HealPlanner.plan(health: o.health ?? 100, shield: o.shield ?? 100, stacks: [HealPlanner.Stack(incoming, count: amount)]).count
                if amount == 1 || urgent && drunk >= amount, let slot = weapons.min(by: { Self.value(profile($0)!) < Self.value(profile($1)!) }), let weapon = slot.itemID {
                    if let swapWait { return skip(swapWait) }
                    if recovery == nil { recovery = Recovery(slot: slot.index, weapon: weapon, consumable: id, created: t) }
                    return take(replacing: slot, "Swap \(name(slot)) for \(incoming.name) to heal")
                }
            }
            return skip(stacksFull + (empty.isEmpty ? "inventory full" : "keeping free slots for missing guns"))
        default:
            return nil
        }
    }
}
