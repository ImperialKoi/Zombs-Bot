import Testing
import Foundation
@testable import RecorderCore

/// Talks to the real Kaggle API with ~/.kaggle/access_token. Opt in: ZOMBS_LIVE_KAGGLE=1 bash scripts/swift.sh test
/// Creates a tiny private dataset outside the zombs-rec- prefix (so ingest never sees it), then deletes it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ZOMBS_LIVE_KAGGLE"] == "1"))
struct LiveKaggleTests {
    @Test func testUploadCreateAndDeleteAgainstKaggle() async throws {
        let token = try #require(Credentials.localAccessToken(), "needs ~/.kaggle/access_token")
        let client = KaggleClient(token: token)
        let owner = try #require(try await client.username(), "Kaggle reports the token inactive")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("zrec-smoke-\(UUID().uuidString).bin")
        let data = Data((0..<700_000).map { UInt8(($0 * 7) % 251) })
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let blob = try await client.startBlobUpload(name: "smoke.bin", size: Int64(data.count), contentType: "application/octet-stream", lastModified: Date())
        let uploader = ResumableUploader(chunkSize: 256 << 10)
        let target = try #require(URL(string: blob.createUrl))
        // Send one chunk, ask the server how much it holds, then resume from there.
        var chunks = 0
        struct Stop: Error {}
        do {
            _ = try await uploader.upload(file: file, size: Int64(data.count), to: target, from: 0, beforeChunk: {
                chunks += 1
                if chunks == 2 { throw Stop() }
            }, progress: { _ in })
        } catch is Stop {}
        let progress = try await uploader.query(target, size: Int64(data.count))
        #expect(progress == .received(256 << 10))
        guard case .received(let offset) = progress else { return }
        #expect(try await uploader.upload(file: file, size: Int64(data.count), to: target, from: offset, beforeChunk: {}, progress: { _ in }) == .complete)

        let slug = "zrec-smoke-\(Int(Date().timeIntervalSince1970))"
        #expect(try await client.datasetStatus(owner: owner, slug: slug) == .missing)
        let ref = try await client.createDataset(owner: owner, slug: slug, title: "zrec smoke test \(slug.suffix(6))", blobTokens: [blob.token])
        #expect(ref.lowercased() == "\(owner)/\(slug)".lowercased())
        var status = DatasetStatus.pending("")
        for _ in 0..<60 where status != .ready {
            status = try await client.datasetStatus(owner: owner, slug: slug)
            if case .failed = status { break }
            if status != .ready { try await Task.sleep(for: .seconds(5)) }
        }
        #expect(status == .ready)
        try await client.deleteDataset(owner: owner, slug: slug)
        var gone = false
        for _ in 0..<12 where !gone {
            gone = try await client.datasetStatus(owner: owner, slug: slug) == .missing
            if !gone { try await Task.sleep(for: .seconds(5)) }
        }
        #expect(gone, "deleted dataset should read as missing")
    }
}
