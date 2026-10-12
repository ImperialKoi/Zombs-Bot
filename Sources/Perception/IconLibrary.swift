import Foundation
import AssistantCore

/// What an inventory icon is, independent of rarity (which comes from the tile color).
public struct ItemIdentity: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case weapon, healing, throwable, melee }
    public var kind: Kind
    public var weaponClass: WeaponClass?
    public var healID: String?
    /// The prompt's item name, e.g. "M4" or "Hybrid Potion".
    public var name: String
    public init(kind: Kind, weaponClass: WeaponClass? = nil, healID: String? = nil, name: String) {
        self.kind = kind; self.weaponClass = weaponClass; self.healID = healID; self.name = name
    }
    /// From an item prompt; nil for anything that is not a recognized item.
    public init?(prompt: InteractionPrompt) {
        switch prompt.kind {
        case .weapon:
            guard let weaponClass = prompt.weaponClass else { return nil }
            self.init(kind: .weapon, weaponClass: weaponClass, name: prompt.name)
        case .healing:
            guard let id = prompt.itemID else { return nil }
            self.init(kind: .healing, healID: id, name: prompt.name)
        case .throwable:
            self.init(kind: .throwable, name: prompt.name)
        case .chest, .other:
            return nil
        }
    }
    /// The catalog ID for this item at a tile's rarity. Light tiles hold common weapons.
    public func itemID(rarity: Rarity?) -> String? {
        switch kind {
        case .weapon: return weaponClass.map { ItemCatalog.weaponID($0, rarity ?? .common) }
        case .healing: return healID
        case .throwable: return ItemCatalog.throwableID
        case .melee: return ItemCatalog.fistsID
        }
    }
}

public struct IconEntry: Codable, Equatable, Sendable {
    public var identity: ItemIdentity
    public var fingerprint: IconFingerprint
    public var samples: Int
}

/// Inventory icons labeled by the pickup prompt that preceded them. Weapons match on outline shape
/// alone, since their colors may change with rarity; other items also match on color.
public final class IconLibrary: @unchecked Sendable {
    public private(set) var entries: [IconEntry] = []
    private let url: URL?
    private let lock = NSLock()
    public private(set) var dirty = false
    public static let matchThreshold = 0.88
    public static let matchMargin = 0.04

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([IconEntry].self, from: data) { entries = saved }
    }
    public init(entries: [IconEntry]) { url = nil; self.entries = entries }

    static func similarity(_ a: IconFingerprint, _ b: IconFingerprint, kind: ItemIdentity.Kind) -> Double {
        let shape = a.shapeSimilarity(b)
        return kind == .weapon ? shape : 0.65 * shape + 0.35 * a.colorSimilarity(b)
    }

    public func match(_ fingerprint: IconFingerprint) -> (identity: ItemIdentity, similarity: Double)? {
        lock.lock(); defer { lock.unlock() }
        var best: [ItemIdentity: Double] = [:]
        for entry in entries {
            let s = Self.similarity(fingerprint, entry.fingerprint, kind: entry.identity.kind)
            best[entry.identity] = max(best[entry.identity] ?? 0, s)
        }
        let ranked = best.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value >= Self.matchThreshold else { return nil }
        // Same class under another name is not a conflict for the decisions that matter.
        if let second = ranked.dropFirst().first(where: { $0.key.kind != top.key.kind || $0.key.weaponClass != top.key.weaponClass || $0.key.healID != top.key.healID }),
           top.value - second.value < Self.matchMargin { return nil }
        return (top.key, top.value)
    }

    /// Adds a labeled icon. Repeated sightings refine the stored fingerprint; an icon already
    /// matched to a different item is left alone rather than relabeled.
    @discardableResult
    public func learn(_ identity: ItemIdentity, _ fingerprint: IconFingerprint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entries.contains(where: { $0.identity.kind != identity.kind || $0.identity.weaponClass != identity.weaponClass || $0.identity.healID != identity.healID ? Self.similarity(fingerprint, $0.fingerprint, kind: $0.identity.kind) >= 0.97 : false }) {
            return false
        }
        if let i = entries.indices.first(where: { entries[$0].identity == identity && Self.similarity(fingerprint, entries[$0].fingerprint, kind: identity.kind) >= 0.93 }) {
            var e = entries[i]
            let n = Float(min(e.samples, 20))
            var outline = zip(e.fingerprint.outline, fingerprint.outline).map { ($0 * n + $1) / (n + 1) }
            let norm = outline.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { outline = outline.map { $0 / norm } }
            var colors = zip(e.fingerprint.colors, fingerprint.colors).map { ($0 * n + $1) / (n + 1) }
            let total = colors.reduce(0, +)
            if total > 0 { colors = colors.map { $0 / total } }
            e.fingerprint = IconFingerprint(outline: outline, colors: colors); e.samples += 1
            entries[i] = e
        } else {
            guard entries.filter({ $0.identity == identity }).count < 6 else { return false }
            entries.append(IconEntry(identity: identity, fingerprint: fingerprint, samples: 1))
        }
        dirty = true
        return true
    }

    public func save() throws {
        lock.lock(); defer { lock.unlock() }
        guard dirty, let url else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
        dirty = false
    }
}
