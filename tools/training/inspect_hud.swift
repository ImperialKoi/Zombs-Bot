// Read-only OCR inspection for recorded frames. Coordinates use top-left origin.
// swiftc -module-cache-path .build/clang-cache tools/training/inspect_hud.swift -o .build/inspect-hud
// .build/inspect-hud image.jpg [x y width height]
import Foundation
import Vision
import ImageIO

var arguments = CommandLine.arguments
let repeatOption = arguments.first(where: { $0.hasPrefix("--repeat=") })
let repetitions = repeatOption.flatMap { Int($0.dropFirst(9)) } ?? 1
guard (1...100).contains(repetitions) else { fputs("Repeat count must be 1–100\n", stderr); exit(1) }
arguments.removeAll(where: { $0.hasPrefix("--repeat=") })
let accurate = arguments.last == "--accurate"
if accurate { arguments.removeLast() }
guard arguments.count == 2 || arguments.count == 6 else {
    fputs("Usage: inspect-hud image.jpg [x y width height] [--accurate] [--repeat=N]\n", stderr)
    exit(1)
}
let url = URL(fileURLWithPath: arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fputs("Cannot read image\n", stderr); exit(1)
}
var region = CGRect(x: 0, y: 0, width: 1, height: 1)
if arguments.count == 6 {
    let values = arguments.dropFirst(2).compactMap(Double.init)
    guard values.count == 4, values.allSatisfy(\.isFinite),
          values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0,
          values[0] + values[2] <= 1, values[1] + values[3] <= 1 else {
        fputs("Invalid normalized rectangle\n", stderr); exit(1)
    }
    region = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}
let pixels = CGRect(x: region.minX * Double(original.width), y: region.minY * Double(original.height),
                    width: region.width * Double(original.width), height: region.height * Double(original.height))
guard let image = original.cropping(to: pixels) else { exit(1) }
var request = VNRecognizeTextRequest()
var timings: [Double] = []
for _ in 0..<repetitions {
    request = VNRecognizeTextRequest()
    request.recognitionLevel = accurate ? .accurate : .fast
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["en-US"]
    let start = ProcessInfo.processInfo.systemUptime
    do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
    catch { fputs("OCR failed: \(error.localizedDescription)\n", stderr); exit(2) }
    timings.append(ProcessInfo.processInfo.systemUptime - start)
}
let rows: [[String: Any]] = (request.results ?? []).compactMap { observation in
    guard let candidate = observation.topCandidates(1).first else { return nil }
    let b = observation.boundingBox
    return ["text": candidate.string, "confidence": candidate.confidence,
            "bounds": ["x": region.minX + b.minX * region.width,
                       "y": region.minY + (1 - b.maxY) * region.height,
                       "width": b.width * region.width, "height": b.height * region.height]]
}
let output: [String: Any] = ["image": url.path, "width": original.width, "height": original.height,
                           "recognitionLevel": accurate ? "accurate" : "fast", "elapsedSeconds": timings, "text": rows]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
