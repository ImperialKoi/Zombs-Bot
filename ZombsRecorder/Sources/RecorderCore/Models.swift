import Foundation

public enum RecorderInfo {
    public static let version = "0.1.0"
    /// Kaggle dataset slugs for uploaded matches start with this; ingest lists them by it.
    public static let slugPrefix = "zombs-rec-"
}

public enum GameMode: String, Codable, CaseIterable, Sendable {
    case solo, duo, squad
}

public enum MatchID {
    /// Same format as ZombsAssistant's SessionRecorder: UTC time with `:` → `-`, then 6 uppercase hex characters.
    public static func make(date: Date = Date(), suffix: String? = nil) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return stamp + "-" + (suffix ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)))
    }
    public static func isValid(_ id: String) -> Bool {
        id.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-[0-9A-F]{6}$"#, options: .regularExpression) != nil
    }
    /// Kaggle slugs allow lowercase letters, digits and hyphens, up to 50 characters.
    public static func slug(_ id: String) -> String {
        let lowered = id.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String((RecorderInfo.slugPrefix + String(lowered)).prefix(50))
    }
    public static func title(_ id: String, mode: GameMode) -> String {
        // "zombs-rec duo 2026-10-06 19-02Z 4C1A9E": 6–50 characters as Kaggle requires.
        let parts = id.split(separator: "T", maxSplits: 1)
        guard parts.count == 2 else { return "zombs-rec \(mode.rawValue) \(id)".prefix(50).description }
        let time = parts[1].split(separator: "-")
        let clock = time.count >= 4 ? "\(time[0])-\(time[1])Z \(time[3])" : String(parts[1])
        return String("zombs-rec \(mode.rawValue) \(parts[0]) \(clock)".prefix(50))
    }
}

public enum EndReason: String, Codable, Sendable {
    case hotkey, menu, windowClosed = "window-closed", maxDuration = "max-duration", error, recovered
}

public struct CaptureInfo: Codable, Equatable, Sendable {
    public var fps: Int
    public var codec: String
    public var bitrate: Int
    public var topInsetPoints: Double
    public var scale: Double
    public init(fps: Int, codec: String, bitrate: Int, topInsetPoints: Double, scale: Double) {
        self.fps = fps; self.codec = codec; self.bitrate = bitrate; self.topInsetPoints = topInsetPoints; self.scale = scale
    }
}

public struct RecordingPart: Codable, Equatable, Sendable {
    public var file: String
    public var width: Int
    public var height: Int
    public var frames: Int
    /// Seconds from the match start to this part's first frame.
    public var startSeconds: Double
    public var durationSeconds: Double
    public var bytes: Int64
    public var sha256: String
    public init(file: String, width: Int, height: Int, frames: Int, startSeconds: Double, durationSeconds: Double, bytes: Int64, sha256: String) {
        self.file = file; self.width = width; self.height = height; self.frames = frames
        self.startSeconds = startSeconds; self.durationSeconds = durationSeconds; self.bytes = bytes; self.sha256 = sha256
    }
}

/// Written when recording starts; recovery uses it if the app quits before `recording.json`.
public struct RecordingStart: Codable, Equatable, Sendable {
    public var matchID: String
    public var mode: GameMode
    public var teammates: [String]
    public var recordedBy: String
    public var createdAt: String
    public var capture: CaptureInfo
    /// Seconds from the match start at which each part began; a resize starts a new part.
    public var partStarts: [Double]
    public init(matchID: String, mode: GameMode, teammates: [String], recordedBy: String, createdAt: String, capture: CaptureInfo) {
        self.matchID = matchID; self.mode = mode; self.teammates = teammates; self.recordedBy = recordedBy
        self.createdAt = createdAt; self.capture = capture; partStarts = []
    }
}

/// `recording.json`. It is written last and atomically, so its presence marks a finished match.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public var schema = 1
    public var matchID: String
    public var mode: GameMode
    public var teammates: [String]
    public var recordedBy: String
    public var recorderVersion: String
    public var createdAt: String
    public var endedAt: String
    public var endReason: EndReason
    public var capture: CaptureInfo
    public var parts: [RecordingPart]
    public var complete: Bool
    public init(start: RecordingStart, endedAt: String, endReason: EndReason, parts: [RecordingPart]) {
        matchID = start.matchID; mode = start.mode; teammates = start.teammates; recordedBy = start.recordedBy
        recorderVersion = RecorderInfo.version; createdAt = start.createdAt; capture = start.capture
        self.endedAt = endedAt; self.endReason = endReason; self.parts = parts; complete = true
    }
    public var durationSeconds: Double { parts.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0 }
    public var bytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
}

public func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}
