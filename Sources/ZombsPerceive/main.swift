import Foundation
import CoreImage
import ImageIO
import AssistantCore
import Perception

/// Runs the app's perception on recorded frames. Sends no input.
struct Options {
    var sessions: [URL] = []
    var model: URL?
    var stride = 1
    var frames: ClosedRange<Int>?
    var icons: URL?
    var learnIcons = false
    var report: URL?
    var jsonl: URL?
    var reviewed: URL?
    var mode: GameMode?
    var detect = false
    var checkBufferPath = false
    var decide = false
}

func parse() -> Options? {
    var o = Options(), args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
        switch a {
        case "--model": o.model = value().map { URL(fileURLWithPath: $0) }; o.detect = true
        case "--stride": o.stride = max(1, Int(value() ?? "") ?? 1)
        case "--frames":
            let parts = (value() ?? "").split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { o.frames = parts[0]...parts[1] }
        case "--icons": o.icons = value().map { URL(fileURLWithPath: $0) }
        case "--learn-icons": o.icons = value().map { URL(fileURLWithPath: $0) }; o.learnIcons = true
        case "--report": o.report = value().map { URL(fileURLWithPath: $0) }
        case "--jsonl": o.jsonl = value().map { URL(fileURLWithPath: $0) }
        case "--hud-reviewed": o.reviewed = value().map { URL(fileURLWithPath: $0) }
        case "--mode": o.mode = value().flatMap(GameMode.init(rawValue:))
        case "--check-buffer-path": o.checkBufferPath = true
        case "--decide": o.decide = true
        default: o.sessions.append(URL(fileURLWithPath: a))
        }
    }
    return o.sessions.isEmpty ? nil : o
}

struct FrameRow: Decodable { var image: String; var timestamp: Double }
struct SessionInfo: Decodable { var matchID: String; var mode: GameMode }
struct Reviewed: Decodable { struct Sample: Decodable { var matchID: String; var image: String; var health: Double; var shield: Double }; var samples: [Sample] }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

/// The app feeds the detector from BGRA capture buffers; recordings decode to CGImages. Both must agree.
func bufferImage(_ cg: CGImage) -> CIImage? {
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: cg.width, height: cg.height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return CIImage(cvPixelBuffer: buffer)
}

func iou(_ a: Rect, _ b: Rect) -> Double {
    let w = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x)), h = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
    return w * h / max(1e-9, a.width * a.height + b.width * b.height - w * h)
}

func run() throws {
    guard let options = parse() else {
        print("""
        Usage: ZombsPerceive <session>... [--model artifacts] [--stride N] [--frames A:B] [--icons icons.json | --learn-icons icons.json]
                             [--hud-reviewed hud-reviewed.json] [--report report.json] [--jsonl frames.jsonl] [--mode solo|duo|squad]
        Runs the assistant's recognition on recorded JPEG frames and reports HUD readings, prompts, inventory and timing.
        """)
        return
    }
    let library = IconLibrary(url: options.icons)
    let reviewed = try options.reviewed.map { try JSONDecoder().decode(Reviewed.self, from: Data(contentsOf: $0)) }
    let wanted = Set(reviewed?.samples.map { "\($0.matchID)/\($0.image)" } ?? [])
    var output = Data()
    var hudTimes: [Double] = [], detectTimes: [Double] = [], decodeTimes: [Double] = []
    var frames = 0, alive = 0, layouts = 0, prompts = 0, parsedPrompts = 0, selected = 0, readouts = 0
    var vocabulary: [String: Int] = [:], names: [String: Int] = [:]
    var vitalErrors: [Double] = [], vitalMissing = 0
    var learned: [[String: String]] = []
    var pathChecks: [Double] = [], pathCounts: [Int] = []
    var actions: [String: Int] = [:], reasons: [String: Int] = [:]
    let checker = options.checkBufferPath ? options.model.flatMap { try? SceneDetector(artifacts: $0) } : nil
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for session in options.sessions {
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(contentsOf: session.appendingPathComponent("session.json")))
        let rows = try String(contentsOf: session.appendingPathComponent("frames.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(FrameRow.self, from: Data($0.utf8)) }
        let engine = PerceptionEngine(artifacts: options.detect ? options.model : nil,
                                      settings: PerceptionSettings(mode: options.mode ?? info.mode), library: library,
                                      text: TextReader(synchronous: true))
        let learnedBefore = engine.inventory.learned.count
        // What the assistant would have done, treating each recorded frame as live and focused.
        let coordinator = Coordinator(catalog: .standard)
        for (index, row) in rows.enumerated() {
            if let range = options.frames, !range.contains(index) { continue }
            if !wanted.isEmpty { guard wanted.contains("\(info.matchID)/\(row.image)") else { continue } }
            else if index % options.stride != 0 { continue }
            let decodeStart = ProcessInfo.processInfo.systemUptime
            let url = session.appendingPathComponent(row.image)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let pixels = PixelImage(cgImage: cg) else { continue }
            decodeTimes.append((ProcessInfo.processInfo.systemUptime - decodeStart) * 1000)
            if let checker, let buffered = bufferImage(cg) {
                let a = try checker.predict(CIImage(cgImage: cg)), b = try checker.predict(buffered)
                pathCounts.append(abs(a.count - b.count))
                for d in a where d.label == "player" || d.label == "tree" {
                    pathChecks.append(b.filter { $0.label == d.label }.map { iou($0.bounds, d.bounds) }.max() ?? 0)
                }
            }
            let result = engine.process(image: pixels, ciImage: options.detect ? CIImage(cgImage: cg) : nil, timestamp: row.timestamp)
            frames += 1
            hudTimes.append(result.hudMilliseconds); if options.detect { detectTimes.append(result.detectorMilliseconds) }
            var o = result.observation
            if result.hud != nil { layouts += 1 }
            var decision: Decision?
            if options.decide {
                o.focused = true; o.perceptionReady = result.recognitionReady || !options.detect
                let d = coordinator.step(o, now: o.timestamp)
                decision = d
                for intent in d.intents {
                    switch intent {
                    case .fire: actions["fire", default: 0] += 1
                    case .selectSlot(let i): actions["select \(i)", default: 0] += 1
                    case .pickup(let name): actions["pickup \(name)", default: 0] += 1
                    case .open(let name): actions["open \(name)", default: 0] += 1
                    case .holdOpen(let name): actions["hold open \(name)", default: 0] += 1
                    case .reload: actions["reload", default: 0] += 1
                    case .useConsumable: actions["heal", default: 0] += 1
                    case .aim: actions["aim", default: 0] += 1
                    case .throwAt: actions["throw", default: 0] += 1
                    case .fireAtPull: actions["fire at pull", default: 0] += 1
                    case .releaseAll: break
                    }
                }
                reasons[d.reason.components(separatedBy: CharacterSet.decimalDigits).joined(), default: 0] += 1
            }
            if o.phase == .alive { alive += 1 }
            if o.selectedSlotConfidence >= 0.98 { selected += 1 }
            if o.selected?.ammo != nil { readouts += 1 }
            if !result.promptLines.isEmpty {
                prompts += 1
                if let p = o.prompt {
                    parsedPrompts += 1
                    vocabulary["\(p.kind.rawValue): \(p.subtitle)", default: 0] += 1
                    if p.kind != .other { names["\(p.subtitle) — \(p.name)", default: 0] += 1 }
                }
            }
            if let reviewed, let sample = reviewed.samples.first(where: { $0.matchID == info.matchID && $0.image == row.image }) {
                if let h = o.health, let s = o.shield { vitalErrors += [abs(h - sample.health), abs(s - sample.shield)] } else { vitalMissing += 1 }
            }
            var record: [String: Any] = ["match": info.matchID, "image": row.image, "t": row.timestamp, "alive": o.phase == .alive,
                                         "selected": o.selectedSlot as Any, "health": o.health as Any, "shield": o.shield as Any,
                                         "vitalsOK": o.hudConfidence >= 0.98, "promptLines": result.promptLines,
                                         "readout": result.readoutText as Any, "players": o.players.count, "teamMode": o.teamMode,
                                         "playerDetections": o.players.map { ["x": ($0.position.x * 1000).rounded() / 1000, "y": ($0.position.y * 1000).rounded() / 1000,
                                                                              "confidence": ($0.confidence * 100).rounded() / 100, "confirmed": $0.confirmed,
                                                                              "affiliation": $0.affiliation.rawValue, "validEnemy": Policy.validEnemy($0),
                                              "canFire": Policy.canFireToward(o, at: $0.position), "hasMotion": $0.motion != nil, "predicted": $0.predicted] },
                                         "blockers": o.obstacles.filter { $0.preventsEngagement }.map { "\($0.kind.rawValue)@\(($0.bounds.center.x * 100).rounded() / 100),\(($0.bounds.center.y * 100).rounded() / 100)" },
                                         "hudMS": result.hudMilliseconds, "detectMS": result.detectorMilliseconds]
            if let p = o.prompt { record["prompt"] = ["kind": p.kind.rawValue, "item": p.itemID as Any, "name": p.name, "subtitle": p.subtitle] }
            if let decision { record["decision"] = decision.reason; record["intents"] = decision.intents.map { "\($0)" } }
            if let hud = result.hud {
                record["slots"] = hud.slots.map { s -> [String: Any] in
                    let slot = o.inventory.first { $0.index == s.index }
                    return ["i": s.index, "occupied": s.occupied, "rarity": s.rarity?.name as Any, "light": s.lightTile,
                            "selection": (s.selectionScore * 100).rounded() / 100, "item": slot?.itemID as Any, "label": slot?.label as Any,
                            "count": slot?.count as Any, "total": slot?.totalAmmo as Any, "source": engine.inventory.source(of: s.index)?.rawValue as Any]
                }
                record["roster"] = result.roster
                record["rosterRows"] = hud.rosterRows
                record["unit"] = (hud.layout.unit * 10).rounded() / 10
                record["origin"] = [hud.layout.originX, hud.layout.originY, hud.layout.pitch]
            }
            if options.jsonl != nil, let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) { output.append(data); output.append(10) }
        }
        for item in engine.inventory.learned.dropFirst(learnedBefore) {
            learned.append(["match": info.matchID, "slot": String(item.slot), "kind": item.identity.kind.rawValue,
                            "class": item.identity.weaponClass?.rawValue ?? item.identity.healID ?? "", "name": item.identity.name])
        }
        FileHandle.standardError.write(Data("\(info.matchID): \(frames) frames so far, \(library.entries.count) icons\n".utf8))
    }
    if options.learnIcons { try library.save() }
    if let jsonl = options.jsonl { try output.write(to: jsonl, options: .atomic) }
    let summary: [String: Any] = [
        "frames": frames, "hudFound": layouts, "alive": alive, "selectedConfident": selected, "ammoReadouts": readouts,
        "promptsRead": prompts, "promptsParsed": parsedPrompts,
        "promptVocabulary": vocabulary, "itemNames": names,
        "iconsInLibrary": library.entries.count, "iconsLearned": learned,
        "actions": actions, "decisionReasons": reasons,
        "bufferPath": ["compared": pathChecks.count, "meanIoU": pathChecks.isEmpty ? NSNull() : pathChecks.reduce(0, +) / Double(pathChecks.count),
                       "minIoU": pathChecks.min() as Any, "maxCountDifference": pathCounts.max() as Any],
        "vitals": ["compared": vitalErrors.count, "missingFrames": vitalMissing, "maxAbsError": vitalErrors.max() as Any,
                   "meanAbsError": vitalErrors.isEmpty ? NSNull() : vitalErrors.reduce(0, +) / Double(vitalErrors.count)],
        "timingMS": ["decodeP50": percentile(decodeTimes, 0.5), "hudP50": percentile(hudTimes, 0.5), "hudP95": percentile(hudTimes, 0.95),
                     "detectorP50": percentile(detectTimes, 0.5), "detectorP95": percentile(detectTimes, 0.95)],
    ]
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    if let report = options.report { try data.write(to: report, options: .atomic) }
    print(String(data: data, encoding: .utf8)!)
}

do { try run() } catch { FileHandle.standardError.write(Data("ZombsPerceive failed: \(error.localizedDescription)\n".utf8)); exit(1) }
