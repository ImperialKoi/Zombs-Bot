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
    /// A gun or utility item swapped out for a consumable, to be picked up again after healing.
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
    /// How many of its consumable or utility item each slot holds. The slot's digits are rarely readable, so the assistant
    /// counts its own pickups, drinks and throws. A stack it did not see arrive counts as one ground stack and is not `known`.
    private struct StackCount { var item: String; var count: Int; var known: Bool }
    private var stacks: [Int: StackCount] = [:]
    /// A consumable just picked up whose slot has not shown yet: the slot it appears in gets this count.
    private var arrivingStack: (item: String, amount: Int, until: Double)?
    /// Slots last read as empty: a consumable that then appears in one is a single ground stack, picked up by either of you.
    private var seenEmpty: Set<Int> = []
    /// The first frame of this match the assistant saw alive; a menu or death screen ends the match.
    private var matchStart: Double?
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
    /// A Reverse Impulse combo under way (see `Combos`): the plan, the opponent as last seen, and what has been thrown.
    private struct Combo {
        var plan: Combos.Plan
        var target: PlayerTrack
        var seen: Double
        var started: Double
        /// The spot both land on, followed on screen from the first throw.
        var mark: GroundMark?
        /// When the first item was thrown, the pull was thrown, and the second grenade was thrown.
        var firstThrow: Double?
        var pulled: Double?
        var secondThrow: Double?
        var shots = 0
    }
    private var combo: Combo?
    private var lastCombo = -Double.infinity
    /// When you last chose a slot yourself.
    private var lastUserSlotChange = -Double.infinity
    /// A lethal grenade of yours on its way, and when it goes off; the app warns you to keep clear.
    public private(set) var liveGrenade: (name: String, explodes: Double)?
    /// A heal with a Healing Grenade or the Healing Gun, for you or a teammate low on health (see `supportStep`).
    private struct Support {
        enum Use: String { case grenade, gun }
        var use: Use
        var slot: Int
        var item: String
        /// The teammate's track, roster name, and where and when they were last seen; no track heals you.
        var target: Int?
        var name: String?
        var seen: Point?
        var lastSeen: Double
        var started: Double
        /// When the grenade was thrown.
        var thrown: Double?
        /// The gun: when it last fired, its first round, and the patient's health with when it last rose.
        var lastShot = -Double.infinity
        var firstShot: Double?
        var health: Double?
        var lastRise: Double?
        /// Since when the gun has waited for a clear line, a settled course, or you to stand still.
        var waitingSince: Double?
        var key: String { Self.key(use, name ?? target.map { "#\($0)" }) }
        static func key(_ use: Use, _ who: String?) -> String { "\(use.rawValue)/\(who ?? "you")" }
    }
    private var support: Support?
    /// Heals with a Healing Grenade or the Healing Gun that came to nothing, by `Support.key`, and when they may be tried again.
    private var supportPaused: [String: Double] = [:]
    /// Your Healing Grenades' circles on the ground, followed on screen: when each opens and closes, and whether it was thrown
    /// for you.
    private struct HealZone { var mark: GroundMark; var opens: Double; var closes: Double; var radius: Double; var rate: Double; var forYou: Bool }
    private var zones: [HealZone] = []
    /// Your own Healing Grenade's circle: seconds until it closes, and whether you stand in it. The app asks you to stay in it.
    public private(set) var healCircle: (seconds: Double, inside: Bool)?

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
        unclearSince = nil; inHandSince = nil; noAmmoUntil = [:]; stacks = [:]; arrivingStack = nil; seenEmpty = []; badge = nil; matchStart = nil
        cooldownUntil = -.infinity; pickupBlockedUntil = [:]; chestBlockedUntil = [:]; interactPresses = [:]; priorWeaponSlot = nil
        band = nil; lastRangeSwitch = -.infinity; lastTargetSeen = -.infinity; healAttempts = []; healPausedUntil = -.infinity
        lastRequested = nil; lastSelection = nil; userChoiceUntil = -.infinity; lootNote = nil; lastIdleRequest = -.infinity
        combo = nil; lastCombo = -.infinity; lastUserSlotChange = -.infinity; liveGrenade = nil
        support = nil; supportPaused = [:]; zones = []; healCircle = nil
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
    /// The healing item being selected or used, nil otherwise: a potion, or the Healing Gun bounced off a wall back to you.
    /// The app asks you to stand still meanwhile.
    public var healingItem: String? {
        if let s = support, s.use == .gun, s.target == nil { return profiles[s.item]?.name ?? s.item }
        guard let id = heal?.item ?? healPlan else { return nil }
        return profiles[id]?.name ?? id
    }
    /// A Healing Grenade or the Healing Gun heals someone below `CombatSettings.lowHealth`; both restore health only.
    private func needsHealing(_ health: Double?) -> Bool { health.map { $0 < settings.lowHealth } ?? false }
    /// Players this far inside a healing circle's edge count as in it.
    static let zoneMargin = 0.02
    /// A heal with a Healing Grenade or the Healing Gun gives up when the item has not come to hand after `supportStartLimit`,
    /// after `supportLimit` in all, or after waiting `supportWait` for a clear line or for you to stand still; the gun also
    /// gives up when its rounds have not raised anyone's health for `gunNoEffect`. A heal given up is not tried again for
    /// `supportPause`.
    static let supportStartLimit = 1.5, supportLimit = 10.0, supportWait = 3.0, gunNoEffect = 1.6, supportPause = 10.0
    /// A Healing Grenade lands where a moving teammate will be this many seconds after the click: its circle opens about a
    /// second later, but it is wide, and a teammate who sees it stops in it.
    static let grenadeLead = 0.3

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
    /// The loadout the assistant works toward: a sniper, an assault rifle and an SMG, then one slot for a utility item
    /// (`isUtility`) or heals, and one for heals. A gun of the class wanted for its range beats any other gun there, so an
    /// SMG replaces a shotgun; within a class, the gun ranking decides.
    static let loadoutClass: [WeaponRole: WeaponClass] = [.long: .sniper, .medium: .ar, .close: .smg]
    static func inLoadout(_ p: ItemProfile) -> Bool { p.role.map { loadoutClass[$0] == p.weaponClass } ?? false }
    /// Worth of a gun for its range: the loadout's class first, then rarity (a Legendary beats an Epic), then `value`.
    static func keep(_ p: ItemProfile) -> Double { (inLoadout(p) ? 1000 : 0) + Double(p.tier) * 100 + value(p) }
    /// Whether a gun replaces one of its range: of the loadout's class when the other is not; of the same class, a higher
    /// rarity wins outright (a Legendary AR beats any Epic AR) and the ranking only decides within one rarity, by
    /// `upgradeMargin`.
    static func better(_ incoming: ItemProfile, than held: ItemProfile) -> Bool {
        if inLoadout(incoming) != inLoadout(held) { return inLoadout(incoming) }
        if incoming.weaponClass == held.weaponClass, incoming.tier != held.tier { return incoming.tier > held.tier }
        return value(incoming) > value(held) + upgradeMargin
    }
    /// Grenades, Reverse Impulses, a Grappling Hook: a throwable the catalog names. The loadout has room for one; the best
    /// by `ItemProfile.power` stays.
    static func isUtility(_ p: ItemProfile) -> Bool { p.kind == .throwable && p.effect != nil }
    /// Score of a weapon for a distance band: class preference, then rarity and how good the gun is for its class. Guns
    /// are first narrowed to the rarest of each class (`rarestOfEachClass`).
    static func bandScore(_ p: ItemProfile, band: WeaponRole) -> Double? {
        preference(p, band: band).map { $0 + Double(p.tier) * 2 + p.edge }
    }
    /// Of one class, only the rarest guns: a Legendary AR is used before any Epic AR, whatever their ranking. A gun with an
    /// empty magazine does not push a loaded one out, so switching still beats reloading mid-fight.
    static func rarestOfEachClass(_ guns: [(InventorySlot, ItemProfile)]) -> [(InventorySlot, ItemProfile)] {
        guns.filter { gun in !guns.contains { $0.1.weaponClass == gun.1.weaponClass && $0.1.tier > gun.1.tier && $0.0.ammo != 0 } }
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
        if let live = liveGrenade, t > live.explodes + 0.3 { liveGrenade = nil }
        followZones(o, now: t)
        if let reason = Policy.haltReason(o, now: t) {
            pending = nil; heal = nil; healPlan = nil; recovery = nil; targetID = nil; lastThreat = t; priorWeaponSlot = nil; band = nil
            healAttempts = []; inHandSince = nil // A halted heal did not fail.
            if combo != nil { combo = nil; lastCombo = t } // What was thrown stays thrown; the rest is off.
            support = nil
            // A slot you press while taking over shows as a change afterwards; a new match does not.
            if !o.manualOverride { lastSelection = nil }
            // A key you press yourself may have added to a stack or drunk from one.
            else { for slot in stacks.keys { stacks[slot]?.known = false } }
            if o.phase == .menu || o.phase == .dead { matchStart = nil }
            return idle(o.timestamp, reason)
        }
        guard o.timestamp > lastFrame else { return idle(o.timestamp, "Awaiting a new frame") }
        lastFrame = o.timestamp
        if matchStart == nil { matchStart = t }
        // A combo's spot moves on screen with you in every frame, also while a slot switch is on its way.
        if var c = combo, var mark = c.mark { mark.follow(o, zoom: viewZoom(o, keeping: mark.zoom)); c.mark = mark; combo = c }
        if lastThreat == nil { lastThreat = t }
        lootNote = nil
        if o.selectedSlotConfidence >= 0.98, let current = o.selectedSlot {
            if let previous = lastSelection, previous != current, !(lastRequested.map { $0.slot == current && t - $0.time <= 2 } ?? false) {
                userChoiceUntil = t + settings.idleUserRespect; lastUserSlotChange = t
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
        if (heal != nil || healPlan != nil || support != nil) && (!features.healing || threatened) {
            heal = nil; healPlan = nil; pending = nil; healAttempts = []; inHandSince = nil; support = nil
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
                usedOne(h.slot, h.item)
                if let item = profiles[h.item], item.overTime > 0 {
                    let gain = HealPlanner.restored(item, health: min(100, h.health + earlier.health), shield: min(100, h.shield + earlier.shield))
                    let seen = min(gained, gain.health + gain.shield)
                    let share = gain.health + gain.shield > 0 ? gain.health / (gain.health + gain.shield) : 0.5
                    arriving.append((h.item, max(0, gain.health - seen * share), max(0, gain.shield - seen * (1 - share)), t, t + item.overTime))
                }
                // A stack left in the borrowed slot is drunk next; what was lent comes back once the slot is empty (never by
                // swapping out the potions left), or not at all after 30 s.
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
                // drink, only another potion or a chest. A combo's switch is part of a fight, and a Healing Grenade's or the
                // Healing Gun's part of a heal that does not wait.
                else if !threatened, combo == nil, support == nil, let decision = takeLoot(o, now: t, safeToHeal: safeToHeal, swapWait: "waiting for slot \(slot)",
                                                             healFirst: healPlan != nil) { return decision }
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
        // A Healing Grenade or the Healing Gun for you or a teammate low on health: one throw or a few rounds, before loot.
        if features.healing, !threatened, let decision = supportStep(o, now: t, safeToHeal: safeToHeal) { return decision }
        let swapWait = healPlan != nil ? "swapping once healed" : t < cooldownUntil ? "waiting for the game to settle" : nil
        // What was lent for a drink is taken back as soon as its slot is drunk empty, while it is still on the panel.
        if !threatened, let decision = takeBack(o, now: t) { return decision }
        // Below full health or shield, healing comes first: a potion on the panel, a chest (one press, often with more),
        // then drinking, then any other loot.
        if !threatened, Policy.belowFull(o) {
            if let decision = takeLoot(o, now: t, safeToHeal: safeToHeal, swapWait: swapWait, healFirst: true) { return decision }
            if features.healing, t >= cooldownUntil, let decision = healing(o, now: t, safeToHeal: safeToHeal) { return decision }
        }
        if !threatened, let decision = takeLoot(o, now: t, safeToHeal: safeToHeal, swapWait: swapWait) { return decision }
        guard t >= cooldownUntil else { return idle(o.timestamp, "Waiting for the game to settle") }
        if threatened { return idle(o.timestamp, holdReason(o) ?? "Threat visible; withholding looting and healing") }

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
        guard t >= userChoiceUntil, heal == nil, healPlan == nil, support == nil, o.selectedSlotConfidence >= 0.98,
              t - (lastThreat ?? t) >= settings.idleQuiet, t - lastPlayerSeen >= settings.idleQuiet,
              t - lastTargetSeen >= settings.idleAfterFight else { return nil }
        let guns = o.inventory.compactMap { slot -> (InventorySlot, ItemProfile)? in
            guard let p = profile(slot), p.kind == .weapon, slot.hasAnyAmmo, noAmmoUntil[slot.index] == nil else { return nil }
            return (slot, p)
        }
        let best = Self.rarestOfEachClass(guns).compactMap { slot, p -> (slot: InventorySlot, item: ItemProfile, score: Double)? in
            guard let score = Self.bandScore(p, band: .long) else { return nil }
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
        guard support == nil else { return nil } // A Healing Grenade or the Healing Gun is in hand.
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
    /// Health and shield still arriving from a hybrid, or from a Healing Grenade's circle you stand in, count as restored already.
    func nextDose(_ o: Observation, now t: Double, continuing: Bool = false) -> (slot: InventorySlot, item: ItemProfile)? {
        guard o.hudConfidence >= 0.98, var health = o.health, var shield = o.shield else { return nil }
        let coming = arrivingTotal(at: t)
        health = min(100, health + coming.health + zoneHealth(o, now: t)); shield = min(100, shield + coming.shield)
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
        // A potion picked up into a borrowed slot is drunk first, so the slot empties and what was lent can be taken back.
        if let r = recovery, r.consumed == nil, let lent = held.first(where: { $0.slot.index == r.slot && $0.item.id == r.consumable }),
           HealPlanner.value(lent.item, health: health, shield: shield, minimumBenefit: thresholds.0) != nil { return lent }
        guard let first = HealPlanner.plan(health: health, shield: shield, stacks: supply, minimumBenefit: thresholds.0, slack: thresholds.1).first else { return nil }
        let holding = held.filter { $0.item.id == first.id }
        return holding.first { $0.slot.index == o.selectedSlot } ?? holding.first
    }

    /// Keeps `stacks` in step with the inventory, for consumables and utility items. A count read off the slot wins. A stack
    /// that appears is the pickup just made, or else one ground stack (not `known`). An emptied or changed slot starts over.
    private func countStacks(_ o: Observation, now t: Double) {
        if let a = arrivingStack, t > a.until { arrivingStack = nil }
        for slot in o.inventory where (2...6).contains(slot.index) && slot.confidence >= 0.98 {
            let wasEmpty = seenEmpty.contains(slot.index)
            if slot.isKnownEmpty { seenEmpty.insert(slot.index) } else { seenEmpty.remove(slot.index) }
            guard let id = slot.itemID, let p = profiles[id], p.kind == .healing || Self.isUtility(p) else { stacks[slot.index] = nil; continue }
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

    /// One of the stack in this slot was used: a dose drunk or a grenade thrown.
    private func usedOne(_ slot: Int, _ item: String) {
        if let held = stacks[slot], held.item == item {
            stacks[slot] = StackCount(item: item, count: max(1, held.count - 1), known: held.known && held.count > 1)
        }
    }

    /// Counts a consumable or utility pickup: into the slot that gained it, else onto the stack of it with room, else into
    /// the slot it shows up in shortly.
    private func countPickup(_ item: String, amount: Int, before: [InventorySlot], in o: Observation, now t: Double) {
        guard let p = profiles[item], p.kind == .healing || Self.isUtility(p) else { return }
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
        // A combo also reaches opponents behind cover: the pull brings them out.
        if let decision = comboStep(o, now: t) { return decision }
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
        let carried = o.inventory.compactMap { slot -> (InventorySlot, ItemProfile)? in
            guard let p = profile(slot), p.kind == .weapon, p.role != nil, slot.hasAnyAmmo else { return nil }
            return (slot, p)
        }
        // Exploding rounds hurt you too: a gun whose round would go off near you (the Assault SCAR on an opponent next to
        // you, or with a tree in the way) is not used on this one.
        let armed = carried.filter { Policy.explosiveSafe(o, weapon: $0.1, toward: target.position, zoom: zoom) }
        var weapons = Self.rarestOfEachClass(armed).compactMap { slot, p -> (InventorySlot, ItemProfile, Double)? in
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
        guard var (slot, p, _) = weapons.first else {
            if let risky = carried.first?.1 { return idle(o.timestamp, "Not firing \(risky.name): its explosion would hit you too") }
            return idle(o.timestamp, "No identified firearm with ammunition")
        }
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
        guard Policy.explosiveSafe(o, weapon: p, toward: aim, zoom: p.zoom) else {
            return Decision(o.timestamp, [.releaseAll, .aim(aim)], "Holding fire: \(p.name)'s explosion would hit you too")
        }
        if !p.automatic && t - lastShot < p.shotInterval { return Decision(o.timestamp, [.releaseAll,.aim(aim)], "Weapon cooldown") }
        lastShot = t
        return Decision(o.timestamp, [.aim(aim),.fire], "Engage enemy at \(band.rawValue) range with \(p.name)")
    }

    /// The view's zoom: the item in hand's. While the selection is unreadable, the last one is kept.
    private func viewZoom(_ o: Observation, keeping last: Double) -> Double {
        o.selectedSlotConfidence >= 0.98 ? (o.selected.flatMap { profile($0) }?.zoom ?? 1) : last
    }

    /// The combos that work on this opponent now, best first, with what you hold.
    private func comboPlans(_ o: Observation, on target: PlayerTrack, now t: Double) -> [Combos.Plan] {
        let held = o.inventory.compactMap { slot -> Combos.Held? in
            guard let p = profile(slot), p.kind != .weapon || noAmmoUntil[slot.index] == nil else { return nil }
            return Combos.Held(slot: slot, item: p)
        }
        let zoom = o.selected.flatMap { profile($0) }?.zoom ?? 1
        return Combos.plans(on: target, in: o, holding: held, inHand: o.selectedSlotConfidence >= 0.98 ? o.selectedSlot : nil, zoom: zoom,
                            settings: settings, now: t)
    }

    /// Starts or carries on a Reverse Impulse combo (see `Combos`). Nil when none is under way or worth starting, and once
    /// one is over, so the fight goes on with guns. Each step checks again that it is still safe and still worth it.
    private func comboStep(_ o: Observation, now t: Double) -> Decision? {
        if combo == nil {
            guard features.combos, heal == nil, healPlan == nil, support == nil, t - lastCombo >= Combos.cooldown, o.selectedSlotConfidence >= 0.98
            else { return nil }
            let enemies = o.players.filter { Policy.validEnemy($0, settings) && $0.motion != nil }
                .sorted { $0.position.distance(to: o.player, aspect: o.aspect) < $1.position.distance(to: o.player, aspect: o.aspect) }
            guard let (target, plan) = enemies.prefix(3).lazy.compactMap({ e in self.comboPlans(o, on: e, now: t).first.map { (e, $0) } }).first
            else { return nil }
            combo = Combo(plan: plan, target: target, seen: t, started: t)
        }
        guard var c = combo else { return nil }
        func end(_ reason: String?) -> Decision? {
            combo = nil; lastCombo = t
            return reason.map { idle(o.timestamp, $0) }
        }
        guard features.combos else { return end(nil) }
        guard let pull = profiles[c.plan.pull], let follow = profiles[c.plan.follow] else { return end(nil) }
        lastTargetSeen = t
        let zoom = viewZoom(o, keeping: c.mark?.zoom ?? 1)
        // The opponent: its track, or an enemy right where it was (a track can be lost and found again).
        if let seen = o.players.first(where: { $0.id == c.plan.target && Policy.validEnemy($0, settings) }) {
            c.target = seen; c.seen = t
        } else if let near = o.players.filter({ Policy.validEnemy($0, settings) })
                    .min(by: { $0.position.distance(to: c.target.position, aspect: o.aspect) < $1.position.distance(to: c.target.position, aspect: o.aspect) }),
                  near.position.distance(to: c.target.position, aspect: o.aspect) <= 0.06 {
            c.target = near; c.seen = t; c.plan.target = near.id
        }
        combo = c
        if lastUserSlotChange > c.started { return end("Combo stopped: you changed slots") }
        if t - c.started > Combos.maxDuration { return end("Combo stopped: it took too long") }
        let latency = settings.leadLatency, margin = Policy.blastMargin
        /// The slot still holds the item, ready to use; selects it when it is not in hand yet.
        func take(_ index: Int, _ item: ItemProfile, reason: String) -> Decision? {
            guard let slot = o.slot(index), profile(slot)?.id == item.id, slot.count > 0,
                  item.kind != .weapon || slot.hasAnyAmmo && (slot.ammo ?? 1) > 0 else { return end("Combo stopped: \(item.name) is not ready in slot \(index)") }
            if o.selectedSlot != index { return select(slot, in: o, now: t, reason: reason) }
            // A readout showing rounds means a gun is in hand: a throwable click would fire it.
            if item.kind == .throwable && o.gunInHand == true { return end("Combo stopped: slot \(index) holds a gun, not \(item.name)") }
            return nil
        }

        guard let firstThrow = c.firstThrow, let mark = c.mark else {
            let first = c.plan.first == follow.id ? follow : pull
            guard t - c.started <= Combos.startLimit else { return end("Combo stopped: \(first.name) never came to hand") }
            guard t - c.seen <= 0.3 else { return end("Combo stopped: lost sight of the opponent") }
            let title: String
            switch c.plan.finisher {
            case .grenade: title = "Rev-nade: \(first.name), then \(first.id == pull.id ? follow.name : pull.name) on the same spot"
            case .gun: title = "Combo: \(pull.name), then \(follow.name) as the opponent lands"
            case .close: title = "Combo: \(pull.name) at your feet, then \(follow.name)"
            }
            if let decision = take(c.plan.firstSlot, first, reason: "\(title): take \(first.name)") { return decision }
            // In hand, plan again: the opponent has moved on, and the throwable's view is the default one.
            guard let fresh = comboPlans(o, on: c.target, now: t).first(where: {
                $0.finisher == c.plan.finisher && $0.pullSlot == c.plan.pullSlot && $0.followSlot == c.plan.followSlot
            }) else { return end("Combo off: no safe spot to throw \(first.name) now") }
            c.plan = fresh; c.firstThrow = t; c.mark = GroundMark(fresh.point, zoom: zoom, time: o.timestamp)
            if first.id == pull.id { c.pulled = t } else { liveGrenade = (follow.name, t + latency + follow.fuse) }
            usedOne(c.plan.firstSlot, first.id)
            combo = c
            return Decision(o.timestamp, [.releaseAll, .throwAt(fresh.point)], title)
        }
        // The click is let go where it was made before anything else.
        if t - max(firstThrow, c.secondThrow ?? -.infinity) < Combos.throwHold { return Decision(o.timestamp, [], "Throwing") }

        switch c.plan.finisher {
        case .grenade:
            // Once both are thrown, the fight goes on with guns while they go off.
            guard c.secondThrow == nil else { return end(nil) }
            let pullFirst = c.plan.gap >= 0
            let item = pullFirst ? follow : pull
            let due = firstThrow + abs(c.plan.gap)
            if t > due + Combos.lateLimit { return end("Rev-nade off: \(item.name) would come too late") }
            if let decision = take(pullFirst ? c.plan.followSlot : c.plan.pullSlot, item, reason: "Rev-nade: take \(item.name)") { return decision }
            if t < due {
                // An opponent clearly getting away from the Frag is fought with guns instead of waited for.
                if !pullFirst, t - c.seen <= 0.3, Combos.predicted(c.target, in: o, after: due - t + latency + pull.fuse, now: t, settings: settings)
                    .distance(to: mark.point, aspect: o.aspect) > 2 * pull.radius * Combos.reach {
                    return end("Rev-nade off: the opponent got away from the \(follow.name)")
                }
                return Decision(o.timestamp, [.releaseAll], "Rev-nade: \(item.name) in \(String(format: "%.1f", due - t)) s")
            }
            if pullFirst {
                // The blast lands where the pull is bringing the opponent; you must be clear of it when it goes off.
                guard o.players.contains(where: { Policy.validEnemy($0, settings) && $0.position.distance(to: mark.point, aspect: o.aspect) <= max(follow.radius, pull.radius) + 0.06 })
                else { return end("Rev-nade off: nobody at the spot") }
                guard Policy.throwSafe(o, item: follow, at: mark.point, settings: settings),
                      (mark.point + Combos.drift(o, after: latency + follow.fuse, settings: settings)).distance(to: o.player, aspect: o.aspect) >= follow.radius + margin
                else { return end("Rev-nade off: \(follow.name) would go off too close to you") }
                liveGrenade = (follow.name, t + latency + follow.fuse)
            } else {
                // The pull must still catch the opponent, and never you: it would drag you into your own blast.
                let pullOff = latency + pull.fuse
                guard t - c.seen <= 0.3 else { return end("Rev-nade off: lost sight of the opponent") }
                guard Combos.predicted(c.target, in: o, after: pullOff, now: t, settings: settings).distance(to: mark.point, aspect: o.aspect)
                        <= pull.radius * Combos.reach, c.target.position.distance(to: mark.point, aspect: o.aspect) <= pull.radius + 0.06
                else { return end("Rev-nade off: the opponent got away from the \(follow.name)") }
                guard Policy.throwSafe(o, item: pull, at: mark.point, settings: settings),
                      (mark.point + Combos.drift(o, after: pullOff, settings: settings)).distance(to: o.player, aspect: o.aspect) >= pull.radius + margin
                else { return end("Rev-nade off: \(pull.name) would pull you into your own \(follow.name)") }
                c.pulled = t
            }
            c.secondThrow = t; combo = c
            usedOne(pullFirst ? c.plan.followSlot : c.plan.pullSlot, item.id)
            return Decision(o.timestamp, [.releaseAll, .throwAt(mark.point)], "Rev-nade: \(item.name) on the spot")
        case .gun, .close:
            guard let pulled = c.pulled else { return end(nil) }
            let arrive = Combos.arrival(thrown: pulled, pull: pull, settings: settings)
            if t > arrive + Combos.window || c.shots > 0 && !follow.automatic { return end(nil) }
            if let decision = take(c.plan.followSlot, follow, reason: "Combo: take \(follow.name) for the pull") { return decision }
            // The opponent landing: an enemy right at the spot once the pull has gone off, else the spot itself.
            var aim = mark.point
            if c.plan.finisher == .gun, t >= arrive - pull.pullDuration,
               let landed = o.players.filter({ $0.affiliation == .enemy }).min(by: {
                   $0.position.distance(to: mark.point, aspect: o.aspect) < $1.position.distance(to: mark.point, aspect: o.aspect) }),
               landed.position.distance(to: mark.point, aspect: o.aspect) <= 0.04 { aim = landed.position }
            // The shot arrives just after the opponent does, and only with an opponent there or on the way.
            let flight = follow.projectileSpeed > 0 ? aim.distance(to: o.player, aspect: o.aspect) * zoom / follow.projectileSpeed : 0
            if t < arrive + Combos.settle - flight - latency {
                return Decision(o.timestamp, [.releaseAll, .aim(aim)], "Combo: \(follow.name) on the spot, waiting for the pull")
            }
            let reach = Policy.pullReach(profiles.values)
            guard o.players.contains(where: { $0.affiliation == .enemy && $0.affiliationConfidence >= settings.minAffiliationConfidence
                                              && $0.position.distance(to: aim, aspect: o.aspect) <= reach }) else {
                return Decision(o.timestamp, [.releaseAll, .aim(aim)], "Combo: \(follow.name) on the spot, no opponent there")
            }
            guard Policy.canFireToward(o, at: aim), Policy.explosiveSafe(o, weapon: follow, toward: aim, zoom: zoom) else {
                return Decision(o.timestamp, [.releaseAll, .aim(aim)], "Combo: holding \(follow.name): the line to the spot is not clear")
            }
            if !follow.automatic && t - lastShot < follow.shotInterval { return Decision(o.timestamp, [.releaseAll, .aim(aim)], "Weapon cooldown") }
            c.shots += 1; combo = c; lastShot = t
            return Decision(o.timestamp, [.aim(aim), .fireAtPull], "Combo: \(follow.name) at the spot as the opponent lands")
        }
    }

    // MARK: Healing Grenades and the Healing Gun

    /// Moves your Healing Grenades' circles with the view, forgets the closed ones, and updates `healCircle`.
    private func followZones(_ o: Observation, now t: Double) {
        zones.removeAll { t >= $0.closes }
        for i in zones.indices { zones[i].mark.follow(o, zoom: viewZoom(o, keeping: zones[i].mark.zoom)) }
        healCircle = zones.filter(\.forYou).max { $0.closes < $1.closes }.map { (max(0, $0.closes - t), covers($0, o.player, o)) }
    }
    private func covers(_ zone: HealZone, _ p: Point, _ o: Observation) -> Bool {
        zone.mark.point.distance(to: p, aspect: o.aspect) <= zone.radius - Self.zoneMargin
    }
    /// Health your Healing Grenades' circles have still to give you, standing where you are.
    private func zoneHealth(_ o: Observation, now t: Double) -> Double {
        zones.filter { covers($0, o.player, o) }.reduce(0) { $0 + $1.rate * max(0, $1.closes - max(t, $1.opens)) }
    }

    /// The heal a Healing Grenade or the Healing Gun gives next, best first:
    /// 1. a grenade at your feet when you are low on health, its circle taking in a low teammate beside you too;
    /// 2. a grenade at the feet of a teammate low on health, where a throw can reach;
    /// 3. the gun at a teammate low on health, in its range with a clear line;
    /// 4. in a safe gap, when you are low on health, the gun square at a wall, which sends its rounds back to you.
    /// Nobody in a circle of yours that still heals is healed again, and a heal that came to nothing waits `supportPause`.
    private func supportPlan(_ o: Observation, now t: Double, safeToHeal: Bool) -> Support? {
        guard o.hudConfidence >= 0.98, let health = o.health else { return nil }
        let grenade = o.inventory.lazy.compactMap { slot -> (InventorySlot, ItemProfile)? in
            guard let p = self.profile(slot), Policy.isHealGrenade(p), slot.count > 0 else { return nil }
            return (slot, p)
        }.first
        let gun = o.inventory.lazy.compactMap { slot -> (InventorySlot, ItemProfile)? in
            guard let p = self.profile(slot), Policy.isHealingGun(p), slot.hasAnyAmmo, (slot.ammo ?? 1) > 0 else { return nil }
            return (slot, p)
        }.first
        guard grenade != nil || gun != nil else { return nil }
        func paused(_ use: Support.Use, _ mate: PlayerTrack?) -> Bool {
            t < supportPaused[Support.key(use, mate.map { $0.name ?? "#\($0.id)" })] ?? -.infinity
        }
        func plan(_ use: Support.Use, _ slot: InventorySlot, _ item: ItemProfile, for mate: PlayerTrack?) -> Support {
            Support(use: use, slot: slot.index, item: item.id, target: mate?.id, name: mate?.name, seen: mate?.position, lastSeen: t, started: t,
                    health: mate?.health ?? health)
        }
        let you = needsHealing(health) && !zones.contains { covers($0, o.player, o) }
        let mates = o.players.filter { mate in
            Policy.validTeammate(mate, settings) && needsHealing(mate.health) && !zones.contains { covers($0, mate.position, o) }
        }.sorted { ($0.health ?? 100) < ($1.health ?? 100) }
        if let (slot, item) = grenade {
            if you, !paused(.grenade, nil) { return plan(.grenade, slot, item, for: nil) }
            if let mate = mates.first(where: { !paused(.grenade, $0) && Policy.throwSafe(o, item: item, at: $0.position, settings: settings) }) {
                return plan(.grenade, slot, item, for: mate)
            }
        }
        if let (slot, item) = gun {
            if let mate = mates.first(where: { !paused(.gun, $0) && $0.position.distance(to: o.player, aspect: o.aspect) <= item.maxRange
                                               && Policy.clearLine(o, to: $0.position, except: $0.id) }) {
                return plan(.gun, slot, item, for: mate)
            }
            if you, safeToHeal, !paused(.gun, nil), Policy.bounceTarget(o) != nil { return plan(.gun, slot, item, for: nil) }
        }
        return nil
    }

    /// Where a Healing Grenade lands: at the teammate's feet, where their motion will have carried them `grenadeLead` after the
    /// click, or at yours. At yours it lands halfway to a teammate beside you who is low on health too, when its circle then
    /// takes in you both; otherwise a step to one side, so the click has a direction.
    private func grenadeSpot(_ o: Observation, _ item: ItemProfile, for mate: PlayerTrack?, now t: Double) -> Point? {
        func safe(_ p: Point) -> Point? { Policy.throwSafe(o, item: item, at: p, settings: settings) ? p : nil }
        if let mate {
            return safe(Combos.predicted(mate, in: o, after: settings.leadLatency + Self.grenadeLead, now: t, settings: settings)) ?? safe(mate.position)
        }
        let reach = item.radius - Self.zoneMargin
        if let buddy = o.players.first(where: { Policy.validTeammate($0, settings) && needsHealing($0.health)
                                                && $0.position.distance(to: o.player, aspect: o.aspect) <= 2 * reach - 0.01 }),
           let spot = safe(o.player + (buddy.position - o.player) * 0.5) { return spot }
        for (dx, dy) in [(0.0, -1.0), (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0)] {
            if let spot = safe(Point(o.player.x + dx * Combos.feetOffset, o.player.y + dy * Combos.feetOffset * o.aspect)) { return spot }
        }
        return nil
    }

    /// Starts or carries on a heal with a Healing Grenade or the Healing Gun (see `supportPlan`); nil when none is under way or
    /// due, and once one is over. A grenade is selected and thrown once. The gun fires a round at a time, leading a moving
    /// teammate, or square at a wall while you stand still, until the patient is within one round of full health; rounds
    /// that raise nobody's health end it. Combat comes first: an opponent in the open or a hit ends any of it at once.
    private func supportStep(_ o: Observation, now t: Double, safeToHeal: Bool) -> Decision? {
        if support == nil {
            guard heal == nil, healPlan == nil, combo == nil, o.selectedSlotConfidence >= 0.98,
                  let plan = supportPlan(o, now: t, safeToHeal: safeToHeal) else { return nil }
            support = plan
        }
        guard var s = support, let item = profiles[s.item] else { support = nil; return nil }
        /// Ends the heal; `pause` keeps it from being tried again at once.
        func end(_ reason: String?, pause: Bool = false) -> Decision? {
            if pause { supportPaused[s.key] = t + Self.supportPause }
            support = nil
            return reason.map { idle(o.timestamp, $0) }
        }
        // The teammate: their track, else the teammate of that name, else one right where they were (tracks are lost and found).
        var mate: PlayerTrack?
        if s.target != nil {
            let mates = o.players.filter { Policy.validTeammate($0, settings) }
            mate = mates.first { $0.id == s.target } ?? s.name.flatMap { name in mates.first { $0.name == name } }
                ?? s.seen.flatMap { seen in
                    mates.min { $0.position.distance(to: seen, aspect: o.aspect) < $1.position.distance(to: seen, aspect: o.aspect) }
                        .flatMap { $0.position.distance(to: seen, aspect: o.aspect) <= 0.06 ? $0 : nil }
                }
            if let mate { s.target = mate.id; s.name = mate.name ?? s.name; s.seen = mate.position; s.lastSeen = t }
            else if t - s.lastSeen > 0.5 { return end(s.thrown == nil ? "Heal stopped: lost sight of \(s.name ?? "your teammate")" : nil) }
        }
        support = s
        let who = s.target == nil ? "you" : s.name ?? "your teammate"
        if lastUserSlotChange > s.started { return end("Heal stopped: you changed slots") }
        if t - s.started > Self.supportLimit { return end("Heal stopped: it took too long", pause: true) }
        /// The slot still holds the item, ready; selects it when it is not in hand yet.
        func take(_ reason: String) -> Decision? {
            guard let slot = o.slot(s.slot), profile(slot)?.id == item.id,
                  item.kind == .weapon ? slot.hasAnyAmmo && (slot.ammo ?? 1) > 0 : slot.count > 0
            else { return end("Heal stopped: \(item.name) is not ready in slot \(s.slot)") }
            if o.selectedSlot != slot.index {
                guard t - s.started <= Self.supportStartLimit else { return end("Heal stopped: \(item.name) never came to hand", pause: true) }
                if let current = o.selected, profile(current).map({ $0.kind == .weapon && $0.role != nil }) ?? false { priorWeaponSlot = current.index }
                return select(slot, in: o, now: t, reason: reason)
            }
            // A readout showing rounds means a gun is in hand: a grenade's click would fire it.
            if item.kind == .throwable && o.gunInHand == true { return end("Heal stopped: slot \(slot.index) holds a gun, not \(item.name)", pause: true) }
            return nil
        }

        switch s.use {
        case .grenade:
            if let thrown = s.thrown {
                // The click is let go where it was made; the gun comes back after that.
                return t - thrown < Combos.throwHold ? Decision(o.timestamp, [], "Throwing \(item.name)") : end(nil)
            }
            if let decision = take(s.target == nil ? "Select \(item.name) to heal you" : "Select \(item.name) to heal \(who)") { return decision }
            guard let spot = grenadeSpot(o, item, for: mate, now: t) else { return end("Heal stopped: nowhere clear to throw \(item.name) for \(who)", pause: true) }
            s.thrown = t; support = s
            usedOne(s.slot, item.id)
            let opens = t + settings.leadLatency + item.fuse
            zones.append(HealZone(mark: GroundMark(spot, zoom: viewZoom(o, keeping: 1), time: o.timestamp), opens: opens, closes: opens + item.overTime,
                                  radius: item.radius, rate: item.healthGain / item.overTime,
                                  forYou: spot.distance(to: o.player, aspect: o.aspect) <= item.radius - Self.zoneMargin))
            let health = s.target == nil ? o.health : mate?.health
            return Decision(o.timestamp, [.releaseAll, .throwAt(spot)],
                            "\(item.name) at \(s.target == nil ? "your" : "\(who)'s") feet" + (health.map { ": health \(Int($0))" } ?? ""))
        case .gun:
            // The patient's health: yours, or the teammate's off their roster row (the last reading while it is unreadable).
            let reading = s.target == nil ? (o.hudConfidence >= 0.98 ? o.health : nil) : mate?.health
            guard let health = reading ?? s.health else { return end("Heal stopped: \(who)'s health is not readable") }
            if health > 100 - item.healthGain { return end(s.firstShot == nil ? nil : s.target == nil ? "Healed with the \(item.name)" : "Healed \(who) with the \(item.name)") }
            if let last = s.health, health > last + 1 { s.lastRise = t }
            s.health = health; support = s
            if let first = s.firstShot, t - (s.lastRise ?? first) > Self.gunNoEffect {
                return end(s.target == nil ? "\(item.name) rounds off the wall are not reaching you; not trying again for \(Int(Self.supportPause)) s"
                                           : "\(item.name) rounds are not reaching \(who); not trying again for \(Int(Self.supportPause)) s", pause: true)
            }
            if let decision = take(s.target == nil ? "Select \(item.name) to heal you off a wall" : "Select \(item.name) to heal \(who)") { return decision }
            /// Aims and waits, for up to `supportWait`.
            func wait(_ reason: String, aim: Point?) -> Decision? {
                let since = s.waitingSince ?? t; s.waitingSince = since; support = s
                if t - since > Self.supportWait { return end("Heal stopped: \(reason.prefix(1).lowercased() + reason.dropFirst())", pause: true) }
                return Decision(o.timestamp, [.releaseAll] + (aim.map { [InputIntent.aim($0)] } ?? []), reason)
            }
            let aim: Point
            if let mate {
                guard let intercept = Targeting.intercept(mate, in: o, weapon: item, now: t, settings: settings, friendly: true) else {
                    return wait("\(who) is out of the \(item.name)'s range", aim: nil)
                }
                guard Policy.clearLine(o, to: intercept.point, except: mate.id) else { return wait("No clear line to \(who)", aim: intercept.point) }
                guard intercept.hitProbability >= item.minHitProbability ?? Policy.minHitProbability else {
                    return wait("\(who)'s course is still uncertain", aim: intercept.point)
                }
                aim = intercept.point
            } else if s.target != nil {
                return Decision(o.timestamp, [.releaseAll], "Looking for \(who)")
            } else {
                guard let wall = Policy.bounceTarget(o) else { return end("Heal stopped: no wall to bounce the \(item.name) off", pause: true) }
                guard Policy.standingStill(o) else { return wait("Stand still: the \(item.name) bounces off the wall back to you", aim: wall) }
                aim = wall
            }
            s.waitingSince = nil; support = s
            if t - s.lastShot < item.shotInterval { return Decision(o.timestamp, [.releaseAll, .aim(aim)], "\(item.name): next round") }
            s.lastShot = t; s.firstShot = s.firstShot ?? t; support = s
            return Decision(o.timestamp, [.aim(aim), .fireHealing],
                            s.target == nil ? "\(item.name) off the wall to heal you: health \(Int(health))" : "\(item.name) at \(who): health \(Int(health))")
        }
    }

    /// Opening a chest or taking an item is one key press, and the loot stays behind once you walk on, so it comes before
    /// heals and settling times: it never changes the selected slot. A swap into a full inventory does change it (the game
    /// swaps out the selected item), so it waits while `swapWait` says why.
    /// - Parameter healFirst: only a potion or a chest, for when drinking comes next.
    private func takeLoot(_ o: Observation, now t: Double, safeToHeal: Bool, swapWait: String?, healFirst: Bool = false) -> Decision? {
        if features.loot, let decision = loot(o, now: t, safeToHeal: safeToHeal, swapWait: swapWait, potionsOnly: healFirst) { return decision }
        if features.chests, let decision = openChest(o, now: t) { return decision }
        return nil
    }

    /// Takes back what was lent for a drink (see `loot`) once its slot is drunk empty: one press into that slot.
    private func takeBack(_ o: Observation, now t: Double) -> Decision? {
        guard let r = recovery, r.consumed != nil else { return nil }
        guard let slot = o.slot(r.slot), slot.isKnownEmpty else { recovery = nil; return idle(o.timestamp, "Recovery slot is no longer empty") }
        guard features.loot, let prompt = Policy.pickupPrompt(o), let id = prompt.itemID, Self.sameItem(id, r.weapon),
              pickupBlockedUntil[prompt.name] == nil else { return nil }
        return pickup(prompt, replacing: nil, in: o, now: t, reason: "Pick up \(prompt.name) again after healing")
    }

    /// Early in the match: within `CombatSettings.earlyGame` of the first frame seen alive.
    private func earlyGame(_ t: Double) -> Bool { matchStart.map { t - $0 < settings.earlyGame } ?? true }

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

    /// Decides on the item the prompt names, read by text recognition ("M4 / Epic AR"), working toward the loadout: a
    /// sniper, an AR and an SMG, one slot for a utility item or heals, one for heals (`loadoutClass`, `isUtility`). A gun is
    /// weighed by its class and then its place in the gun ranking and its rarity (`ItemProfile.power`) against the guns of
    /// its range. What the loadout has no place for (a second gun for a range, utility beyond one) is the first to go.
    private func loot(_ o: Observation, now t: Double, safeToHeal: Bool, swapWait: String?, potionsOnly: Bool = false) -> Decision? {
        guard let prompt = Policy.pickupPrompt(o), let id = prompt.itemID, let incoming = profiles[id], incoming.verified,
              !potionsOnly || incoming.kind == .healing else { return nil }
        func skip(_ why: String) -> Decision? { lootNote = "Not picking up \(incoming.name): \(why)"; return nil }
        func take(replacing slot: InventorySlot? = nil, _ reason: String) -> Decision? {
            if slot != nil, let swapWait { return skip(swapWait) }
            return pickup(prompt, replacing: slot, in: o, now: t, reason: reason)
        }
        func name(_ slot: InventorySlot) -> String { profile(slot)?.name ?? "slot \(slot.index)" }
        func keep(_ slot: InventorySlot) -> Double { Self.keep(profile(slot)!) }
        guard pickupBlockedUntil[prompt.name] == nil else { return skip("just tried") }
        let slots = o.inventory.filter { (2...6).contains($0.index) }
        guard slots.count == 5 else { return skip("inventory not fully read") }
        let empty = slots.filter(\.isKnownEmpty)
        let weapons = slots.filter { profile($0).map { $0.kind == .weapon && $0.role != nil } ?? false }
        let heals = slots.filter { profile($0)?.kind == .healing }
        // The Healing Gun takes one of the slots kept for heals, but it is yours to manage and never makes way.
        let healingGuns = slots.filter { profile($0).map(Policy.isHealingGun) ?? false }
        // Utility items, the one the loadout keeps first.
        let utility = slots.filter { profile($0).map(Self.isUtility) ?? false }.sorted { Self.value(profile($0)!) > Self.value(profile($1)!) }
        let missingRoles = WeaponRole.allCases.filter { role in !weapons.contains { profile($0)?.role == role } }
        // What the loadout has no place for, least needed first: a second gun for a range (the weaker), then utility
        // beyond the one kept. Launchers, bows and items it cannot name are yours to manage and never go.
        let seconds = WeaponRole.allCases.flatMap { role in weapons.filter { profile($0)?.role == role }.sorted { keep($0) > keep($1) }.dropFirst() }
        // A tier C gun is not worth its slot either, unless it is your only gun.
        let tierC = weapons.count > 1 ? weapons.filter { slot in profile(slot)?.rankingTier == "C" && !seconds.contains { $0.index == slot.index } } : []
        let spareGuns = (seconds + tierC).sorted { keep($0) < keep($1) }
        let spare = spareGuns + utility.dropFirst().reversed()
        switch incoming.kind {
        case .weapon:
            guard let role = incoming.role else { return skip("launchers and special weapons stay manual") }
            guard incoming.rankingTier != "C" else { return skip("a tier C gun is not worth picking up") }
            let sameRole = weapons.filter { profile($0)?.role == role }
            if let best = sameRole.max(by: { keep($0) < keep($1) }), let worst = sameRole.min(by: { keep($0) < keep($1) }) {
                guard Self.better(incoming, than: profile(best)!) else { return skip("not better than \(name(best))") }
                return empty.isEmpty ? take(replacing: worst, "Pick up \(incoming.name) in place of \(name(worst))")
                    : take("Pick up \(incoming.name): better than \(name(worst))")
            }
            if !empty.isEmpty { return take("Pick up \(incoming.name) for \(role.rawValue) range") }
            // Full: what the loadout has no place for goes first, then a heal or the utility beyond the slots kept for
            // them, keeping a heal.
            if let victim = spare.first {
                return take(replacing: victim, "Pick up \(incoming.name) for \(role.rawValue) range in place of \(name(victim))")
            }
            if heals.count + healingGuns.count + utility.count > settings.minHealSlots,
               let victim = heals.count > 1 ? heals.min(by: { Policy.healingBenefit(profile($0)!, in: o) < Policy.healingBenefit(profile($1)!, in: o) }) : utility.last {
                return take(replacing: victim, "Pick up \(incoming.name) for \(role.rawValue) range in place of \(name(victim))")
            }
            return skip(slots.contains { $0.confidence < 0.98 } ? "inventory full and some slots unrecognized" : "inventory full")
        case .throwable:
            // The loadout's one utility item: more of it stacks, a better one replaces it, and one goes into a free slot
            // that no missing gun needs.
            let same = utility.filter { $0.itemID == id }
            if let stack = same.first(where: { (stackRoom($0) ?? 0) > 0 }), let held = stacks[stack.index] {
                return take("Pick up \(incoming.name): \(held.count) of \(incoming.maxStack ?? held.count) held")
            }
            if same.contains(where: { stackRoom($0) == nil }) {
                if !empty.isEmpty { return take("Pick up more \(incoming.name)") }
                return skip("its stack may be full, and the inventory is full")
            }
            if !same.isEmpty { return skip("its stack is full") }
            if let kept = utility.first, let weakest = utility.last {
                guard Self.value(incoming) > Self.value(profile(weakest)!) else { return skip("your utility slot holds \(name(kept))") }
                return empty.isEmpty ? take(replacing: weakest, "Pick up \(incoming.name) in place of \(name(weakest))")
                    : take("Pick up \(incoming.name): better than \(name(weakest))")
            }
            if empty.count > missingRoles.count { return take("Pick up \(incoming.name) for your utility slot") }
            if empty.isEmpty, let victim = spareGuns.first {
                return take(replacing: victim, "Pick up \(incoming.name) in place of \(name(victim)), a second gun for its range")
            }
            return skip(empty.isEmpty ? "inventory full" : "keeping free slots for missing guns")
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
            // would swap out the selected item instead, perhaps a gun, so only something the loadout has no place for is
            // selected first.
            if same.contains(where: { stackRoom($0) == nil }) {
                if !empty.isEmpty { return take("Pick up \(incoming.name)" + (urgent ? ": low on health" : "")) }
                if let victim = spare.first { return take(replacing: victim, "Pick up \(incoming.name), or else in place of \(name(victim))") }
                return skip("its stack may be full, and the inventory is full")
            }
            let stacksFull = !same.isEmpty ? "its stack is full; " : ""
            // Keep enough free slots for the weapon roles still missing, unless it helps now and you are low on health, or it
            // is early in the match, when potions are stocked up (guns take back a slot from heals beyond the two kept).
            if empty.count > missingRoles.count { return take("Pick up \(incoming.name)") }
            if urgent, !empty.isEmpty { return take("Pick up \(incoming.name): low on health") }
            if earlyGame(t), !empty.isEmpty { return take("Pick up \(incoming.name): stocking up on heals early") }
            // Full, with something the loadout has no place for: the potion takes its slot for good.
            if empty.isEmpty, let victim = spare.first { return take(replacing: victim, "Pick up \(incoming.name) in place of \(name(victim))") }
            // Full inventory, a quiet moment, and the heal plan would drink all of it now: drink it from a borrowed slot and
            // take back what was lent, so the potions you carry are kept for later.
            if features.healing, safeToHeal, empty.isEmpty, helps {
                // Low on health, a potion that cannot help now goes for good.
                if urgent, let victim = heals.filter({ Policy.healingBenefit(profile($0)!, in: o) < Policy.minHealingBenefit }).min(by: { profile($0)!.keepValue < profile($1)!.keepValue }) {
                    return take(replacing: victim, "Swap \(name(victim)) for \(incoming.name): low on health")
                }
                // Your utility item is lent first, else the gun you would miss least.
                // One lend at a time: the one under way goes on (its slot switch done, the press follows).
                let drunk = HealPlanner.plan(health: o.health ?? 100, shield: o.shield ?? 100, stacks: [HealPlanner.Stack(incoming, count: amount)]).count
                if drunk >= amount, let slot = utility.first ?? weapons.min(by: { keep($0) < keep($1) }), let lent = slot.itemID,
                   recovery.map({ $0.slot == slot.index && $0.consumable == id }) ?? true {
                    if let swapWait { return skip(swapWait) }
                    if recovery == nil { recovery = Recovery(slot: slot.index, weapon: lent, consumable: id, created: t) }
                    return take(replacing: slot, "Swap \(name(slot)) for \(incoming.name) to drink it, then take it back")
                }
            }
            return skip(stacksFull + (empty.isEmpty ? "inventory full" : "keeping free slots for missing guns"))
        default:
            return nil
        }
    }
}
