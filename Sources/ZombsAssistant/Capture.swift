import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit
import AssistantCore

struct CaptureFrame: @unchecked Sendable {
    /// The game area only, BGRA in sRGB, at the display's pixel density.
    let pixelBuffer: CVPixelBuffer
    let timestamp: Double
    let windowID: CGWindowID
    /// The window in global points.
    let windowBounds: CGRect
    /// The captured game area inside the window, in window points (below Chrome's tabs and toolbar).
    let contentRect: CGRect
}

final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var window: SCWindow?
    private var contentRect = CGRect.zero
    private var geometryChanged = false
    private let queue = DispatchQueue(label: "capture.samples", qos: .userInteractive)
    var onFrame: ((CaptureFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    static func windows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.google.Chrome" &&
            Self.isGameTitle($0.title ?? "") && $0.frame.width > 400 && $0.frame.height > 250
        }
    }
    private static func isGameTitle(_ title: String) -> Bool {
        title.localizedCaseInsensitiveContains("zombs") && title.localizedCaseInsensitiveContains("royale")
    }
    /// Captures the window below `topInset` points, the same crop Zombs Recorder uses.
    func start(window: SCWindow, topInset: Double) async throws {
        try await stop()
        self.window = window
        geometryChanged = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
        let inset = min(max(0, topInset), max(0, Double(window.frame.height) - 150))
        contentRect = CGRect(x: 0, y: inset, width: Double(window.frame.width), height: Double(window.frame.height) - inset)
        let config = SCStreamConfiguration()
        config.sourceRect = contentRect
        config.width = Int(Double(contentRect.width) * scale) & ~1
        config.height = Int(Double(contentRect.height) * scale) & ~1
        // Frames that arrive while one is processed are dropped untouched; a high rate keeps the wait short.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    func stop() async throws {
        let old = stream; stream = nil; window = nil
        if let old { try await old.stopCapture() }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard stream === self.stream, type == .screen, buffer.isValid, let pixel = buffer.imageBuffer, let window,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window.windowID) as? [[String:Any]])?.first
        guard Self.isGameTitle(info?[kCGWindowName as String] as? String ?? "") else {
            if !geometryChanged { geometryChanged=true; onFailure?("The selected window no longer shows ZombsRoyale. Return to the game and restart observation.") }
            return
        }
        let presentation = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard presentation.isFinite else { return }
        let bounds = Self.bounds(info) ?? window.frame
        if abs(bounds.width-window.frame.width)>1 || abs(bounds.height-window.frame.height)>1 {
            if !geometryChanged { geometryChanged=true; onFailure?("Game window resized. Refresh windows and restart observation.") }
            return
        }
        onFrame?(CaptureFrame(pixelBuffer: pixel, timestamp: presentation, windowID: window.windowID, windowBounds: bounds, contentRect: contentRect))
    }
    static func bounds(_ id: CGWindowID) -> CGRect? {
        bounds((CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String:Any]])?.first)
    }
    /// The bounds in a window-list entry; each frame reads its title and bounds from one WindowServer query.
    static func bounds(_ info: [String:Any]?) -> CGRect? {
        guard let dict = info?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }
    static func isFocused(_ id: CGWindowID) -> Bool { focusProblem(id) == nil }
    /// Keyboard and mouse events go to the active app, so input is sent only while Chrome is in front.
    /// Which Chrome window is frontmost is not checked: macOS can list Chrome helper windows above the game.
    static func focusProblem(_ id: CGWindowID) -> String? {
        let active = ActiveApp.shared.current
        guard active.bundleID.hasPrefix("com.google.Chrome") else {
            return active.name.isEmpty ? "Chrome is not in front" : "\(active.name) is in front, not Chrome"
        }
        return nil
    }
    static var chromeActive: Bool { ActiveApp.shared.current.bundleID.hasPrefix("com.google.Chrome") }
    /// Makes Chrome the active app with the game window in front. Needs Accessibility access.
    static func bringToFront(_ id: CGWindowID, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if let target = bounds(id), AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for window in windows {
                var position: CFTypeRef?, size: CFTypeRef?
                var p = CGPoint.zero, s = CGSize.zero
                guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                      let position, let size, AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s),
                      abs(p.x - target.minX) <= 2, abs(p.y - target.minY) <= 2, abs(s.width - target.width) <= 2, abs(s.height - target.height) <= 2 else { continue }
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                break
            }
        }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

/// The active app, recorded on the main thread from workspace notifications so capture and input
/// threads read a current value.
final class ActiveApp: @unchecked Sendable {
    static let shared = ActiveApp()
    struct Info { var pid: pid_t; var bundleID: String; var name: String }
    private let lock = NSLock()
    private var info = Info(pid: 0, bundleID: "", name: "")
    private var observer: NSObjectProtocol?
    var current: Info { lock.lock(); defer { lock.unlock() }; return info }
    @MainActor func start() {
        guard observer == nil else { return }
        record(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.record(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }
    private func record(_ app: NSRunningApplication?) {
        lock.lock(); defer { lock.unlock() }
        info = Info(pid: app?.processIdentifier ?? 0, bundleID: app?.bundleIdentifier ?? "", name: app?.localizedName ?? "")
    }
}
