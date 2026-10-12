import Foundation

/// Rarity as shown by the second prompt line ("Rare AR") and the slot background color.
public enum Rarity: Int, Codable, CaseIterable, Comparable, Sendable {
    case common = 0, uncommon, rare, epic, legendary, mythic
    public static func < (a: Rarity, b: Rarity) -> Bool { a.rawValue < b.rawValue }
    public var name: String { ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic"][rawValue] }
    public init?(word: String) {
        guard let match = Rarity.allCases.first(where: { $0.name.caseInsensitiveCompare(word) == .orderedSame }) else { return nil }
        self = match
    }
}

public enum WeaponClass: String, Codable, CaseIterable, Sendable {
    case shotgun, smg, pistol, ar, lmg, minigun, dmr, sniper, launcher, special
}

/// The four reserve counters above the inventory.
public enum AmmoFamily: String, Codable, CaseIterable, Sendable {
    case small, medium, large, shells
    /// The class assumed for an unidentified weapon that draws this ammunition.
    public var likelyClass: WeaponClass {
        switch self { case .small: return .smg; case .medium: return .ar; case .large: return .sniper; case .shells: return .shotgun }
    }
}

/// Class-level weapon behavior. Values are estimates until measured in game; a zero
/// projectile speed compensates frame age only.
public struct WeaponSpec: Codable, Equatable, Sendable {
    public var weaponClass: WeaponClass
    /// nil: never selected or fired automatically (launchers, special weapons).
    public var role: WeaponRole?
    public var automatic: Bool
    public var shotInterval: Double
    public var reloadDuration: Double
    public var switchDelay: Double
    public var projectileSpeed: Double
    public var maxRange: Double
    public var minHitProbability: Double
    public var ammo: AmmoFamily?
    /// View scale while held (see `ItemProfile.zoom`); nil means the default view.
    public var zoom: Double? = nil
}

public struct HealSpec: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Prompt names (case-insensitive, letters only) that identify this item.
    public var aliases: [String]
    public var healthGain: Double
    public var shieldGain: Double
    public var healthCap: Double
    public var shieldCap: Double
    public var useDuration: Double
    /// Points the item is worth keeping for later (see `HealPlanner`); nil uses a fifth of its gains.
    public var keepValue: Double?
    /// Seconds over which the gains arrive after the drink; nil or 0: at once.
    public var overTime: Double?
    /// What the prompt panel says while the item is in your hand, below "Left Click to Consume".
    public var hints: [String]?
}

/// Items the assistant can recognize. Weapon IDs are `<class>:<rarity>`, e.g. `ar:rare`.
public struct ItemCatalog: Codable, Equatable, Sendable {
    public var weapons: [WeaponSpec]
    public var heals: [HealSpec]
    /// Class phrase of the second prompt line, lowercased ("ar", "assault rifle").
    public var classWords: [String: WeaponClass]
    public var healingWords: [String]
    public var throwableWords: [String]

    public static let fistsID = "fists"
    public static let throwableID = "throwable"

    public static func weaponID(_ weaponClass: WeaponClass, _ rarity: Rarity) -> String {
        "\(weaponClass.rawValue):\(rarity.name.lowercased())"
    }
    public static func parseWeaponID(_ id: String) -> (WeaponClass, Rarity)? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let c = WeaponClass(rawValue: String(parts[0])), let r = Rarity(word: String(parts[1])) else { return nil }
        return (c, r)
    }
    public func weapon(_ weaponClass: WeaponClass) -> WeaponSpec? { weapons.first { $0.weaponClass == weaponClass } }
    public func heal(id: String) -> HealSpec? { heals.first { $0.id == id } }
    /// The consumable whose in-hand hint best matches one of these lines, when the match is clear.
    public func heal(hintLines lines: [String]) -> HealSpec? {
        var scores: [(HealSpec, Double)] = []
        for heal in heals { for hint in heal.hints ?? [] {
            if let best = lines.map({ HUDText.nameSimilarity($0, hint) }).max() { scores.append((heal, best)) }
        } }
        let ranked = scores.sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= 0.85 else { return nil }
        // "Charge shield by 25% up to 50%" and "Charge shields by 50% up to full" share most letters.
        if let second = ranked.first(where: { $0.0.id != top.0.id }), top.1 - second.1 < 0.1 { return nil }
        return top.0
    }
    public func heal(named name: String) -> HealSpec? {
        let key = Self.letters(name)
        guard !key.isEmpty else { return nil }
        return heals.first { heal in ([heal.name] + heal.aliases).contains { Self.letters($0) == key } }
    }
    static func letters(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter }) }

    public func profile(_ id: String) -> ItemProfile? {
        if id == Self.fistsID { var p = ItemProfile(id: id, name: "Fists", kind: .melee); p.verified = true; return p }
        if id == Self.throwableID { var p = ItemProfile(id: id, name: "Throwable", kind: .throwable); p.verified = true; return p }
        if let (weaponClass, rarity) = Self.parseWeaponID(id), let spec = weapon(weaponClass) {
            var p = ItemProfile(id: id, name: "\(rarity.name) \(weaponClass.rawValue.uppercased())", kind: .weapon, role: spec.role)
            p.tier = rarity.rawValue; p.verified = true; p.estimated = true
            p.automatic = spec.automatic; p.shotInterval = spec.shotInterval; p.reloadDuration = spec.reloadDuration
            p.switchDelay = spec.switchDelay; p.projectileSpeed = spec.projectileSpeed; p.maxRange = spec.maxRange
            p.weaponClass = weaponClass; p.rarity = rarity; p.minHitProbability = spec.minHitProbability; p.ammo = spec.ammo
            p.zoom = spec.zoom ?? 1
            return p
        }
        if let heal = heal(id: id) {
            var p = ItemProfile(id: id, name: heal.name, kind: .healing)
            p.verified = true; p.estimated = true
            p.healthGain = heal.healthGain; p.shieldGain = heal.shieldGain; p.healthCap = heal.healthCap
            p.shieldCap = heal.shieldCap; p.useDuration = heal.useDuration
            p.keepValue = heal.keepValue ?? (heal.healthGain + heal.shieldGain) / 5
            p.overTime = heal.overTime ?? 0
            return p
        }
        return nil
    }

    /// Every recognizable item, for the coordinator and the input guard.
    public var profiles: [ItemProfile] {
        var ids = [Self.fistsID, Self.throwableID]
        for spec in weapons { for rarity in Rarity.allCases { ids.append(Self.weaponID(spec.weaponClass, rarity)) } }
        ids += heals.map(\.id)
        return ids.compactMap(profile)
    }

    /// Estimates for the current game, with bullet speeds measured on a 30 fps recording: pistol and minigun bullets
    /// cross about 41 map-grid cells a second, an Epic sniper's 47. The default view is 37.3 cells wide, so bullets fly
    /// about 1.1 view widths a second; a sniper zooms the view out 1.2× (44.8 cells), where its bullet does 1.05.
    /// Automatic guns fire at the predicted point whenever it is in range; single-shot guns wait for a fair chance.
    public static let standard = ItemCatalog(
        weapons: [
            WeaponSpec(weaponClass: .shotgun, role: .close, automatic: false, shotInterval: 0.7, reloadDuration: 2.5, switchDelay: 0.25,
                       projectileSpeed: 1.1, maxRange: 0.22, minHitProbability: 0.15, ammo: .shells),
            WeaponSpec(weaponClass: .smg, role: .close, automatic: true, shotInterval: 0.08, reloadDuration: 1.8, switchDelay: 0.2,
                       projectileSpeed: 1.1, maxRange: 0.35, minHitProbability: 0.01, ammo: .small),
            WeaponSpec(weaponClass: .pistol, role: .medium, automatic: false, shotInterval: 0.22, reloadDuration: 1.5, switchDelay: 0.2,
                       projectileSpeed: 1.1, maxRange: 0.4, minHitProbability: 0.12, ammo: .small),
            WeaponSpec(weaponClass: .ar, role: .medium, automatic: true, shotInterval: 0.11, reloadDuration: 2, switchDelay: 0.25,
                       projectileSpeed: 1.1, maxRange: 0.55, minHitProbability: 0.01, ammo: .medium),
            WeaponSpec(weaponClass: .lmg, role: .medium, automatic: true, shotInterval: 0.09, reloadDuration: 3.5, switchDelay: 0.3,
                       projectileSpeed: 1.1, maxRange: 0.55, minHitProbability: 0.01, ammo: .medium),
            WeaponSpec(weaponClass: .minigun, role: .medium, automatic: true, shotInterval: 0.06, reloadDuration: 4, switchDelay: 0.35,
                       projectileSpeed: 1.1, maxRange: 0.5, minHitProbability: 0.01, ammo: .medium),
            WeaponSpec(weaponClass: .dmr, role: .long, automatic: false, shotInterval: 0.4, reloadDuration: 2.5, switchDelay: 0.25,
                       projectileSpeed: 1.1, maxRange: 0.7, minHitProbability: 0.06, ammo: .large),
            WeaponSpec(weaponClass: .sniper, role: .long, automatic: false, shotInterval: 1.1, reloadDuration: 3, switchDelay: 0.3,
                       projectileSpeed: 1.05, maxRange: 0.8, minHitProbability: 0.06, ammo: .large, zoom: 1.2),
            WeaponSpec(weaponClass: .launcher, role: nil, automatic: false, shotInterval: 1.5, reloadDuration: 3, switchDelay: 0.3,
                       projectileSpeed: 0, maxRange: 0.6, minHitProbability: 0.5, ammo: nil),
            WeaponSpec(weaponClass: .special, role: nil, automatic: false, shotInterval: 0.5, reloadDuration: 2, switchDelay: 0.3,
                       projectileSpeed: 0, maxRange: 0.4, minHitProbability: 0.5, ammo: nil),
        ],
        heals: [
            // Keep values: small shields only work below 50 shield and bandages below 75 health, so they are cheap to spend;
            // hybrids are the only quick health besides bandages, and a med kit is the only full health.
            HealSpec(id: "bandage", name: "Bandage", aliases: ["Bandages"], healthGain: 15, shieldGain: 0, healthCap: 75, shieldCap: 100, useDuration: 2.5, keepValue: 2),
            HealSpec(id: "medkit", name: "Med Kit", aliases: ["Medkit", "Medical Kit"], healthGain: 100, shieldGain: 0, healthCap: 100, shieldCap: 100, useDuration: 6, keepValue: 25,
                     hints: ["Heals to full health"]),
            HealSpec(id: "small_shield", name: "Small Shield", aliases: ["Shield Potion", "Small Shield Potion", "Mini Shield"], healthGain: 0, shieldGain: 25, healthCap: 100, shieldCap: 50, useDuration: 2, keepValue: 2,
                     hints: ["Charge shield by 25% up to 50%"]),
            HealSpec(id: "large_shield", name: "Big Shield", aliases: ["Large Shield", "Big Shield Potion", "Large Shield Potion"], healthGain: 0, shieldGain: 50, healthCap: 100, shieldCap: 100, useDuration: 4, keepValue: 10,
                     hints: ["Charge shields by 50% up to full"]),
            // Drinking takes about 2 s (progress ring on recordings); health and shield then rise about 2.5 points a second.
            HealSpec(id: "hybrid_potion", name: "Hybrid Potion", aliases: [], healthGain: 25, shieldGain: 25, healthCap: 100, shieldCap: 100, useDuration: 2, keepValue: 12,
                     overTime: 10, hints: ["Heals and shields 25% over time"]),
        ],
        classWords: [
            "ar": .ar, "assault rifle": .ar, "rifle": .ar, "burst rifle": .ar,
            "smg": .smg, "submachine gun": .smg,
            "shotgun": .shotgun,
            "sniper": .sniper, "sniper rifle": .sniper, "bolt action": .sniper,
            "dmr": .dmr, "marksman rifle": .dmr,
            "pistol": .pistol, "handgun": .pistol, "revolver": .pistol,
            "lmg": .lmg, "light machine gun": .lmg,
            "minigun": .minigun,
            "rocket launcher": .launcher, "launcher": .launcher, "grenade launcher": .launcher, "rpg": .launcher,
            "crossbow": .special, "bow": .special, "special": .special,
        ],
        healingWords: ["healing", "heal", "consumable", "potion", "shield", "shields", "medical"],
        throwableWords: ["throwable", "throwables", "grenade", "explosive"])
}
