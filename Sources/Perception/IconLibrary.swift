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
    /// The catalog ID for this item at a tile's rarity, naming the gun when the catalog knows it. Light tiles hold
    /// common weapons.
    public func itemID(rarity: Rarity?, catalog: ItemCatalog = .standard) -> String? {
        switch kind {
        case .weapon: return weaponClass.map { catalog.weaponID($0, rarity ?? .common, name: name) }
        case .healing: return healID
        // A throwable is thrown only when its name is known: a Frag taken for a Reverse Impulse would land at your feet.
        case .throwable: return catalog.throwable(named: name)?.id ?? ItemCatalog.throwableID
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
    /// Items of a different kind: another weapon class, another consumable, a throwable against a gun.
    static func otherKind(_ a: ItemIdentity, _ b: ItemIdentity) -> Bool {
        a.kind != b.kind || a.weaponClass != b.weaponClass || a.healID != b.healID
    }
    /// Different items, as far as an icon can tell. Throwables also differ by name: a Reverse Impulse and an Impulse
    /// share a shape, and a Reverse Impulse may be thrown at your feet, where nothing else must land. Names that differ
    /// only in characters text recognition confuses are one item.
    static func differ(_ a: ItemIdentity, _ b: ItemIdentity) -> Bool {
        otherKind(a, b) || a.kind == .throwable && ItemCatalog.shapeKey(a.name) != ItemCatalog.shapeKey(b.name)
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
        let close = ranked.dropFirst().filter { top.value - $0.value < Self.matchMargin }
        if close.contains(where: { Self.otherKind($0.key, top.key) }) { return nil }
        // Another gun of the same class about as close: the class is certain, the gun is not. A name decides how good
        // the gun is, so it is left out rather than guessed. Names that differ only in OCR'd look-alikes are one gun.
        // Likewise a throwable as close to another one stays unnamed, and an unnamed throwable is never thrown.
        if top.key.kind == .weapon || top.key.kind == .throwable,
           close.contains(where: { ItemCatalog.shapeKey($0.key.name) != ItemCatalog.shapeKey(top.key.name) }) {
            var unnamed = top.key; unnamed.name = ""
            return (unnamed, top.value)
        }
        return (top.key, top.value)
    }

    /// Adds a labeled icon. Repeated sightings refine the stored fingerprint; an icon already
    /// matched to a different item is left alone rather than relabeled.
    @discardableResult
    public func learn(_ identity: ItemIdentity, _ fingerprint: IconFingerprint) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entries.contains(where: { Self.differ($0.identity, identity) ? Self.similarity(fingerprint, $0.fingerprint, kind: $0.identity.kind) >= 0.97 : false }) {
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
