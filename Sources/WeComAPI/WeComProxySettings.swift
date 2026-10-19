import ControlCore
import Foundation

/// Where the token-injecting proxy is and how this controller authenticates
/// to it. Stored locally (0600, never committed). The corp secret never
/// reaches this machine: the proxy injects `access_token` on the way out.
public struct WeComProxySettings: Codable, Equatable {
    public var baseURL: String
    public var token: String
    public var corpId: String?
    public var agentId: Int?
    public var timeoutSeconds: Double

    public init(baseURL: String, token: String, corpId: String? = nil, agentId: Int? = nil, timeoutSeconds: Double = 15) {
        self.baseURL = baseURL; self.token = token; self.corpId = corpId; self.agentId = agentId; self.timeoutSeconds = timeoutSeconds
    }

    public static let fileName = "wecom-proxy.json"
    public static var defaultURL: URL { IMCTLPaths.dataDirectory.appendingPathComponent(fileName) }

    public static func load(from url: URL) throws -> WeComProxySettings {
        try JSONDecoder().decode(WeComProxySettings.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Base URL without a trailing slash; requests are `{base}/wecom/{path}`.
    public var normalizedBaseURL: URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed) ?? URL(string: "invalid://invalid")!
    }

    /// For logs, `describe` and `imctl wecom status`: never the token.
    public var summary: String {
        "\(normalizedBaseURL.absoluteString) corpId=\(corpId ?? "-") agentId=\(agentId.map(String.init) ?? "-")"
    }
}
