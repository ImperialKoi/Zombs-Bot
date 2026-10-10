import CoreGraphics
import Foundation
import Vision

public struct TextLine: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    /// Normalized within the read region, origin at top left.
    public var box: CGRect
}

public struct TextResult: Sendable {
    public var lines: [TextLine]
    /// Fingerprint of the pixels that were read.
    public var fingerprint: [UInt8]
    public var time: Double
    public var text: String { lines.map(\.text).joined(separator: " ") }
    public var confidence: Double { lines.map(\.confidence).min() ?? 0 }
}

public enum TextRegion: Hashable, Sendable {
    case prompt, readout, roster
    case slot(Int)
    case reserve(Int)
    case nameTag(Int)
    var priority: Int {
        switch self {
        case .prompt: return 0
        case .readout: return 1
        case .nameTag: return 2
        case .slot: return 3
        case .reserve: return 4
        case .roster: return 5
        }
    }
}

/// Text recognition off the frame loop. Each region keeps its latest result with the fingerprint
/// of the pixels it read, so a caller can tell whether the text still describes the screen.
public final class TextReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "text.recognition", qos: .userInitiated)
    private let lock = NSLock()
    private var results: [TextRegion: TextResult] = [:]
    private var waiting: [TextRegion: (image: CGImage, fingerprint: [UInt8], time: Double)] = [:]
    private var lastRequest: [TextRegion: Double] = [:]
    private var running = false
    /// Offline tools read inline so each frame sees its own text.
    public let synchronous: Bool
    public var minimumInterval = 0.12
    public private(set) var reads = 0

    public init(synchronous: Bool = false) { self.synchronous = synchronous }

    public func reset() {
        lock.lock(); results = [:]; waiting = [:]; lastRequest = [:]; lock.unlock()
    }

    public func result(_ region: TextRegion) -> TextResult? {
        lock.lock(); defer { lock.unlock() }
        return results[region]
    }

    /// The latest result, only when it was read from pixels matching `fingerprint`.
    public func current(_ region: TextRegion, fingerprint: [UInt8], tolerance: Int = 12) -> TextResult? {
        guard let result = result(region), fingerprintsMatch(result.fingerprint, fingerprint, tolerance: tolerance) else { return nil }
        return result
    }

    /// Queues a read unless these pixels were read already. The newest image for a region replaces an older waiting one.
    public func request(_ region: TextRegion, fingerprint: [UInt8], time: Double, image: () -> CGImage?) {
        guard !fingerprint.isEmpty else { return }
        lock.lock()
        if let done = results[region], fingerprintsMatch(done.fingerprint, fingerprint, tolerance: 12) { lock.unlock(); return }
        if !synchronous, let last = lastRequest[region], time - last < minimumInterval, waiting[region] == nil { lock.unlock(); return }
        lastRequest[region] = time
        lock.unlock()
        guard let image = image() else { return }
        if synchronous {
            let lines = Self.recognize(image)
            lock.lock(); results[region] = TextResult(lines: lines, fingerprint: fingerprint, time: time); reads += 1; lock.unlock()
            return
        }
        lock.lock()
        waiting[region] = (image, fingerprint, time)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let region = waiting.keys.min(by: { $0.priority < $1.priority }), let job = waiting.removeValue(forKey: region) else {
                running = false; lock.unlock(); return
            }
            lock.unlock()
            let lines = Self.recognize(job.image)
            lock.lock(); results[region] = TextResult(lines: lines, fingerprint: job.fingerprint, time: job.time); reads += 1; lock.unlock()
        }
    }

    /// Accurate recognition without language correction: HUD text is names and numbers.
    public static func recognize(_ image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return [] }
        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return TextLine(text: candidate.string, confidence: Double(candidate.confidence),
                            box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        // Reading order: rows top to bottom, then left to right within a row.
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) < 0.12 { rows[rows.count - 1].append(line) }
            else { rows.append([line]) }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }
}
