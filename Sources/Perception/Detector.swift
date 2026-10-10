import Foundation
import CoreML
import CoreImage
import CryptoKit
import AssistantCore

public struct Detection: Sendable {
    public var label: String
    public var confidence: Double
    public var bounds: Rect
    public var maskCells: [Rect] = []
    public var id: Int = 0
    public var velocity = Point()
    public var motion: MotionEstimate?
    public var confirmed = false
    /// A briefly missed player at its predicted position; see `PlayerMotionTracker.hold`.
    public var predicted = false
    public init(label: String, confidence: Double, bounds: Rect) { self.label = label; self.confidence = confidence; self.bounds = bounds }
}

public enum ModelError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

public struct ModelManifest: Codable, Sendable {
    public var modelFile: String
    public var modelSHA256: String
    /// The model input's width, and its height unless `inputHeight` is set.
    public var inputSize: Int
    /// The input height when it differs from the width. Up to 960 × 832 the whole YOLO11 model runs on the Neural
    /// Engine; a square 960 input exceeds its 16,384-anchor limit, which sends the model's head to the GPU.
    public var inputHeight: Int?
    public var labels: [String]
    public var detectorThreshold: Double
    public var maskThreshold: Double
    /// Optional per-class operating points calibrated on validation matches.
    public var classThresholds: [String: Double]?
    public var scope: String?
    public func threshold(_ label: String) -> Double { classThresholds?[label] ?? detectorThreshold }
    public var inputPixels: (width: Int, height: Int) { (inputSize, inputHeight ?? inputSize) }
}

/// A frame scaled into the model input, centered on gray.
public struct ModelInput: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    /// The frame's area in buffer pixels, top-left origin.
    public let content: CGRect

    /// The frame part as a standalone image, for previews. No GPU work: the buffer is already small.
    public func cgImage() -> CGImage? {
        let x0 = Int(content.minX.rounded(.up)), y0 = Int(content.minY.rounded(.up))
        let x1 = Int(content.maxX.rounded(.down)), y1 = Int(content.maxY.rounded(.down))
        guard x1 > x0, y1 > y0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = x1 - x0, h = y1 - y0, row = w * 4, stride = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = Data(count: row * h)
        bytes.withUnsafeMutableBytes { out in
            for y in 0..<h { memcpy(out.baseAddress! + y * row, base + (y0 + y) * stride + x0 * 4, row) }
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

public struct ValidationReport: Codable, Sendable {
    public var modelSHA256: String
    public var passed: Bool
    public var matches: Int
    public var modes: [String]
    public var precision: Double
    public var recall: Double
    public var forbiddenInteractions: Int
}

public func fileTreeHash(_ url: URL) throws -> String {
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath:url.path, isDirectory:&directory) else { throw ModelError.invalid("Missing artifact: \(url.lastPathComponent)") }
    let files: [URL]
    if directory.boolValue {
        files = (FileManager.default.enumerator(at:url, includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    } else { files = [url] }
    var hash = SHA256()
    for file in files {
        let name = directory.boolValue ? String(file.path.dropFirst(url.path.count + 1)) : file.lastPathComponent
        hash.update(data: Data(name.utf8)); hash.update(data: Data([0])); hash.update(data: try Data(contentsOf:file))
    }
    return hash.finalize().map { String(format:"%02x",$0) }.joined()
}

/// Runs the exported YOLO11 segmentation model (raw outputs, nms=False) on a viewport frame.
public final class SceneDetector: @unchecked Sendable {
    public let manifest: ModelManifest
    /// Passed the release gate: held-out matches in all three modes at the required precision and recall.
    public let validated: Bool
    public let validationReason: String
    private let model: MLModel
    private let inputName: String
    private let context = CIContext(options:[.cacheIntermediates:false])
    /// Reused IOSurface input buffers: no per-frame allocation, and Core ML reads them without a copy.
    private let inputs: CVPixelBufferPool
    private let background: CIImage
    /// The latest prediction's input, valid until the next prediction.
    public private(set) var lastInput: ModelInput?
    public static let requiredLabels: Set<String> = ["self_player","player","ally_marker","enemy_marker","ground_item","door","chest","wall","rock","tree","revive_target"]

    public init(artifacts: URL) throws {
        let decoder = JSONDecoder()
        manifest = try decoder.decode(ModelManifest.self, from: Data(contentsOf: artifacts.appendingPathComponent("model.json")))
        let (inputWidth, inputHeight) = manifest.inputPixels
        guard (320...1536).contains(inputWidth), (160...inputWidth).contains(inputHeight), manifest.labels.count > 0,
              Set(manifest.labels).count == manifest.labels.count,
              (0.1...0.99).contains(manifest.detectorThreshold), (0.1...0.9).contains(manifest.maskThreshold),
              (manifest.classThresholds ?? [:]).values.allSatisfy({ (0.05...0.99).contains($0) }) else { throw ModelError.invalid("Invalid model manifest") }
        guard Self.requiredLabels.isSubset(of:Set(manifest.labels)) else { throw ModelError.invalid("Model is missing required ZombsRoyale classes") }
        let url = artifacts.appendingPathComponent(manifest.modelFile)
        guard url.standardizedFileURL.path.hasPrefix(artifacts.standardizedFileURL.path + "/") else { throw ModelError.invalid("Model path must be inside artifacts") }
        let hash = try fileTreeHash(url)
        guard hash == manifest.modelSHA256 else { throw ModelError.invalid("Model checksum does not match manifest") }
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at:url)
        let config = MLModelConfiguration(); config.computeUnits = .all
        model = try MLModel(contentsOf:compiled, configuration:config)
        guard let input = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              input.value.imageConstraint?.pixelsWide == inputWidth,
              input.value.imageConstraint?.pixelsHigh == inputHeight else { throw ModelError.invalid("Expected a fixed \(inputWidth)×\(inputHeight) image input") }
        inputName = input.key
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferWidthKey as String: inputWidth, kCVPixelBufferHeightKey as String: inputHeight,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                         kCVPixelBufferMetalCompatibilityKey as String: true]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else { throw ModelError.invalid("Cannot allocate model input") }
        inputs = pool
        background = CIImage(color:CIColor(red:114.0/255,green:114.0/255,blue:114.0/255)).cropped(to:CGRect(x:0,y:0,width:inputWidth,height:inputHeight))
        let report = try? decoder.decode(ValidationReport.self, from: Data(contentsOf: artifacts.appendingPathComponent("validation.json")))
        validated = report.map { $0.modelSHA256 == hash && $0.matches >= 3 && Set($0.modes) == Set(["solo","duo","squad"]) && $0.precision >= 0.98 && $0.recall >= 0.85 && $0.forbiddenInteractions <= 0 } ?? false
        validationReason = validated ? (report?.passed == true ? "Model and supervised acceptance passed" : "Detection evaluation passed; supervised gameplay acceptance is still required")
            : "Beta: \(manifest.scope ?? "unvalidated") detector without held-out results in all three modes"
    }

    /// - Parameter image: the viewport (the image's extent origin must be zero).
    public func predict(_ image: CIImage) throws -> [Detection] {
        let (inputWidth, inputHeight) = manifest.inputPixels
        let width = Double(image.extent.width), height = Double(image.extent.height)
        guard width > 0, height > 0 else { return [] }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, inputs, &buffer) == kCVReturnSuccess, let buffer else { throw ModelError.invalid("Cannot allocate model input") }
        let scale = min(Double(inputWidth)/width,Double(inputHeight)/height)
        let padX = (Double(inputWidth) - width * scale)/2
        let padY = (Double(inputHeight) - height * scale)/2
        let resized = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale)).transformed(by:CGAffineTransform(translationX:padX,y:padY))
        context.render(resized.composited(over:background),to:buffer)
        lastInput = ModelInput(buffer: buffer, content: CGRect(x: padX, y: padY, width: width * scale, height: height * scale))
        let input = try MLDictionaryFeatureProvider(dictionary:[inputName:MLFeatureValue(pixelBuffer:buffer)])
        let result = try model.prediction(from:input)
        let arrays = result.featureNames.compactMap { result.featureValue(for:$0)?.multiArrayValue }
        let classes = manifest.labels.count
        guard let boxes = arrays.first(where: { $0.shape.count == 3 && $0.shape[1].intValue == 4 + classes + 32 }),
              let proto = arrays.first(where: { $0.shape.count == 4 && $0.shape[1].intValue == 32 }) else { throw ModelError.invalid("Expected raw YOLO11 segmentation outputs; export with nms=False") }
        let raw = DenseArray(boxes), prototypes = DenseArray(proto)
        let count = boxes.shape[2].intValue
        // Best class per anchor, scanning each class row contiguously.
        var bestScore = [Double](repeating: 0, count: count), bestClass = [Int](repeating: 0, count: count)
        for c in 0..<classes { for i in 0..<count {
            let p = raw.value(0, 4 + c, i)
            if p > bestScore[i] { bestScore[i] = p; bestClass[i] = c }
        } }
        let floor = min(manifest.detectorThreshold, manifest.classThresholds?.values.min() ?? 1)
        var candidates: [(Detection,Int)] = []
        for i in 0..<count where bestScore[i] >= floor {
            let label = manifest.labels[bestClass[i]]
            guard bestScore[i] >= manifest.threshold(label) else { continue }
            let cx=raw.value(0,0,i), cy=raw.value(0,1,i), w=raw.value(0,2,i), h=raw.value(0,3,i)
            let x=max(0,(cx-w/2-padX)/(scale*width))
            let y=max(0,(cy-h/2-padY)/(scale*height))
            let right=min(1,(cx+w/2-padX)/(scale*width))
            let bottom=min(1,(cy+h/2-padY)/(scale*height))
            let bounds=Rect(x,y,right-x,bottom-y)
            guard bounds.isValid else { continue }
            candidates.append((Detection(label:label,confidence:bestScore[i],bounds:bounds),i))
        }
        candidates.sort { $0.0.confidence > $1.0.confidence }
        var kept: [(Detection,Int)] = []
        for candidate in candidates.prefix(1000) {
            if !kept.contains(where: { $0.0.label == candidate.0.label && Self.iou($0.0.bounds,candidate.0.bounds) > 0.45 }) { kept.append(candidate) }
            if kept.count == 100 { break }
        }
        let obstacleLabels: Set<String> = ["wall","rock","tree","door","chest"]
        let ph = proto.shape[2].intValue, pw = proto.shape[3].intValue
        return kept.map { detection,index in
            var detection=detection
            if obstacleLabels.contains(detection.label) {
                let coefficients=(0..<32).map { raw.value(0,4+classes+$0,index) }
                let b=detection.bounds, grid=12
                for row in 0..<grid { for col in 0..<grid {
                    let x=b.x+b.width*(Double(col)+0.5)/Double(grid), y=b.y+b.height*(Double(row)+0.5)/Double(grid)
                    let px=min(pw-1,max(0,Int((x*width*scale+padX)/Double(inputWidth)*Double(pw))))
                    let py=min(ph-1,max(0,Int((y*height*scale+padY)/Double(inputHeight)*Double(ph))))
                    var logit=0.0
                    for k in 0..<32 { logit += coefficients[k]*prototypes.value(0,k,py,px) }
                    if 1/(1+exp(-logit)) >= manifest.maskThreshold {
                        detection.maskCells.append(Rect(b.x+b.width*Double(col)/Double(grid),b.y+b.height*Double(row)/Double(grid),b.width/Double(grid),b.height/Double(grid)))
                    }
                } }
            }
            return detection
        }
    }
    static func iou(_ a:Rect,_ b:Rect)->Double {
        let area=max(0,min(a.x+a.width,b.x+b.width)-max(a.x,b.x))*max(0,min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
        return area/max(1e-9,a.width*a.height+b.width*b.height-area)
    }
}

/// Typed, stride-aware reads from a model output without per-element bridging.
struct DenseArray {
    let pointer: UnsafeMutableRawPointer
    /// Set for float32 outputs, the usual case, so reads skip the type dispatch.
    let floats: UnsafeMutablePointer<Float>?
    let s0: Int, s1: Int, s2: Int, s3: Int
    let type: MLMultiArrayDataType
    let array: MLMultiArray
    init(_ array: MLMultiArray) {
        self.array = array; pointer = array.dataPointer; type = array.dataType
        floats = type == .float32 ? pointer.assumingMemoryBound(to: Float.self) : nil
        let strides = array.strides.map(\.intValue) + [0, 0, 0, 0]
        s0 = strides[0]; s1 = strides[1]; s2 = strides[2]; s3 = strides[3]
    }
    @inline(__always) func read(_ offset: Int) -> Double {
        if let floats { return Double(floats[offset]) }
        switch type {
        case .float16: return Double(pointer.assumingMemoryBound(to: Float16.self)[offset])
        case .double: return pointer.assumingMemoryBound(to: Double.self)[offset]
        default: return array[offset].doubleValue
        }
    }
    @inline(__always) func value(_ a: Int, _ b: Int, _ c: Int) -> Double { read(a * s0 + b * s1 + c * s2) }
    @inline(__always) func value(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double { read(a * s0 + b * s1 + c * s2 + d * s3) }
}

/// Associates detections across frames: players through the ground-motion tracker, everything else by
/// nearest match after compensating the camera shift measured from static scenery.
public final class SceneTracker {
    private var previous:[Detection]=[]
    private var time=0.0
    private var nextID=1
    private var motion=PlayerMotionTracker()
    public init() {}
    public func reset() { previous=[]; time=0; motion.reset() }
    public func update(_ input:[Detection], at timestamp:Double, aspect:Double)->[Detection] {
        let dt=timestamp-time
        let fresh=dt > 0 && dt < 0.3
        // Static obstacles estimate camera translation; identity matching includes that shift.
        let staticLabels:Set<String>=["wall","rock","tree","door","chest"]
        let shifts = !fresh ? [] : input.filter { staticLabels.contains($0.label) }.compactMap { current -> Point? in
            guard let old=previous.filter({ $0.label==current.label }).min(by:{ $0.bounds.center.distance(to:current.bounds.center)<$1.bounds.center.distance(to:current.bounds.center) }), old.bounds.center.distance(to:current.bounds.center)<0.08 else { return nil }
            return current.bounds.center-old.bounds.center
        }
        func median(_ values:[Double])->Double { values.isEmpty ? 0 : values.sorted()[values.count/2] }
        let camera=Point(median(shifts.map(\.x)),median(shifts.map(\.y)))
        // Players get ground-motion filters, which keep their identity through brief misses.
        let playerIndices=input.indices.filter { input[$0].label=="player" }
        let tracks=motion.update(time:timestamp,aspect:aspect,sceneryShift:shifts.isEmpty ? nil : camera,
                                 players:playerIndices.map { input[$0].bounds.center })
        var result=input
        for (index,track) in zip(playerIndices,tracks) {
            result[index].id=track.id; result[index].velocity=track.velocity; result[index].motion=track.motion; result[index].confirmed=track.confirmed
        }
        // A confirmed player the detector missed stays briefly where its motion predicts, with its last box size.
        for (track,position) in motion.held {
            guard position.isInViewport, let last=previous.first(where:{ $0.label=="player" && $0.id==track.id }) else { continue }
            let w=last.bounds.width, h=last.bounds.height
            var d=Detection(label:"player",confidence:last.confidence,bounds:Rect(min(max(0,position.x-w/2),1-w),min(max(0,position.y-h/2),1-h),w,h))
            d.id=track.id; d.velocity=track.velocity; d.motion=track.motion; d.confirmed=true; d.predicted=true
            result.append(d)
        }
        var used=Set<Int>()
        for index in result.indices where result[index].label != "player" {
            let d=result[index]
            let matches=fresh ? previous.filter { $0.label==d.label && !used.contains($0.id) } : []
            if let old=matches.min(by:{ ($0.bounds.center+camera).distance(to:d.bounds.center)<($1.bounds.center+camera).distance(to:d.bounds.center) }), (old.bounds.center+camera).distance(to:d.bounds.center)<0.08 {
                result[index].id=old.id; used.insert(old.id)
                let relative=(d.bounds.center-old.bounds.center)*(1/dt)
                result[index].velocity=old.velocity*0.5+relative*0.5
            } else { result[index].id=nextID; nextID += 1 }
        }
        previous=result; time=timestamp; return result
    }
}
