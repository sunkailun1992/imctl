import Foundation

/// A file fetched for `message.sendFile`, sitting in the outbox until the attempt is over.
public struct FetchedFile: Equatable {
    public var url: URL
    public var fileName: String
    public var bytes: Int64
    /// image | video | file
    public var kind: String
    public var contentType: String
    public init(url: URL, fileName: String, bytes: Int64, kind: String, contentType: String) {
        self.url = url; self.fileName = fileName; self.bytes = bytes; self.kind = kind; self.contentType = contentType
    }
}

/// B13: streams an https source (or an OSS object) into the outbox under the policy's host allowlist and byte
/// cap, checking the redirect chain hop by hop and the file head against the extension. Synchronous on purpose
/// (the executor is a serial queue); the session is injectable so tests script responses with a `URLProtocol`.
public final class FileFetcher: NSObject, URLSessionDataDelegate {
    public let outbox: URL
    public var timeout: TimeInterval = 120
    public var sessionConfiguration: URLSessionConfiguration = .ephemeral
    /// Live defect (observed 2026-09-23, WeCom 5.0.11, imctl 1.0.2): every download used to land as
    /// `<outbox>/<id>-<name>`, so the id prefix rode along onto the pasteboard and out to the client — the
    /// recipient saw the prefixed name, and matching a received row's `fileName` back to the send (see
    /// `OriginClassifier`) or to its OSS key (`message.media`) silently failed. Anything left directly under
    /// `outbox` older than this is safe for `sweep()` to remove: the executor is a serial queue, so a real
    /// attempt finishes (or times out) in minutes, never sits for an hour; a directory fresher than this is
    /// left alone in case `sweep()` is ever called while something is still in flight.
    private static let staleAfter: TimeInterval = 3600

    public init(outbox: URL) { self.outbox = outbox }

    // MARK: Sources

    public func fetch(url: URL, fileName: String?, policy: SendFilePolicy, allowHEICPreview: Bool = false) throws -> FetchedFile {
        if let why = policy.rejection(for: url) { throw ControlError.sourceNotAllowed(why) }
        let name = FileNames.sanitize(fileName ?? "", fallback: FileNames.name(from: url))
        guard let info = FileKind.info(forFileName: name, allowHEICPreview: allowHEICPreview) else {
            throw ControlError.sourceUnsupported(FileKind.rejection(fileName: name, head: [], allowHEICPreview: allowHEICPreview) ?? name)
        }
        let destination = try prepareDestination(for: url.absoluteString, name: name)
        let job = Job(destination: destination, name: name, maxBytes: policy.maxBytes, policy: policy)
        let session = URLSession(configuration: sessionConfiguration, delegate: job, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        // Padded well past the semaphore wait's own `timeout + 5` bound below: our explicit wait-and-cancel
        // path is the one true bound (and the one that produces the "no answer" message), not this per-request
        // idle timer, which URLSession honours even for a URLProtocol-stubbed session and would otherwise race
        // (and normally win) ahead of it, completing the task out from under us before we ever decide to give up.
        request.timeoutInterval = timeout + 10
        let task = session.dataTask(with: request)
        job.task = task
        task.resume()
        guard job.done.wait(timeout: .now() + timeout + 5) == .success else {
            job.cancelAndDiscard()
            // Bounded wait for the delegate's own completion so `didCompleteWithError` (and, for a stubbed
            // session, the URLProtocol's `stopLoading()`) has run before we return — otherwise a caller (or a
            // test's assertion right after `fetch` throws) can race that still-in-flight callback. Padded to
            // the same ~5 s the rest of this method gives async completions (see the waits above): under heavy
            // concurrent-build CPU contention a 2 s bound was observed to occasionally elapse before the
            // session's delegate queue got scheduled at all, reproducing the very race this wait exists to close.
            _ = job.done.wait(timeout: .now() + 5)
            throw ControlError.sourceUnreachable("\"\(name)\": no answer within \(Int(timeout)) s")
        }
        if let error = job.failure { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw error }
        return try finish(destination: destination, name: name, info: info, allowHEICPreview: allowHEICPreview)
    }

    public func fetch(ossKey: String, fileName: String?, store: ObjectStore, maxBytes: Int64) throws -> FetchedFile {
        let name = FileNames.sanitize(fileName ?? "", fallback: FileNames.sanitize((ossKey as NSString).lastPathComponent, fallback: "file"))
        guard let info = FileKind.info(forFileName: name) else { throw ControlError.sourceUnsupported(FileKind.rejection(fileName: name, head: []) ?? name) }
        let destination = try prepareDestination(for: "oss:" + ossKey, name: name)
        do { _ = try store.download(key: ossKey, to: destination, maxBytes: maxBytes) }
        catch let e as ControlError { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw e }
        catch { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw ControlError.sourceUnreachable("ossKey \(ossKey): \(error.localizedDescription)") }
        return try finish(destination: destination, name: name, info: info)
    }

    /// Removes the whole per-download directory, not just the file, so nothing named after this attempt is
    /// left for `sweep()` to age out later.
    public func discard(_ file: FetchedFile) { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }

    /// Daemon start: removes every per-download directory directly under `outbox` older than `staleAfter`
    /// (nothing legitimate survives a restart that long), plus any flat file sitting directly under `outbox`
    /// — that shape can only be a leftover from the flat `<id>-<name>` layout this fix replaces, so it is
    /// always stale and removed regardless of age.
    public func sweep() {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let cutoff = Date().addingTimeInterval(-Self.staleAfter)
        for item in (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: Array(keys))) ?? [] {
            let values = try? item.resourceValues(forKeys: keys)
            if values?.isDirectory == true, let modified = values?.contentModificationDate, modified >= cutoff { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: Helpers

    /// `<outbox>/<12-hex id>/<name>`: the id (a hash of the source, truncated exactly as before) now names the
    /// directory instead of prefixing the file, so the file on disk — the URL `WeComActions.sendFile` puts on
    /// the pasteboard — is exactly `name`, matching what `SendFileResult.fileName` reports and what
    /// `OriginClassifier` / `message.media` key off of. The id still keeps two sources that sanitise to the
    /// same name from colliding in the same directory.
    private func prepareDestination(for source: String, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outbox.path)
        let stamp = String(MessageKey.make(conversation: "outbox", sender: nil, timeLabel: nil, text: source, ordinal: 0).prefix(12))
        let downloadDir = outbox.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: downloadDir.path)
        let destination = downloadDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return destination
    }

    private func finish(destination: URL, name: String, info: FileKind.Info, allowHEICPreview: Bool = false) throws -> FetchedFile {
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let head = [UInt8]((try? FileHandle(forReadingAtPath: destination.path)?.read(upToCount: 16)) ?? Data())
        if let why = FileKind.rejection(fileName: name, head: head, allowHEICPreview: allowHEICPreview) {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()); throw ControlError.sourceUnsupported(why)
        }
        return FetchedFile(url: destination, fileName: name, bytes: size, kind: info.kind, contentType: info.contentType)
    }

    /// One download's delegate: enforces the allowlist on every redirect, the byte cap on the header and on the stream.
    final class Job: NSObject, URLSessionDataDelegate {
        let destination: URL; let name: String; let maxBytes: Int64; let policy: SendFilePolicy
        let done = DispatchSemaphore(value: 0)
        var failure: ControlError?
        var task: URLSessionTask?
        private let lock = NSLock()
        private var closed = false
        private var handle: FileHandle?
        private var received: Int64 = 0

        init(destination: URL, name: String, maxBytes: Int64, policy: SendFilePolicy) {
            self.destination = destination; self.name = name; self.maxBytes = maxBytes; self.policy = policy
            handle = FileHandle(forWritingAtPath: destination.path)
        }

        /// Called from the calling thread when `fetch(url:)` gives up on `done.wait`. Cancels the still-possibly-live
        /// task first (so `finishTasksAndInvalidate()` doesn't block waiting for it, and so `didComplete` follows
        /// promptly), then closes the handle under the lock and marks it `closed` so a late, already-in-flight
        /// `didReceive data:` on the delegate queue finds the flag and skips its write instead of racing the close.
        func cancelAndDiscard() {
            task?.cancel()
            lock.lock(); closed = true; try? handle?.close(); handle = nil; lock.unlock()
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = request.url, let why = policy.rejection(for: url) {
                failure = .sourceNotAllowed("redirect refused: " + why); completionHandler(nil); task.cancel(); return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
            guard (200..<300).contains(http.statusCode) else {
                failure = .sourceUnreachable("\"\(name)\": HTTP \(http.statusCode)"); completionHandler(.cancel); return
            }
            if http.expectedContentLength > maxBytes {
                failure = .sourceTooLarge("\"\(name)\" is \(http.expectedContentLength) bytes; policy.json sendFile.maxBytes is \(maxBytes)"); completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            received += Int64(data.count)
            if received > maxBytes {
                failure = .sourceTooLarge("\"\(name)\" exceeded policy.json sendFile.maxBytes (\(maxBytes)) while streaming"); dataTask.cancel(); return
            }
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            handle?.write(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock(); try? handle?.close(); handle = nil; closed = true; lock.unlock()
            if failure == nil, let error, (error as NSError).code != NSURLErrorCancelled {
                failure = .sourceUnreachable("\"\(name)\": \(error.localizedDescription)")
            }
            done.signal()
        }
    }
}
