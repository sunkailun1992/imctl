import ControlCore
import Foundation

/// Where pictures / files behind `message.media` are uploaded and where `ossKey` sources come from. Field names
/// mirror the business side's `aliyun.oss.*` block. Stored locally (0600, never committed); the AccessKey pair
/// never appears in logs, `describe` or the console (masked).
public struct OSSSettings: Codable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var endpoint: String
    public var bucket: String
    public var baseDir: String
    public var accessKeyId: String
    public var accessKeySecret: String
    public var viewExpireSeconds: Int
    public var maxUploadBytes: Int64

    public init(endpoint: String, bucket: String, baseDir: String, accessKeyId: String, accessKeySecret: String, viewExpireSeconds: Int = 1800, maxUploadBytes: Int64 = 52_428_800) {
        self.endpoint = endpoint; self.bucket = bucket; self.baseDir = baseDir; self.accessKeyId = accessKeyId; self.accessKeySecret = accessKeySecret
        self.viewExpireSeconds = viewExpireSeconds; self.maxUploadBytes = maxUploadBytes
    }

    public static let fileName = "oss.json"
    public static var defaultURL: URL { IMCTLPaths.dataDirectory.appendingPathComponent(fileName) }

    /// Reads and validates `oss.json`. A hand-edited or tampered file is untrusted input as far as the daemon
    /// is concerned, so it goes through `validate()` before any request can be built from it.
    /// - Throws: `ControlError.ossNotConfigured` when a field is unusable; a `DecodingError` / `CocoaError`
    ///   when the file is missing or is not the expected JSON.
    public static func load(from url: URL) throws -> OSSSettings {
        let settings = try JSONDecoder().decode(OSSSettings.self, from: Data(contentsOf: url)).normalized()
        try settings.validate()
        return settings
    }

    /// Writes owner-only (0600) after the same validation `load` applies, so `imctl oss set` cannot persist a
    /// file that would later throw or trap in the daemon. The normalised form is what lands on disk.
    /// - Throws: `ControlError.ossNotConfigured` when a field is unusable.
    public func save(to url: URL) throws {
        let settings = normalized()
        try settings.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The form actually stored and signed with: endpoint whitespace trimmed, `baseDir` without a trailing
    /// slash so keys never come out as `imctl//2026/...`.
    public func normalized() -> OSSSettings {
        var copy = self
        copy.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while copy.baseDir.hasSuffix("/") { copy.baseDir.removeLast() }
        return copy
    }

    private static let endpointHostPattern = "^oss-[a-z0-9-]+\\.aliyuncs\\.com$"
    private static let bucketPattern = "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"
    /// OSS's own ceiling for a presigned URL.
    public static let maxViewExpireSeconds = 604_800

    /// Refuses a settings value the daemon must not act on. Two of these are security boundaries rather than
    /// tidiness: an endpoint host outside `oss-<region>.aliyuncs.com` would aim signed requests at a foreign
    /// host, and a bucket that cannot form a host (`my bucket`) used to trap `imctld` on `URL(string:)!`.
    /// Messages name the field but never a stored value, so a rejection is safe to log.
    /// - Throws: `ControlError.ossNotConfigured` (`OSS_NOT_CONFIGURED`).
    public func validate() throws {
        func reject(_ why: String) -> ControlError { .ossNotConfigured("oss.json: \(why)") }
        guard let parts = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let host = parts.host, host.range(of: Self.endpointHostPattern, options: .regularExpression) != nil
        else { throw reject("endpoint must be https://oss-<region>.aliyuncs.com with no path or query") }
        guard bucket.range(of: Self.bucketPattern, options: .regularExpression) != nil else {
            throw reject("bucket must be 3-63 lowercase letters, digits or hyphens and start and end alphanumeric")
        }
        for (field, value) in [("accessKeyId", accessKeyId), ("accessKeySecret", accessKeySecret)] {
            guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw reject("\(field) must not be empty or contain whitespace")
            }
        }
        // A baseDir that is nothing but slashes normalises to "", and every object key would then start with
        // "/" — a different (and unintended) place in the bucket than the prefix the RAM sub-account is
        // scoped to (review 2026-09-23).
        guard !baseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            throw reject("baseDir must not be empty; object keys would start with \"/\"")
        }
        guard !baseDir.hasPrefix("/"), !baseDir.split(separator: "/").contains("..") else {
            throw reject("baseDir must be a relative prefix with no leading slash and no \"..\" segment")
        }
        guard (1...Self.maxViewExpireSeconds).contains(viewExpireSeconds) else {
            throw reject("viewExpireSeconds must be 1...\(Self.maxViewExpireSeconds)")
        }
        guard maxUploadBytes > 0 else { throw reject("maxUploadBytes must be greater than 0") }
    }

    public var endpointHost: String? { URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host }
    /// `oss-cn-hangzhou.aliyuncs.com` → `cn-hangzhou`; `oss-cn-shanghai-internal.…` → `cn-shanghai`.
    public var region: String {
        guard let host = endpointHost, let first = host.split(separator: ".").first, first.hasPrefix("oss-") else { return "" }
        var r = String(first.dropFirst(4))
        if r.hasSuffix("-internal") { r.removeLast("-internal".count) }
        return r
    }
    public var bucketHost: String { "\(bucket).\(endpointHost ?? "")" }
    /// For `imctl oss status`, `describe` and logs.
    public var summary: String { "\(endpointHost ?? "-") bucket=\(bucket) baseDir=\(baseDir) ak=\(Self.mask(accessKeyId)) view=\(viewExpireSeconds)s maxUpload=\(maxUploadBytes)" }
    public static func mask(_ id: String) -> String { id.count > 6 ? "\(id.prefix(4))…\(id.suffix(2))" : "…" }

    /// Default reflection would print `accessKeySecret`, so both string conversions render `summary`:
    /// `"\(settings)"` anywhere in a log line stays masked.
    public var description: String { summary }
    public var debugDescription: String { summary }
}
