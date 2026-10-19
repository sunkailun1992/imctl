import CryptoKit
import Foundation

/// Aliyun OSS signature V4 (`OSS4-HMAC-SHA256`): header signing for PUT / HEAD / GET / DELETE and query
/// signing for presigned GET URLs. Pure string functions so the canonical form is unit-testable; the live
/// round trip (`imctl oss test`) is the final judge, and a 403 carries the server's `CanonicalRequest` for comparison.
public struct OSSSigner: CustomStringConvertible, CustomDebugStringConvertible {
    public var accessKeyId: String
    public var accessKeySecret: String
    public var region: String
    public static let algorithm = "OSS4-HMAC-SHA256"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public init(accessKeyId: String, accessKeySecret: String, region: String) {
        self.accessKeyId = accessKeyId; self.accessKeySecret = accessKeySecret; self.region = region
    }

    /// Default reflection would print `accessKeySecret`; only the masked key id and the region are shown.
    public var description: String { "OSSSigner(\(OSSSettings.mask(accessKeyId)), \(region))" }
    public var debugDescription: String { description }

    /// UTC stamp and day, e.g. `20231203T121212Z` and `20231203`.
    public static func stamps(_ date: Date) -> (stamp: String, day: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }

    /// RFC 3986: unreserved characters stay; `/` stays only when `keepSlash` (paths).
    public static func encode(_ s: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert(charactersIn: "/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func canonicalURI(bucket: String, key: String) -> String { "/" + bucket + "/" + encode(key, keepSlash: true) }

    // Deviation from the brief (see task-9-report.md): the one-expression chain form timed out the type
    // checker ("unable to type-check this expression in reasonable time"); split into typed sub-expressions
    // with identical behaviour, per the brief's own fallback instruction.
    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        let encoded: [(String, String)] = items.map { item -> (String, String) in
            (encode(item.0, keepSlash: false), encode(item.1, keepSlash: false))
        }
        let sorted: [(String, String)] = encoded.sorted { a, b -> Bool in
            a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        let parts: [String] = sorted.map { pair -> String in
            pair.1.isEmpty ? pair.0 : "\(pair.0)=\(pair.1)"
        }
        return parts.joined(separator: "&")
    }

    /// Always signed: `x-oss-*`, `content-type` and `content-md5`. Optionally signed: anything named in
    /// `additionalHeaders` (`host` in the Aliyun doc's own worked example), which is how a header outside the
    /// mandatory set joins the signature. Lowercase names, trimmed values, sorted, each line `\n`-terminated.
    public static func canonicalHeaders(_ headers: [String: String], additionalHeaders: [String] = []) -> String {
        let optional = Set(additionalHeaders.map { $0.lowercased() })
        return headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.0.hasPrefix("x-oss-") || $0.0 == "content-type" || $0.0 == "content-md5" || optional.contains($0.0) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
    }

    /// Line 5 of the canonical request and the `AdditionalHeaders=` value: lowercased, de-duplicated, sorted,
    /// `;`-joined. Empty when nothing optional is signed, which is what B13's own requests send.
    public static func additionalHeadersLine(_ names: [String]) -> String {
        Set(names.map { $0.lowercased() }).sorted().joined(separator: ";")
    }

    /// Verb, URI, query, canonical headers, additional headers, payload hash — joined by `\n`.
    public static func canonicalRequest(method: String, bucket: String, key: String, query: [(String, String)], headers: [String: String], payloadHash: String, additionalHeaders: [String] = []) -> String {
        [method, canonicalURI(bucket: bucket, key: key), canonicalQuery(query),
         canonicalHeaders(headers, additionalHeaders: additionalHeaders),
         additionalHeadersLine(additionalHeaders), payloadHash].joined(separator: "\n")
    }

    public func scope(day: String) -> String { "\(day)/\(region)/oss/aliyun_v4_request" }

    public func stringToSign(canonicalRequest: String, stamp: String, day: String) -> String {
        [Self.algorithm, stamp, scope(day: day), Self.hex(Data(SHA256.hash(data: Data(canonicalRequest.utf8))))].joined(separator: "\n")
    }

    /// HMAC chain: ("aliyun_v4" + secret) → day → region → "oss" → "aliyun_v4_request" → string to sign.
    public func signature(stringToSign: String, day: String) -> String {
        let dateKey = Self.hmac(key: Data(("aliyun_v4" + accessKeySecret).utf8), data: Data(day.utf8))
        let regionKey = Self.hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = Self.hmac(key: regionKey, data: Data("oss".utf8))
        let signingKey = Self.hmac(key: serviceKey, data: Data("aliyun_v4_request".utf8))
        return Self.hex(Self.hmac(key: signingKey, data: Data(stringToSign.utf8)))
    }

    /// The request's headers plus `x-oss-date`, `x-oss-content-sha256` and `Authorization`. `additionalHeaders`
    /// names the optional headers to sign (they must already be in `headers`); it also adds the
    /// `AdditionalHeaders=` segment the server needs to rebuild the same canonical request. B13's callers pass
    /// none and let OSS derive `Host`.
    public func signedHeaders(method: String, bucket: String, key: String, query: [(String, String)] = [], headers: [String: String], date: Date = Date(), additionalHeaders: [String] = []) -> [String: String] {
        let (stamp, day) = Self.stamps(date)
        var h = headers
        h["x-oss-date"] = stamp
        h["x-oss-content-sha256"] = Self.unsignedPayload
        let canonical = Self.canonicalRequest(method: method, bucket: bucket, key: key, query: query, headers: h, payloadHash: Self.unsignedPayload, additionalHeaders: additionalHeaders)
        let sig = signature(stringToSign: stringToSign(canonicalRequest: canonical, stamp: stamp, day: day), day: day)
        let optional = Self.additionalHeadersLine(additionalHeaders)
        let segment = optional.isEmpty ? "" : "AdditionalHeaders=\(optional),"
        h["Authorization"] = "\(Self.algorithm) Credential=\(accessKeyId)/\(scope(day: day)),\(segment)Signature=\(sig)"
        return h
    }

    /// Presigned URL parameters in order: signature-version, credential, date, expires, signature. No header is signed.
    public func presignedQuery(method: String = "GET", bucket: String, key: String, expiresIn: Int, date: Date = Date()) -> [(String, String)] {
        let (stamp, day) = Self.stamps(date)
        var query: [(String, String)] = [
            ("x-oss-signature-version", Self.algorithm),
            ("x-oss-credential", "\(accessKeyId)/\(scope(day: day))"),
            ("x-oss-date", stamp),
            ("x-oss-expires", String(expiresIn)),
        ]
        let canonical = Self.canonicalRequest(method: method, bucket: bucket, key: key, query: query, headers: [:], payloadHash: Self.unsignedPayload)
        query.append(("x-oss-signature", signature(stringToSign: stringToSign(canonicalRequest: canonical, stamp: stamp, day: day), day: day)))
        return query
    }

    static func hmac(key: Data, data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
