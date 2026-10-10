import Foundation

/// The Kaggle account that receives uploads. Friends get it from the owner's setup code.
public struct Credentials: Codable, Equatable, Sendable {
    public var owner: String
    public var token: String
    public init(owner: String, token: String) { self.owner = owner; self.token = token }

    private static let prefix = "ZREC1:"

    /// A single string the owner sends to friends: `ZREC1:` + base64url JSON `{owner, token}`.
    public var setupCode: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(setupCode: String) {
        let text = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(Self.prefix) else { return nil }
        var base64 = String(text.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let decoded = try? JSONDecoder().decode(Credentials.self, from: data),
              !decoded.owner.isEmpty, !decoded.token.isEmpty else { return nil }
        self = decoded
    }

    /// `~/.kaggle/access_token`, the token the owner's training tools already use.
    public static func localAccessToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kaggle/access_token")
        let token = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
}

extension MatchStore {
    public func loadCredentials() -> Credentials? { try? readJSON(Credentials.self, from: credentialsURL) }
    public func saveCredentials(_ credentials: Credentials) throws { try writeJSON(credentials, to: credentialsURL, permissions: 0o600) }
}
