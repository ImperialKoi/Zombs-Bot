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
    /// `WeaponModel` power of an average gun of this class at Legendary, for a gun whose name is not recognized.
    public var power: Double? = nil
}

/// A named gun, as its prompt names it ("M4 / Rare AR"). Its stats replace the class estimates where the ZombsRoyale
/// wiki gives them, and its rank is its place in the gun ranking of docs/WEAPONS.md. Power falls 1 point per rank
/// place and changes `rarityStep` points per rarity step from `best`, about what a step adds to a gun's damage.
public struct WeaponModel: Codable, Equatable, Sendable {
    public var id: String
    /// As the prompt shows it.
    public var name: String
    /// Other spellings. Names match ignoring case, spaces, punctuation and Cyrillic look-alike letters.
    public var aliases: [String]?
    public var weaponClass: WeaponClass
    /// Place in the gun ranking, 1 being the best, at `best` rarity.
    public var rank: Int
    /// The best rarity the gun normally drops at; the ranking compares guns at it.
    public var best: Rarity
    // Overrides of the class estimates; nil keeps the class's value.
    public var role: WeaponRole?
    public var automatic: Bool?
    public var shotInterval: Double?
    public var reloadDuration: Double?
    public var ammo: AmmoFamily?
    public var minHitProbability: Double?

    public static let rarityStep = 3.0
    public func power(_ rarity: Rarity) -> Double { Double(101 - rank) + Self.rarityStep * Double(rarity.rawValue - best.rawValue) }
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

/// Items the assistant can recognize. Weapon IDs are `<class>:<rarity>:<model>` for a gun whose name is in `models`,
/// e.g. `ar:rare:m4`, and `<class>:<rarity>` for any other gun of that class.
public struct ItemCatalog: Codable, Equatable, Sendable {
    public var weapons: [WeaponSpec]
    public var models: [WeaponModel]
    public var heals: [HealSpec]
    /// Class phrase of the second prompt line, lowercased ("ar", "assault rifle").
    public var classWords: [String: WeaponClass]
    public var healingWords: [String]
    public var throwableWords: [String]

    public static let fistsID = "fists"
    public static let throwableID = "throwable"

    public static func weaponID(_ weaponClass: WeaponClass, _ rarity: Rarity, model: String? = nil) -> String {
        "\(weaponClass.rawValue):\(rarity.name.lowercased())" + (model.map { ":\($0)" } ?? "")
    }
    /// The ID for a gun the prompt or an icon names: its model's ID when the name is a known gun of that class.
    public func weaponID(_ weaponClass: WeaponClass, _ rarity: Rarity, name: String) -> String {
        Self.weaponID(weaponClass, rarity, model: model(named: name, weaponClass: weaponClass)?.id)
    }
    public static func parseWeaponID(_ id: String) -> (WeaponClass, Rarity)? {
        let parts = id.split(separator: ":")
        guard (2...3).contains(parts.count), let c = WeaponClass(rawValue: String(parts[0])), let r = Rarity(word: String(parts[1])) else { return nil }
        return (c, r)
    }
    /// The model part of a weapon ID, nil for a class-only ID.
    public static func modelID(in id: String) -> String? {
        let parts = id.split(separator: ":")
        return parts.count == 3 && parseWeaponID(id) != nil ? String(parts[2]) : nil
    }
    public func weapon(_ weaponClass: WeaponClass) -> WeaponSpec? { weapons.first { $0.weaponClass == weaponClass } }
    public func model(id: String) -> WeaponModel? { models.first { $0.id == id } }
    /// The gun of this class with this name. Allows one misread letter in a name of five or more letters when no other
    /// gun is that close; shorter names ("M4", "AK", "UMP") must match exactly.
    public func model(named name: String, weaponClass: WeaponClass?) -> WeaponModel? {
        let key = Self.nameKey(name)
        guard !key.isEmpty else { return nil }
        let candidates = models.filter { weaponClass == nil || $0.weaponClass == weaponClass }
        func keys(_ m: WeaponModel) -> [String] { ([m.name] + (m.aliases ?? [])).map(Self.nameKey) }
        if let exact = candidates.first(where: { keys($0).contains(key) }) { return exact }
        guard key.count >= 5 else { return nil }
        let near = candidates.filter { keys($0).contains { HUDText.editDistance($0, key) <= 1 } }
        return near.count == 1 ? near[0] : nil
    }
    /// Lowercased letters and digits, with Cyrillic look-alikes as Latin: "AR-15" is "ar15", and an OCR'd "АК" is "ak".
    public static func nameKey(_ text: String) -> String {
        String(text.map { HUDText.lookalikes[$0] ?? $0 }).lowercased().filter { $0.isLetter || $0.isNumber }
    }
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
            var named: WeaponModel?
            if let modelID = Self.modelID(in: id) {
                guard let m = model(id: modelID), m.weaponClass == weaponClass else { return nil } // A gun this catalog does not have.
                named = m
            }
            var p = ItemProfile(id: id, name: "\(rarity.name) \(named?.name ?? weaponClass.rawValue.uppercased())", kind: .weapon, role: named?.role ?? spec.role)
            p.tier = rarity.rawValue; p.verified = true; p.estimated = true
            p.automatic = named?.automatic ?? spec.automatic; p.shotInterval = named?.shotInterval ?? spec.shotInterval
            p.reloadDuration = named?.reloadDuration ?? spec.reloadDuration
            p.switchDelay = spec.switchDelay; p.projectileSpeed = spec.projectileSpeed; p.maxRange = spec.maxRange
            p.weaponClass = weaponClass; p.rarity = rarity; p.ammo = named?.ammo ?? spec.ammo
            p.minHitProbability = named?.minHitProbability ?? spec.minHitProbability
            p.zoom = spec.zoom ?? 1
            // A gun whose name is not recognized counts as an average one of its class.
            let average = spec.power.map { $0 + WeaponModel.rarityStep * Double(rarity.rawValue - Rarity.legendary.rawValue) }
            p.power = named.map { $0.power(rarity) } ?? average
            if let named, let average { p.edge = named.power(rarity) - average }
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
        for model in models { for rarity in Rarity.allCases { ids.append(Self.weaponID(model.weaponClass, rarity, model: model.id)) } }
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
                       projectileSpeed: 1.1, maxRange: 0.22, minHitProbability: 0.15, ammo: .shells, power: 78),
            WeaponSpec(weaponClass: .smg, role: .close, automatic: true, shotInterval: 0.08, reloadDuration: 1.8, switchDelay: 0.2,
                       projectileSpeed: 1.1, maxRange: 0.35, minHitProbability: 0.01, ammo: .small, power: 90),
            WeaponSpec(weaponClass: .pistol, role: .medium, automatic: false, shotInterval: 0.22, reloadDuration: 1.5, switchDelay: 0.2,
                       projectileSpeed: 1.1, maxRange: 0.4, minHitProbability: 0.12, ammo: .small, power: 76),
            WeaponSpec(weaponClass: .ar, role: .medium, automatic: true, shotInterval: 0.11, reloadDuration: 2, switchDelay: 0.25,
                       projectileSpeed: 1.1, maxRange: 0.55, minHitProbability: 0.01, ammo: .medium, power: 85),
            WeaponSpec(weaponClass: .lmg, role: .medium, automatic: true, shotInterval: 0.09, reloadDuration: 3.5, switchDelay: 0.3,
                       projectileSpeed: 1.1, maxRange: 0.55, minHitProbability: 0.01, ammo: .medium, power: 85),
            WeaponSpec(weaponClass: .minigun, role: .medium, automatic: true, shotInterval: 0.06, reloadDuration: 4, switchDelay: 0.35,
                       projectileSpeed: 1.1, maxRange: 0.5, minHitProbability: 0.01, ammo: .medium, power: 73),
            WeaponSpec(weaponClass: .dmr, role: .long, automatic: false, shotInterval: 0.4, reloadDuration: 2.5, switchDelay: 0.25,
                       projectileSpeed: 1.1, maxRange: 0.7, minHitProbability: 0.06, ammo: .large, power: 79),
            WeaponSpec(weaponClass: .sniper, role: .long, automatic: false, shotInterval: 1.1, reloadDuration: 3, switchDelay: 0.3,
                       projectileSpeed: 1.05, maxRange: 0.8, minHitProbability: 0.06, ammo: .large, zoom: 1.2, power: 79),
            WeaponSpec(weaponClass: .launcher, role: nil, automatic: false, shotInterval: 1.5, reloadDuration: 3, switchDelay: 0.3,
                       projectileSpeed: 0, maxRange: 0.6, minHitProbability: 0.5, ammo: nil),
            WeaponSpec(weaponClass: .special, role: nil, automatic: false, shotInterval: 0.5, reloadDuration: 2, switchDelay: 0.3,
                       projectileSpeed: 0, maxRange: 0.4, minHitProbability: 0.5, ammo: nil),
        ],
        // Ranks, rarities, fire rates (shot interval = 1 / shots per second), reloads and ammunition from the ZombsRoyale
        // wiki, October 2026; see docs/WEAPONS.md. Burst guns keep firing while the button is held, so they count as
        // automatic. Range, bullet speed and zoom stay the class estimates: the wiki only describes them in words.
        models: [
            WeaponModel(id: "scoped_m4", name: "Scoped M4", weaponClass: .ar, rank: 1, best: .mythic, automatic: true, shotInterval: 0.1, reloadDuration: 1.5, ammo: .medium),
            WeaponModel(id: "assault_scar", name: "Assault SCAR", weaponClass: .ar, rank: 2, best: .mythic, automatic: true, shotInterval: 0.083, reloadDuration: 1.5, ammo: .medium),
            WeaponModel(id: "mg36", name: "MG36", weaponClass: .ar, rank: 3, best: .mythic, automatic: true, shotInterval: 0.1, reloadDuration: 1.4, ammo: .medium),
            WeaponModel(id: "m4", name: "M4", weaponClass: .ar, rank: 6, best: .legendary, automatic: true, shotInterval: 0.1, reloadDuration: 1.4, ammo: .medium),
            WeaponModel(id: "xm8", name: "XM8", aliases: ["XM-8"], weaponClass: .ar, rank: 8, best: .mythic, automatic: true, shotInterval: 0.083, reloadDuration: 1.5, ammo: .medium),
            WeaponModel(id: "scar", name: "SCAR", weaponClass: .ar, rank: 13, best: .legendary, automatic: true, shotInterval: 0.14, reloadDuration: 2, ammo: .medium),
            WeaponModel(id: "silenced_ar15", name: "Silenced AR-15", weaponClass: .ar, rank: 14, best: .mythic, automatic: true, shotInterval: 0.11, reloadDuration: 1, ammo: .medium),
            WeaponModel(id: "ar15", name: "AR-15", weaponClass: .ar, rank: 18, best: .legendary, automatic: true, shotInterval: 0.11, reloadDuration: 1.4, ammo: .medium),
            WeaponModel(id: "ak", name: "AK", aliases: ["AK-47"], weaponClass: .ar, rank: 19, best: .legendary, automatic: true, shotInterval: 0.17, reloadDuration: 1.4, ammo: .medium),
            WeaponModel(id: "famas", name: "Famas", weaponClass: .ar, rank: 27, best: .epic, automatic: true, shotInterval: 0.17, reloadDuration: 2.1, ammo: .medium),
            WeaponModel(id: "ump", name: "UMP", weaponClass: .smg, rank: 4, best: .legendary, automatic: true, shotInterval: 0.071, reloadDuration: 1, ammo: .small),
            WeaponModel(id: "vector", name: "Vector", weaponClass: .smg, rank: 5, best: .mythic, automatic: true, shotInterval: 0.042, reloadDuration: 1, ammo: .small),
            WeaponModel(id: "p90", name: "P90", weaponClass: .smg, rank: 9, best: .legendary, automatic: true, shotInterval: 0.045, reloadDuration: 1.7, ammo: .small),
            WeaponModel(id: "mp5", name: "MP5", weaponClass: .smg, rank: 10, best: .legendary, automatic: true, shotInterval: 0.067, reloadDuration: 1, ammo: .small),
            WeaponModel(id: "uzi", name: "Uzi", weaponClass: .smg, rank: 11, best: .legendary, automatic: true, shotInterval: 0.067, reloadDuration: 1, ammo: .small),
            WeaponModel(id: "silenced_smg", name: "Silenced SMG", weaponClass: .smg, rank: 12, best: .epic, automatic: true, shotInterval: 0.067, reloadDuration: 1, ammo: .small),
            WeaponModel(id: "tommy_gun", name: "Tommy Gun", weaponClass: .smg, rank: 26, best: .epic, automatic: true, shotInterval: 0.1, reloadDuration: 1.5, ammo: .medium),
            // Shotguns load one shell at a time; the reload is one shell's.
            WeaponModel(id: "pump_shotgun", name: "Pump Shotgun", aliases: ["Pump"], weaponClass: .shotgun, rank: 16, best: .legendary, shotInterval: 1, reloadDuration: 1.1, ammo: .shells),
            WeaponModel(id: "assault_shotgun", name: "Assault Shotgun", weaponClass: .shotgun, rank: 17, best: .epic, shotInterval: 0.4, reloadDuration: 0.9, ammo: .shells),
            WeaponModel(id: "raid_shotgun", name: "RAID Shotgun", weaponClass: .shotgun, rank: 33, best: .epic, shotInterval: 0.8, reloadDuration: 1.5, ammo: .shells),
            WeaponModel(id: "ksg_shotgun", name: "KSG Shotgun", aliases: ["KSG"], weaponClass: .shotgun, rank: 35, best: .epic, shotInterval: 0.25, reloadDuration: 0.9, ammo: .shells),
            WeaponModel(id: "semi_auto_sniper", name: "Semi-Auto Sniper", aliases: ["Semi-Automatic Sniper"], weaponClass: .sniper, rank: 7, best: .legendary, shotInterval: 0.25, reloadDuration: 1.2, ammo: .large),
            WeaponModel(id: "awp", name: "AWP", weaponClass: .sniper, rank: 15, best: .mythic, shotInterval: 1, reloadDuration: 3.2, ammo: .large),
            WeaponModel(id: "bolt_mk2", name: "Bolt Mk. II Sniper", aliases: ["Bolt Mk II"], weaponClass: .sniper, rank: 20, best: .legendary, shotInterval: 1, reloadDuration: 2.5, ammo: .large),
            WeaponModel(id: "bolt_action_sniper", name: "Bolt-Action Sniper", weaponClass: .sniper, rank: 21, best: .epic, shotInterval: 1, reloadDuration: 2.5, ammo: .large),
            WeaponModel(id: "dragunov", name: "Dragunov", weaponClass: .sniper, rank: 23, best: .mythic, shotInterval: 1.7, reloadDuration: 1.7, ammo: .large),
            // The VSS and the Hunting Rifle keep firing while the button is held.
            WeaponModel(id: "vss", name: "VSS", weaponClass: .sniper, rank: 32, best: .legendary, automatic: true, shotInterval: 0.125, reloadDuration: 1.2, ammo: .small, minHitProbability: 0.01),
            WeaponModel(id: "hunting_rifle", name: "Hunting Rifle", weaponClass: .sniper, rank: 36, best: .epic, automatic: true, shotInterval: 0.25, reloadDuration: 0.9, ammo: .large, minHitProbability: 0.03),
            // Pistols keep their class role, a fallback: in the close or long slot one would only take up space, as the range
            // bands prefer an assault rifle to it.
            WeaponModel(id: "silenced_pistol", name: "Silenced Pistol", weaponClass: .pistol, rank: 24, best: .epic, automatic: true, shotInterval: 0.1, reloadDuration: 1, ammo: .small, minHitProbability: 0.01),
            WeaponModel(id: "dual_berettas", name: "Dual Berettas", aliases: ["Dual Pistols"], weaponClass: .pistol, rank: 25, best: .rare, automatic: true, shotInterval: 0.067, reloadDuration: 1, ammo: .small, minHitProbability: 0.01),
            WeaponModel(id: "deagle", name: "Deagle", aliases: ["Desert Eagle"], weaponClass: .pistol, rank: 31, best: .epic, automatic: false, shotInterval: 0.5, reloadDuration: 1, ammo: .large),
            WeaponModel(id: "glock", name: "Glock", weaponClass: .pistol, rank: 38, best: .uncommon, automatic: true, shotInterval: 0.083, reloadDuration: 1, ammo: .small, minHitProbability: 0.01),
            WeaponModel(id: "p2000", name: "P2000", aliases: ["P2K"], weaponClass: .pistol, rank: 39, best: .uncommon, automatic: true, shotInterval: 0.09, reloadDuration: 1, ammo: .small, minHitProbability: 0.01),
            WeaponModel(id: "minigun", name: "Minigun", weaponClass: .minigun, rank: 28, best: .legendary, automatic: true, shotInterval: 0.045, reloadDuration: 3, ammo: .small),
            // Launchers and bows stay manual; named here for the dashboard.
            WeaponModel(id: "rpg", name: "RPG", weaponClass: .launcher, rank: 30, best: .legendary, ammo: .large),
            WeaponModel(id: "grenade_launcher", name: "Grenade Launcher", weaponClass: .launcher, rank: 37, best: .legendary, ammo: .large),
            WeaponModel(id: "crossbow", name: "Crossbow", weaponClass: .special, rank: 34, best: .mythic, ammo: .large),
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

extension ItemCatalog {
    /// A tuned catalog saved before named guns existed gets the built-in list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weapons = try c.decode([WeaponSpec].self, forKey: .weapons)
        models = try c.decodeIfPresent([WeaponModel].self, forKey: .models) ?? ItemCatalog.standard.models
        heals = try c.decode([HealSpec].self, forKey: .heals)
        classWords = try c.decode([String: WeaponClass].self, forKey: .classWords)
        healingWords = try c.decode([String].self, forKey: .healingWords)
        throwableWords = try c.decode([String].self, forKey: .throwableWords)
    }
}
