import Foundation

public enum GameMode: String, Codable, CaseIterable, Sendable { case solo, duo, squad }
public enum MatchPhase: String, Codable, Sendable { case unknown, menu, alive, downed, dead }
public enum Affiliation: String, Codable, Sendable { case enemy, teammate, unknown }
public enum ItemKind: String, Codable, Sendable { case weapon, healing, melee, throwable }
public enum WeaponRole: String, Codable, CaseIterable, Sendable { case close, medium, long }

public struct ItemProfile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ItemKind
    public var role: WeaponRole?
    public var tier: Int = 0
    /// Approved for automation.
    public var verified: Bool = false
    /// Catalog defaults that have not been measured in game.
    public var estimated: Bool = false
    public var automatic: Bool = false
    public var shotInterval: Double = 0.2
    public var reloadDuration: Double = 2
    public var switchDelay: Double = 0.2
    public var projectileSpeed: Double = 0 // viewport widths / second; 0 means frame-age compensation only
    public var minRange: Double = 0
    public var maxRange: Double = 0.75
    public var healthGain: Double = 0
    public var shieldGain: Double = 0
    public var healthCap: Double = 100
    public var shieldCap: Double = 100
    public var useDuration: Double = 0
    public var weaponClass: WeaponClass?
    public var rarity: Rarity?
    /// Fire only above this estimated hit chance; nil uses `Policy.minHitProbability`.
    public var minHitProbability: Double?
    public var ammo: AmmoFamily?
    public init(id: String, name: String, kind: ItemKind, role: WeaponRole? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.role = role
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(ItemKind.self, forKey: .kind); role = try c.decodeIfPresent(WeaponRole.self, forKey: .role)
        tier = try c.decodeIfPresent(Int.self, forKey: .tier) ?? 0
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        estimated = try c.decodeIfPresent(Bool.self, forKey: .estimated) ?? false
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        shotInterval = try c.decodeIfPresent(Double.self, forKey: .shotInterval) ?? 0.2
        reloadDuration = try c.decodeIfPresent(Double.self, forKey: .reloadDuration) ?? 2
        switchDelay = try c.decodeIfPresent(Double.self, forKey: .switchDelay) ?? 0.2
        projectileSpeed = try c.decodeIfPresent(Double.self, forKey: .projectileSpeed) ?? 0
        minRange = try c.decodeIfPresent(Double.self, forKey: .minRange) ?? 0
        maxRange = try c.decodeIfPresent(Double.self, forKey: .maxRange) ?? 0.75
        healthGain = try c.decodeIfPresent(Double.self, forKey: .healthGain) ?? 0
        shieldGain = try c.decodeIfPresent(Double.self, forKey: .shieldGain) ?? 0
        healthCap = try c.decodeIfPresent(Double.self, forKey: .healthCap) ?? 100
        shieldCap = try c.decodeIfPresent(Double.self, forKey: .shieldCap) ?? 100
        useDuration = try c.decodeIfPresent(Double.self, forKey: .useDuration) ?? 0
        weaponClass = try c.decodeIfPresent(WeaponClass.self, forKey: .weaponClass)
        rarity = try c.decodeIfPresent(Rarity.self, forKey: .rarity)
        minHitProbability = try c.decodeIfPresent(Double.self, forKey: .minHitProbability)
        ammo = try c.decodeIfPresent(AmmoFamily.self, forKey: .ammo)
    }
    public var isValid: Bool {
        !id.isEmpty && [shotInterval,reloadDuration,switchDelay,projectileSpeed,minRange,maxRange,healthGain,shieldGain,healthCap,shieldCap,useDuration].allSatisfy { $0.isFinite && $0 >= 0 }
        && shotInterval >= 0.03 && switchDelay >= 0.05 && maxRange >= minRange && healthCap <= 100 && shieldCap <= 100
        && (minHitProbability.map { $0.isFinite && $0 > 0 && $0 <= 1 } ?? true)
    }
}

public struct InventorySlot: Codable, Equatable, Sendable {
    public var index: Int
    public var itemID: String?
    /// Stack size for consumables.
    public var count: Int
    /// Loaded rounds; read only for the selected weapon.
    public var ammo: Int?
    /// Reserve rounds; read only for the selected weapon.
    public var reserveAmmo: Int?
    /// Loaded plus reserve, as printed on the slot.
    public var totalAmmo: Int?
    public var rarity: Rarity?
    /// Display name learned from the pickup prompt, e.g. "M4".
    public var label: String?
    public var confidence: Double
    public init(_ index: Int, itemID: String? = nil, count: Int = 1, ammo: Int? = nil, reserveAmmo: Int? = nil,
                totalAmmo: Int? = nil, rarity: Rarity? = nil, label: String? = nil, confidence: Double = 1) {
        self.index = index; self.itemID = itemID; self.count = count; self.ammo = ammo; self.reserveAmmo = reserveAmmo
        self.totalAmmo = totalAmmo; self.rarity = rarity; self.label = label; self.confidence = confidence
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        ammo = try c.decodeIfPresent(Int.self, forKey: .ammo)
        reserveAmmo = try c.decodeIfPresent(Int.self, forKey: .reserveAmmo)
        totalAmmo = try c.decodeIfPresent(Int.self, forKey: .totalAmmo)
        rarity = try c.decodeIfPresent(Rarity.self, forKey: .rarity)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
    public var isKnownEmpty: Bool { itemID == nil && confidence >= 0.98 }
    /// False only when the slot is known to hold no rounds at all.
    public var hasAnyAmmo: Bool {
        if let ammo, ammo > 0 { return true }
        if let reserveAmmo, reserveAmmo > 0 { return true }
        if let totalAmmo { return totalAmmo > 0 }
        return ammo == nil && reserveAmmo == nil
    }
}

public struct PlayerTrack: Codable, Equatable, Sendable {
    public var id: Int
    public var position: Point
    public var velocity: Point // normalized viewport displacement per second, relative to self
    public var affiliation: Affiliation
    public var confidence: Double
    public var affiliationConfidence: Double
    /// Ground motion from the tracker. Without it the target's course is unknown and it is not engaged.
    public var motion: MotionEstimate?
    /// Seen in enough recent frames to rule out a one-frame false detection.
    public var confirmed: Bool
    /// Not detected in this frame: the position is the motion filter's prediction for a briefly missed player.
    public var predicted: Bool
    public init(id: Int, position: Point, velocity: Point = .init(), affiliation: Affiliation = .unknown, confidence: Double = 1,
                affiliationConfidence: Double = 1, motion: MotionEstimate? = nil, confirmed: Bool = true, predicted: Bool = false) {
        self.id = id; self.position = position; self.velocity = velocity; self.affiliation = affiliation; self.confidence = confidence
        self.affiliationConfidence = affiliationConfidence; self.motion = motion; self.confirmed = confirmed; self.predicted = predicted
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id); position = try c.decode(Point.self, forKey: .position)
        velocity = try c.decodeIfPresent(Point.self, forKey: .velocity) ?? Point()
        affiliation = try c.decodeIfPresent(Affiliation.self, forKey: .affiliation) ?? .unknown
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        affiliationConfidence = try c.decodeIfPresent(Double.self, forKey: .affiliationConfidence) ?? 0
        motion = try c.decodeIfPresent(MotionEstimate.self, forKey: .motion)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? true
        predicted = try c.decodeIfPresent(Bool.self, forKey: .predicted) ?? false
    }
}

public enum ObstacleKind: String, Codable, Sendable { case wall, rock, tree, door, chest, reviveTarget }
public struct Obstacle: Codable, Equatable, Sendable {
    public var kind: ObstacleKind
    public var bounds: Rect
    public var confidence: Double
    /// Conservative occupied rectangles decoded from the segmentation mask. Empty falls back to bounds.
    public var maskCells: [Rect]
    public init(_ kind: ObstacleKind, bounds: Rect, confidence: Double = 1, maskCells: [Rect] = []) {
        self.kind = kind; self.bounds = bounds; self.confidence = confidence; self.maskCells = maskCells
    }
    public func blocks(from: Point, to: Point) -> Bool {
        guard kind != .reviveTarget else { return false }
        return (maskCells.isEmpty ? [bounds] : maskCells).contains { $0.intersectsSegment(from: from, to: to, padding: 0.008) }
    }
    /// Foliage and rocks still intercept bullets, but the user wants to fire at enemies behind them.
    public var preventsEngagement: Bool { kind != .tree && kind != .rock }
}

/// The interaction panel below your character. It names what the interact key will do,
/// e.g. "M4 / Rare AR", "Hybrid Potion / Healing" or "Gold Chest / Interact".
public struct InteractionPrompt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case weapon, healing, throwable, other }
    public var name: String
    public var subtitle: String
    public var kind: Kind
    /// Catalog item the interact key would pick up; nil for anything that is not a known item.
    public var itemID: String?
    public var weaponClass: WeaponClass?
    public var rarity: Rarity?
    /// Stack badge ("x2").
    public var count: Int?
    public var confidence: Double
    /// The text was read from the panel exactly as it is shown in this frame, and the panel has been steady.
    public var stable: Bool
    public init(name: String, subtitle: String, kind: Kind, itemID: String? = nil, weaponClass: WeaponClass? = nil,
                rarity: Rarity? = nil, count: Int? = nil, confidence: Double = 1, stable: Bool = true) {
        self.name = name; self.subtitle = subtitle; self.kind = kind; self.itemID = itemID; self.weaponClass = weaponClass
        self.rarity = rarity; self.count = count; self.confidence = confidence; self.stable = stable
    }
    public var isItem: Bool { (kind == .weapon || kind == .healing) && itemID != nil }
}

public struct Observation: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var mode: GameMode = .solo
    /// A teammate roster is visible or a team mode was configured: players need positive enemy evidence.
    public var teamMode: Bool = false
    public var phase: MatchPhase = .unknown
    public var phaseConfidence: Double = 0
    public var focused: Bool = false
    public var perceptionReady: Bool = false
    public var player = Point(0.5,0.5)
    public var playerConfidence: Double = 0
    public var aspect: Double = 16.0 / 9.0
    public var health: Double?
    public var shield: Double?
    public var hudConfidence: Double = 0
    public var selectedSlot: Int?
    public var selectedSlotConfidence: Double = 0
    public var inventory: [InventorySlot] = []
    public var players: [PlayerTrack] = []
    public var obstacles: [Obstacle] = []
    public var prompt: InteractionPrompt?
    public var healingProgress: Double?
    public var manualOverride: Bool = false
    public var captureHealthy: Bool = true
    public init(timestamp: Double) { self.timestamp = timestamp }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Double.self, forKey: .timestamp)
        mode = try c.decodeIfPresent(GameMode.self, forKey: .mode) ?? .solo
        teamMode = try c.decodeIfPresent(Bool.self, forKey: .teamMode) ?? (mode != .solo)
        phase = try c.decodeIfPresent(MatchPhase.self, forKey: .phase) ?? .unknown
        phaseConfidence = try c.decodeIfPresent(Double.self, forKey: .phaseConfidence) ?? 0
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        perceptionReady = try c.decodeIfPresent(Bool.self, forKey: .perceptionReady) ?? false
        player = try c.decodeIfPresent(Point.self, forKey: .player) ?? Point(0.5, 0.5)
        playerConfidence = try c.decodeIfPresent(Double.self, forKey: .playerConfidence) ?? 0
        aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 16.0 / 9.0
        health = try c.decodeIfPresent(Double.self, forKey: .health)
        shield = try c.decodeIfPresent(Double.self, forKey: .shield)
        hudConfidence = try c.decodeIfPresent(Double.self, forKey: .hudConfidence) ?? 0
        selectedSlot = try c.decodeIfPresent(Int.self, forKey: .selectedSlot)
        selectedSlotConfidence = try c.decodeIfPresent(Double.self, forKey: .selectedSlotConfidence) ?? 0
        inventory = try c.decodeIfPresent([InventorySlot].self, forKey: .inventory) ?? []
        players = try c.decodeIfPresent([PlayerTrack].self, forKey: .players) ?? []
        obstacles = try c.decodeIfPresent([Obstacle].self, forKey: .obstacles) ?? []
        prompt = try c.decodeIfPresent(InteractionPrompt.self, forKey: .prompt)
        healingProgress = try c.decodeIfPresent(Double.self, forKey: .healingProgress)
        manualOverride = try c.decodeIfPresent(Bool.self, forKey: .manualOverride) ?? false
        captureHealthy = try c.decodeIfPresent(Bool.self, forKey: .captureHealthy) ?? true
    }
    public func slot(_ index: Int) -> InventorySlot? { inventory.first { $0.index == index } }
    public var selected: InventorySlot? { selectedSlot.flatMap(slot) }
}

public struct Features: Codable, Equatable, Sendable {
    public var combat = true; public var loot = true; public var healing = true
    public init() {}
}

/// No raw-key or movement intent is representable here.
public enum InputIntent: Codable, Equatable, Sendable {
    case aim(Point)
    case fire
    case useConsumable
    case selectSlot(Int)
    case reload
    /// Press interact once for the item the prompt names.
    case pickup(String)
    case releaseAll
}

public struct Decision: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var intents: [InputIntent]
    public var reason: String
    public init(_ timestamp: Double, _ intents: [InputIntent], _ reason: String) { self.timestamp = timestamp; self.intents = intents; self.reason = reason }
}
