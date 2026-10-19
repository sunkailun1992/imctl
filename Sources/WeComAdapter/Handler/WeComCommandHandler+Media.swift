import ControlCore
import Foundation
import ImageIO

/// B10/B13 media route: tie a `media` / `file` / `video` row to the client's local cache, upload the file to
/// the configured object store exactly once, and hand back a signed reference — never bytes.
extension WeComCommandHandler {
    /// How far a picture file may be written before / after the row was observed (the client writes the
    /// thumbnail while it renders the bubble; the watcher sees the row within its poll interval).
    static let observedWindowBeforeMs: Int64 = 120_000
    static let observedWindowAfterMs: Int64 = 30_000
    /// A video's own file only appears once it is played, so it may lag its row by a long while.
    static let videoBodyWindowAfterMs: Int64 = 3_600_000
    /// Where a video's body is remembered — next to, and never on top of, the poster's own assignment.
    static let bodyKeySuffix = "#body"

    /// How long the cache work may block — on macOS's "access data from other apps" prompt, or on a cache scan
    /// of its own — before the caller gets an answer (the socket serves connections one at a time, so a blocked
    /// read would stall every client). It covers file access only: the Accessibility read of the visible rows
    /// happens outside it (see `messageMedia`).
    public static var fileGrantTimeout: TimeInterval = 8

    /// Runs `body` on its own thread; a body still blocked after `fileGrantTimeout` (the system prompt is up)
    /// keeps running there and finishes on its own, while the caller gets a retryable MEDIA_NOT_FOUND.
    final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

    static func withFileGrantTimeout<T>(_ what: String, _ body: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Thread { box.result = Result { try body() }; done.signal() }.start()
        guard done.wait(timeout: .now() + fileGrantTimeout) == .success, let result = box.result else {
            throw ControlError.mediaNotFound("\(what) is waiting for macOS's \"access data from other apps\" prompt (allow imctl.app, or add it under 完全磁盘访问权限), or the cache scan took longer than \(String(format: "%g", fileGrantTimeout)) s; retry afterwards")
        }
        return try result.get()
    }

    /// The observation window held nothing, and the visible rows — which the index path deliberately did not
    /// read — could still bracket this row. Thrown by `resolveMedia` only while `rows` is empty, caught by
    /// `messageMedia`, and never seen by a caller: it carries the `MEDIA_NOT_FOUND` that stands when the rows
    /// cannot answer either. A hard refusal (a kind mismatch, a `file` row with no name) is *not* this: it is
    /// thrown as the `ControlError` it is, and no row is read for it.
    struct WindowMiss: Error { let fallback: ControlError }

    /// What the cache resolution decided before anything is uploaded: which local file stands for the row
    /// (plus a video's optional body) and how it is named in the bucket.
    struct MediaPlan {
        var kind: String
        var matchedBy: String
        var file: MediaCacheFile
        var fileName: String
        var contentType: String
        var width: Int?
        var height: Int?
        var duration: String?
        var body: (file: MediaCacheFile, fileName: String, contentType: String)?
        init(kind: String, matchedBy: String, file: MediaCacheFile, fileName: String, contentType: String,
             width: Int? = nil, height: Int? = nil, duration: String? = nil,
             body: (file: MediaCacheFile, fileName: String, contentType: String)? = nil) {
            self.kind = kind; self.matchedBy = matchedBy; self.file = file; self.fileName = fileName; self.contentType = contentType
            self.width = width; self.height = height; self.duration = duration; self.body = body
        }
    }

    /// Read the active title and its rows from the same AX snapshot. Legacy-key recovery must hash the
    /// visible row under this exact conversation; an index entry alone does not prove which chat is open.
    func visibleMediaRows(now: Date) -> (conversation: String, rows: [MessageRow])? {
        guard let r = try? reader(), let title = try? r.activeConversationTitle(), !title.isEmpty,
              let rows = try? r.chatMessages(conversationTitle: title, now: now) else { return nil }
        return (title, rows)
    }

    public func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference {
        try mapErrors {
            guard let store = objectStore else { throw ControlError.ossNotConfigured("message.media needs oss.json on this Mac (imctl oss set, or the console's 设置 page)") }
            // The rows are read here, *outside* the grant box below, and only for a key the index cannot settle
            // on its own (phase 1 is index-only; the `WindowMiss` path below reads them once after the fact).
            // Reading the message table over Accessibility is not a file access — the system's grant prompt can
            // never answer it — and it costs seconds whenever the client is busy: live 2026-09-23 (5.0.11,
            // macOS 27.0) it took ~14 s, so inside the box every `message.media` timed out before resolution
            // had even started, blaming the TCC prompt for the client's latency.
            // `try?` as before: an unreadable client (mid-render, no window) must not turn a resolvable key into
            // CLIENT_UNAVAILABLE; a key with neither rows nor an index entry still gets the explicit
            // MEDIA_NOT_FOUND below.
            let settled = indexSettles(messageKey: messageKey)
            let readNow = Date()
            let visible = settled ? nil : visibleMediaRows(now: readNow)
            let rows = visible?.rows ?? []
            // Only the cache work can block on the system's grant prompt, so only it belongs in the timeout box.
            // The upload runs here, on the calling (serial) thread: a PUT slower than the box would otherwise be
            // abandoned mid-flight behind a misleading MEDIA_NOT_FOUND and started a second time on the retry
            // (review 2026-09-22). This means a slow upload now occupies the serial command executor for up to
            // the transport's resource timeout (300 s, `OSSTransport.resourceTimeout`) rather than the old 8 s
            // file-grant box — every other command queues behind it until the PUT finishes or times out.
            let plan: MediaPlan
            do {
                plan = try Self.withFileGrantTimeout("message.media") {
                    try self.mediaPlan(messageKey: messageKey, hd: hd, store: store, rows: rows,
                                       conversation: visible?.conversation, now: readNow)
                }
            } catch let miss as WindowMiss {
                // Phase 2. Phase 1 needed no row at all and its observation window came up empty — a thumbnail
                // the client wrote late, or a sighting that lags the row. The bracket stage can still place the
                // row between its neighbours' time labels, which is what it did before the index path existed
                // (regression of 29ffefc), so the rows are read exactly once here, outside the box, and the
                // plan is tried again with them. Unreadable client, or the key not on screen: phase 1's error.
                guard settled else { throw miss.fallback }
                guard let retry = visibleMediaRows(now: readNow),
                      retry.rows.contains(where: { $0.messageKey == messageKey }) else { throw miss.fallback }
                plan = try Self.withFileGrantTimeout("message.media") {
                    try self.mediaPlan(messageKey: messageKey, hd: hd, store: store, rows: retry.rows,
                                       conversation: retry.conversation, now: readNow)
                }
            } catch ControlError.mediaNotFound(let reason) where reason.hasPrefix("no cached file named ") {
                // The client may discard duplicate outbound downloads while retaining the row. Only an
                // exact message.observed -> successful sendFile command association can supply its source;
                // never guess from another cache entry with the same displayed name.
                guard let sent = try sentAttachmentSource?(messageKey) else { throw ControlError.mediaNotFound(reason) }
                return try sentSourceMedia(messageKey: messageKey, sent: sent, store: store)
            }
            let up = try upload(file: plan.file, messageKey: messageKey, fileName: plan.fileName, contentType: plan.contentType, store: store)
            var ref = MediaReference(messageKey: messageKey, kind: plan.kind, matchedBy: plan.matchedBy, fileName: plan.fileName, bytes: plan.file.size,
                                     contentType: up.contentType, ossKey: up.key, url: up.url, expiresAtMs: up.expiresAtMs,
                                     width: plan.width, height: plan.height, duration: plan.duration,
                                     body: plan.kind == "video" ? "absent" : nil)
            if let body = plan.body {
                let bodyUp = try upload(file: body.file, messageKey: messageKey, fileName: body.fileName, contentType: body.contentType, store: store)
                ref.body = "uploaded"; ref.bodyOssKey = bodyUp.key; ref.bodyUrl = bodyUp.url
            } else if plan.kind == "video", let lookup = sentAttachmentSource,
                      let sent = try? lookup(messageKey), FileKind.info(forFileName: sent.fileName)?.kind == "video" {
                // An outbound video can lack Caches/Videos until playback. Its observed event identifies
                // the successful send command exactly, so the original source can supply the real body.
                do {
                    let bodyUp = try uploadSentAttachment(messageKey: messageKey, sent: sent, store: store, expectedKind: "video")
                    ref.body = "uploaded"; ref.bodyOssKey = bodyUp.key; ref.bodyUrl = bodyUp.url
                } catch { ref.body = "source-failed" } // preserve the usable poster; the client may cache a body later
            }
            return ref
        }
    }

    /// Restore a controller-sent file after WeCom removed its cache copy. The original command's byte count
    /// and row name must still agree with what is downloaded, so a changed URL cannot silently replace the
    /// historical attachment. Once uploaded, the dedicated object key makes later reads cheap and stable.
    func sentSourceMedia(messageKey: String, sent: SentFileSource, store: ObjectStore) throws -> MediaReference {
        let up = try uploadSentAttachment(messageKey: messageKey, sent: sent, store: store, expectedKind: "file")
        return MediaReference(messageKey: messageKey, kind: "file", matchedBy: "sent-source", fileName: sent.fileName,
                              bytes: sent.bytes, contentType: up.contentType, ossKey: up.key, url: up.url,
                              expiresAtMs: up.expiresAtMs)
    }

    func uploadSentAttachment(messageKey: String, sent: SentFileSource, store: ObjectStore, expectedKind: String)
        throws -> (key: String, url: String, contentType: String, expiresAtMs: Int64) {
        guard sent.bytes <= store.maxUploadBytes,
              FileNames.sanitize(sent.fileName, fallback: "") == sent.fileName,
              FileKind.info(forFileName: sent.fileName)?.kind == expectedKind else {
            throw ControlError.mediaNotFound("the sent file exceeds the media limit or has an invalid name")
        }
        let key = "\(store.baseDir)/sent/\(messageKey)-\(sent.fileName)"
        let contentType = FileKind.info(forFileName: sent.fileName)?.contentType ?? "application/octet-stream"
        if try !store.exists(key: key) {
            let fetched: FetchedFile
            switch sent.source {
            case .url(let url):
                fetched = try fileFetcher.fetch(url: url, fileName: sent.fileName, policy: currentPolicy.sendPolicy.sendFile)
            case .ossKey(let sourceKey):
                fetched = try fileFetcher.fetch(ossKey: sourceKey, fileName: sent.fileName, store: store,
                                               maxBytes: min(store.maxUploadBytes, currentPolicy.sendPolicy.sendFile.maxBytes))
            }
            defer { fileFetcher.discard(fetched) }
            guard fetched.fileName == sent.fileName, fetched.kind == expectedKind, fetched.bytes == sent.bytes else {
                throw ControlError.mediaNotFound("the original sent file changed since it was sent; refusing to substitute it")
            }
            try store.put(fileURL: fetched.url, key: key, contentType: fetched.contentType)
        }
        let url = try store.signedGetURL(key: key, expiresIn: TimeInterval(store.viewExpireSeconds))
        return (key, url.absoluteString, contentType, Clock.nowMs() + Int64(store.viewExpireSeconds) * 1000)
    }

    /// Whether the index alone settles this key, so `message.media` can skip the Accessibility read of the
    /// visible rows for now (live 2026-09-23: that read took ~14 s on a busy 5.0.11 client) — "for now",
    /// because a settled key whose observation window comes up empty still falls back to one row read.
    /// What it needs is the kind — plus, for a `file` row, the name it showed: an observation carries both
    /// since 2026-09-23, and a key already tied to a cache file carries its kind in the cache it sits in.
    func indexSettles(messageKey: String) -> Bool {
        guard let observed = mediaIndex.observation(for: messageKey) else { return assignedKind(messageKey: messageKey) != nil }
        switch MessageRowKind(rawValue: observed.kind) {
        case .media?, .video?: return true
        case .file?: return !(observed.fileName ?? "").isEmpty || assignedKind(messageKey: messageKey) == .file
        default: return false
        }
    }

    /// What an earlier assignment stands for, read off the cache directory it points at — the kind of a key
    /// that was resolved once already and now needs neither a row nor an observation to be served again.
    func assignedKind(messageKey: String) -> MessageRowKind? {
        guard let path = mediaIndex.assignment(for: messageKey)?.file.path else { return nil }
        if path.contains("Caches/Files/") { return .file }
        if path.contains("Caches/Video_Thumbnail/") { return .video }
        return WeComMediaStore.pictureKinds.contains(where: { path.contains("Caches/\($0)/") }) ? .media : nil
    }

    /// Decides which cache file a row stands for, without touching the object store and without reading the
    /// client: `rows` is whatever the caller already read (empty when the index settled the key by itself).
    /// The row's kind is settled **first** — from what the watcher recorded, else from the visible row, else
    /// from an earlier assignment's cache — because it decides which cache is searched at all: a `video`,
    /// `file` or text key that fell through to the picture rules would consume (and permanently assign) the
    /// picture belonging to a `media` row (review 2026-09-22). The observation wins over the visible row: it is
    /// what the row was when it arrived, and it is all a key resolved without a row has; a visible row that
    /// disagrees means the key does not stand for what the caller thinks it does, so both kinds are named and
    /// nothing is handed over (2026-09-23).
    func mediaPlan(messageKey: String, hd: Bool, store: ObjectStore, rows: [MessageRow],
                   conversation: String?, now: Date) throws -> MediaPlan {
        let row = rows.first { $0.messageKey == messageKey }
        let observed = mediaIndex.observation(for: messageKey)
        guard let kind = observed?.kind ?? row?.kind.rawValue ?? assignedKind(messageKey: messageKey)?.rawValue else {
            throw ControlError.mediaNotFound("no observation for \(messageKey) and it is not in the open conversation; open that conversation (conversation.read) and ask again")
        }
        if let observed, let row, observed.kind != row.kind.rawValue {
            throw Self.kindMismatch(messageKey, seen: observed.kind, wanted: row.kind)
        }
        switch MessageRowKind(rawValue: kind) {
        case .file?:
            // A file is matched by the name and size its row showed — from the row itself, or from what the
            // watcher wrote down when it first saw it. With neither (an index from before 2026-09-23, and the
            // conversation not open) there is nothing to match, and no candidate may be touched.
            let name = row?.fileName ?? observed?.fileName ?? ""
            guard !name.isEmpty || mediaIndex.assignment(for: messageKey) != nil else {
                throw ControlError.mediaNotFound("\(messageKey) is a file row and is not in the open conversation; open the conversation (conversation.read) and ask again — a file is matched by the name and size its row shows")
            }
            let (file, matchedBy) = try resolveFile(messageKey: messageKey, name: name, sizeLabel: row?.fileSize ?? observed?.fileSize)
            // A key served from its assignment alone knows no name; the cache file kept the client's own.
            let served = name.isEmpty ? FileNames.sanitize((file.path as NSString).lastPathComponent, fallback: "file") : name
            try Self.checkSize(file, fileName: served, store: store)
            return MediaPlan(kind: "file", matchedBy: matchedBy, file: file, fileName: served,
                             contentType: WeComMediaStore.contentType(for: file, fileName: served))
        case .video?:
            let (poster, matchedBy) = try resolveMedia(messageKey: messageKey, kinds: ["Video_Thumbnail"], rowKind: .video, rows: rows)
            let posterName = "\(messageKey)-poster.\(Self.pictureExtension(poster.signature))"
            try Self.checkSize(poster, fileName: posterName, store: store)
            return MediaPlan(kind: "video", matchedBy: matchedBy, file: poster, fileName: posterName,
                             contentType: WeComMediaStore.contentType(for: poster, fileName: posterName),
                             duration: row?.duration ?? observed?.duration,
                             body: videoBody(messageKey: messageKey, observed: observed, poster: poster, store: store))
        case .media?:
            let (file, matchedBy) = try resolveMedia(messageKey: messageKey, kinds: WeComMediaStore.pictureKinds,
                                                      rowKind: .media, rows: rows, conversation: conversation, now: now)
            let chosen = hd ? (mediaStore.hdSibling(of: file) ?? file) : file
            let url = mediaStore.url(of: chosen)
            guard FileManager.default.fileExists(atPath: url.path) else {
                mediaIndex.forget(messageKey: messageKey)
                throw ControlError.mediaNotFound("cache file for \(messageKey) is gone (\(chosen.path)); the client may have cleared it")
            }
            let name = FileNames.sanitize(url.lastPathComponent, fallback: "picture")
            let displayName = try Self.pictureDisplayName(cacheName: name, signature: chosen.signature)
            try Self.checkSize(chosen, fileName: displayName, store: store)
            let dims = Self.pixelSize(of: url)
            return MediaPlan(kind: "image", matchedBy: matchedBy, file: chosen, fileName: displayName,
                             contentType: WeComMediaStore.contentType(for: chosen, fileName: displayName), width: dims?.width, height: dims?.height)
        default:
            throw ControlError.mediaNotFound("\(messageKey) is a \(kind) row; message.media serves picture, file and video rows")
        }
    }

    /// The cache files are named after what they actually are, not after what the client called them.
    static func pictureExtension(_ signature: String?) -> String {
        // Every signature `WeComMediaStore.contentType(for:)` distinguishes, so the served file name's
        // extension and its content type never disagree (review 2026-09-23: a heic picture was named
        // `.jpg` while its content type said `image/heic`).
        ["png": "png", "jpeg": "jpg", "gif": "gif", "webp": "webp", "heic": "heic", "mp4": "mp4"][signature ?? ""] ?? "jpg"
    }

    /// Cache names are not trustworthy type labels: WeCom has stored JPEG bytes under a `.png` name.
    /// The signed object's extension must describe the verified file head or the console will reject it.
    static func pictureDisplayName(cacheName: String, signature: String?) throws -> String {
        guard let signature, ["png", "jpeg", "gif", "webp", "heic"].contains(signature) else {
            throw ControlError.mediaNotFound("picture cache has no supported image signature")
        }
        let expected = pictureExtension(signature)
        let ext = (cacheName as NSString).pathExtension.lowercased()
        if ext == expected || (signature == "jpeg" && ext == "jpeg") { return cacheName }
        let stem = FileKind.info(forFileName: cacheName, allowHEICPreview: true) == nil
            ? cacheName : (cacheName as NSString).deletingPathExtension
        return FileNames.sanitize("\(stem).\(expected)", fallback: "picture.\(expected)")
    }

    static func checkSize(_ file: MediaCacheFile, fileName: String, store: ObjectStore) throws {
        guard file.size <= store.maxUploadBytes else { throw ControlError.mediaTooLarge("\(fileName) is \(file.size) bytes; oss.json maxUploadBytes is \(store.maxUploadBytes)") }
    }

    /// Object key `<baseDir>/<yyyy>/<MM>/<dd>/<messageKey>-<name>`; a HEAD hit skips the PUT, the URL is signed every time.
    func upload(file: MediaCacheFile, messageKey: String, fileName: String, contentType: String, store: ObjectStore) throws -> (key: String, url: String, expiresAtMs: Int64, contentType: String) {
        let day = Date(timeIntervalSince1970: Double(file.modifiedMs) / 1000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let key = "\(store.baseDir)/\(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))/\(messageKey)-\(FileNames.sanitize(fileName, fallback: "file"))"
        if try !store.exists(key: key) { try store.put(fileURL: mediaStore.url(of: file), key: key, contentType: contentType) }
        let url = try store.signedGetURL(key: key, expiresIn: TimeInterval(store.viewExpireSeconds))
        return (key, url.absoluteString, Clock.nowMs() + Int64(store.viewExpireSeconds) * 1000, contentType)
    }

    /// The video's own file, best effort: the client writes it under `Caches/Videos` only after the video was
    /// played (unverified 2026-09-22 observation from the cache layout; live confirmation pending). Among the
    /// bodies in the row's window that no other row already holds, the one nearest the sighting wins, and it is
    /// remembered under `<messageKey>#body`, so two videos in the same hour cannot be handed the same file.
    /// An unrecognised head (neither mp4 nor mov) means no body rather than a guessed content type.
    func videoBody(messageKey: String, observed: MediaIndex.Observation?, poster: MediaCacheFile, store: ObjectStore) -> (file: MediaCacheFile, fileName: String, contentType: String)? {
        let bodyKey = messageKey + Self.bodyKeySuffix
        let anchorMs = observed?.observedMs ?? poster.modifiedMs
        let chosen: MediaCacheFile
        if let assigned = mediaIndex.assignment(for: bodyKey) {
            chosen = assigned.file
        } else {
            let taken = mediaIndex.assignedPaths
            guard let best = mediaStore.videoBodyCandidates(sinceMs: anchorMs - Self.observedWindowBeforeMs, untilMs: anchorMs + Self.videoBodyWindowAfterMs)
                .filter({ !taken.contains($0.root + ":" + $0.path) })
                .min(by: { abs($0.modifiedMs - anchorMs) < abs($1.modifiedMs - anchorMs) }) else { return nil }
            chosen = best
        }
        guard chosen.size <= store.maxUploadBytes, let type = Self.videoType(of: mediaStore.url(of: chosen)) else { return nil }
        mediaIndex.assign(messageKey: bodyKey, file: chosen, matchedBy: "observed", nowMs: Clock.nowMs())
        return (chosen, "\(messageKey)-video.\(type.ext)", type.contentType)
    }

    /// mp4 vs mov from the file's own first bytes, so a QuickTime body is not served as `video/mp4`.
    static func videoType(of url: URL) -> (contentType: String, ext: String)? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        switch FileKind.signature(of: [UInt8]((try? handle.read(upToCount: 16)) ?? Data())) {
        case "mp4"?: return ("video/mp4", "mp4")
        case "mov"?: return ("video/quicktime", "mov")
        default: return nil
        }
    }

    /// File rows: an earlier assignment, else the cached file with that name (and size label), the newest one on ties.
    func resolveFile(messageKey: String, name: String, sizeLabel: String?) throws -> (MediaCacheFile, String) {
        if let a = reusableAssignment(messageKey: messageKey, rowKind: .file, directories: ["Files"]) { return (a.file, a.matchedBy) }
        guard !name.isEmpty else { throw ControlError.mediaNotFound("row \(messageKey) shows no file name") }
        let taken = mediaIndex.assignedPaths
        let candidates = mediaStore.fileCandidates(name: name, sizeLabel: sizeLabel).filter { !taken.contains($0.root + ":" + $0.path) }
        let chosen: MediaCacheFile?
        if let o = mediaIndex.observation(for: messageKey) { chosen = candidates.min { abs($0.modifiedMs - o.observedMs) < abs($1.modifiedMs - o.observedMs) } } else { chosen = candidates.first }
        guard let chosen else { throw ControlError.mediaNotFound("no cached file named \"\(name)\"\(sizeLabel.map { " (\($0))" } ?? "") under Caches/Files; open the file in the client once, then ask again") }
        mediaIndex.assign(messageKey: messageKey, file: chosen, matchedBy: "name", nowMs: Clock.nowMs())
        return (chosen, "name")
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// A stored assignment is only reused while it still fits the row: the recorded kind must agree and the file
    /// must sit in one of the caches this kind is served from. Anything else was written by a build that let one
    /// row consume another's file (review 2026-09-22) — drop it instead of serving it.
    func reusableAssignment(messageKey: String, rowKind: MessageRowKind, directories: [String]) -> MediaIndex.Assignment? {
        guard let assigned = mediaIndex.assignment(for: messageKey) else { return nil }
        let kindAgrees = mediaIndex.observation(for: messageKey).map { $0.kind == rowKind.rawValue } ?? true
        if kindAgrees, directories.contains(where: { assigned.file.path.contains("Caches/\($0)/") }) { return assigned }
        mediaIndex.forget(messageKey: messageKey)
        return nil
    }

    /// The key was seen as one kind of row and is being resolved as another: refuse rather than hand this row a
    /// file that belongs to a different one.
    static func kindMismatch(_ messageKey: String, seen: String, wanted: MessageRowKind) -> ControlError {
        .mediaNotFound("\(messageKey) was seen as a \(seen) row, not a \(wanted.rawValue) row; message.media will not give it another row's file")
    }

    /// 1. an earlier assignment; 2. a file that appeared around the row's observation; 3. the current history:
    /// the row bracketed by its neighbours' time labels, files in that bracket handed out in order. `kinds`
    /// narrows the cache directories searched — pictures use `WeComMediaStore.pictureKinds` (`Images` /
    /// `Emotions` / `Link_Thumbnail`; never `Video_Thumbnail`, so a picture row can never take — and
    /// permanently assign — a video's poster, review 2026-09-23), a video poster only `Video_Thumbnail` — and
    /// `rowKind` is the kind the caller established for this key: every stage refuses a row of any other kind,
    /// so the picture in a video's (or a text row's) time window stays where it belongs. `rows` is what the
    /// caller already read (empty when the index settled the key without asking the client): this stage never
    /// reads the client itself, so nothing inside the file-grant box can block on Accessibility (2026-09-23).
    /// With no rows and nothing in the window it throws `WindowMiss` instead of refusing, which is the caller's
    /// cue to read the rows once and run stage 3 with them.
    func resolveMedia(messageKey: String, kinds: [String] = WeComMediaStore.pictureKinds, rowKind: MessageRowKind,
                      rows: [MessageRow], conversation: String? = nil, now: Date = Date()) throws -> (MediaCacheFile, String) {
        if let a = reusableAssignment(messageKey: messageKey, rowKind: rowKind, directories: kinds) { return (a.file, a.matchedBy) }
        let taken = mediaIndex.assignedPaths
        if let o = mediaIndex.observation(for: messageKey) {
            guard o.kind == rowKind.rawValue else { throw Self.kindMismatch(messageKey, seen: o.kind, wanted: rowKind) }
            let files = mediaStore.candidates(sinceMs: o.observedMs - Self.observedWindowBeforeMs, untilMs: o.observedMs + Self.observedWindowAfterMs, kinds: kinds)
                .filter { !taken.contains($0.root + ":" + $0.path) }
            if let best = files.min(by: { abs($0.modifiedMs - o.observedMs) < abs($1.modifiedMs - o.observedMs) }) {
                mediaIndex.assign(messageKey: messageKey, file: best, matchedBy: "observed", nowMs: Clock.nowMs())
                return (best, "observed")
            }
        }
        // history bracket: only for rows of the conversation currently open
        guard let index = rows.firstIndex(where: { $0.messageKey == messageKey }) else {
            let missed = ControlError.mediaNotFound("nothing matched the observation window for \(messageKey) and it is not in the open conversation; open that conversation (conversation.read) and ask again")
            // No rows at all means the caller never read them (the index settled the kind by itself), not that
            // the conversation is closed: ask it to read them once and come back, rather than refusing a row
            // the bracket below would have matched (regression of 29ffefc).
            if rows.isEmpty { throw WindowMiss(fallback: missed) }
            throw missed
        }
        guard rows[index].kind == rowKind else { throw Self.kindMismatch(messageKey, seen: rows[index].kind.rawValue, wanted: rowKind) }
        func label(_ i: Int) -> Int64? { rows[i].timeLabel.flatMap { MessageTimeLabel.parse($0, now: now) }.map { Int64($0.timeIntervalSince1970 * 1000) } }
        var lower: Int64?
        var lowerIndex = 0
        for i in stride(from: index, through: 0, by: -1) { if let l = label(i) { lower = l; lowerIndex = i; break } }
        var upper: Int64?
        var upperIndex = rows.count
        for i in (index + 1)..<max(index + 1, rows.count) { if let u = label(i) { upper = u; upperIndex = i; break } }
        guard let lower else {
            throw ControlError.mediaNotFound("no time label above \(messageKey) in the open conversation; scroll back (message.history{scrollback}) so the client shows one")
        }
        let until = (upper ?? lower + 6 * 3_600_000) + 60_000
        let sameKindRows = rows[lowerIndex..<upperIndex].filter { $0.kind == rowKind }
        guard let position = sameKindRows.firstIndex(where: { $0.messageKey == messageKey }) else { throw ControlError.mediaNotFound("row \(messageKey) is not a \(rowKind.rawValue) row") }   // unreachable: the kind was checked above
        let allFiles = Array(mediaStore.candidates(sinceMs: lower - 60_000, untilMs: until, kinds: kinds).reversed())
        // A matching legacy key takes precedence over ordinary bracket assignment. If its old file
        // cannot be verified, choosing a different unassigned file from this bracket would silently
        // attach the wrong image to the row.
        if rowKind == .media, let conversation,
           let moved = try recoverLegacyPictureAssignment(messageKey: messageKey, rows: rows, rowIndex: index,
                                                           conversation: conversation, now: now,
                                                           bracketRows: sameKindRows, bracketFiles: allFiles) {
            return (moved.file, moved.matchedBy)
        }
        let files = allFiles.filter { !taken.contains($0.root + ":" + $0.path) }   // oldest first, like the rows
        guard position < files.count else {
            throw ControlError.mediaNotFound("no cache file between the neighbouring time labels for \(messageKey) (\(files.count) file(s) for \(sameKindRows.count) \(rowKind.rawValue) row(s))")
        }
        let chosen = files[position]
        mediaIndex.assign(messageKey: messageKey, file: chosen, matchedBy: "window", nowMs: Clock.nowMs())
        return (chosen, "window")
    }

    /// Recover an assignment written before time labels were normalised for keys. The old key used either
    /// the row's current raw label or the bare clock it showed yesterday. Exactly one old key must be
    /// assigned to the sole picture in this row's bracket; another candidate, day or kind refuses recovery.
    func recoverLegacyPictureAssignment(messageKey: String, rows: [MessageRow], rowIndex: Int,
                                        conversation: String, now: Date, bracketRows: [MessageRow],
                                        bracketFiles: [MediaCacheFile]) throws -> MediaIndex.Assignment? {
        guard rows.indices.contains(rowIndex), rows[rowIndex].kind == .media,
              let label = rows[rowIndex].timeLabel,
              let targetDate = MessageTimeLabel.parse(label, now: now) else { return nil }

        // The old implementation hashed the AX label verbatim. On the previous day this same row may
        // have shown just `16:36`, so consider that spelling too. Never pick one when both have bindings.
        let rawKeys = MessageKey.assign(rows, conversation: conversation, sender: \.senderLabel,
                                        timeLabel: \.timeLabel, text: { $0.text ?? $0.fileName ?? "" })
        var aliases: [(key: String, label: String)] = [(rawKeys[rowIndex], label)]
        if let bare = MessageTimeLabel.legacyBareClock(label) {
            let bareKeys = MessageKey.assign(rows, conversation: conversation, sender: \.senderLabel,
                                             timeLabel: { MessageTimeLabel.legacyBareClock($0.timeLabel) ?? $0.timeLabel },
                                             text: { $0.text ?? $0.fileName ?? "" })
            if bareKeys[rowIndex] != rawKeys[rowIndex] { aliases.append((bareKeys[rowIndex], bare)) }
        }
        let bound = aliases.filter { $0.key != messageKey && mediaIndex.assignment(for: $0.key) != nil }
        guard !bound.isEmpty else { return nil }
        guard bound.count == 1, let alias = bound.first,
              let old = mediaIndex.assignment(for: alias.key) else {
            throw ControlError.mediaNotFound("legacy picture assignment is ambiguous for \(messageKey); refusing to substitute another cached image")
        }
        let matchingRows = rows.filter {
            $0.timeLabel == alias.label &&
            $0.senderLabel == rows[rowIndex].senderLabel &&
            ($0.text ?? $0.fileName ?? "") == (rows[rowIndex].text ?? rows[rowIndex].fileName ?? "")
        }
        let legacyMatchingRows = rows.filter {
            MessageTimeLabel.legacyBareClock($0.timeLabel) == alias.label &&
            $0.senderLabel == rows[rowIndex].senderLabel &&
            ($0.text ?? $0.fileName ?? "") == (rows[rowIndex].text ?? rows[rowIndex].fileName ?? "")
        }
        let sameTupleCount = alias.label == label ? matchingRows.count : legacyMatchingRows.count
        let oldObservation = mediaIndex.observation(for: alias.key)
        let observationAgrees = oldObservation.map {
            $0.kind == MessageRowKind.media.rawValue && $0.conversation == conversation &&
            Calendar.current.isDate(Date(timeIntervalSince1970: Double($0.observedMs) / 1000), inSameDayAs: targetDate)
        } ?? true
        guard rows.filter({ $0.messageKey == messageKey }).count == 1,
              sameTupleCount == 1, bracketRows.count == 1, bracketFiles.count == 1,
              !rows.enumerated().contains(where: { $0.offset != rowIndex && $0.element.messageKey == alias.key }),
              MessageKey.make(conversation: conversation, sender: rows[rowIndex].senderLabel,
                              timeLabel: alias.label, text: rows[rowIndex].text ?? rows[rowIndex].fileName ?? "",
                              ordinal: 0) == alias.key,
              observationAgrees,
              mediaIndex.observation(for: messageKey) == nil,
              mediaIndex.assignment(for: messageKey) == nil,
              old.file == bracketFiles[0],
              old.file.root == WeComMediaStore.rootLabel, old.file.kind == "image",
              WeComMediaStore.pictureKinds.contains(where: { old.file.path.contains("Caches/\($0)/") }),
              let actual = WeComMediaCacheScanner.signature(of: mediaStore.url(of: old.file)),
              actual.kind == "image", actual.name == old.file.signature,
              Calendar.current.isDate(Date(timeIntervalSince1970: Double(old.file.modifiedMs) / 1000), inSameDayAs: targetDate)
        else { throw ControlError.mediaNotFound("legacy picture assignment is ambiguous for \(messageKey); refusing to substitute another cached image") }
        guard let moved = mediaIndex.rebindLegacyAssignment(from: alias.key, to: messageKey, file: old.file, nowMs: Clock.nowMs()) else {
            throw ControlError.mediaNotFound("legacy picture assignment changed for \(messageKey); retry after the cache is stable")
        }
        return moved
    }
}
