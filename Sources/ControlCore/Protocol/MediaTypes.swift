import Foundation

/// One media file found in the client's local cache (B10 step 1). `path` is
/// relative to its root; contents are never read beyond the file signature.
public struct MediaCacheFile: Codable, Equatable {
    public var root: String
    public var path: String
    public var size: Int64
    public var modifiedMs: Int64
    /// image | video | audio
    public var kind: String
    /// Extension-less or misnamed files whose signature said what they are carry the signature name (jpeg, png, …).
    public var signature: String?
    public init(root: String, path: String, size: Int64, modifiedMs: Int64, kind: String, signature: String? = nil) {
        self.root = root; self.path = path; self.size = size; self.modifiedMs = modifiedMs; self.kind = kind; self.signature = signature
    }
}

/// Where the images cluster: a directory (relative to its root) with its image count and newest file.
public struct MediaCacheDirectory: Codable, Equatable {
    public var root: String
    public var path: String
    public var images: Int
    public var newestMs: Int64
    public init(root: String, path: String, images: Int, newestMs: Int64) { self.root = root; self.path = path; self.images = images; self.newestMs = newestMs }
}

/// One directory entry of a `controller.mediaCache{dir}` listing: names, sizes, dates and the first bytes (hex) — never contents.
public struct MediaCacheEntry: Codable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modifiedMs: Int64
    public var head: String?
    public var signature: String?
    public init(name: String, isDirectory: Bool, size: Int64, modifiedMs: Int64, head: String? = nil, signature: String? = nil) {
        self.name = name; self.isDirectory = isDirectory; self.size = size; self.modifiedMs = modifiedMs; self.head = head; self.signature = signature
    }
}

/// `controller.mediaCache` result. `pending` while the scan (or the system's
/// "access data from other apps" prompt) is still running; the daemon never
/// blocks its command queue on it.
public struct MediaCacheReport: Codable, Equatable {
    public var status: String
    public var roots: [String]
    public var elapsedMs: Int
    public var scanned: Int
    public var files: [MediaCacheFile]
    public var directories: [MediaCacheDirectory]
    public var notes: [String]
    /// Only for `{dir}` listings.
    public var entries: [MediaCacheEntry]?
    public init(status: String, roots: [String], elapsedMs: Int = 0, scanned: Int = 0, files: [MediaCacheFile] = [],
                directories: [MediaCacheDirectory] = [], notes: [String] = [], entries: [MediaCacheEntry]? = nil) {
        self.status = status; self.roots = roots; self.elapsedMs = elapsedMs; self.scanned = scanned
        self.files = files; self.directories = directories; self.notes = notes; self.entries = entries
    }

    /// The newest `limit` files, everything else unchanged.
    public func trimmed(to limit: Int) -> MediaCacheReport {
        var copy = self
        copy.files = Array(files.sorted { $0.modifiedMs > $1.modifiedMs }.prefix(max(limit, 1)))
        return copy
    }
}

/// B13 `message.media` result: the file behind a picture / file / video row, uploaded to the configured object
/// store; callers get a signed GET URL, never bytes (all transports alike).
public struct MediaReference: Codable, Equatable {
    public var messageKey: String
    /// image | file | video
    public var kind: String
    /// observed | window | name — how the cache file was tied to the row. A remembered assignment is served
    /// under the value it was first matched by, so `assigned` never appears here (it is only `message.history`'s
    /// per-row `media` state).
    public var matchedBy: String
    public var fileName: String
    public var bytes: Int64
    public var contentType: String
    public var ossKey: String
    public var url: String
    public var expiresAtMs: Int64
    public var width: Int?
    public var height: Int?
    public var duration: String?
    /// video only: `uploaded` when the client had the body cached (played), else `absent`.
    public var body: String?
    public var bodyOssKey: String?
    public var bodyUrl: String?
    public init(messageKey: String, kind: String, matchedBy: String, fileName: String, bytes: Int64, contentType: String, ossKey: String, url: String, expiresAtMs: Int64,
                width: Int? = nil, height: Int? = nil, duration: String? = nil, body: String? = nil, bodyOssKey: String? = nil, bodyUrl: String? = nil) {
        self.messageKey = messageKey; self.kind = kind; self.matchedBy = matchedBy; self.fileName = fileName; self.bytes = bytes; self.contentType = contentType
        self.ossKey = ossKey; self.url = url; self.expiresAtMs = expiresAtMs; self.width = width; self.height = height; self.duration = duration
        self.body = body; self.bodyOssKey = bodyOssKey; self.bodyUrl = bodyUrl
    }
}
