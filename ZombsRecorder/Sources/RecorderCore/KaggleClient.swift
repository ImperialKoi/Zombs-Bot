import Foundation

public enum KaggleError: Error, LocalizedError, Equatable {
    case http(Int, String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let message): return "Kaggle returned \(code)" + (message.isEmpty ? "" : ": \(message)")
        case .invalid(let message): return message
        }
    }
    public var isAuthFailure: Bool { if case .http(let code, _) = self { return code == 401 || code == 403 }; return false }
    public var isTransient: Bool { if case .http(let code, _) = self { return code == 408 || code == 429 || code >= 500 }; return false }
}

public enum DatasetStatus: Equatable, Sendable {
    case ready, pending(String), failed(String), missing
}

/// The handful of Kaggle API calls the recorder needs, mirroring kagglesdk:
/// JSON POSTs to `https://api.kaggle.com/v1/<Service>/<Method>` with the access token as a Bearer token.
public final class KaggleClient: @unchecked Sendable {
    public let token: String
    let session: URLSession
    let base: String

    /// Kaggle answers with a `ka_sessionid` cookie; sending it back makes later API calls fail with 401,
    /// so the recorder's requests never store or send cookies (kagglesdk uses a fresh session per call).
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public init(token: String, session: URLSession = KaggleClient.session, base: String = "https://api.kaggle.com/v1") {
        self.token = token; self.session = session; self.base = base
    }

    struct TokenRequest: Encodable { var token: String }
    public struct TokenInfo: Decodable, Sendable { public var active: Bool?; public var username: String? }

    /// The username a token belongs to, or nil if Kaggle reports it inactive.
    public func username() async throws -> String? {
        let info = try await call("security.OAuthService", "IntrospectToken", TokenRequest(token: token), as: TokenInfo.self)
        return info.active == true ? info.username : nil
    }

    struct StartBlobUploadRequest: Encodable {
        var type = "DATASET"
        var name: String
        var contentType: String?
        var contentLength: Int64
        var lastModifiedEpochSeconds: Int64?
    }
    public struct BlobUpload: Codable, Sendable { public var token: String; public var createUrl: String }

    public func startBlobUpload(name: String, size: Int64, contentType: String?, lastModified: Date?) async throws -> BlobUpload {
        let request = StartBlobUploadRequest(name: name, contentType: contentType, contentLength: size,
                                             lastModifiedEpochSeconds: lastModified.map { Int64($0.timeIntervalSince1970) })
        let blob = try await call("blobs.BlobApiService", "StartBlobUpload", request, as: BlobUpload.self)
        guard !blob.token.isEmpty, URL(string: blob.createUrl) != nil else { throw KaggleError.invalid("Kaggle did not return an upload URL") }
        return blob
    }

    struct CreateDatasetRequest: Encodable {
        struct NewFile: Encodable { var token: String }
        var ownerSlug: String
        var slug: String
        var title: String
        var licenseName = "other"
        var isPrivate = true
        var files: [NewFile]
    }
    struct CreateDatasetResponse: Decodable { var ref: String?; var error: String? }

    /// Creates a private dataset from uploaded blob tokens and returns its `owner/slug` reference.
    public func createDataset(owner: String, slug: String, title: String, blobTokens: [String]) async throws -> String {
        let request = CreateDatasetRequest(ownerSlug: owner, slug: slug, title: title, files: blobTokens.map { .init(token: $0) })
        let response = try await call("datasets.DatasetApiService", "CreateDataset", request, as: CreateDatasetResponse.self)
        if let error = response.error, !error.isEmpty { throw KaggleError.invalid("Kaggle refused the dataset: \(error)") }
        // Kaggle answers with a path such as "/datasets/owner/slug"; keep the "owner/slug" form.
        let components = (response.ref ?? "").split(separator: "/").suffix(2)
        return components.count == 2 ? components.joined(separator: "/") : "\(owner)/\(slug)"
    }

    struct DatasetRequest: Encodable { var ownerSlug: String; var datasetSlug: String }
    struct StatusResponse: Decodable { var status: String? }
    struct ErrorResponse: Decodable { var error: String? }

    public func datasetStatus(owner: String, slug: String) async throws -> DatasetStatus {
        do {
            let response = try await call("datasets.DatasetApiService", "GetDatasetStatus",
                                          DatasetRequest(ownerSlug: owner, datasetSlug: slug), as: StatusResponse.self)
            let status = (response.status ?? "").uppercased()
            if status.contains("READY") { return .ready }
            if status.contains("FAILED") || status.contains("DELETED") { return .failed(status) }
            return .pending(status)
        } catch KaggleError.http(let code, _) where code == 403 || code == 404 {
            return .missing  // Kaggle answers 403 for a dataset that does not exist (it hides unknown datasets).
        }
    }

    public func deleteDataset(owner: String, slug: String) async throws {
        let response = try await call("datasets.DatasetApiService", "DeleteDataset",
                                      DatasetRequest(ownerSlug: owner, datasetSlug: slug), as: ErrorResponse.self)
        if let error = response.error, !error.isEmpty { throw KaggleError.invalid(error) }
    }

    func call<Body: Encodable, Response: Decodable>(_ service: String, _ method: String, _ body: Body,
                                                    as type: Response.Type) async throws -> Response {
        guard let url = URL(string: "\(base)/\(service)/\(method)") else { throw KaggleError.invalid("Bad Kaggle URL") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("zombs-recorder/\(RecorderInfo.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KaggleError.invalid("Kaggle sent no HTTP response") }
        // kagglesdk treats a JSON body with code >= 400 as an error even when the HTTP status is 200.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["message"] as? String ?? ""
        if let code = object?["code"] as? Int, code >= 400 { throw KaggleError.http(code, message) }
        guard (200..<300).contains(http.statusCode) else { throw KaggleError.http(http.statusCode, message) }
        return try JSONDecoder().decode(type, from: data.isEmpty ? Data("{}".utf8) : data)
    }
}
