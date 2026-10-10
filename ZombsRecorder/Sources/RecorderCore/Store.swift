import Foundation
import CryptoKit
import AVFoundation

public enum MatchFiles {
    public static let manifest = "recording.json"
    public static let start = "recording-start.json"
    public static let upload = "upload.json"
    public static func part(_ index: Int) -> String { String(format: "part-%03d.mov", index) }
}

/// `~/Library/Application Support/ZombsRecorder/`: settings, credentials and one folder per match.
public final class MatchStore: @unchecked Sendable {
    public let root: URL
    public let matches: URL
    public var credentialsURL: URL { root.appendingPathComponent("credentials.json") }

    public init(root: URL? = nil) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.root = root ?? support.appendingPathComponent("ZombsRecorder", isDirectory: true)
        matches = self.root.appendingPathComponent("matches", isDirectory: true)
        try FileManager.default.createDirectory(at: matches, withIntermediateDirectories: true)
        // The folder holds the Kaggle token, so keep it private to this user.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
    }

    public func directory(for matchID: String) -> URL { matches.appendingPathComponent(matchID, isDirectory: true) }

    /// Finished matches, oldest first. Only folders with a complete `recording.json` count.
    public func finished() -> [(directory: URL, manifest: RecordingManifest)] {
        folders().compactMap { folder in
            guard let manifest = try? readJSON(RecordingManifest.self, from: folder.appendingPathComponent(MatchFiles.manifest)),
                  manifest.complete, manifest.matchID == folder.lastPathComponent else { return nil }
            return (folder, manifest)
        }
    }

    /// Folders whose recording started but never finished, e.g. after a crash or force quit.
    public func unfinished() -> [URL] {
        folders().filter { !FileManager.default.fileExists(atPath: $0.appendingPathComponent(MatchFiles.manifest).path) }
    }

    private func folders() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: matches, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { MatchID.isValid($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Rebuild `recording.json` from the movie fragments written before the app stopped.
    /// Returns nil (and removes the folder) when less than `minimumSeconds` is readable.
    public func recover(_ folder: URL, minimumSeconds: Double) async -> RecordingManifest? {
        guard let start = try? readJSON(RecordingStart.self, from: folder.appendingPathComponent(MatchFiles.start)) else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        var parts: [RecordingPart] = []
        var end = 0.0
        for index in 0..<1000 {
            let url = folder.appendingPathComponent(MatchFiles.part(index))
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            guard let summary = await MovieSummary.read(url), summary.frames > 0, let digest = try? sha256Hex(of: url) else { continue }
            let startSeconds = index < start.partStarts.count ? max(start.partStarts[index], end) : end
            parts.append(RecordingPart(file: url.lastPathComponent, width: summary.width, height: summary.height, frames: summary.frames,
                                       startSeconds: startSeconds, durationSeconds: summary.duration, bytes: fileSize(url), sha256: digest))
            end = startSeconds + summary.duration
        }
        guard end >= minimumSeconds else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        let manifest = RecordingManifest(start: start, endedAt: timestamp(), endReason: .recovered, parts: parts)
        do { try writeJSON(manifest, to: folder.appendingPathComponent(MatchFiles.manifest)) } catch { return nil }
        return manifest
    }
}

public struct MovieSummary: Sendable {
    public var width: Int
    public var height: Int
    public var frames: Int
    public var duration: Double

    /// Reads dimensions, duration and the compressed sample count without decoding frames.
    public static func read(_ url: URL) async -> MovieSummary? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var frames = 0
        var first: CMTime?
        var last = CMTime.zero
        while let buffer = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(buffer)
            guard count > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(buffer)
            if first == nil || time < first! { first = time }
            if time > last { last = time }
            frames += count
        }
        guard reader.status == .completed || frames > 0, let first else { return nil }
        return MovieSummary(width: Int(size.width), height: Int(size.height), frames: frames, duration: max(0, (last - first).seconds))
    }
}

public func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty { hasher.update(data: data) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

public func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

public func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

public func writeJSON<T: Encodable>(_ value: T, to url: URL, permissions: Int? = nil) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
}
