import Foundation

/// B13: where `message.sendFile` may fetch from. Empty `allowedHosts` (the default) refuses every https
/// source — like titles and phone numbers, opening a host is a person's decision made on this Mac.
/// `ossKey` sources bypass this list: the bucket is itself configuration (`oss.json`).
public struct SendFilePolicy: Codable, Equatable {
    public var allowedHosts: [String]
    /// Hard cap on one downloaded file (bytes).
    public var maxBytes: Int64

    public init(allowedHosts: [String] = [], maxBytes: Int64 = 104_857_600) {
        self.allowedHosts = allowedHosts; self.maxBytes = maxBytes
    }

    enum CodingKeys: String, CodingKey { case allowedHosts, maxBytes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .maxBytes) ?? 104_857_600
    }

    public static func normalize(_ host: String) -> String { host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Exact host, or a `.suffix` rule that matches `x.suffix` (never the bare suffix, never `evil-suffix`).
    public func allows(host: String) -> Bool {
        let h = Self.normalize(host)
        guard !h.isEmpty else { return false }
        return allowedHosts.contains { rule in
            let r = Self.normalize(rule)
            if r.hasPrefix(".") { return h.hasSuffix(r) && h.count > r.count }
            return h == r
        }
    }

    /// nil when the URL may be fetched; otherwise the wire message for SOURCE_NOT_ALLOWED.
    public func rejection(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else { return "only https sources are accepted (got \(url.scheme ?? "no scheme"))" }
        guard let host = url.host, allows(host: host) else {
            return "host \"\(url.host ?? "-")\" is not in policy.json sendFile.allowedHosts (imctl policy hosts --allow <host>, or the console's 策略 page)"
        }
        return nil
    }

    public mutating func allow(_ host: String) {
        let n = Self.normalize(host)
        guard !n.isEmpty, !allowedHosts.contains(where: { Self.normalize($0) == n }) else { return }
        allowedHosts.append(n)
    }

    public mutating func deny(_ host: String) {
        let n = Self.normalize(host)
        allowedHosts.removeAll { Self.normalize($0) == n }
    }

    public var summary: String { "hosts=\(allowedHosts.count) maxBytes=\(maxBytes)" }
}
