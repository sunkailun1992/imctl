import Foundation
import Testing
@testable import OSSClient

/// Scripted `URLProtocol` so the real `URLSessionOSSTransport` can be exercised without a network: the suite
/// registers it on an ephemeral configuration, so every request in these tests is answered in-process.
/// `stall` answers the headers and then never finishes, which is the shape that used to hang `done.wait()`.
final class StubOSSURLProtocol: URLProtocol {
    struct Script { var status: Int; var headers: [String: String]; var body: Data; var stall: Bool = false; var failure: URLError.Code? = nil }
    nonisolated(unsafe) static var scripts: [String: Script] = [:]
    /// Guards `cancelled`: `stopLoading()` runs on URLSession's own queue, which can otherwise race a test's
    /// read right after `send(_:uploading:downloadingTo:)` returns.
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var cancelled: [URL] = []
    static var cancelledURLs: [URL] { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }
    static func reset() { stateLock.lock(); cancelled = []; stateLock.unlock(); scripts = [:] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let script = Self.scripts[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        if let failure = script.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: nil, headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if script.stall { return }
        client?.urlProtocol(self, didLoad: script.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        guard let url = request.url else { return }
        Self.stateLock.lock(); Self.cancelled.append(url); Self.stateLock.unlock()
    }
}

@Suite("URLSessionOSSTransport", .serialized)
struct OSSTransportTests {
    static let base = "https://b.oss-cn-hangzhou.aliyuncs.com"

    func transport(resourceTimeout: TimeInterval = 300) -> URLSessionOSSTransport {
        StubOSSURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOSSURLProtocol.self]
        let t = URLSessionOSSTransport(session: URLSession(configuration: config))
        t.resourceTimeout = resourceTimeout
        return t
    }

    @Test func aDataRequestCarriesTheStatusHeadersAndBody() throws {
        let t = transport()
        let url = URL(string: "\(Self.base)/imctl/x.png")!
        StubOSSURLProtocol.scripts[url.absoluteString] = .init(status: 404, headers: ["Content-Length": "7", "x-oss-request-id": "REQ1"], body: Data("missing".utf8))
        let r = try t.send(URLRequest(url: url), uploading: nil, downloadingTo: nil)
        #expect(r.status == 404 && r.body == Data("missing".utf8))
        #expect(r.headers.first { $0.key.lowercased() == "x-oss-request-id" }?.value == "REQ1")
        #expect(r.headers.first { $0.key.lowercased() == "content-length" }?.value == "7")
    }

    @Test func anUploadSendsTheFileAndReportsTheStatus() throws {
        let t = transport()
        let url = URL(string: "\(Self.base)/imctl/up.png")!
        StubOSSURLProtocol.scripts[url.absoluteString] = .init(status: 200, headers: [:], body: Data())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-up-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3]).write(to: file)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        #expect(try t.send(request, uploading: file, downloadingTo: nil).status == 200)
    }

    /// URLSession hands the download back in a temporary file that is deleted when the completion handler
    /// returns; the transport must move it into place before that.
    @Test func aDownloadMovesTheTemporaryFileToTheDestination() throws {
        let t = transport()
        let url = URL(string: "\(Self.base)/imctl/doc.pdf")!
        StubOSSURLProtocol.scripts[url.absoluteString] = .init(status: 200, headers: [:], body: Data("pdf-bytes".utf8))
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-dl-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: dest) }
        let r = try t.send(URLRequest(url: url), uploading: nil, downloadingTo: dest)
        #expect(r.status == 200)
        #expect(try Data(contentsOf: dest) == Data("pdf-bytes".utf8))
    }

    /// A transport failure is re-thrown as a `URLError` that carries only a description: no failing URL, so
    /// a signed URL's query can never reach a log through the error. Finding F10: the code is the original
    /// one, not a blanket `.cannotConnectToHost` — that relabelling made `OSSObjectStore`'s `.timedOut`
    /// branch dead code and reported every failure as "could not connect".
    @Test func aTransportErrorIsRethrownWithItsOwnCodeButWithoutTheURL() throws {
        let t = transport()
        // No script for this URL: the stub fails the request with `.cannotFindHost`.
        let url = URL(string: "\(Self.base)/imctl/nowhere.png")!
        do {
            _ = try t.send(URLRequest(url: url), uploading: nil, downloadingTo: nil)
            Issue.record("expected a URLError")
        } catch let error as URLError {
            #expect(error.code == .cannotFindHost)
            let info = (error as NSError).userInfo
            #expect(info[NSURLErrorFailingURLErrorKey] == nil && info[NSURLErrorFailingURLStringErrorKey] == nil)
            #expect(!info.values.contains { "\($0)".contains("oss-cn-hangzhou") || "\($0)".contains("nowhere.png") })
        }
    }

    /// Finding F10, the case the relabelling hid: a request the server itself times out has to reach
    /// `OSSObjectStore` as `.timedOut`, which is what turns into its "timed out" message — and the URL still
    /// must not ride along in the error.
    @Test func aCompletionTimeoutKeepsItsCodeSoTheStoreCanReportIt() throws {
        let t = transport()
        let url = URL(string: "\(Self.base)/imctl/slow2.png")!
        StubOSSURLProtocol.scripts[url.absoluteString] = .init(status: 200, headers: [:], body: Data(), failure: .timedOut)
        do {
            _ = try t.send(URLRequest(url: url), uploading: nil, downloadingTo: nil)
            Issue.record("expected a timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
            let info = (error as NSError).userInfo
            #expect(info[NSURLErrorFailingURLErrorKey] == nil && info[NSURLErrorFailingURLStringErrorKey] == nil)
            #expect(!info.values.contains { "\($0)".contains("oss-cn-hangzhou") || "\($0)".contains("slow2.png") })
        }
    }

    /// Finding F10, the other half: the download's own `moveItem` into the destination is a LOCAL failure.
    /// Reported as `.cannotConnectToHost` it read as "OSS is unreachable"; it now carries `.cannotCreateFile`,
    /// which `OSSObjectStore` words as a local write failure.
    @Test func aFailedMoveIntoTheDestinationIsALocalWriteNotATransportFailure() throws {
        let t = transport()
        let url = URL(string: "\(Self.base)/imctl/doc2.pdf")!
        StubOSSURLProtocol.scripts[url.absoluteString] = .init(status: 200, headers: [:], body: Data("pdf-bytes".utf8))
        // The parent directory does not exist, so the move out of URLSession's temporary file fails.
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-oss-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("doc2.pdf")
        do {
            _ = try t.send(URLRequest(url: url), uploading: nil, downloadingTo: dest)
            Issue.record("expected the move to fail")
        } catch let error as URLError {
            #expect(error.code == .cannotCreateFile)
            let info = (error as NSError).userInfo
            #expect(info[NSURLErrorFailingURLErrorKey] == nil && info[NSURLErrorFailingURLStringErrorKey] == nil)
        }
    }

    /// The regression this finding is about: an unbounded `done.wait()` parks the executor's serial queue for
    /// as long as a trickling server keeps the connection open. The wait is now capped by `resourceTimeout`.
    @Test func aStalledRequestHitsResourceTimeoutAndCancelsTheTask() throws {
        let t = transport(resourceTimeout: 0.5)
        let url = URL(string: "\(Self.base)/imctl/slow.png")!
        StubOSSURLProtocol.scripts[url.absoluteString] = .init(status: 200, headers: [:], body: Data("x".utf8), stall: true)
        let started = Date()
        do {
            _ = try t.send(URLRequest(url: url), uploading: nil, downloadingTo: nil)
            Issue.record("expected a timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.4 && elapsed < 5, "elapsed \(elapsed)s")
        // URLSession may deliver its cancelled completion before URLProtocol's
        // stopLoading callback; allow that separate queue to finish.
        let cancellationDeadline = Date().addingTimeInterval(1)
        while !StubOSSURLProtocol.cancelledURLs.contains(url), Date() < cancellationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(StubOSSURLProtocol.cancelledURLs.contains(url))
    }
}
