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
    /// See `ItemProfile`: an exploding round's radius, a bouncing round's delay, and overrides of the class's bullet
    /// speed, zoom and range for launchers and bows, whose rounds and views differ from the rest of their class.
    public var radius: Double?
    public var fuse: Double?
    public var projectileSpeed: Double?
    public var zoom: Double?
    public var maxRange: Double?
    /// Health each round restores to whoever it hits, instead of damage (the Healing Gun).
    public var healthGain: Double?

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
    /// Most a slot holds, and how many one ground stack holds. nil: not known, so a full stack cannot be ruled out.
    public var maxStack: Int?
    public var groundStack: Int?
}

/// A grenade or other throwable, as its prompt names it ("Frag Grenade"), or another utility item (the Grappling Hook).
/// The game throws it to where you click, and it goes off `fuse` seconds after the throw (it cannot be cooked). Distances
/// are in the default view's widths; see `ItemProfile` for each field.
public struct ThrowableSpec: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Other spellings, matched like gun names.
    public var aliases: [String]?
    public var effect: ThrowableEffect
    public var fuse: Double
    public var radius: Double
    public var damage: Double
    public var throwRange: Double
    /// Seconds between two throws.
    public var throwInterval: Double
    public var pullDuration: Double?
    public var maxStack: Int?
    public var groundStack: Int?
    /// Worth in the loadout's one utility slot (`ItemProfile.power`): the Reverse Impulse, which starts combos, most.
    public var power: Double?
    /// Healing throwables: health restored to someone inside the circle the whole time, and the seconds it heals for.
    public var healthGain: Double?
    public var duration: Double?
}

/// Items the assistant can recognize. Weapon IDs are `<class>:<rarity>:<model>` for a gun whose name is in `models`,
/// e.g. `ar:rare:m4`, and `<class>:<rarity>` for any other gun of that class.
public struct ItemCatalog: Codable, Equatable, Sendable {
    public var weapons: [WeaponSpec]
    public var models: [WeaponModel]
    public var heals: [HealSpec]
    public var throwables: [ThrowableSpec]
    /// Class phrase of the second prompt line, lowercased ("ar", "assault rifle").
    public var classWords: [String: WeaponClass]
    public var healingWords: [String]
    public var throwableWords: [String]

    public static let fistsID = "fists"
    /// A throwable whose name is not known: never thrown.
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
    /// The gun of this class with the name text recognition read from the prompt. The read may confuse look-alike
    /// characters ("MPS" for "MP5", "Uzl" for "Uzi", see `shapeKey`) or carry a stray mark beside the name ("KSG Shotgun
    /// Z"); a name of five or more letters may also have one other letter wrong. Each step takes a gun only when no other
    /// gun of the class matches as well, and nothing else is guessed: a short name one letter off ("M5") names no gun.
    public func model(named name: String, weaponClass: WeaponClass?) -> WeaponModel? {
        let candidates = models.filter { weaponClass == nil || $0.weaponClass == weaponClass }
        func keys(_ m: WeaponModel) -> [String] { ([m.name] + (m.aliases ?? [])).map(Self.nameKey) }
        func unique(_ found: [WeaponModel]) -> WeaponModel? { Set(found.map(\.id)).count == 1 ? found[0] : nil }
        var words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        while words.count > 1, Self.nameKey(words.last!).count <= 1 { words.removeLast() }
        while words.count > 1, Self.nameKey(words.first!).count <= 1 { words.removeFirst() }
        let whole = Self.nameKey(name), trimmed = Self.nameKey(words.joined())
        let readings = (trimmed == whole ? [whole] : [whole, trimmed]).filter { !$0.isEmpty }
        for key in readings { if let m = unique(candidates.filter { keys($0).contains(key) }) { return m } }
        for key in readings.map(Self.shapeKey) {
            if let m = unique(candidates.filter { keys($0).map(Self.shapeKey).contains(key) }) { return m }
        }
        for key in readings.map(Self.shapeKey) where key.count >= 5 {
            if let m = unique(candidates.filter { keys($0).contains { HUDText.editDistance(Self.shapeKey($0), key) <= 1 } }) { return m }
        }
        return nil
    }
    /// Lowercased letters and digits without accents, with Cyrillic look-alikes as Latin: "AR-15" is "ar15", and an
    /// OCR'd "АК" is "ak" and "Üzi" is "uzi".
    public static func nameKey(_ text: String) -> String {
        String(text.map { HUDText.lookalikes[$0] ?? $0 }).folding(options: .diacriticInsensitive, locale: nil).lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
    /// `nameKey` with the characters text recognition confuses in the prompt's font made one: o and 0, i, l and 1, s and
    /// 5, b and 8, z and 2, g and 6, vv and w. "MPS" and "MP5" share a shape key; no two guns of a class do.
    public static func shapeKey(_ text: String) -> String {
        let same: [Character: Character] = ["o": "0", "i": "1", "l": "1", "s": "5", "b": "8", "z": "2", "g": "6"]
        return String(nameKey(text).replacingOccurrences(of: "vv", with: "w").map { same[$0] ?? $0 })
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
    public func throwable(id: String) -> ThrowableSpec? { throwables.first { $0.id == id } }
    /// The throwable a prompt or icon names. Like gun names, look-alike characters match, and a name of eight or more
    /// letters may have one other letter wrong, each only when no other throwable matches as well. A Reverse Impulse is
    /// never taken for an Impulse: their names differ by a whole word.
    public func throwable(named name: String) -> ThrowableSpec? {
        func keys(_ t: ThrowableSpec) -> [String] { ([t.name] + (t.aliases ?? [])).map(Self.nameKey) }
        func unique(_ found: [ThrowableSpec]) -> ThrowableSpec? { Set(found.map(\.id)).count == 1 ? found[0] : nil }
        let key = Self.nameKey(name), shape = Self.shapeKey(name)
        guard !key.isEmpty else { return nil }
        if let t = unique(throwables.filter { keys($0).contains(key) }) { return t }
        if let t = unique(throwables.filter { keys($0).map(Self.shapeKey).contains(shape) }) { return t }
        guard shape.count >= 8 else { return nil }
        return unique(throwables.filter { keys($0).contains { HUDText.editDistance(Self.shapeKey($0), shape) <= 1 } })
    }
    static func letters(_ text: String) -> String { String(text.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter { $0.isLetter }) }

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
            p.switchDelay = spec.switchDelay; p.projectileSpeed = named?.projectileSpeed ?? spec.projectileSpeed
            p.maxRange = named?.maxRange ?? spec.maxRange
            p.weaponClass = weaponClass; p.rarity = rarity; p.ammo = named?.ammo ?? spec.ammo
            p.minHitProbability = named?.minHitProbability ?? spec.minHitProbability
            p.zoom = named?.zoom ?? spec.zoom ?? 1
            p.radius = named?.radius ?? 0; p.fuse = named?.fuse ?? 0; p.healthGain = named?.healthGain ?? 0
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
            p.maxStack = heal.maxStack; p.groundStack = heal.groundStack
            return p
        }
        if let spec = throwable(id: id) {
            var p = ItemProfile(id: id, name: spec.name, kind: .throwable)
            p.verified = true; p.estimated = true
            p.effect = spec.effect; p.fuse = spec.fuse; p.radius = spec.radius; p.damage = spec.damage
            p.throwRange = spec.throwRange; p.shotInterval = spec.throwInterval; p.pullDuration = spec.pullDuration ?? 0
            p.maxStack = spec.maxStack; p.groundStack = spec.groundStack; p.power = spec.power
            p.healthGain = spec.healthGain ?? 0; p.overTime = spec.duration ?? 0
            return p
        }
        return nil
    }

    /// Every recognizable item, for the coordinator and the input guard.
    public var profiles: [ItemProfile] {
        var ids = [Self.fistsID, Self.throwableID]
        for spec in weapons { for rarity in Rarity.allCases { ids.append(Self.weaponID(spec.weaponClass, rarity)) } }
        for model in models { for rarity in Rarity.allCases { ids.append(Self.weaponID(model.weaponClass, rarity, model: model.id)) } }
        ids += heals.map(\.id) + throwables.map(\.id)
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
            // Every sixth round explodes, hurting you too when what it hits is close (radius estimated).
            WeaponModel(id: "assault_scar", name: "Assault SCAR", weaponClass: .ar, rank: 2, best: .mythic, automatic: true, shotInterval: 0.083, reloadDuration: 1.5, ammo: .medium,
                        radius: 0.035),
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
            // Launchers and bows are never picked up or used in an ordinary fight; one you carry finishes a Reverse Impulse
            // combo (see `Combos`). A rocket or present explodes on the first thing it hits, hurting you too when that is
            // close. The Grenade Launcher's grenades bounce around before they go off, so it is never fired. Rocket and
            // arrow speeds, explosion radii and the bows' zoom (the wiki: an AWP's view) are estimates.
            WeaponModel(id: "rpg", name: "RPG", aliases: ["Rocket Launcher"], weaponClass: .launcher, rank: 30, best: .legendary, shotInterval: 1, reloadDuration: 1, ammo: .large,
                        radius: 0.07, projectileSpeed: 0.5),
            WeaponModel(id: "grenade_launcher", name: "Grenade Launcher", weaponClass: .launcher, rank: 37, best: .legendary, shotInterval: 0.5, reloadDuration: 0.7, ammo: .large,
                        radius: 0.06, fuse: 1, projectileSpeed: 0.7),
            WeaponModel(id: "gift_launcher", name: "Gift Launcher", weaponClass: .launcher, rank: 40, best: .legendary, automatic: true, shotInterval: 0.25, reloadDuration: 1, ammo: .large,
                        radius: 0.04, projectileSpeed: 0.8),
            WeaponModel(id: "xbow", name: "XBow", aliases: ["X-Bow"], weaponClass: .special, rank: 22, best: .mythic, shotInterval: 1.6, reloadDuration: 1.6, ammo: .large,
                        projectileSpeed: 0.75, zoom: 1.2, maxRange: 0.8),
            WeaponModel(id: "crossbow", name: "Crossbow", weaponClass: .special, rank: 34, best: .mythic, shotInterval: 1.6, reloadDuration: 1.6, ammo: .large,
                        projectileSpeed: 0.75, zoom: 1.2, maxRange: 0.8),
            // Its rounds heal whoever they hit, 12 health each and no shield, and hurt nobody. They bounce off walls: fired square
            // at one, a round comes straight back and heals you. 8 rounds, no reload. It is never fired in a fight, only to heal
            // (see `Coordinator`), and stays below every gun in the ranking. The wiki says only that its fire rate was lowered in
            // 2021; the rate, bullet speed and range here are estimates, and it is clicked once per round.
            WeaponModel(id: "healing_gun", name: "Healing Gun", aliases: ["Healing Weapon"], weaponClass: .special, rank: 43, best: .epic,
                        automatic: false, shotInterval: 0.5, reloadDuration: 1, minHitProbability: 0.15, projectileSpeed: 1.1, maxRange: 0.45,
                        healthGain: 12),
        ],
        heals: [
            // Keep values: small shields only work below 50 shield and bandages below 75 health, so they are cheap to spend;
            // hybrids are the only quick health besides bandages, and a med kit is the only full health.
            // Use times and stacks are the ZombsRoyale wiki's (October 2026); its 2 s for small shields and hybrids matches the
            // progress ring on recordings. Ground stacks of 2 show an "x2" badge on the panel; a big shield has none.
            HealSpec(id: "bandage", name: "Bandage", aliases: ["Bandages"], healthGain: 15, shieldGain: 0, healthCap: 75, shieldCap: 100, useDuration: 2.2, keepValue: 2,
                     maxStack: 8, groundStack: 8),
            HealSpec(id: "medkit", name: "Med Kit", aliases: ["Medkit", "Medical Kit"], healthGain: 100, shieldGain: 0, healthCap: 100, shieldCap: 100, useDuration: 5, keepValue: 25,
                     hints: ["Heals to full health"], maxStack: 2, groundStack: 1),
            HealSpec(id: "small_shield", name: "Small Shield", aliases: ["Shield Potion", "Small Shield Potion", "Mini Shield"], healthGain: 0, shieldGain: 25, healthCap: 100, shieldCap: 50, useDuration: 2, keepValue: 2,
                     hints: ["Charge shield by 25% up to 50%"], maxStack: 4, groundStack: 2),
            HealSpec(id: "large_shield", name: "Big Shield", aliases: ["Large Shield", "Big Shield Potion", "Large Shield Potion"], healthGain: 0, shieldGain: 50, healthCap: 100, shieldCap: 100, useDuration: 5, keepValue: 10,
                     hints: ["Charge shields by 50% up to full"], maxStack: 2, groundStack: 1),
            // Health and shield rise about 2.5 points a second after the drink. A second hybrid during those 10 s is wasted
            // (the wiki: the effect does not stack).
            HealSpec(id: "hybrid_potion", name: "Hybrid Potion", aliases: [], healthGain: 25, shieldGain: 25, healthCap: 100, shieldCap: 100, useDuration: 2, keepValue: 12,
                     overTime: 10, hints: ["Heals and shields 25% over time"], maxStack: 4, groundStack: 2),
        ],
        // Fuses and damage from the ZombsRoyale wiki (October 2026): a Frag goes off about 2 s after the throw, an RGD-5 and
        // an Impulse about 0.5 s; the Reverse Impulse is taken to be as quick as the Impulse, as the wiki's combos imply
        // (Frag first, then the Reverse Impulse; Reverse Impulse first, then the RGD-5). Stacks from docs/WEAPONS.md. Blast and
        // pull radii, throw ranges, intervals and how long a pull takes are estimates to check in play. Only pulls, blasts and
        // Healing Grenades, which land where you click, are ever thrown: a Sticky Bomb flies until it hits something, a Cactus
        // Bomb bursts into bouncing thorns, and the rest do not combine.
        throwables: [
            ThrowableSpec(id: "frag_grenade", name: "Frag Grenade", aliases: ["Frag"], effect: .blast, fuse: 2, radius: 0.08, damage: 83,
                          throwRange: 0.4, throwInterval: 1, maxStack: 9, groundStack: 3, power: 8),
            ThrowableSpec(id: "rgd5_grenade", name: "RGD-5 Grenade", aliases: ["RGD-5", "RGD5 Grenade"], effect: .blast, fuse: 0.5, radius: 0.065, damage: 40,
                          throwRange: 0.45, throwInterval: 0.5, maxStack: 10, groundStack: 5, power: 7),
            // The prompt says "Reverse Impulse / Common Grenade".
            ThrowableSpec(id: "reverse_impulse_grenade", name: "Reverse Impulse", aliases: ["Reverse Impulse Grenade"], effect: .pull, fuse: 0.5, radius: 0.09,
                          damage: 0, throwRange: 0.4, throwInterval: 1, pullDuration: 0.3, maxStack: 9, groundStack: 3, power: 10),
            ThrowableSpec(id: "impulse_grenade", name: "Impulse Grenade", effect: .push, fuse: 0.5, radius: 0.09, damage: 0,
                          throwRange: 0.4, throwInterval: 1, maxStack: 9, groundStack: 3, power: 5),
            ThrowableSpec(id: "sticky_bomb", name: "Sticky Bomb", effect: .other, fuse: 2, radius: 0.07, damage: 50, throwRange: 0, throwInterval: 1, maxStack: 9, groundStack: 3, power: 6),
            ThrowableSpec(id: "cactus_bomb", name: "Cactus Bomb", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 1, maxStack: 9, groundStack: 3, power: 5),
            ThrowableSpec(id: "gassy_grenade", name: "Gassy Grenade", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 1, maxStack: 9, groundStack: 3, power: 4),
            ThrowableSpec(id: "incendiary_grenade", name: "Incendiary Grenade", aliases: ["Fire Grenade"], effect: .other, fuse: 0, radius: 0, damage: 0,
                          throwRange: 0, throwInterval: 1, maxStack: 9, groundStack: 3, power: 4),
            ThrowableSpec(id: "smoke_grenade", name: "Smoke Grenade", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 1, maxStack: 9, groundStack: 3, power: 3),
            ThrowableSpec(id: "freeze_grenade", name: "Freeze Grenade", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 1, maxStack: 3, groundStack: 3, power: 4),
            ThrowableSpec(id: "snowman_grenade", name: "Snowman Grenade", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 1, maxStack: 6, groundStack: 3, power: 3),
            // Measured on a recorded Duo match (October 2026): it lies on the ground for about a second, then a circle 0.118 view
            // widths in radius heals everyone of your team inside it for 4.5 s, health only, +5 about four times a second (some 20
            // a second); never opponents. The fuse is an estimate between 0.9 and 1.8 s.
            ThrowableSpec(id: "healing_grenade", name: "Healing Grenade", aliases: ["Heal Grenade"], effect: .heal, fuse: 1.2, radius: 0.118, damage: 0,
                          throwRange: 0.4, throwInterval: 1, maxStack: 6, groundStack: 2, power: 4, healthGain: 90, duration: 4.5),
            ThrowableSpec(id: "shuriken", name: "Shuriken", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 0.5, maxStack: 90, groundStack: 30, power: 2),
            ThrowableSpec(id: "snowball", name: "Snowball", effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 0.5, maxStack: 30, groundStack: 6, power: 1),
            // Fired, not thrown, and never used by the assistant; it rides in the utility slot ("Grappling Hook / Legendary
            // Unique", with its uses as the badge).
            ThrowableSpec(id: "grappling_hook", name: "Grappling Hook", aliases: ["Grapple Hook"], effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0,
                          throwInterval: 1, maxStack: 1, groundStack: 1, power: 6),
            // A flare that calls in explosions, "Airstrike / Legendary Grenade" on the prompt.
            ThrowableSpec(id: "airstrike", name: "Airstrike", aliases: ["Airstrike Gun"], effect: .other, fuse: 0, radius: 0, damage: 0, throwRange: 0, throwInterval: 1,
                          maxStack: nil, groundStack: 5, power: 5),
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
    /// A tuned catalog saved before named guns or throwables existed gets the built-in lists.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weapons = try c.decode([WeaponSpec].self, forKey: .weapons)
        models = try c.decodeIfPresent([WeaponModel].self, forKey: .models) ?? ItemCatalog.standard.models
        heals = try c.decode([HealSpec].self, forKey: .heals)
        throwables = try c.decodeIfPresent([ThrowableSpec].self, forKey: .throwables) ?? ItemCatalog.standard.throwables
        classWords = try c.decode([String: WeaponClass].self, forKey: .classWords)
        healingWords = try c.decode([String].self, forKey: .healingWords)
        throwableWords = try c.decode([String].self, forKey: .throwableWords)
    }
}
