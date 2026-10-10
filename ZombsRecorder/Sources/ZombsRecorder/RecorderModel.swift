import SwiftUI
import ScreenCaptureKit
import CryptoKit
import RecorderCore

@MainActor
final class RecorderModel: ObservableObject {
    static let minimumSeconds = 20.0
    static let maximumSeconds = 45.0 * 60
    static let windowGoneSeconds = 10.0
    static let defaultTopInset = 87.0

    @Published var mode: GameMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var recordedBy: String { didSet { defaults.set(recordedBy, forKey: "recordedBy") } }
    @Published var teammates: String { didSet { defaults.set(teammates, forKey: "teammates") } }
    @Published var topInset: Double { didSet { defaults.set(topInset, forKey: "topInset") } }
    @Published var uploadsEnabled: Bool {
        didSet { defaults.set(uploadsEnabled, forKey: "uploadsEnabled"); uploadsOn.current = uploadsEnabled; wakeUploads() }
    }
    @Published var deleteAfterUpload: Bool {
        didSet { defaults.set(deleteAfterUpload, forKey: "deleteAfterUpload"); deleteVideo.current = deleteAfterUpload; wakeUploads() }
    }
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var upload = UploadStatus()
    @Published private(set) var credentials: Credentials?
    @Published private(set) var notice: String?

    let store: MatchStore?
    private let defaults = UserDefaults.standard
    private let isRecording = Locked(false)
    private let uploadsOn = Locked(true)
    private let deleteVideo = Locked(true)
    private let wake = Locked(false)
    private var queue: UploadQueue?
    private var recordKey: RecordKey?
    private var session: CaptureSession?
    private var start: RecordingStart?
    private var directory: URL?
    private var startedAt = Date()
    private var monitor: Timer?
    private var goneSince: Date?
    private var activity: NSObjectProtocol?
    private var uploadLoop: Task<Void, Never>?

    init() {
        mode = GameMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .solo
        recordedBy = defaults.string(forKey: "recordedBy") ?? NSFullUserName()
        teammates = defaults.string(forKey: "teammates") ?? ""
        topInset = defaults.object(forKey: "topInset") as? Double ?? Self.defaultTopInset
        uploadsEnabled = defaults.object(forKey: "uploadsEnabled") as? Bool ?? true
        deleteAfterUpload = defaults.object(forKey: "deleteAfterUpload") as? Bool ?? true
        store = try? MatchStore()
        uploadsOn.current = uploadsEnabled
        deleteVideo.current = deleteAfterUpload
        guard let store else { notice = "Cannot create ~/Library/Application Support/ZombsRecorder."; return }
        applyBuiltInSetupCode(store)
        credentials = store.loadCredentials()
        queue = UploadQueue(store: store, isRecording: { [isRecording] in isRecording.current },
                            deleteAfterUpload: { [deleteVideo] in deleteVideo.current },
                            report: { [weak self] status in Task { @MainActor in self?.upload = status } })
        recordKey = RecordKey { [weak self] in self?.toggle(.hotkey) }
        // Listed now, before any recording can start, so recovery never touches a new recording.
        let unfinished = store.unfinished()
        Task {
            for folder in unfinished {
                if let manifest = await store.recover(folder, minimumSeconds: Self.minimumSeconds) {
                    say("Recovered an unfinished \(manifest.mode.rawValue) recording.")
                }
            }
            startUploadLoop()
        }
    }

    var menuTitle: String {
        recording ? "\(Self.clock(elapsed)) \(mode.rawValue.uppercased())" : mode.rawValue.uppercased()
    }

    var statusLine: String {
        if recording { return "Recording \(mode.rawValue) · \(Self.clock(elapsed))" }
        return busy ? "Working…" : "Not recording · press \(RecordKey.label) in the game to start"
    }

    var uploadLine: String {
        if !uploadsEnabled { return "Uploads off · \(upload.pending) waiting" }
        if upload.needsCredentials { return "Uploads need the setup code (Setup…)" }
        if upload.waitingForMatch { return "Uploads paused until this match ends" }
        if upload.current != nil, let fraction = upload.fraction {
            return "Uploading \(Int(fraction * 100))% · \(upload.pending) waiting"
        }
        if upload.pending > 0 { return "\(upload.pending) waiting to upload (\(Self.size(upload.pendingBytes)))" }
        return upload.uploaded > 0 ? "All \(upload.uploaded) recordings uploaded" : "Nothing to upload yet"
    }

    func toggle(_ reason: EndReason = .menu) {
        if recording { Task { await stop(reason) } } else { Task { await startRecording() } }
    }

    func startRecording() async {
        guard !recording, !busy, let store else { return }
        guard CGPreflightScreenCaptureAccess() else {
            Feedback.failed()
            requestScreenRecording()
            say("Allow Screen Recording for ZombsRecorder (Setup…), then reopen it.")
            return
        }
        busy = true
        defer { busy = false }
        do {
            guard let window = try await GameWindow.find() else {
                Feedback.failed()
                say("Open ZombsRoyale in Chrome first.")
                return
            }
            let id = MatchID.make()
            let directory = store.directory(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let session = try await CaptureSession(window: window, directory: directory, topInset: topInset)
                let start = RecordingStart(matchID: id, mode: mode, teammates: teammateList, recordedBy: recorderName,
                                           createdAt: timestamp(), capture: session.info)
                try writeJSON(start, to: directory.appendingPathComponent(MatchFiles.start))
                session.onPartStarted = { [weak self] index, seconds in Task { @MainActor in self?.partStarted(index, seconds) } }
                session.onFailure = { [weak self] message in Task { @MainActor in await self?.stop(.error, note: message) } }
                isRecording.current = true  // Uploads pause before the first frame.
                try await session.start()
                self.session = session; self.start = start; self.directory = directory
                startedAt = Date(); elapsed = 0; goneSince = nil
                recording = true
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Recording a ZombsRoyale match")
                monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
                Feedback.started()
                say("Recording a \(mode.rawValue) match. Press \(RecordKey.label) again to stop.")
            } catch {
                isRecording.current = false
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        } catch {
            Feedback.failed()
            say("Could not start recording: \(error.localizedDescription)")
        }
    }

    func stop(_ reason: EndReason, note: String? = nil) async {
        guard recording, let session, let start, let directory else { return }
        recording = false
        busy = true
        defer { busy = false }
        monitor?.invalidate(); monitor = nil
        self.session = nil; self.start = nil; self.directory = nil
        let parts = await session.stop()
        endActivity()
        let duration = parts.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
        guard duration >= Self.minimumSeconds else {
            try? FileManager.default.removeItem(at: directory)
            isRecording.current = false
            say("Discarded a \(Int(duration)) s recording: anything under 20 s is treated as an accidental start.")
            return
        }
        let manifest = await Task.detached(priority: .utility) {
            Self.finalize(directory: directory, start: start, parts: parts, reason: reason)
        }.value
        isRecording.current = false
        Feedback.stopped()
        guard let manifest else {
            say("Could not save the recording files in \(directory.lastPathComponent).")
            return
        }
        // An automatic stop says why it stopped.
        say((note.map { $0 + " " } ?? "") + "Saved a \(Self.clock(manifest.durationSeconds)) \(manifest.mode.rawValue) match"
            + (uploadsEnabled ? "; it uploads next." : "."))
        wakeUploads()
    }

    func discard() async {
        guard recording, let session, let directory else { return }
        recording = false
        monitor?.invalidate(); monitor = nil
        self.session = nil; self.start = nil; self.directory = nil
        _ = await session.stop()
        endActivity()
        try? FileManager.default.removeItem(at: directory)
        isRecording.current = false
        say("Recording discarded.")
    }

    nonisolated static func finalize(directory: URL, start: RecordingStart, parts: [FinishedPart], reason: EndReason) -> RecordingManifest? {
        let recorded = parts.compactMap { part -> RecordingPart? in
            let url = directory.appendingPathComponent(part.file)
            guard let digest = try? sha256Hex(of: url) else { return nil }
            return RecordingPart(file: part.file, width: part.width, height: part.height, frames: part.frames,
                                 startSeconds: part.startSeconds, durationSeconds: part.durationSeconds, bytes: fileSize(url), sha256: digest)
        }
        guard !recorded.isEmpty else { return nil }
        let manifest = RecordingManifest(start: start, endedAt: timestamp(), endReason: reason, parts: recorded)
        do { try writeJSON(manifest, to: directory.appendingPathComponent(MatchFiles.manifest)) } catch { return nil }
        return manifest
    }

    private func partStarted(_ index: Int, _ seconds: Double) {
        guard var start, let directory else { return }
        if index >= start.partStarts.count { start.partStarts.append(contentsOf: Array(repeating: seconds, count: index - start.partStarts.count + 1)) }
        start.partStarts[index] = seconds
        self.start = start
        try? writeJSON(start, to: directory.appendingPathComponent(MatchFiles.start))
    }

    private func tick() {
        guard recording, let session else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.maximumSeconds {
            Task { await stop(.maxDuration, note: "Stopped after 45 minutes. Start a new recording for the next match.") }
            return
        }
        if let info = GameWindow.info(session.windowID), GameWindow.isGameTitle(info.title) {
            goneSince = nil
        } else {
            let since = goneSince ?? Date()
            goneSince = since
            if Date().timeIntervalSince(since) >= Self.windowGoneSeconds {
                Task { await stop(.windowClosed, note: "The ZombsRoyale window closed or left the game page.") }
            }
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private var teammateList: [String] {
        teammates.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Uploads

    private func startUploadLoop() {
        guard let queue, uploadLoop == nil else { return }
        let uploadsOn = uploadsOn, wake = wake
        uploadLoop = Task.detached(priority: .utility) {
            var delay = 20.0
            while !Task.isCancelled {
                if uploadsOn.current {
                    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Uploading recorded matches")
                    let status = await queue.runPending()
                    ProcessInfo.processInfo.endActivity(activity)
                    delay = status.problem == nil ? 20 : min(delay * 2, 600)  // Back off while Kaggle or the network fails.
                }
                var waited = 0.0
                while waited < delay && !wake.current && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    waited += 1
                }
                wake.current = false
            }
        }
    }

    func wakeUploads() { wake.current = true }

    func retryFailed() {
        queue?.retryFailed()
        wakeUploads()
    }

    // MARK: Setup

    /// The setup window opens at launch until screen recording is allowed, uploads are set up and Done was clicked once.
    var needsSetup: Bool { !CGPreflightScreenCaptureAccess() || credentials == nil || !defaults.bool(forKey: "setupDone") }

    func finishSetup() { defaults.set(true, forKey: "setupDone") }

    private var recorderName: String {
        let name = recordedBy.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? NSFullUserName() : name
    }

    /// A friend kit carries the owner's setup code inside the app. Apply it once per new code,
    /// so a later kit with a new token replaces the old one without undoing changes made in Setup.
    private func applyBuiltInSetupCode(_ store: MatchStore) {
        guard let url = Bundle.main.url(forResource: "setup-code", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8), let code = Credentials(setupCode: text) else { return }
        let fingerprint = SHA256.hash(data: Data(code.setupCode.utf8)).map { String(format: "%02x", $0) }.joined()
        guard defaults.string(forKey: "builtInSetupCode") != fingerprint, (try? store.saveCredentials(code)) != nil else { return }
        defaults.set(fingerprint, forKey: "builtInSetupCode")
    }

    /// macOS shows its own prompt only for the first request; after that the switch is in System Settings.
    func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        if defaults.bool(forKey: "askedForScreenRecording") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            defaults.set(true, forKey: "askedForScreenRecording")
            CGRequestScreenCaptureAccess()
        }
    }

    func openGuide() {
        if let guide = Bundle.main.url(forResource: "SetupGuide", withExtension: "html") { NSWorkspace.shared.open(guide) }
    }

    // MARK: Settings

    /// Returns an error message, or nil once the code is checked with Kaggle and saved.
    func useSetupCode(_ code: String) async -> String? {
        guard let decoded = Credentials(setupCode: code) else { return "That is not a Zombs Recorder setup code." }
        return await connect(token: decoded.token, expectedOwner: decoded.owner)
    }

    func useLocalToken() async -> String? {
        guard let token = Credentials.localAccessToken() else { return "No token in ~/.kaggle/access_token." }
        return await connect(token: token, expectedOwner: nil)
    }

    private func connect(token: String, expectedOwner: String?) async -> String? {
        do {
            guard let username = try await KaggleClient(token: token).username() else { return "Kaggle reports this token as inactive." }
            if let expectedOwner, expectedOwner.lowercased() != username.lowercased() {
                return "The token belongs to \(username), not \(expectedOwner)."
            }
            let credentials = Credentials(owner: username, token: token)
            try store?.saveCredentials(credentials)
            self.credentials = credentials
            wakeUploads()
            return nil
        } catch {
            return "Could not check the token with Kaggle: \(error.localizedDescription)"
        }
    }

    func copySetupCode() {
        guard let credentials else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(credentials.setupCode, forType: .string)
    }

    func openRecordings() {
        if let store { NSWorkspace.shared.open(store.matches) }
    }

    /// A 1× still of the whole game window for placing the top inset.
    func windowPreview() async -> (image: CGImage, size: CGSize)? {
        guard CGPreflightScreenCaptureAccess(), let window = try? await GameWindow.find() else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { return nil }
        return (image, window.frame.size)
    }

    private func say(_ message: String) { notice = message }

    static func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
