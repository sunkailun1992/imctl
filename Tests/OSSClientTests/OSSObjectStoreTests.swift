import Foundation
import Testing
@testable import ControlCore
@testable import OSSClient

final class ScriptedTransport: OSSTransport {
    var responses: [OSSResponse] = []
    var sent: [(request: URLRequest, upload: URL?, download: URL?)] = []
    var downloadBody = Data("hello".utf8)
    /// When set, `send` throws this instead of answering — how a transport-level failure (a timeout,
    /// a refused connection) reaches the store.
    var failure: Error?
    func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse {
        sent.append((request, file, destination))
        if let failure { throw failure }
        if let destination { try downloadBody.write(to: destination) }
        return responses.isEmpty ? OSSResponse(status: 200, headers: [:], body: Data()) : responses.removeFirst()
    }
}

@Suite("OSSObjectStore")
struct OSSObjectStoreTests {
    // "buk" (not "b"): OSSSettings.validate() requires 3+ characters, and OSSObjectStore now validates at
    // init (Task 9 residual) — a 1-char bucket would fail before any request is even sent.
    func store(bucket: String = "buk") -> (OSSObjectStore, ScriptedTransport) {
        let settings = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: bucket, baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", viewExpireSeconds: 60, maxUploadBytes: 100)
        let t = ScriptedTransport()
        return (OSSObjectStore(settings: settings, transport: t, now: { Date(timeIntervalSince1970: 1_790_000_000) }), t)
    }

    @Test func putHeadDeleteAndSignedURL() throws {
        let (s, t) = store()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-put-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3]).write(to: file)
        try s.put(fileURL: file, key: "imctl/2026/09/22/k-a b.png", contentType: "image/png")
        let put = t.sent[0].request
        #expect(put.httpMethod == "PUT" && put.url?.absoluteString == "https://buk.oss-cn-hangzhou.aliyuncs.com/imctl/2026/09/22/k-a%20b.png" && t.sent[0].upload == file)
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "image/png" && put.value(forHTTPHeaderField: "Authorization")?.hasPrefix("OSS4-HMAC-SHA256 Credential=TESTAKID0000000001/20260921/cn-hangzhou/oss/aliyun_v4_request,Signature=") == true)
        #expect(put.value(forHTTPHeaderField: "x-oss-content-sha256") == "UNSIGNED-PAYLOAD" && put.value(forHTTPHeaderField: "Host") == "buk.oss-cn-hangzhou.aliyuncs.com")
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "3"], body: Data()), OSSResponse(status: 404, headers: [:], body: Data())]
        #expect(try s.exists(key: "k") == true && (try s.exists(key: "k")) == false && t.sent[1].request.httpMethod == "HEAD")
        let url = try s.signedGetURL(key: "imctl/x.pdf", expiresIn: 60)
        #expect(url.absoluteString.hasPrefix("https://buk.oss-cn-hangzhou.aliyuncs.com/imctl/x.pdf?x-oss-signature-version=OSS4-HMAC-SHA256&x-oss-credential=") && url.absoluteString.contains("x-oss-expires=60") && url.absoluteString.contains("&x-oss-signature="))
        try s.delete(key: "k")
        #expect(t.sent.last?.request.httpMethod == "DELETE")
        #expect(s.summary.contains("bucket=buk") && !s.summary.contains("test-secret") && s.baseDir == "imctl" && s.maxUploadBytes == 100)
    }

    /// Errors carry the verb, the object key, the HTTP status and the server's `Code` / `Message`. The
    /// requests below really do carry `Authorization: …Signature=…`, and `signedGetURL` really does mint
    /// `x-oss-signature=…`, so the assertion is that none of that ever reaches a message a daemon logs.
    @Test func errorsCarryStatusAndCodeNeverTheSecretOrSignature() throws {
        let (s, t) = store()
        t.responses = [OSSResponse(status: 403, headers: [:], body: Data("<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match.</Message></Error>".utf8))]
        do { _ = try s.exists(key: "k"); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError { #expect(e.code == "OSS_ERROR" && e.message == "HEAD k: HTTP 403 SignatureDoesNotMatch: The request signature we calculated does not match.") }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-put-\(UUID().uuidString).png")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-dl-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: dest) }
        try Data([1, 2, 3]).write(to: file)
        let denied = Data("<Error><Code>AccessDenied</Code><Message>You have no right to access this object.</Message></Error>".utf8)
        var messages: [String] = []
        t.responses = [OSSResponse(status: 403, headers: [:], body: denied)]
        do { try s.put(fileURL: file, key: "imctl/x.png", contentType: "image/png"); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError { messages.append(e.message) }
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "3"], body: Data()), OSSResponse(status: 403, headers: [:], body: denied)]
        do { _ = try s.download(key: "imctl/x.pdf", to: dest, maxBytes: 100); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError { messages.append(e.message) }
        #expect(messages.count == 2)
        for m in messages {
            #expect(m.contains("AccessDenied") && !m.contains("test-secret") && !m.contains("x-oss-signature=") && !m.contains("Signature=") && !m.contains("TESTAKID0000000001"), "leaky message: \(m)")
        }
        // The signature only ever lives in the URL handed to the consumer, never in `summary` / errors.
        let signed = try s.signedGetURL(key: "imctl/x.pdf", expiresIn: 60)
        #expect(signed.absoluteString.contains("x-oss-signature=") && !s.summary.contains("x-oss-signature="))
    }

    /// A malformed `bucket` (a hand-edited `oss.json` that never went through `OSSSettings.validate`) used to
    /// trap `imctld` on `URL(string:)!`. Since the Task 9 fix, `OSSObjectStore.init` runs `validate()` itself,
    /// so this is now caught even earlier — as `OSS_NOT_CONFIGURED`, before `url(for:)`'s own "cannot form a
    /// URL" guard is ever reached — but the property this test cares about is unchanged: no trap, nothing sent.
    @Test func anUnbuildableURLThrowsInsteadOfTrapping() throws {
        let (s, t) = store(bucket: "my bucket")
        do { _ = try s.exists(key: "k"); Issue.record("expected OSS_NOT_CONFIGURED") }
        catch let e as ControlError { #expect(e.code == "OSS_NOT_CONFIGURED") }
        do { _ = try s.signedGetURL(key: "k", expiresIn: 60); Issue.record("expected OSS_NOT_CONFIGURED") }
        catch let e as ControlError { #expect(e.code == "OSS_NOT_CONFIGURED") }
        #expect(t.sent.isEmpty)
    }

    /// A stalled request reaches the store as `URLError(.timedOut)`; the message must say so rather than
    /// blend into every other transport failure.
    @Test func aTimeoutGetsItsOwnMessage() throws {
        let (s, t) = store()
        t.failure = URLError(.timedOut)
        do { _ = try s.exists(key: "k"); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError { #expect(e.code == "OSS_ERROR" && e.message.contains("timed out") && e.message.hasPrefix("HEAD k:")) }
    }

    /// Finding F10: writing the downloaded body into its destination is a LOCAL failure, which the transport
    /// now reports as `.cannotCreateFile`. The store must word it as a local write rather than blame OSS —
    /// "OSS is unreachable" would send an operator looking at the wrong machine.
    @Test func aLocalWriteFailureIsNotBlamedOnTheObjectStore() throws {
        let (s, t) = store()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-lw-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "3"], body: Data())]
        t.failure = nil
        _ = try? s.exists(key: "k")
        t.failure = URLError(.cannotCreateFile, userInfo: [NSLocalizedDescriptionKey: "could not write the file"])
        do { _ = try s.download(key: "imctl/x.pdf", to: dest, maxBytes: 100); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError {
            #expect(e.code == "OSS_ERROR" && e.message.contains("local write failed") && e.message.contains("could not write the file"))
            #expect(!e.message.contains("timed out"))
        }
    }

    /// OSS caps a presigned URL at 7 days, and `Int(expiresIn)` traps on a non-finite `TimeInterval`.
    @Test func signedURLExpiryIsClampedAndNeverTraps() throws {
        let (s, _) = store()
        func expires(_ seconds: TimeInterval) throws -> String? {
            let q = try s.signedGetURL(key: "k.pdf", expiresIn: seconds).absoluteString
            return q.split(separator: "&").first { $0.hasPrefix("x-oss-expires=") }.map { String($0.dropFirst("x-oss-expires=".count)) }
        }
        #expect(try expires(60) == "60")
        #expect(try expires(0) == "1")
        #expect(try expires(-5) == "1")
        #expect(try expires(604_801) == "604800")
        #expect(try expires(.infinity) == "604800")
        #expect(try expires(-.infinity) == "1")
        #expect(try expires(.nan) == "1")
        #expect(try expires(1e30) == "604800")
    }

    @Test func downloadChecksTheSizeFirst() throws {
        let (s, t) = store()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-dl-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: dest) }
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "5"], body: Data()), OSSResponse(status: 200, headers: [:], body: Data())]
        #expect(try s.download(key: "k.txt", to: dest, maxBytes: 10) == 5 && (try String(contentsOf: dest, encoding: .utf8)) == "hello")
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "5000"], body: Data())]
        #expect(throws: ControlError.self) { try s.download(key: "big", to: dest, maxBytes: 10) }
        t.responses = [OSSResponse(status: 404, headers: [:], body: Data())]
        do { _ = try s.download(key: "gone", to: dest, maxBytes: 10); Issue.record("expected SOURCE_UNREACHABLE") }
        catch let e as ControlError { #expect(e.code == "SOURCE_UNREACHABLE") }
    }

    // MARK: - Task 9 residual: OSSObjectStore must validate settings itself, not just trust OSSSettings.load

    /// A hand-built `OSSSettings` (as `imctld` could construct if some future caller skipped `.load`) never
    /// goes through `validate()`. `endpoint: "https://evil.example"` forms a perfectly valid URL — the
    /// existing "cannot form a URL" guard in `url(for:)` does not catch it — so without validating at init, a
    /// signed request would leave the Mac aimed at a foreign host. Every operation must refuse before the
    /// stub transport ever sees a request.
    @Test func invalidSettingsRefuseEveryOperationBeforeAnyRequestIsSent() throws {
        let bad = OSSSettings(endpoint: "https://evil.example", bucket: "buk", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", viewExpireSeconds: 60, maxUploadBytes: 100)
        let t = ScriptedTransport()
        let s = OSSObjectStore(settings: bad, transport: t, now: { Date(timeIntervalSince1970: 1_790_000_000) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-invalid-\(UUID().uuidString).png")
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-invalid-dl-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: dest) }
        try Data([1, 2, 3]).write(to: file)

        func expectRefused(_ body: () throws -> Void) {
            do { try body(); Issue.record("expected OSS_NOT_CONFIGURED") }
            catch let e as ControlError { #expect(e.code == "OSS_NOT_CONFIGURED") }
            catch { Issue.record("expected a ControlError, got \(error)") }
        }
        expectRefused { _ = try s.exists(key: "k") }
        expectRefused { try s.put(fileURL: file, key: "k", contentType: "image/png") }
        expectRefused { _ = try s.signedGetURL(key: "k", expiresIn: 60) }
        expectRefused { _ = try s.download(key: "k", to: dest, maxBytes: 100) }
        expectRefused { try s.delete(key: "k") }
        #expect(t.sent.isEmpty)
    }

    // MARK: - Task 11 critical: the daemon's startup decision must never throw

    /// No `oss.json` at all: the daemon's existing, unchanged "disabled" outcome.
    @Test func loadIfConfiguredReturnsNilAndLogsWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-load-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("oss.json")
        var lines: [String] = []
        let result = OSSObjectStore.loadIfConfigured(at: file, log: { lines.append($0) })
        #expect(result == nil)
        #expect(lines.count == 1)
        #expect(lines[0].contains("disabled") && lines[0].contains("OSS_NOT_CONFIGURED"))
    }

    /// A hand-edited `oss.json` that is well-formed JSON but fails `OSSSettings.validate()` (a bucket with a
    /// space): this must disable OSS instead of throwing out of `imctld`'s `run()` — a KeepAlive LaunchAgent
    /// would otherwise crash-loop. The log line names the offending field but must never echo the secret.
    @Test func loadIfConfiguredReturnsNilAndLogsWithoutTheSecretWhenInvalid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("oss.json")
        let secret = "do-not-log-this-secret-value"
        let bad = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "my bucket", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: secret, viewExpireSeconds: 60, maxUploadBytes: 100)
        // Bypasses OSSSettings.save (which would itself refuse this), exactly like a hand-edited file would.
        try JSONEncoder().encode(bad).write(to: file)

        var lines: [String] = []
        let result = OSSObjectStore.loadIfConfigured(at: file, log: { lines.append($0) })
        #expect(result == nil)
        #expect(lines.count == 1)
        #expect(lines[0].contains("invalid") && lines[0].contains("OSS disabled"))
        #expect(lines[0].contains("bucket"), "expected the field name in: \(lines[0])")
        #expect(!lines[0].contains(secret), "leaked the secret: \(lines[0])")
    }

    /// A valid `oss.json`: unchanged "enabled" outcome, still never logging the secret.
    @Test func loadIfConfiguredReturnsAStoreAndLogsWhenValid() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("oss.json")
        let secret = "do-not-log-this-secret-value"
        let good = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: secret, viewExpireSeconds: 60, maxUploadBytes: 100)
        try good.save(to: file)

        var lines: [String] = []
        let result = OSSObjectStore.loadIfConfigured(at: file, log: { lines.append($0) })
        #expect(result != nil)
        #expect(lines.count == 1)
        #expect(lines[0].contains("enabled") && !lines[0].contains(secret))
    }

    // MARK: - Important: imctl oss test's presigned-GET step must not leak a raw URLError

    /// A stalled presigned GET must surface the same `ControlError.objectStore` shape ("$what: timed out
    /// after Ns") every other operation already uses, never a bare `URLError`.
    @Test func fetchPresignedMapsATimeoutToTheSameShapeAsEveryOtherOperation() throws {
        let (s, t) = store()
        t.failure = URLError(.timedOut)
        do { _ = try s.fetchPresigned(URL(string: "https://b.oss-cn-hangzhou.aliyuncs.com/k?x-oss-signature=abc")!, what: "presigned GET k", timeoutSeconds: 30); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError { #expect(e.code == "OSS_ERROR" && e.message == "presigned GET k: timed out after 30 s") }
        #expect(t.sent.last?.request.timeoutInterval == 30)
    }

    /// The happy path still returns whatever the transport answered, untouched (status/body handling stays
    /// the caller's job — `fetchPresigned` only shapes the exception path).
    @Test func fetchPresignedReturnsTheResponseOnSuccess() throws {
        let (s, t) = store()
        t.responses = [OSSResponse(status: 200, headers: [:], body: Data("hello".utf8))]
        let response = try s.fetchPresigned(URL(string: "https://b.oss-cn-hangzhou.aliyuncs.com/k?x-oss-signature=abc")!, what: "presigned GET k")
        #expect(response.status == 200 && response.body == Data("hello".utf8))
    }
}
