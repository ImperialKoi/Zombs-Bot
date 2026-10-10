import Foundation
import ImageIO
import UniformTypeIdentifiers
import AssistantCore
import Perception

final class SessionRecorder {
    private let queue=DispatchQueue(label:"session.recorder",qos:.utility)
    private let lock=NSLock()
    private var directory:URL?
    private var lastImage = -Double.infinity
    private var index=0
    private var scheduled=0
    private var mode:GameMode = .solo
    var onError:((String)->Void)?
    func start(in root:URL,mode:GameMode)throws {
        let id=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")+"-"+UUID().uuidString.prefix(6)
        let directory=root.appendingPathComponent(String(id))
        try FileManager.default.createDirectory(at:directory.appendingPathComponent("images"),withIntermediateDirectories:true)
        let manifest:[String:Any]=["matchID":String(id),"mode":mode.rawValue,"coordinateSystem":"viewport-normalized-top-left","createdAt":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("session.json"))
        for name in ["observations.jsonl", "decisions.jsonl", "frames.jsonl"] {
            try Data().write(to:directory.appendingPathComponent(name))
        }
        lock.lock(); self.directory=directory; self.mode=mode; lastImage = -.infinity; index=0; lock.unlock()
    }
    func stop() { lock.lock(); directory=nil; lock.unlock() }
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return directory != nil }
    /// `image` is only called for frames saved as JPEG (up to 5 per second).
    func append(image makeImage:()->CGImage?,observation:Observation,decision:Decision) {
        lock.lock()
        guard let directory, scheduled<3 else { lock.unlock(); return }
        let saveImage=observation.timestamp-lastImage>=0.2
        let frameIndex=index; index += 1
        if saveImage { lastImage=observation.timestamp }
        let mode=self.mode; scheduled += 1; lock.unlock()
        let image = saveImage ? makeImage() : nil
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.scheduled -= 1; self.lock.unlock() }
            do {
                let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
                try self.appendLine(encoder.encode(observation),to:directory.appendingPathComponent("observations.jsonl"))
                try self.appendLine(encoder.encode(decision),to:directory.appendingPathComponent("decisions.jsonl"))
                if let image {
                    let name=String(format:"images/%06d.jpg",frameIndex)
                    let url=directory.appendingPathComponent(name)
                    guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw ModelError.invalid("Cannot create recording image") }
                    CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw ModelError.invalid("Cannot save recording image") }
                    let row:[String:Any]=["image":name,"timestamp":observation.timestamp,"mode":mode.rawValue,"matchID":directory.lastPathComponent,"width":image.width,"height":image.height]
                    try self.appendLine(JSONSerialization.data(withJSONObject:row,options:.sortedKeys),to:directory.appendingPathComponent("frames.jsonl"))
                }
            } catch { self.onError?(error.localizedDescription) }
        }
    }
    private func appendLine(_ data:Data,to url:URL)throws {
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil) }
        let handle=try FileHandle(forWritingTo:url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf:data); try handle.write(contentsOf:Data([10]))
    }
}
