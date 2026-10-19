import ControlCore
import Foundation

/// The 1 KB round trip behind `imctl oss test` and the B52 readiness probe: PUT → HEAD → presigned GET →
/// download (HEAD + GET) → DELETE. A failure part-way still deletes the probe object once.
public enum OSSRoundTrip {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missingAfterPut, mismatch, cleanup
        public var description: String {
            switch self {
            case .missingAfterPut: "HEAD after PUT says the object is missing"
            case .mismatch: "presigned GET or download returned different bytes"
            case .cleanup: "the probe object could not be deleted"
            }
        }
    }

    public static func run(store: OSSObjectStore, keyPrefix: String, step: (String) -> Void = { _ in }) throws {
        let key = "\(store.baseDir)/\(keyPrefix)/\(UUID().uuidString.lowercased()).txt"
        let payload = Data(repeating: 0x61, count: 1024)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-probe-\(UUID().uuidString).txt")
        try payload.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        step("1/5 PUT \(key)")
        try store.put(fileURL: temp, key: key, contentType: "text/plain")
        var deleted = false
        defer {
            if !deleted {
                do { try store.delete(key: key); step("cleanup: deleted probe") }
                catch let error as ControlError { step("cleanup failed: \(error.code)") }
                catch { step("cleanup failed: \(error)") }
            }
        }
        step("2/5 HEAD")
        guard try store.exists(key: key) else { throw Failure.missingAfterPut }
        step("3/5 presigned GET")
        let fetched = try store.fetchPresigned(try store.signedGetURL(key: key, expiresIn: 60), what: "presigned GET \(key)")
        // fetchPresigned hands back the raw status: keep the code for `imctl oss test` and the readiness category.
        guard fetched.status == 200 else { throw ControlError.objectStore("presigned GET \(key): HTTP \(fetched.status)") }
        guard fetched.body == payload else { throw Failure.mismatch }
        step("4/5 download via HEAD + GET")
        let back = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-probe-back-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: back) }
        guard try store.download(key: key, to: back, maxBytes: 4096) == 1024, (try? Data(contentsOf: back)) == payload else { throw Failure.mismatch }
        step("5/5 DELETE")
        do { try store.delete(key: key) } catch {
            // The old `imctl oss test` retried once before giving up; a second failure leaves the object behind.
            step("DELETE failed, retrying once")
            do { try store.delete(key: key) } catch { deleted = true; throw Failure.cleanup }
        }
        deleted = true
    }

    /// B52: the round trip as a readiness result; never throws, never returns remote text.
    public static func probe(settingsURL: URL, resourceTimeout: TimeInterval = 15, transport: OSSTransport? = nil) -> ReadinessProbeResult {
        let started = Date()
        guard let settings = try? OSSSettings.load(from: settingsURL) else { return .failure("config", latencyMs: 0) }
        let live: OSSTransport = transport ?? {
            let t = URLSessionOSSTransport()
            t.resourceTimeout = resourceTimeout
            return t
        }()
        do {
            try run(store: OSSObjectStore(settings: settings, transport: live), keyPrefix: "imctl-readiness")
            return .success(latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        } catch {
            return .failure(category(of: error), latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
    }

    /// A fixed category; the message (key, bucket, host) never leaves this function.
    static func category(of error: Error) -> String {
        if let failure = error as? Failure { return failure == .cleanup ? "cleanup" : "mismatch" }
        guard let control = error as? ControlError else { return "network" }
        let message = control.message
        if message.contains("timed out") { return "timeout" }
        if let range = message.range(of: #"HTTP \d{3}"#, options: .regularExpression), let code = Int(message[range].suffix(3)) {
            if code == 401 || code == 403 { return "auth" }
            if (400..<500).contains(code) { return "http4xx" }
            if (500..<600).contains(code) { return "http5xx" }
        }
        return "network"
    }
}
