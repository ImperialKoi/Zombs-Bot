import Testing
import Foundation
@testable import RecorderCore

/// Imitates Kaggle's API and the resumable upload server inside URLSession.
final class FakeKaggle: URLProtocol {
    struct Upload { var name: String; var data = Data(); var expired = false }
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var bodies: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var authorization: Set<String> = []
    nonisolated(unsafe) static var uploads: [String: Upload] = [:]
    nonisolated(unsafe) static var datasets: [String: String] = [:]  // slug → status
    nonisolated(unsafe) static var chunks = 0
    nonisolated(unsafe) static var dropChunk: Int?                   // fail this numbered chunk PUT with a network error
    nonisolated(unsafe) static var rangeErrors: [String] = []
    nonisolated(unsafe) static var expireQueries = 0                 // answer this many resume queries with 404
    nonisolated(unsafe) static var username: String? = "owner"

    static func reset() {
        calls = []; bodies = [:]; authorization = []; uploads = [:]; datasets = [:]; chunks = 0; dropChunk = nil; rangeErrors = []
        expireQueries = 0; username = "owner"
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeKaggle.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let url = request.url!
        if url.host == "upload.test" {
            if !body.isEmpty {
                Self.chunks += 1
                if Self.chunks == Self.dropChunk {
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
            }
            return answerUpload(url.lastPathComponent, range: request.value(forHTTPHeaderField: "Content-Range") ?? "", body: body)
        }
        let method = url.lastPathComponent
        Self.calls.append(method)
        Self.authorization.insert(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.bodies[method] = json
        switch method {
        case "IntrospectToken":
            respond(200, Self.username.map { ["active": true, "username": $0] } ?? ["active": false])
        case "StartBlobUpload":
            let name = json["name"] as! String
            let id = "\(name)-\(Self.calls.count)"
            Self.uploads[id] = Upload(name: name)
            respond(200, ["token": "token-\(id)", "createUrl": "https://upload.test/\(id)"])
        case "GetDatasetStatus":
            if let status = Self.datasets[json["datasetSlug"] as! String] { respond(200, ["status": status]) }
            else { respond(403, [:]) }  // What api.kaggle.com returns for a dataset that does not exist.
        case "CreateDataset":
            let slug = json["slug"] as! String
            Self.datasets[slug] = "READY"
            respond(200, ["ref": "/datasets/\(json["ownerSlug"]!)/\(slug)", "url": "https://www.kaggle.com/datasets/x", "status": "Ok"])  // Real shape of the reply.
        case "DeleteDataset":
            Self.datasets[json["datasetSlug"] as! String] = nil
            respond(200, [:])
        default:
            respond(404, ["code": 404, "message": "Unknown method"])
        }
    }

    private func answerUpload(_ id: String, range: String, body: Data) {
        guard var upload = Self.uploads[id], !upload.expired else { return respond(404, [:]) }
        let total = Int(range.split(separator: "/").last ?? "") ?? -1
        if range.hasPrefix("bytes */") {
            if Self.expireQueries > 0 {
                Self.expireQueries -= 1
                upload.expired = true
                Self.uploads[id] = upload
                return respond(404, [:])
            }
        } else {
            let bounds = range.dropFirst("bytes ".count).split(separator: "/")[0].split(separator: "-").compactMap { Int($0) }
            if bounds.first != upload.data.count { Self.rangeErrors.append(range) }  // A chunk must continue where the server stopped.
            upload.data.append(body)
            Self.uploads[id] = upload
        }
        if upload.data.count == total { return respond(200, [:]) }
        respond(308, [:], headers: upload.data.isEmpty ? [:] : ["Range": "bytes=0-\(upload.data.count - 1)"])
    }

    private func respond(_ status: Int, _ json: [String: Any], headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized)
struct UploadTests {
    static let matchID = "2026-10-06T19-02-11Z-4C1A9E"

    /// A finished match folder holding a fake 600 KB video (the uploader never decodes it).
    static func store(video: Data = Data((0..<600_000).map { UInt8($0 % 251) })) throws -> MatchStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("upload-tests-\(UUID().uuidString)")
        let store = try MatchStore(root: root)
        let folder = store.directory(for: matchID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent("part-000.mov")
        try video.write(to: part)
        let start = RecordingStart(matchID: matchID, mode: .duo, teammates: [], recordedBy: "friend", createdAt: timestamp(),
                                   capture: CaptureInfo(fps: 30, codec: "hevc", bitrate: 16_000_000, topInsetPoints: 87, scale: 2))
        let manifest = RecordingManifest(start: start, endedAt: timestamp(), endReason: .hotkey,
                                         parts: [RecordingPart(file: "part-000.mov", width: 3840, height: 1736, frames: 900, startSeconds: 0,
                                                               durationSeconds: 30, bytes: Int64(video.count), sha256: try sha256Hex(of: part))])
        try writeJSON(manifest, to: folder.appendingPathComponent(MatchFiles.manifest))
        try store.saveCredentials(Credentials(owner: "owner", token: "secret-token"))
        return store
    }

    static func queue(_ store: MatchStore, recording: Locked<Int> = Locked(0), deleteVideo: Bool = true) -> UploadQueue {
        let queue = UploadQueue(store: store, session: FakeKaggle.session(), kaggleBase: "https://api.test/v1",
                                isRecording: { recording.take() }, deleteAfterUpload: { deleteVideo }, report: { _ in })
        queue.chunkSize = 256 << 10
        queue.pauseCheckSeconds = 0.01
        queue.readyPollSeconds = 0.01
        return queue
    }

    @Test func testCredentialsAreCheckedWithIntrospection() async throws {
        FakeKaggle.reset()
        let client = KaggleClient(token: "secret-token", session: FakeKaggle.session(), base: "https://api.test/v1")
        #expect(try await client.username() == "owner")
        #expect(FakeKaggle.authorization == ["Bearer secret-token"])
        #expect(FakeKaggle.bodies["IntrospectToken"]?["token"] as? String == "secret-token")
        FakeKaggle.username = nil
        #expect(try await client.username() == nil)
    }

    @Test func testUploadCreatesPrivateDatasetAndDeletesLocalVideo() async throws {
        FakeKaggle.reset()
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let folder = store.directory(for: Self.matchID)
        let recording = Locked(2)  // A match is being recorded for the first two checks.
        let status = await Self.queue(store, recording: recording).runPending()
        #expect(status.problem == nil && status.uploaded == 1 && status.pending == 0)
        #expect(recording.current == 0)

        let slug = "zombs-rec-2026-10-06t19-02-11z-4c1a9e"
        #expect(FakeKaggle.datasets[slug] == "READY")
        let create = try #require(FakeKaggle.bodies["CreateDataset"])
        #expect(create["ownerSlug"] as? String == "owner" && create["slug"] as? String == slug && create["isPrivate"] as? Bool == true)
        #expect(create["licenseName"] as? String == "other" && create["title"] as? String == "zombs-rec duo 2026-10-06 19-02Z 4C1A9E")
        #expect((create["files"] as? [[String: String]])?.count == 2)
        let blob = try #require(FakeKaggle.bodies["StartBlobUpload"])
        #expect(blob["type"] as? String == "DATASET" && blob["name"] as? String == MatchFiles.manifest)
        let uploaded = FakeKaggle.uploads.values.first { $0.name == "part-000.mov" }
        #expect(uploaded?.data == Data((0..<600_000).map { UInt8($0 % 251) }))
        #expect(FakeKaggle.uploads.values.contains { $0.name == MatchFiles.manifest && $0.data == (try? Data(contentsOf: folder.appendingPathComponent(MatchFiles.manifest))) })

        let state = try #require(Self.queue(store).state(folder))
        #expect(state.ready && state.videoDeleted && state.ref == "owner/\(slug)")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("part-000.mov").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MatchFiles.manifest).path))
        #expect(FakeKaggle.rangeErrors.isEmpty)

        let calls = FakeKaggle.calls.count
        await Self.queue(store).runPending()
        #expect(FakeKaggle.calls.count == calls, "a finished match is never uploaded twice")
    }

    @Test func testDroppedConnectionResumesWhereTheServerStopped() async throws {
        FakeKaggle.reset()
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let queue = Self.queue(store, deleteVideo: false)
        FakeKaggle.dropChunk = 2  // 600 KB in 256 KiB chunks: the server keeps the first chunk only.
        let interrupted = await queue.runPending()
        #expect(interrupted.problem != nil && interrupted.pending == 1)
        #expect(FakeKaggle.uploads.values.first { $0.name == "part-000.mov" }?.data.count == 256 << 10)
        let starts = FakeKaggle.calls.filter { $0 == "StartBlobUpload" }.count
        let status = await queue.runPending()
        #expect(status.problem == nil && status.uploaded == 1)
        #expect(FakeKaggle.calls.filter { $0 == "StartBlobUpload" }.count == starts + 1, "only recording.json needs a new upload session")
        #expect(FakeKaggle.uploads.values.filter { $0.name == "part-000.mov" }.map(\.data.count) == [600_000])
        #expect(FakeKaggle.rangeErrors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: Self.matchID).appendingPathComponent("part-000.mov").path))
    }

    @Test func testExpiredUploadSessionStartsAgain() async throws {
        FakeKaggle.reset()
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let queue = Self.queue(store)
        FakeKaggle.dropChunk = 2
        #expect(await queue.runPending().problem != nil)
        FakeKaggle.expireQueries = 1
        let status = await queue.runPending()
        #expect(status.problem == nil && status.uploaded == 1)
        let parts = FakeKaggle.uploads.values.filter { $0.name == "part-000.mov" }
        #expect(parts.count == 2 && parts.contains { $0.expired } && parts.contains { $0.data.count == 600_000 })
        #expect(FakeKaggle.rangeErrors.isEmpty)
    }

    @Test func testRejectedTokenStopsUploadsUntilSetupCodeChanges() async throws {
        FakeKaggle.reset()
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.saveCredentials(Credentials(owner: "owner", token: "revoked"))
        final class Revoked: URLProtocol {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func stopLoading() {}
            override func startLoading() {
                let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{\"code\":401,\"message\":\"Unauthenticated\"}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Revoked.self]
        let queue = UploadQueue(store: store, session: URLSession(configuration: configuration), kaggleBase: "https://api.test/v1",
                                isRecording: { false }, deleteAfterUpload: { true }, report: { _ in })
        let status = await queue.runPending()
        #expect(status.needsCredentials && status.pending == 1 && status.failed == 0)
    }

    @Test func testMissingCredentialsAreReported() async throws {
        FakeKaggle.reset()
        let store = try Self.store()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.removeItem(at: store.credentialsURL)
        let status = await Self.queue(store).runPending()
        #expect(status.needsCredentials && status.pending == 1 && FakeKaggle.calls.isEmpty)
    }
}

extension Locked where Value == Int {
    /// True while the counter is positive, counting down on each call.
    func take() -> Bool {
        let value = current
        if value > 0 { current = value - 1 }
        return value > 0
    }
}
