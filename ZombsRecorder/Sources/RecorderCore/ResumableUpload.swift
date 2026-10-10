import Foundation

/// Google resumable-upload protocol behind Kaggle's blob `createUrl`: chunked PUTs with `Content-Range`;
/// 308 + `Range: bytes=0-N` means "have N+1 bytes, send the rest"; 404/410 means the session expired.
public struct ResumableUploader: Sendable {
    public enum Progress: Equatable, Sendable { case complete, received(Int64), expired }

    let session: URLSession
    /// A multiple of 256 KiB, as the protocol requires for every chunk but the last.
    public var chunkSize: Int

    public init(session: URLSession = KaggleClient.session, chunkSize: Int = 8 << 20) {
        precondition(chunkSize > 0 && chunkSize % (256 << 10) == 0)
        self.session = session; self.chunkSize = chunkSize
    }

    /// How much of the file the server already holds.
    public func query(_ url: URL, size: Int64) async throws -> Progress {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "PUT"
        request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        return try await send(request, body: Data())
    }

    /// Sends the file from `offset`. `beforeChunk` runs before every request (pausing, cancellation);
    /// `progress` reports the server-confirmed byte count after each chunk.
    public func upload(file: URL, size: Int64, to url: URL, from offset: Int64,
                       beforeChunk: () async throws -> Void, progress: (Int64) -> Void) async throws -> Progress {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = max(0, offset)
        while offset < size {
            try await beforeChunk()
            let length = Int(min(Int64(chunkSize), size - offset))
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw KaggleError.invalid("\(file.lastPathComponent) changed while uploading")
            }
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "PUT"
            request.setValue("bytes \(offset)-\(offset + Int64(length) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
            switch try await send(request, body: data) {
            case .complete:
                progress(size)
                return .complete
            case .received(let received):
                guard received > offset else { throw KaggleError.invalid("Upload made no progress at byte \(offset)") }
                offset = received
                progress(received)
            case .expired:
                return .expired
            }
        }
        try await beforeChunk()
        return try await query(url, size: size)
    }

    private func send(_ request: URLRequest, body: Data) async throws -> Progress {
        let (_, response) = try await session.upload(for: request, from: body, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse else { throw KaggleError.invalid("Upload server sent no HTTP response") }
        switch http.statusCode {
        case 200, 201:
            return .complete
        case 308:
            return .received(Self.receivedBytes(http.value(forHTTPHeaderField: "Range")))
        case 404, 410:
            return .expired
        default:
            throw KaggleError.http(http.statusCode, "upload server")
        }
    }

    /// `Range: bytes=0-8388607` → 8388608. No header means nothing has been stored yet.
    static func receivedBytes(_ range: String?) -> Int64 {
        guard let range, let last = range.split(separator: "-").last, let end = Int64(last) else { return 0 }
        return end + 1
    }
}

/// The upload server answers 308 without a Location header; it must never be followed as a redirect.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
