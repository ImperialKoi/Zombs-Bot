import Foundation
import RecorderCore

// zombs-extract RECORDING OUTPUT [--fps 5] [--quality 0.95]
//   Writes OUTPUT/images/%06d.jpg and prints one JSON line per saved frame (used by ingest_recordings.py).
// zombs-extract --info MOVIE
//   Prints codec-independent facts about one part: size, frames, duration, bytes and SHA-256.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func option(_ name: String, in arguments: inout [String], default value: Double) -> Double {
    guard let index = arguments.firstIndex(of: name) else { return value }
    guard index + 1 < arguments.count, let parsed = Double(arguments[index + 1]) else { fail("\(name) needs a number") }
    arguments.removeSubrange(index...index + 1)
    return parsed
}

var arguments = Array(CommandLine.arguments.dropFirst())
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

if arguments.first == "--info" {
    guard arguments.count == 2 else { fail("usage: zombs-extract --info MOVIE") }
    let url = URL(fileURLWithPath: arguments[1])
    guard let summary = await MovieSummary.read(url) else { fail("Cannot read \(url.path)") }
    let digest = (try? sha256Hex(of: url)) ?? ""
    let info: [String: String] = ["width": "\(summary.width)", "height": "\(summary.height)", "frames": "\(summary.frames)",
                                  "durationSeconds": String(format: "%.3f", summary.duration), "bytes": "\(fileSize(url))",
                                  "averageBitrate": summary.duration > 0 ? "\(Int(Double(fileSize(url)) * 8 / summary.duration))" : "0",
                                  "sha256": digest]
    print(String(data: try encoder.encode(info), encoding: .utf8)!)
    exit(0)
}

let fps = option("--fps", in: &arguments, default: 5)
let quality = option("--quality", in: &arguments, default: 0.95)
guard arguments.count == 2 else { fail("usage: zombs-extract RECORDING OUTPUT [--fps 5] [--quality 0.95]") }
let recording = URL(fileURLWithPath: arguments[0], isDirectory: true)
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard let manifest = try? readJSON(RecordingManifest.self, from: recording.appendingPathComponent(MatchFiles.manifest)), manifest.complete else {
    fail("\(recording.path) has no complete recording.json")
}
do {
    try await FrameExtractor.extract(recording: recording, manifest: manifest, to: output, fps: fps, quality: quality) { frame in
        print(String(data: try encoder.encode(frame), encoding: .utf8)!)
    }
} catch {
    fail("Extraction failed: \(error.localizedDescription)")
}
