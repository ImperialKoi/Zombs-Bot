import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import RecorderCore

enum GameWindow {
    static func isGameTitle(_ title: String) -> Bool {
        title.localizedCaseInsensitiveContains("zombs") && title.localizedCaseInsensitiveContains("royale")
    }

    /// The largest Chrome window showing ZombsRoyale (same filter as ZombsAssistant's CaptureService).
    static func find() async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter {
            ($0.owningApplication?.bundleIdentifier ?? "").hasPrefix("com.google.Chrome") &&
            isGameTitle($0.title ?? "") && $0.frame.width > 400 && $0.frame.height > 250
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The ZombsRoyale window if it is Chrome's front window and Chrome is the front app, else nil.
    static func frontmostGame() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication, (app.bundleIdentifier ?? "").hasPrefix("com.google.Chrome"),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        // The list runs front to back; skip Chrome's small helper windows (popups, status bubbles).
        let front = windows.first { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier, (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return frame.width > 400 && frame.height > 250
        }
        guard let front, isGameTitle(front[kCGWindowName as String] as? String ?? "") else { return nil }
        return front[kCGWindowNumber as String] as? CGWindowID
    }

    /// Title and size of a window, or nil once it has closed.
    static func info(_ id: CGWindowID) -> (title: String, size: CGSize)? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        return (entry[kCGWindowName as String] as? String ?? "", frame.size)
    }
}

enum CaptureError: LocalizedError {
    case noHardwareEncoder, windowTooSmall, writer(String)
    var errorDescription: String? {
        switch self {
        case .noHardwareEncoder: return "This Mac has no hardware video encoder for the game window's size, so recording would load the CPU."
        case .windowTooSmall: return "The game area is too small. Check the top inset in Settings."
        case .writer(let message): return message
        }
    }
}

/// Captures the game area of one Chrome window into `part-NNN.mov` files.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let windowID: CGWindowID
    let info: CaptureInfo
    private let filter: SCContentFilter
    private let directory: URL
    private let topInset: Double
    private let scale: Double
    private let codec: CMVideoCodecType
    private let queue = DispatchQueue(label: "recorder.capture", qos: .userInitiated)
    private var stream: SCStream?
    // Touched only on `queue`.
    private var geometry: CaptureGeometry
    private var windowSize: CGSize
    private var writer: MovieWriter?
    private var nextPart = 0
    private var matchStart: CMTime?
    private var lastCheck = 0.0
    private var dropUntil = 0.0
    private var gameVisible = true
    private var finishing: [Task<FinishedPart?, Never>] = []
    var onFailure: ((String) -> Void)?
    var onPartStarted: ((Int, Double) -> Void)?

    init(window: SCWindow, directory: URL, topInset: Double) async throws {
        windowID = window.windowID
        filter = SCContentFilter(desktopIndependentWindow: window)
        scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        guard let geometry = CaptureGeometry(windowSize: window.frame.size, topInset: topInset, scale: scale) else { throw CaptureError.windowTooSmall }
        guard let codec = VideoEncoding.preferredCodec(width: geometry.width, height: geometry.height) else { throw CaptureError.noHardwareEncoder }
        self.geometry = geometry
        self.directory = directory
        self.topInset = topInset
        self.codec = codec
        windowSize = window.frame.size
        info = CaptureInfo(fps: VideoEncoding.fps, codec: codec == kCMVideoCodecType_HEVC ? "hevc" : "h264",
                           bitrate: VideoEncoding.bitrate(width: geometry.width, height: geometry.height),
                           topInsetPoints: topInset, scale: scale)
        super.init()
    }

    private func configuration(_ geometry: CaptureGeometry) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = geometry.sourceRect  // Crops off Chrome's tabs and toolbar before anything is encoded.
        config.width = geometry.width
        config.height = geometry.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(VideoEncoding.fps))
        config.queueDepth = 4
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration(geometry), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capture and finishes every part. Returns the parts that contain frames, in order.
    func stop() async -> [FinishedPart] {
        try? await stream?.stopCapture()
        stream = nil
        let tasks: [Task<FinishedPart?, Never>] = queue.sync {
            rotate()
            return finishing
        }
        var parts: [FinishedPart] = []
        for task in tasks { if let part = await task.value { parts.append(part) } }
        return parts.sorted { $0.index < $1.index }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure?(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let pixels = buffer.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        checkWindow()
        // Never record another tab or page: only frames while the window shows ZombsRoyale.
        guard gameVisible, ProcessInfo.processInfo.systemUptime >= dropUntil else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard width == geometry.width, height == geometry.height else { return }  // Old size, before a reconfiguration applied.
        if let writer, writer.width != width || writer.height != height { rotate() }
        let time = buffer.presentationTimeStamp
        if matchStart == nil { matchStart = time }
        if writer == nil {
            let start = (time - matchStart!).seconds
            do {
                writer = try MovieWriter(index: nextPart, url: directory.appendingPathComponent(MatchFiles.part(nextPart)),
                                        width: width, height: height, codec: codec, startSeconds: start)
                onPartStarted?(nextPart, start)
                nextPart += 1
            } catch {
                onFailure?(error.localizedDescription)
                return
            }
        }
        writer?.append(pixels, at: time)
    }

    private func rotate() {
        if let old = writer { finishing.append(Task { await old.finish() }) }
        writer = nil
    }

    /// Four times a second: is the window still on ZombsRoyale, and has it been resized?
    private func checkWindow() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCheck >= 0.25 else { return }
        lastCheck = now
        guard let current = GameWindow.info(windowID) else { gameVisible = false; return }
        gameVisible = GameWindow.isGameTitle(current.title)
        guard abs(current.size.width - windowSize.width) > 1 || abs(current.size.height - windowSize.height) > 1 else { return }
        windowSize = current.size
        guard let next = CaptureGeometry(windowSize: current.size, topInset: topInset, scale: scale) else { gameVisible = false; return }
        if next.width == geometry.width && next.height == geometry.height { dropUntil = now + 0.5 }  // Same output size: skip frames cropped with the old rectangle.
        geometry = next
        let config = configuration(next)
        Task { [weak self] in
            do { try await self?.stream?.updateConfiguration(config) } catch { self?.onFailure?(error.localizedDescription) }
        }
    }
}
