import ControlCore
import Foundation

/// `ObjectStore` on Aliyun OSS (virtual-hosted URLs, V4 signatures). Every error becomes `ControlError.objectStore` (or `ossNotConfigured` when the settings fail validation)
/// carrying the verb, the object key, the HTTP status and the server's `Code` / `Message` — never the AccessKey
/// pair, the `Authorization` header or a signed URL's query, so a failure is safe to log verbatim.
public final class OSSObjectStore: ObjectStore {
    public let settings: OSSSettings
    public let transport: OSSTransport
    public let now: () -> Date
    let signer: OSSSigner
    /// `settings.validate()`'s outcome, captured once at init. `OSSSettings.load` already validates before
    /// handing settings to this initialiser, but nothing stops a caller from building `OSSSettings` in
    /// process (e.g. `OSSSettings(endpoint: "https://evil.example", …)`) and passing it straight here — that
    /// forms a perfectly valid URL, so the "cannot form a URL" guard in `url(for:)` would not catch it. The
    /// initialiser stays non-throwing (other targets construct this unconditionally); `url(for:)` throws this
    /// first instead, so no request can ever be built from invalid settings.
    private let settingsError: Error?

    public init(settings: OSSSettings, transport: OSSTransport = URLSessionOSSTransport(), now: @escaping () -> Date = Date.init) {
        self.settings = settings; self.transport = transport; self.now = now
        signer = OSSSigner(accessKeyId: settings.accessKeyId, accessKeySecret: settings.accessKeySecret, region: settings.region)
        do { try settings.validate(); settingsError = nil } catch { settingsError = error }
    }

    /// The daemon's one startup decision for OSS: missing `oss.json` or one that fails to decode / validate
    /// both leave OSS disabled (`nil`) instead of throwing — `imctld` runs under a KeepAlive LaunchAgent, so
    /// letting `OSSSettings.load`'s error escape `run()` would exit the process and crash-loop it. `log`
    /// receives exactly one line naming the outcome; the invalid branch's line never echoes a secret value —
    /// `OSSSettings.validate()`'s messages name only the offending field, and a `DecodingError`'s
    /// `debugDescription` names only coding keys / expected types, never decoded string content.
    public static func loadIfConfigured(at url: URL, log: (String) -> Void) -> OSSObjectStore? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("oss: disabled (no \(url.path)); message.media and message.sendFile{ossKey} answer OSS_NOT_CONFIGURED")
            return nil
        }
        do {
            let settings = try OSSSettings.load(from: url)
            log("oss: enabled \(settings.summary)")
            return OSSObjectStore(settings: settings)
        } catch {
            log("oss.json invalid, OSS disabled: \(error)")
            return nil
        }
    }

    public var summary: String { settings.summary }
    public var baseDir: String { settings.baseDir }
    public var maxUploadBytes: Int64 { settings.maxUploadBytes }
    public var viewExpireSeconds: Int { settings.viewExpireSeconds }

    /// - Throws: `settingsError` (typically `ControlError.ossNotConfigured`) when `settings` never passed
    ///   `validate()`; `ControlError.objectStore` when bucket + key still cannot form a URL despite valid
    ///   settings (defence in depth — should not happen once the check above holds).
    func url(for key: String, query: [(String, String)] = []) throws -> URL {
        if let settingsError { throw settingsError }
        var s = "https://\(settings.bucketHost)/\(OSSSigner.encode(key, keepSlash: true))"
        if !query.isEmpty { s += "?" + query.map { "\(OSSSigner.encode($0.0, keepSlash: false))=\(OSSSigner.encode($0.1, keepSlash: false))" }.joined(separator: "&") }
        guard let url = URL(string: s) else { throw ControlError.objectStore("\(key): oss.json's bucket / endpoint cannot form a request URL") }
        return url
    }

    func request(_ method: String, key: String, headers: [String: String] = [:]) throws -> URLRequest {
        var r = URLRequest(url: try url(for: key))
        r.httpMethod = method
        r.timeoutInterval = 120
        for (k, v) in signer.signedHeaders(method: method, bucket: settings.bucket, key: key, headers: headers, date: now()) { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(settings.bucketHost, forHTTPHeaderField: "Host")
        return r
    }

    public func exists(key: String) throws -> Bool {
        let r = try send(request("HEAD", key: key), what: "HEAD \(key)", accept: [200, 404])
        return r.status == 200
    }

    public func put(fileURL: URL, key: String, contentType: String) throws {
        _ = try send(request("PUT", key: key, headers: ["Content-Type": contentType]), what: "PUT \(key)", accept: [200], uploading: fileURL)
    }

    public func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL {
        try url(for: key, query: signer.presignedQuery(bucket: settings.bucket, key: key, expiresIn: Self.clampedExpiry(expiresIn), date: now()))
    }

    /// Fetches an already-signed URL (typically `signedGetURL`'s result) bounded to `timeoutSeconds`. A raw
    /// `URLError` is mapped into the same `ControlError.objectStore("$what: timed out after Ns" / "$what:
    /// $description")` shape every other operation already throws on a transport failure, instead of leaking
    /// an unformatted `URLError` — this is what `imctl oss test`'s presigned-GET step calls so a network
    /// hiccup there prints the same way a PUT/HEAD/DELETE failure would. HTTP-status handling (2xx vs. not)
    /// is left to the caller, unlike `send`: a probe wants to see the raw status, not have it turned into an
    /// error.
    public func fetchPresigned(_ url: URL, what: String, timeoutSeconds: TimeInterval = 30) throws -> OSSResponse {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        do {
            return try transport.send(request, uploading: nil, downloadingTo: nil)
        } catch let error as URLError where error.code == .timedOut {
            throw ControlError.objectStore("\(what): timed out after \(Int(timeoutSeconds)) s")
        } catch {
            throw ControlError.objectStore("\(what): \(error.localizedDescription)")
        }
    }

    /// OSS refuses a presigned URL beyond 7 days, and `Int(_:)` traps on a non-finite `TimeInterval`.
    /// Out-of-range values clamp; `nan` clamps to the floor rather than to a week, so a bad caller fails
    /// closed with a useless URL instead of minting a long-lived one.
    static func clampedExpiry(_ seconds: TimeInterval) -> Int {
        let ceiling = OSSSettings.maxViewExpireSeconds
        guard !seconds.isNaN else { return 1 }
        if seconds <= 1 { return 1 }
        if seconds >= TimeInterval(ceiling) { return ceiling }
        return Int(exactly: seconds.rounded()) ?? ceiling
    }

    public func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 {
        let head = try send(request("HEAD", key: key), what: "HEAD \(key)", accept: [200, 404])
        guard head.status == 200 else { throw ControlError.sourceUnreachable("ossKey \(key): no such object") }
        let length = Int64(head.headers.first { $0.key.lowercased() == "content-length" }?.value ?? "") ?? -1
        if length > maxBytes { throw ControlError.sourceTooLarge("ossKey \(key) is \(length) bytes; the cap is \(maxBytes)") }
        _ = try send(request("GET", key: key), what: "GET \(key)", accept: [200], downloadingTo: destination)
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size > maxBytes { try? FileManager.default.removeItem(at: destination); throw ControlError.sourceTooLarge("ossKey \(key) is \(size) bytes; the cap is \(maxBytes)") }
        return size
    }

    public func delete(key: String) throws {
        _ = try send(request("DELETE", key: key), what: "DELETE \(key)", accept: [200, 204])
    }

    @discardableResult
    func send(_ request: URLRequest, what: String, accept: Set<Int>, uploading: URL? = nil, downloadingTo: URL? = nil) throws -> OSSResponse {
        let response: OSSResponse
        do { response = try transport.send(request, uploading: uploading, downloadingTo: downloadingTo) }
        catch let error as URLError where error.code == .timedOut {
            let cap = (transport as? URLSessionOSSTransport).map { " after \(Int($0.resourceTimeout)) s" } ?? ""
            throw ControlError.objectStore("\(what): timed out\(cap)")
        }
        // Writing the downloaded body into its destination failed on THIS Mac (`URLSessionOSSTransport` maps
        // a non-`URLError` from its own `moveItem` to this code): say so, instead of sending an operator off
        // to look at the bucket.
        catch let error as URLError where error.code == .cannotCreateFile {
            throw ControlError.objectStore("\(what): local write failed: \(error.localizedDescription)")
        }
        catch { throw ControlError.objectStore("\(what): \(error.localizedDescription)") }
        guard accept.contains(response.status) else { throw ControlError.objectStore("\(what): HTTP \(response.status)\(Self.detail(response.body))") }
        return response
    }

    /// ` Code: Message` from the XML error body (and nothing else from it).
    static func detail(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        guard let code = tag("Code") else { return "" }
        return " \(code)" + (tag("Message").map { ": \($0)" } ?? "")
    }
}
