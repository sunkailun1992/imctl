import Foundation
import Testing
@testable import ControlCore

/// Serves scripted responses to the fetcher's URLSession; one static script per test run (tests in this suite are serialized).
final class StubURLProtocol: URLProtocol {
    struct Script { var status: Int; var headers: [String: String]; var body: Data; var redirectTo: URL?; var stall: Bool = false }
    nonisolated(unsafe) static var scripts: [String: Script] = [:]
    nonisolated(unsafe) private static var requests: [URL] = []
    nonisolated(unsafe) private static var cancelled: [URL] = []
    /// Protects callback records and waits for a specific source's event. A locked snapshot alone cannot
    /// prove `stopLoading()` has run: URLSession's completion delegate can finish before that callback.
    private static let stateCondition = NSCondition()
    static func recordRequest(_ url: URL) {
        stateCondition.lock(); defer { stateCondition.unlock() }
        requests.append(url)
        stateCondition.broadcast()
    }
    static func recordCancel(_ url: URL) {
        stateCondition.lock(); defer { stateCondition.unlock() }
        cancelled.append(url)
        stateCondition.broadcast()
    }
    static func resetRecordedEvents() {
        stateCondition.lock(); defer { stateCondition.unlock() }
        requests.removeAll(); cancelled.removeAll()
    }
    private enum Event { case start, cancel }
    private static func wait(for event: Event, url: URL, until deadline: Date) -> Bool {
        stateCondition.lock(); defer { stateCondition.unlock() }
        while !(event == .start ? requests : cancelled).contains(url) {
            guard Date() < deadline else { return false }
            _ = stateCondition.wait(until: deadline)
        }
        return true
    }
    static func waitForStart(of url: URL, until deadline: Date) -> Bool {
        wait(for: .start, url: url, until: deadline)
    }
    static func waitForCancel(of url: URL, until deadline: Date) -> Bool {
        wait(for: .cancel, url: url, until: deadline)
    }
    /// Lock-guarded read of `cancelled`; tests must read through this, never the raw array, so a read never races
    /// `stopLoading()`'s append on URLSession's queue.
    static var cancelledURLs: [URL] { stateCondition.lock(); defer { stateCondition.unlock() }; return cancelled }
    /// Lock-guarded read of `requests`, mirroring `cancelledURLs`: `startLoading()` runs on URLSession's own
    /// queue too, so a test reading the raw array right after `fetch(url:)` returns has the same race.
    static var requestedURLs: [URL] { stateCondition.lock(); defer { stateCondition.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let script = Self.scripts[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        Self.recordRequest(url)
        if let target = script.redirectTo {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self); return
        }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: nil, headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if script.stall { return }
        client?.urlProtocol(self, didLoad: script.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if let url = request.url { Self.recordCancel(url) } }
}

@Suite("FileFetcher (B13 outbox)", .serialized)
struct FileFetcherTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 1, 2, 3, 4])
    static let pdf = Data("%PDF-1.4 tiny".utf8)
    static let heic = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63, 0, 0, 0, 0])

    func fetcher() throws -> (FileFetcher, URL) {
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-outbox-\(UUID().uuidString)", isDirectory: true)
        let f = FileFetcher(outbox: outbox)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        f.sessionConfiguration = config
        f.timeout = 5
        StubURLProtocol.scripts = [:]; StubURLProtocol.resetRecordedEvents()
        return (f, outbox)
    }

    var policy: SendFilePolicy { var p = SendFilePolicy(); p.allow("cdn.example"); p.maxBytes = 1000; return p }

    /// A per-download directory name: 12 lowercase hex characters (the truncated `MessageKey` stamp).
    func isTwelveHexDirectoryName(_ s: String) -> Bool { s.count == 12 && s.allSatisfy(\.isHexDigit) }

    @Test func downloadsIntoAPrivateOutboxAndSniffsTheKind() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/pics/single.png"] = .init(status: 200, headers: ["Content-Length": "20"], body: Self.png, redirectTo: nil)
        let got = try f.fetch(url: URL(string: "https://cdn.example/pics/single.png")!, fileName: nil, policy: policy)
        #expect(got.fileName == "single.png" && got.bytes == 20 && got.kind == "image" && got.contentType == "image/png")
        #expect(got.url.lastPathComponent == "single.png")
        #expect(try got.url.path.hasPrefix(outbox.path) && Data(contentsOf: got.url) == Self.png)
        let dirMode = try FileManager.default.attributesOfItem(atPath: outbox.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: got.url.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700 && fileMode == 0o600)
        f.discard(got)
        #expect(!FileManager.default.fileExists(atPath: got.url.path))
    }

    @Test func heicCanBeReadForPreviewButRemainsBlockedForSending() throws {
        let (f, _) = try fetcher()
        let url = URL(string: "https://cdn.example/picture.heic")!
        StubURLProtocol.scripts[url.absoluteString] = .init(status: 200, headers: [:], body: Self.heic, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: url, fileName: nil, policy: policy) }
        let preview = try f.fetch(url: url, fileName: nil, policy: policy, allowHEICPreview: true)
        #expect(preview.kind == "image" && preview.contentType == "image/heic" && preview.bytes == Int64(Self.heic.count))
    }

    /// The live defect (observed 2026-09-23, WeCom 5.0.11, imctl 1.0.2): the file on disk must be named exactly
    /// the sanitised name — no `<id>-` prefix — because that URL is what `WeComActions.sendFile` puts on the
    /// pasteboard, so a prefixed name is what the client shows and sends. The uniqueifying id now names the
    /// per-download directory instead. Uses a percent-encoded URL (like a real https source) so the sanitised
    /// name comes from `FileNames.name(from:)`'s percent-decoding, not a literal test string.
    @Test func fetchedFileKeepsItsExactNameInsideATwelveHexPerDownloadDirectory() throws {
        let (f, outbox) = try fetcher()
        let rawName = "电子发票-17.31.pdf"
        let encoded = try #require(rawName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        let urlString = "https://cdn.example/invoices/\(encoded)"
        StubURLProtocol.scripts[urlString] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        let got = try f.fetch(url: URL(string: urlString)!, fileName: nil, policy: policy)
        #expect(got.fileName == rawName)
        #expect(got.url.lastPathComponent == rawName)
        let parent = got.url.deletingLastPathComponent()
        #expect(parent.deletingLastPathComponent().path == outbox.path)
        #expect(isTwelveHexDirectoryName(parent.lastPathComponent))
        let dirMode = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
    }

    /// Two different sources that happen to sanitise to the same file name must not collide: previously the
    /// id prefixed the file name itself (`<id>-report.pdf`), which already kept them apart; now the id names
    /// the directory instead, so the same guarantee has to come from two different directories.
    @Test func sameSanitisedNameFromDifferentSourcesCoexistsInDifferentDirectories() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/a/report.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        StubURLProtocol.scripts["https://cdn.example/b/report.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        let first = try f.fetch(url: URL(string: "https://cdn.example/a/report.pdf")!, fileName: nil, policy: policy)
        let second = try f.fetch(url: URL(string: "https://cdn.example/b/report.pdf")!, fileName: nil, policy: policy)
        #expect(first.url.lastPathComponent == "report.pdf" && second.url.lastPathComponent == "report.pdf")
        let firstDir = first.url.deletingLastPathComponent(), secondDir = second.url.deletingLastPathComponent()
        #expect(firstDir.path != secondDir.path)
        #expect(FileManager.default.fileExists(atPath: first.url.path) && FileManager.default.fileExists(atPath: second.url.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: outbox.path))?.count == 2)
    }

    @Test func discardRemovesTheWholePerDownloadDirectory() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/c/report.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        let got = try f.fetch(url: URL(string: "https://cdn.example/c/report.pdf")!, fileName: nil, policy: policy)
        let dir = got.url.deletingLastPathComponent()
        f.discard(got)
        #expect(!FileManager.default.fileExists(atPath: got.url.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
    }

    @Test func policyRejectsBeforeAnyRequest() throws {
        let (f, _) = try fetcher()
        #expect(throws: ControlError.sourceNotAllowed("host \"other.example\" is not in policy.json sendFile.allowedHosts (imctl policy hosts --allow <host>, or the console's 策略 page)")) {
            try f.fetch(url: URL(string: "https://other.example/a.pdf")!, fileName: nil, policy: policy)
        }
        #expect(StubURLProtocol.requestedURLs.isEmpty)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "http://cdn.example/a.pdf")!, fileName: nil, policy: policy) }
    }

    @Test func redirectOutsideTheAllowlistIsRefusedAndNothingIsKept() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/a.pdf"] = .init(status: 200, headers: [:], body: Data(), redirectTo: URL(string: "https://evil.example/a.pdf"))
        StubURLProtocol.scripts["https://evil.example/a.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/a.pdf")!, fileName: nil, policy: policy) }
        #expect(StubURLProtocol.requestedURLs.map(\.host) == ["cdn.example"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
    }

    @Test func sizeCapByHeaderAndByStream() throws {
        let (f, _) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/big.pdf"] = .init(status: 200, headers: ["Content-Length": "5000"], body: Data(), redirectTo: nil)
        #expect(throws: ControlError.sourceTooLarge("\"big.pdf\" is 5000 bytes; policy.json sendFile.maxBytes is 1000")) {
            try f.fetch(url: URL(string: "https://cdn.example/big.pdf")!, fileName: nil, policy: policy)
        }
        StubURLProtocol.scripts["https://cdn.example/stream.pdf"] = .init(status: 200, headers: [:], body: Self.pdf + Data(repeating: 0x20, count: 1200), redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/stream.pdf")!, fileName: nil, policy: policy) }
    }

    @Test func typeAndNameRules() throws {
        let (f, _) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/x.exe"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/x.exe")!, fileName: nil, policy: policy) }
        StubURLProtocol.scripts["https://cdn.example/fake.png"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/fake.png")!, fileName: nil, policy: policy) }
        StubURLProtocol.scripts["https://cdn.example/dl?id=7"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        let named = try f.fetch(url: URL(string: "https://cdn.example/dl?id=7")!, fileName: "发票.pdf", policy: policy)
        #expect(named.fileName == "发票.pdf" && named.kind == "file" && named.contentType == "application/pdf")
        StubURLProtocol.scripts["https://cdn.example/missing.pdf"] = .init(status: 404, headers: [:], body: Data(), redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/missing.pdf")!, fileName: nil, policy: policy) }
    }

    @Test func ossKeySourceUsesTheStoreAndYieldsTheSamePerDownloadLayout() throws {
        let (f, outbox) = try fetcher()
        final class Store: ObjectStore {
            var summary = "fake"; var baseDir = "imctl"; var maxUploadBytes: Int64 = 10_000; var viewExpireSeconds = 60
            func exists(key: String) throws -> Bool { true }
            func put(fileURL: URL, key: String, contentType: String) throws {}
            func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL { URL(string: "https://b.example/\(key)")! }
            func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 { try FileFetcherTests.pdf.write(to: destination); return Int64(FileFetcherTests.pdf.count) }
            func delete(key: String) throws {}
        }
        let got = try f.fetch(ossKey: "imctl/2026/09/22/a.pdf", fileName: nil, store: Store(), maxBytes: 1000)
        #expect(got.fileName == "a.pdf" && got.kind == "file" && FileManager.default.fileExists(atPath: got.url.path))
        #expect(got.url.lastPathComponent == "a.pdf")
        let parent = got.url.deletingLastPathComponent()
        #expect(parent.deletingLastPathComponent().path == outbox.path)
        #expect(isTwelveHexDirectoryName(parent.lastPathComponent))
        let dirMode = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
    }

    /// `sweep()` (daemon start) removes a per-download directory whose modification date is old, leaves a
    /// fresh one alone, and always removes a stray flat file directly under `outbox` (the pre-fix layout —
    /// never produced by this code any more, so always stale regardless of age).
    @Test func sweepRemovesAnOldDirectoryKeepsAFreshOneAndAnyLegacyFlatFile() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/old/report.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        StubURLProtocol.scripts["https://cdn.example/new/report.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        let old = try f.fetch(url: URL(string: "https://cdn.example/old/report.pdf")!, fileName: nil, policy: policy)
        let fresh = try f.fetch(url: URL(string: "https://cdn.example/new/report.pdf")!, fileName: nil, policy: policy)
        let oldDir = old.url.deletingLastPathComponent()
        let freshDir = fresh.url.deletingLastPathComponent()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: oldDir.path)
        let legacy = outbox.appendingPathComponent("stale-old.pdf")
        try Data("stale".utf8).write(to: legacy)
        f.sweep()
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: fresh.url.path))
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []
        #expect(remaining == [freshDir.lastPathComponent])
    }

    @Test func aStalledSourceTimesOutCancelsTheTaskAndKeepsNothing() throws {
        let (f, outbox) = try fetcher()
        f.timeout = 0.5
        let source = try #require(URL(string: "https://cdn.example/stall.pdf"))
        StubURLProtocol.scripts[source.absoluteString] = .init(status: 200, headers: [:], body: Data(), redirectTo: nil, stall: true)
        let started = Date()
        let deadline = started.addingTimeInterval(16)
        do { _ = try f.fetch(url: source, fileName: nil, policy: policy); Issue.record("expected SOURCE_UNREACHABLE") }
        catch let e as ControlError { #expect(e.code == "SOURCE_UNREACHABLE" && e.message.contains("no answer")) }
        // Worst case on the timeout path: the semaphore wait (timeout + 5 = 5.5 s here) plus the post-cancel
        // completion wait (a flat 5 s) = 10.5 s. Both URLProtocol events share the original 16 s total bound;
        // startLoading records the start during the synchronous fetch, so we never wait before starting it.
        #expect(StubURLProtocol.waitForStart(of: source, until: deadline))
        #expect(StubURLProtocol.waitForCancel(of: source, until: deadline))
        #expect(Date().timeIntervalSince(started) < 16)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
        #expect(StubURLProtocol.cancelledURLs.contains(source))
    }
}
