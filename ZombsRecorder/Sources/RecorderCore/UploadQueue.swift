import Foundation

/// `upload.json` in a match folder: lets an upload continue after a quit, sleep or lost connection.
public struct UploadState: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var size: Int64
        public var token: String?
        public var url: String?
        public var sent: Int64
        public var done: Bool
    }
    public var slug: String
    public var files: [File]
    public var ref: String?
    public var created: Bool
    public var ready: Bool
    public var failed: String?
    public var videoDeleted: Bool

    init(slug: String, files: [File]) {
        self.slug = slug; self.files = files; created = false; ready = false; videoDeleted = false
    }
}

public struct UploadStatus: Equatable, Sendable {
    public var pending = 0
    public var pendingBytes: Int64 = 0
    public var uploaded = 0
    public var failed = 0
    public var current: String?
    public var fraction: Double?
    public var waitingForMatch = false
    public var needsCredentials = false
    public var problem: String?
    public init() {}
}

/// Uploads each finished match as its own private Kaggle dataset, oldest first, one at a time.
/// Every network step waits while a match is being recorded so uploads never compete with the game.
public final class UploadQueue: @unchecked Sendable {
    let store: MatchStore
    let session: URLSession
    let kaggleBase: String
    let isRecording: @Sendable () -> Bool
    let deleteAfterUpload: @Sendable () -> Bool
    let report: @Sendable (UploadStatus) -> Void
    public var chunkSize = 8 << 20
    public var pauseCheckSeconds = 2.0
    public var readyPollSeconds = 10.0
    public var readyTimeoutSeconds = 600.0
    private var status = UploadStatus()
    private let lock = NSLock()
    private var running = false

    public init(store: MatchStore, session: URLSession = KaggleClient.session, kaggleBase: String = "https://api.kaggle.com/v1",
                isRecording: @escaping @Sendable () -> Bool, deleteAfterUpload: @escaping @Sendable () -> Bool,
                report: @escaping @Sendable (UploadStatus) -> Void) {
        self.store = store; self.session = session; self.kaggleBase = kaggleBase
        self.isRecording = isRecording; self.deleteAfterUpload = deleteAfterUpload; self.report = report
    }

    public func state(_ folder: URL) -> UploadState? { try? readJSON(UploadState.self, from: folder.appendingPathComponent(MatchFiles.upload)) }
    private func save(_ state: UploadState, _ folder: URL) { try? writeJSON(state, to: folder.appendingPathComponent(MatchFiles.upload)) }

    func needsWork(_ folder: URL) -> Bool {
        guard let state = state(folder) else { return true }
        if state.failed != nil { return false }
        return !state.ready || (deleteAfterUpload() && !state.videoDeleted)
    }

    /// Clear permanent failures so the next run tries those matches again.
    public func retryFailed() {
        for match in store.finished() {
            if var state = state(match.directory), state.failed != nil { state.failed = nil; save(state, match.directory) }
        }
    }

    /// Process every match that still needs uploading. Returns when done, blocked, or a transient error occurs;
    /// the caller schedules the next run.
    private func claim(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value && running { return false }
        running = value
        return true
    }

    @discardableResult
    public func runPending() async -> UploadStatus {
        guard claim(true) else { return status }
        defer { _ = claim(false) }

        status = UploadStatus()
        refreshCounts()
        let todo = store.finished().filter { needsWork($0.directory) }
        guard !todo.isEmpty else { report(status); return status }
        guard let credentials = store.loadCredentials() else {
            status.needsCredentials = true
            status.problem = "Paste the setup code in Settings to start uploading"
            report(status)
            return status
        }
        let client = KaggleClient(token: credentials.token, session: session, base: kaggleBase)
        for match in todo {
            do {
                status.current = match.manifest.matchID
                try await process(match.directory, match.manifest, credentials, client)
            } catch let error as KaggleError where error.isAuthFailure {
                status.needsCredentials = true
                status.problem = "Kaggle rejected the token. Paste a new setup code in Settings."
                break
            } catch is CancellationError {
                break
            } catch let error as KaggleError where !error.isTransient {
                // A permanent problem with this match; keep going with the others.
                if var state = state(match.directory) { state.failed = error.localizedDescription; save(state, match.directory) }
                status.problem = "\(match.manifest.matchID): \(error.localizedDescription)"
            } catch {
                status.problem = "Upload paused: \(error.localizedDescription)"
                break
            }
        }
        status.current = nil; status.fraction = nil; status.waitingForMatch = false
        refreshCounts()
        report(status)
        return status
    }

    private func refreshCounts() {
        status.pending = 0; status.pendingBytes = 0; status.uploaded = 0; status.failed = 0
        for match in store.finished() {
            let state = state(match.directory)
            if state?.failed != nil { status.failed += 1 }
            else if state?.ready == true { status.uploaded += 1 }
            else {
                status.pending += 1
                let sent = state?.files.reduce(0) { $0 + ($1.done ? $1.size : $1.sent) } ?? 0
                status.pendingBytes += max(0, match.manifest.bytes - sent)
            }
        }
    }

    private func process(_ folder: URL, _ manifest: RecordingManifest, _ credentials: Credentials, _ client: KaggleClient) async throws {
        let names = manifest.parts.map(\.file) + [MatchFiles.manifest]
        var state = state(folder) ?? UploadState(slug: MatchID.slug(manifest.matchID), files: names.map {
            .init(name: $0, size: fileSize(folder.appendingPathComponent($0)), token: nil, url: nil, sent: 0, done: false)
        })
        save(state, folder)
        if !state.ready {
            if !state.created {
                for index in state.files.indices where !state.files[index].done {
                    try await uploadFile(index, &state, folder, client)
                }
                try await waitForMatchToEnd()
                // Idempotent: a crash right after CreateDataset leaves the dataset in place.
                if try await client.datasetStatus(owner: credentials.owner, slug: state.slug) == .missing {
                    state.ref = try await client.createDataset(owner: credentials.owner, slug: state.slug,
                                                               title: MatchID.title(manifest.matchID, mode: manifest.mode),
                                                               blobTokens: state.files.compactMap(\.token))
                }
                state.ref = state.ref ?? "\(credentials.owner)/\(state.slug)"
                state.created = true
                save(state, folder)
            }
            let deadline = Date().addingTimeInterval(readyTimeoutSeconds)
            while !state.ready {
                switch try await client.datasetStatus(owner: credentials.owner, slug: state.slug) {
                case .ready:
                    state.ready = true
                    save(state, folder)
                case .failed(let reason):
                    throw KaggleError.invalid("Kaggle could not process the dataset (\(reason))")
                case .missing where Date() >= deadline:
                    // Creation did not stick; start over (blob tokens may have expired) on the next run.
                    state = UploadState(slug: state.slug, files: state.files.map { .init(name: $0.name, size: $0.size, token: nil, url: nil, sent: 0, done: false) })
                    save(state, folder)
                    return
                case .missing, .pending:
                    guard Date() < deadline else { return }  // Still processing; check on the next run.
                    try await Task.sleep(for: .seconds(readyPollSeconds))
                }
            }
        }
        if deleteAfterUpload() && !state.videoDeleted {
            for part in manifest.parts { try? FileManager.default.removeItem(at: folder.appendingPathComponent(part.file)) }
            state.videoDeleted = true
            save(state, folder)
        }
    }

    private func uploadFile(_ index: Int, _ state: inout UploadState, _ folder: URL, _ client: KaggleClient) async throws {
        let name = state.files[index].name
        let file = folder.appendingPathComponent(name)
        let size = fileSize(file)
        let total = max(1, state.files.reduce(Int64(0)) { $0 + $1.size })
        let before = state.files.prefix(index).reduce(Int64(0)) { $0 + $1.size }
        let uploader = ResumableUploader(session: session, chunkSize: chunkSize)
        for _ in 0..<3 {
            try await waitForMatchToEnd()
            if state.files[index].token == nil || state.files[index].url == nil || state.files[index].size != size {
                let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
                let blob = try await client.startBlobUpload(name: name, size: size, contentType: name.hasSuffix(".json") ? "application/json" : "video/quicktime",
                                                            lastModified: modified)
                state.files[index] = .init(name: name, size: size, token: blob.token, url: blob.createUrl, sent: 0, done: false)
                save(state, folder)
            }
            guard let target = URL(string: state.files[index].url ?? "") else { throw KaggleError.invalid("Bad upload URL for \(name)") }
            var progress = ResumableUploader.Progress.received(state.files[index].sent)
            if state.files[index].sent > 0 { progress = try await uploader.query(target, size: size) }
            if case .received(let offset) = progress {
                var current = state
                progress = try await uploader.upload(file: file, size: size, to: target, from: offset, beforeChunk: {
                    try await self.waitForMatchToEnd()
                }, progress: { sent in
                    current.files[index].sent = sent
                    self.save(current, folder)
                    self.status.fraction = Double(before + sent) / Double(total)
                    self.report(self.status)
                })
                state = current
            }
            switch progress {
            case .complete:
                state.files[index].sent = size
                state.files[index].done = true
                save(state, folder)
                return
            case .received:
                continue  // The server is missing some bytes; the next pass resumes from its offset.
            case .expired:
                // The server forgot the session: ask Kaggle for a new upload URL.
                state.files[index].token = nil; state.files[index].url = nil; state.files[index].sent = 0
                save(state, folder)
            }
        }
        throw KaggleError.invalid("The upload of \(name) kept failing")
    }

    private func waitForMatchToEnd() async throws {
        var waited = false
        while isRecording() {
            if !waited { waited = true; status.waitingForMatch = true; report(status) }
            try await Task.sleep(for: .seconds(pauseCheckSeconds))
        }
        if waited { status.waitingForMatch = false; report(status) }
        try Task.checkCancellation()
    }
}
