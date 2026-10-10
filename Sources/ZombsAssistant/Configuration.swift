import Foundation
import AssistantCore
import Perception

/// What the user confirms before input is allowed: the game area, mode and key bindings.
/// HUD regions are found automatically in each match.
struct Calibration: Codable {
    var verified = false
    /// Points of Chrome tabs and toolbar above the game.
    var topInset = 87.0
    var mode: GameMode = .solo
    var keyBindings = KeyBindings()
    var combat = CombatSettings()
    init() {}
    /// Reads current and earlier calibration files; fields from the old manual HUD regions are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        topInset = try c.decodeIfPresent(Double.self, forKey: .topInset) ?? 87
        mode = try c.decodeIfPresent(GameMode.self, forKey: .mode) ?? .solo
        keyBindings = try c.decodeIfPresent(KeyBindings.self, forKey: .keyBindings) ?? KeyBindings()
        combat = try c.decodeIfPresent(CombatSettings.self, forKey: .combat) ?? CombatSettings()
    }
    var isValid: Bool { keyBindings.isValid && combat.isValid && topInset.isFinite && (0...300).contains(topInset) }
}

final class Workspace {
    let root: URL
    let artifacts: URL
    let recordings: URL
    var calibrationURL: URL { root.appendingPathComponent("calibration.json") }
    /// Optional catalog override; the built-in catalog is used when absent.
    var catalogURL: URL { root.appendingPathComponent("catalog.json") }
    var iconsURL: URL { artifacts.appendingPathComponent("icons.json") }
    init(root: URL? = nil) throws {
        let fm = FileManager.default
        self.root = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ZombsAssistant", isDirectory: true)
        artifacts = self.root.appendingPathComponent("artifacts", isDirectory: true)
        recordings = self.root.appendingPathComponent("recordings", isDirectory: true)
        for url in [self.root, artifacts, recordings] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        if !fm.fileExists(atPath: calibrationURL.path) { try save(Calibration(), to: calibrationURL) }
    }
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
    func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    /// The built-in catalog, or the user's tuned copy when it is valid.
    func catalog() -> ItemCatalog {
        guard let custom = try? read(ItemCatalog.self, from: catalogURL), custom.profiles.allSatisfy(\.isValid) else { return .standard }
        return custom
    }
}
