import Foundation

/// Team-mode affiliation from name tags. Teammates show their roster name above their head
/// (in their roster color); a player becomes an enemy only after repeated reads find no
/// roster name there. Until then it is unknown and is never fired on.
public struct AffiliationTracker: Sendable {
    public enum Read: Equatable, Sendable {
        /// Text read above the player and its OCR confidence.
        case text(String, Double)
        /// Nothing legible above the player. `colored` reports name-tag-colored text pixels.
        case nothing(colored: Bool)
    }
    struct Evidence: Sendable {
        var matched: Double?
        /// The roster name the tag matched last.
        var name: String?
        var against = 0
        var seen: Double
    }
    public static let teammateSimilarity = 0.75
    public static let strangerSimilarity = 0.45
    public static let readsForEnemy = 2
    /// A teammate match is trusted this long without a fresh read.
    public static let teammateMemory = 10.0
    private var tracks: [Int: Evidence] = [:]
    public init() {}

    public mutating func reset() { tracks = [:] }

    public mutating func record(track: Int, read: Read, roster: [String], time: Double) {
        var e = tracks[track] ?? Evidence(seen: time)
        e.seen = time
        switch read {
        case let .text(text, confidence):
            let ranked = roster.map { ($0, HUDText.nameSimilarity(text, $0)) }.max { $0.1 < $1.1 }
            let best = ranked?.1 ?? 0
            if best >= Self.teammateSimilarity { e.matched = time; e.name = ranked?.0; e.against = 0 }
            else if best < Self.strangerSimilarity && confidence >= 0.5 && HUDText.nameKey(text).count >= 3 && !roster.isEmpty { e.against += 1 }
        case let .nothing(colored):
            if !colored && !roster.isEmpty { e.against += 1 }
        }
        tracks[track] = e
    }

    public func affiliation(track: Int, time: Double) -> (Affiliation, Double) {
        guard let e = tracks[track] else { return (.unknown, 0) }
        if let matched = e.matched, time - matched <= Self.teammateMemory { return (.teammate, 1) }
        if e.matched == nil && e.against >= Self.readsForEnemy { return (.enemy, 0.95) }
        return (.unknown, 0)
    }

    /// The roster name of a teammate's tag; nil for anyone not currently a teammate.
    public func name(track: Int, time: Double) -> String? {
        guard affiliation(track: track, time: time).0 == .teammate else { return nil }
        return tracks[track]?.name
    }

    /// Enemies keep being re-read, so a teammate misread early is corrected by a later legible tag.
    public func needsRead(track: Int, time: Double) -> Bool {
        guard let e = tracks[track], let matched = e.matched else { return true }
        return time - matched > Self.teammateMemory / 2
    }

    public mutating func prune(keeping active: Set<Int>, time: Double) {
        tracks = tracks.filter { active.contains($0.key) || time - $0.value.seen < 1 }
    }
}
