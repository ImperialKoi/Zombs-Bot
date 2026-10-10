import Testing
import Foundation
import AVFoundation
import ImageIO
@testable import RecorderCore

struct RecorderCoreTests {
    @Test func testMatchIDMatchesSessionRecorderFormat() {
        let date = Date(timeIntervalSince1970: 1_791_313_331)  // 2026-10-06T19:02:11Z
        let id = MatchID.make(date: date, suffix: "4C1A9E")
        #expect(id == "2026-10-06T19-02-11Z-4C1A9E")
        #expect(MatchID.isValid(id))
        #expect(MatchID.isValid(MatchID.make()))
        #expect(MatchID.isValid("2026-10-04T00-07-25Z-78E1A3"))
        for bad in ["2026-10-04T00-07-25Z-78e1a3", "2026-10-04T00:07:25Z-78E1A3", "x", ""] { #expect(!MatchID.isValid(bad)) }
    }

    @Test func testSlugAndTitleSuitKaggle() {
        let id = "2026-10-06T19-02-11Z-4C1A9E"
        let slug = MatchID.slug(id)
        #expect(slug == "zombs-rec-2026-10-06t19-02-11z-4c1a9e")
        #expect(slug.count <= 50 && slug.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil)
        let title = MatchID.title(id, mode: .squad)
        #expect(title == "zombs-rec squad 2026-10-06 19-02Z 4C1A9E")
        #expect((6...50).contains(title.count))
    }

    @Test func testGeometryCropsChromeAndKeepsEvenSize() throws {
        // The user's window: 1920 × 955.5 pt on a 2× display with the 87 pt toolbar → the corpus's 3840 × 1736.
        let geometry = try #require(CaptureGeometry(windowSize: CGSize(width: 1920, height: 955.5), topInset: 87, scale: 2))
        #expect(geometry.sourceRect == CGRect(x: 0, y: 87, width: 1920, height: 868.5))
        #expect(geometry.width == 3840 && geometry.height == 1736)
        let large = try #require(CaptureGeometry(windowSize: CGSize(width: 2560, height: 1440), topInset: 87, scale: 2))
        #expect(large.width == 3840 && large.height % 2 == 0 && large.height < 2 * (1440 - 87))
        #expect(CaptureGeometry(windowSize: CGSize(width: 1920, height: 200), topInset: 87, scale: 2) == nil)
        let odd = try #require(CaptureGeometry(windowSize: CGSize(width: 1001, height: 701), topInset: 0, scale: 1))
        #expect(odd.width == 1000 && odd.height == 700)
    }

    @Test func testBitrateScalesWithPixelsWithinBounds() {
        #expect(VideoEncoding.bitrate(width: 3840, height: 1736) == 15_998_976)
        #expect(VideoEncoding.bitrate(width: 640, height: 360) == 4_000_000)
        #expect(VideoEncoding.bitrate(width: 7680, height: 4320) == 24_000_000)
    }

    @Test func testSetupCodeRoundTripsAndRejectsJunk() throws {
        let credentials = Credentials(owner: "imperialkoi", token: "KGAT_example+/=token")
        let code = credentials.setupCode
        #expect(code.hasPrefix("ZREC1:") && !code.contains("+") && !code.contains("/") && !code.contains("="))
        #expect(Credentials(setupCode: "  \(code)\n") == credentials)
        for junk in ["", "ZREC1:", "ZREC1:!!!", "KGAT_token", "ZREC1:" + Data("{}".utf8).base64EncodedString()] {
            #expect(Credentials(setupCode: junk) == nil)
        }
    }

    @Test func testCodesFromTheFriendKitScriptDecode() {
        // Produced by scripts/make-friend-kit.sh's printf | base64 | tr pipeline.
        #expect(Credentials(setupCode: "ZREC1:eyJvd25lciI6ImltcGVyaWFsa29pIiwidG9rZW4iOiJLR0FUX2V4YW1wbGUifQ")
                == Credentials(owner: "imperialkoi", token: "KGAT_example"))
        #expect(Credentials(setupCode: "ZREC1:eyJvd25lciI6ImFiIiwidG9rZW4iOiJjPz4-PyJ9") == Credentials(owner: "ab", token: "c?>>?"))
    }

    @Test func testManifestRoundTripAndTotals() throws {
        var start = RecordingStart(matchID: "2026-10-06T19-02-11Z-4C1A9E", mode: .duo, teammates: ["sam"], recordedBy: "alex",
                                   createdAt: "2026-10-06T19:02:11Z", capture: CaptureInfo(fps: 30, codec: "hevc", bitrate: 16_000_000, topInsetPoints: 87, scale: 2))
        start.partStarts = [0, 120.5]
        let parts = [RecordingPart(file: "part-000.mov", width: 3840, height: 1736, frames: 3600, startSeconds: 0, durationSeconds: 120, bytes: 100, sha256: "a"),
                     RecordingPart(file: "part-001.mov", width: 3840, height: 1600, frames: 900, startSeconds: 120.5, durationSeconds: 30, bytes: 50, sha256: "b")]
        let manifest = RecordingManifest(start: start, endedAt: "2026-10-06T19:05:00Z", endReason: .windowClosed, parts: parts)
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(RecordingManifest.self, from: data) == manifest)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["complete"] as? Bool == true && json["endReason"] as? String == "window-closed" && json["mode"] as? String == "duo")
        #expect(manifest.durationSeconds == 150.5 && manifest.bytes == 150 && manifest.recorderVersion == RecorderInfo.version)
    }

    @Test func testReceivedBytesFromRangeHeader() {
        #expect(ResumableUploader.receivedBytes("bytes=0-8388607") == 8_388_608)
        #expect(ResumableUploader.receivedBytes(nil) == 0)
        #expect(ResumableUploader.receivedBytes("garbage") == 0)
    }

    @Test func testThisMacHasAHardwareEncoder() {
        #expect(VideoEncoding.preferredCodec(width: 3840, height: 1736) != nil)
    }
}

// MARK: - Encoding, extraction and recovery on real movies

struct MovieTests {
    /// BT.709 full-range YCbCr of RGB (200, 100, 50).
    static let color = (r: 200, g: 100, b: 50, y: UInt8(118), cb: UInt8(92), cr: UInt8(180))

    static func fullRangeFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw KaggleError.invalid("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        memset(luma, Int32(color.y), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * height)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, 1), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<rows {
            for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 1) {
                chroma[row * stride + column * 2] = color.cb
                chroma[row * stride + column * 2 + 1] = color.cr
            }
        }
        return buffer
    }

    /// Writes `frames` frames at 30 FPS the way CaptureSession does.
    static func writeClip(_ url: URL, frames: Int, width: Int = 320, height: Int = 240, startSeconds: Double = 0) async throws -> FinishedPart {
        let codec = try #require(VideoEncoding.preferredCodec(width: width, height: height))
        let writer = try MovieWriter(index: 0, url: url, width: width, height: height, codec: codec, startSeconds: startSeconds)
        let frame = try fullRangeFrame(width: width, height: height)
        for i in 0..<frames {
            // Capture drops frames while the encoder is busy; a test feeding faster than real time waits instead.
            for _ in 0..<2000 where !writer.isReady { try await Task.sleep(for: .milliseconds(1)) }
            writer.append(frame, at: CMTime(value: CMTimeValue(1000 + i), timescale: 30))
        }
        return try #require(await writer.finish())
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func start(_ id: String) -> RecordingStart {
        RecordingStart(matchID: id, mode: .solo, teammates: [], recordedBy: "test", createdAt: timestamp(),
                       capture: CaptureInfo(fps: 30, codec: "hevc", bitrate: 4_000_000, topInsetPoints: 87, scale: 2))
    }

    @Test func testWriterExtractorRoundTripKeepsColourAndCadence() async throws {
        let folder = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let part = try await Self.writeClip(folder.appendingPathComponent("part-000.mov"), frames: 60)
        #expect(part.width == 320 && part.height == 240 && part.frames == 60)
        let url = folder.appendingPathComponent(part.file)
        let summary = try #require(await MovieSummary.read(url))
        #expect(summary.frames == part.frames, "file has \(summary.frames), writer counted \(part.frames)")
        #expect(abs(summary.duration - part.durationSeconds) < 0.05, "\(summary.duration) vs \(part.durationSeconds)")

        let manifest = RecordingManifest(start: Self.start("2026-10-06T19-02-11Z-4C1A9E"), endedAt: timestamp(), endReason: .hotkey,
                                         parts: [RecordingPart(file: part.file, width: part.width, height: part.height, frames: part.frames, startSeconds: 0,
                                                               durationSeconds: part.durationSeconds, bytes: fileSize(url), sha256: try sha256Hex(of: url))])
        let output = folder.appendingPathComponent("session")
        var frames: [ExtractedFrame] = []
        try await FrameExtractor.extract(recording: folder, manifest: manifest, to: output, fps: 5) { frames.append($0) }
        #expect(frames.count == 10)  // 0.0 … 1.8 s of 0 … 1.97 s
        #expect(frames.first?.image == "images/000000.jpg" && frames.first?.timestamp == 0)
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.timestamp > $0.timestamp && $1.index > $0.index })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { abs($1.timestamp - $0.timestamp - 0.2) < 0.04 })

        // Full-range BT.709 survives encode → decode → JPEG within a few levels.
        let jpeg = output.appendingPathComponent(frames[3].image)
        let source = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 240)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -160, y: -120, width: 320, height: 240))
        #expect(abs(Int(pixel[0]) - Self.color.r) <= 6 && abs(Int(pixel[1]) - Self.color.g) <= 6 && abs(Int(pixel[2]) - Self.color.b) <= 6,
                "decoded \(pixel)")
    }

    @Test func testRecoveryRebuildsManifestFromFragmentsAndDropsShortOnes() async throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MatchStore(root: root)
        let id = "2026-10-06T19-02-11Z-4C1A9E", shortID = "2026-10-06T19-30-00Z-00AA11"
        for (matchID, frames) in [(id, 45), (shortID, 10)] {
            let folder = store.directory(for: matchID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var start = Self.start(matchID)
            start.partStarts = [0]
            try writeJSON(start, to: folder.appendingPathComponent(MatchFiles.start))
            _ = try await Self.writeClip(folder.appendingPathComponent(MatchFiles.part(0)), frames: frames)
        }
        #expect(store.unfinished().map(\.lastPathComponent) == [id, shortID])
        let recovered = try #require(await store.recover(store.directory(for: id), minimumSeconds: 1))
        #expect(recovered.endReason == .recovered && recovered.parts.count == 1 && recovered.parts[0].frames == 45)
        #expect(await store.recover(store.directory(for: shortID), minimumSeconds: 1) == nil)
        #expect(store.finished().map(\.manifest.matchID) == [id])
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: shortID).path))
    }
}
