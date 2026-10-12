import Foundation
import AssistantCore

/// Keeps track of what each inventory slot holds. Icons are recognized from the library; a slot
/// that changes right after an item prompt was showing takes that prompt's identity, and the icon
/// is learned. Items you rearrange keep their identity, and an unknown selected weapon is placed
/// by the reserve counter its ammunition comes from.
public final class InventoryTracker {
    public enum Source: String, Sendable { case library, pickup, rearranged, ammunition, hint }
    struct SlotState {
        var icon: IconFingerprint?
        var identity: ItemIdentity?
        var source: Source?
        var changedAt: Double
        /// Whether the slot was selected when `icon` was read: the selected tile is drawn larger, with a highlight.
        var selected = false
        /// Since when an ammunition readout has contradicted a consumable identity on the selected slot.
        var conflictSince: Double?
    }
    struct Change { var slot: Int; var time: Double; var icon: IconFingerprint; var prompt: InteractionPrompt? }
    public struct Learned: Sendable { public var slot: Int; public var identity: ItemIdentity; public var time: Double }

    public let library: IconLibrary
    private var states: [Int: SlotState] = [:]
    private var lastItemPrompt: (prompt: InteractionPrompt, seen: Double)?
    private var pending: [Change] = []
    public private(set) var learned: [Learned] = []
    /// Seconds between a slot change and the prompt that named the item.
    public static let promptWindow = 1.5
    /// A pickup is learned only when no other slot changed this close to it.
    public static let isolation = 0.4
    /// Outline similarity that still counts as the same item when a slot gains or loses the selection. Recorded tiles
    /// keep about 0.8–0.88 across the highlight; a consumable and a gun share about 0.5.
    public static let reselectedShape = 0.6
    /// Seconds an ammunition readout must contradict a consumable on the selected slot before that identity is dropped.
    public static let conflictDelay = 0.4

    public init(library: IconLibrary) { self.library = library }
    public func reset() { states = [:]; lastItemPrompt = nil; pending = [] }

    static func sameItem(_ a: IconFingerprint, _ b: IconFingerprint) -> Bool {
        a.shapeSimilarity(b) >= 0.9 && a.colorSimilarity(b) >= 0.7
    }

    /// - Parameters:
    ///   - counts: printed slot numbers read for this frame's pixels (stack size or total ammunition).
    ///   - reserves: reserve counters by index (small, medium, large, shells).
    ///   - held: the consumable the prompt panel says is in your hand ("Left Click to Consume"), if it shows one.
    ///   - gunInHand: whether the ammunition readout shows rounds; nil when it could not be read. Defaults to `readout`.
    public func update(_ hud: HUDSnapshot, prompt: InteractionPrompt?, readout: (loaded: Int, reserve: Int)?,
                       counts: [Int: Int], reserves: [Int: Int], time: Double, held: ItemIdentity? = nil, gunInHand: Bool?? = nil) -> [InventorySlot] {
        let gun: Bool? = gunInHand ?? (readout != nil ? true : nil)
        guard hud.alive, hud.slots.count == 6 else { return [] }
        // Only an item prompt can name what lands in a slot; a chest or door prompt never does.
        if let prompt, prompt.stable, [.weapon, .healing, .throwable].contains(prompt.kind) { lastItemPrompt = (prompt, time) }
        let previous = states
        var changed: [Int] = []
        for reading in hud.slots where reading.index >= 2 {
            guard reading.occupied, let icon = reading.icon else { states[reading.index] = SlotState(changedAt: time); continue }
            let selected = hud.selectedSlot == reading.index
            if let old = previous[reading.index], let oldIcon = old.icon {
                if Self.sameItem(oldIcon, icon) {
                    states[reading.index]?.icon = icon; states[reading.index]?.selected = selected // Follow gradual changes.
                    continue
                }
                // Selecting a slot redraws its tile larger with a highlight. That is the same item, not a pickup: re-identifying
                // it from the library turned selected potions into grenades and pistols, and an unselected hybrid into an AR.
                if old.selected != selected, old.identity != nil, oldIcon.shapeSimilarity(icon) >= Self.reselectedShape {
                    states[reading.index]?.icon = icon; states[reading.index]?.selected = selected
                    continue
                }
            }
            var state = SlotState(icon: icon, changedAt: time, selected: selected)
            if let moved = previous.first(where: { $0.key != reading.index && $0.value.identity != nil && $0.value.icon.map { Self.sameItem($0, icon) } == true }) {
                state.identity = moved.value.identity; state.source = .rearranged
            } else if let match = library.match(icon) {
                state.identity = match.identity; state.source = .library
            }
            states[reading.index] = state
            // A tile that only gained or lost the selection never takes a prompt's name or teaches an icon.
            let toggled = previous[reading.index].map { $0.icon != nil && $0.selected != selected } ?? false
            if !toggled { changed.append(reading.index) }
        }
        let quiet = pending.allSatisfy { time - $0.time >= Self.isolation }
        for slot in changed {
            // Provisionally take the prompt's identity when this is the only change; it is learned once no other slot changes nearby.
            let recent = lastItemPrompt.flatMap { time - $0.seen <= Self.promptWindow ? $0.prompt : nil }
            if changed.count == 1, quiet, let prompt = recent, states[slot]?.source != .rearranged, let identity = ItemIdentity(prompt: prompt),
               states[slot]?.identity.map({ $0.kind == identity.kind && $0.weaponClass == identity.weaponClass && $0.healID == identity.healID }) ?? true {
                states[slot]?.identity = identity; states[slot]?.source = .pickup
            }
            if let icon = states[slot]?.icon { pending.append(Change(slot: slot, time: time, icon: icon, prompt: recent)) }
        }
        // Learn isolated pickups; discard prompt guesses when several slots changed together.
        for change in pending where time - change.time >= Self.isolation {
            let crowded = pending.contains { $0.slot != change.slot && abs($0.time - change.time) < Self.isolation }
            if crowded {
                if states[change.slot]?.source == .pickup { states[change.slot]?.identity = library.match(change.icon)?.identity; states[change.slot]?.source = .library }
            } else if let prompt = change.prompt, let identity = ItemIdentity(prompt: prompt), states[change.slot]?.source == .pickup {
                if library.learn(identity, change.icon) { learned.append(Learned(slot: change.slot, identity: identity, time: time)) }
            }
        }
        pending.removeAll { time - $0.time >= Self.isolation }

        if let selected = hud.selectedSlot, selected >= 2, states[selected]?.icon != nil {
            // An ammunition readout means a gun is in your hand: a consumable or throwable identity there is a misread. An
            // unreadable readout (often, while you walk) neither confirms nor clears the conflict.
            if gun == true, let kind = states[selected]?.identity?.kind, kind == .healing || kind == .throwable {
                let since = states[selected]?.conflictSince ?? time
                states[selected]?.conflictSince = since
                if time - since >= Self.conflictDelay { states[selected]?.identity = nil; states[selected]?.source = nil; states[selected]?.conflictSince = nil }
            } else if gun == false || states[selected]?.identity.map({ $0.kind != .healing && $0.kind != .throwable }) ?? true {
                states[selected]?.conflictSince = nil
            }
            // The panel names the consumable in your hand. It never relabels a gun: only an unknown slot, or one whose
            // consumable or throwable label disagrees, and never while the readout shows rounds.
            if let held, gun != true, let state = states[selected],
               state.identity == nil || ((state.identity!.kind == .healing || state.identity!.kind == .throwable) && state.identity!.healID != held.healID) {
                states[selected]?.identity = held; states[selected]?.source = .hint
            }
        }

        // An unidentified selected weapon is placed by its ammunition.
        if let selected = hud.selectedSlot, selected >= 2, var state = states[selected], state.icon != nil, state.identity == nil,
           let readout, readout.reserve > 0 {
            let families = reserves.filter { $0.value == readout.reserve }.map(\.key)
            if families.count == 1, let family = AmmoFamily.allCases[safe: families[0]] {
                state.identity = ItemIdentity(kind: .weapon, weaponClass: family.likelyClass, name: "")
                state.source = .ammunition
                states[selected] = state
            }
        }

        return hud.slots.map { reading in
            if reading.index == 1 { return InventorySlot(1, itemID: ItemCatalog.fistsID, count: 1, label: "Melee", confidence: 1) }
            guard reading.occupied else { return InventorySlot(reading.index, count: 0, confidence: 1) }
            guard let state = states[reading.index], let identity = state.identity,
                  let itemID = identity.itemID(rarity: reading.rarity) else {
                return InventorySlot(reading.index, count: counts[reading.index] ?? 1, rarity: reading.rarity, confidence: 0.5)
            }
            var slot = InventorySlot(reading.index, itemID: itemID, count: 1, rarity: identity.kind == .weapon ? (reading.rarity ?? .common) : reading.rarity,
                                     label: identity.name.isEmpty ? nil : identity.name, confidence: state.source == .ammunition ? 0.98 : 1)
            switch identity.kind {
            case .weapon:
                slot.totalAmmo = counts[reading.index]
                if reading.index == hud.selectedSlot, let readout { slot.ammo = readout.loaded; slot.reserveAmmo = readout.reserve }
            case .healing, .throwable:
                // Stacks are small; a larger number is a misread that included part of the icon.
                slot.count = counts[reading.index].flatMap { (1...30).contains($0) ? $0 : nil } ?? 1
            case .melee:
                break
            }
            return slot
        }
    }

    /// Diagnostics: where each slot's identity came from.
    public func source(of slot: Int) -> Source? { states[slot]?.source }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
