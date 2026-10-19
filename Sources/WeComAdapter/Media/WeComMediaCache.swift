import ControlCore
import Foundation

/// B10 step 1 of the picture route: pictures have no accessibility
/// representation (B9 probe), so they must come from the client's own local
/// cache. This scanner takes a **read-only inventory** of the client's
/// container / group containers — which files look like images or videos,
/// where they cluster, how fresh they are — never their contents. macOS
/// protects other apps' containers: the first access shows the system's
/// "access data from other apps" prompt and blocks until the user answers,
/// so the scan runs on its own thread and `report` answers `pending`
/// meanwhile (the daemon's command queue is never held).
public final class WeComMediaCacheScanner {
    public struct Root: Equatable {
        public var label: String
        public var url: URL
        public init(label: String, url: URL) { self.label = label; self.url = url }
    }

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Root] {
        [
            Root(label: "container", url: home.appendingPathComponent("Library/Containers/com.tencent.WeWorkMac/Data", isDirectory: true)),
            Root(label: "group", url: home.appendingPathComponent("Library/Group Containers/88L2Q4487U.com.tencent.WeWorkMac", isDirectory: true)),
            Root(label: "group-legacy", url: home.appendingPathComponent("Library/Group Containers/88L2Q4487U.WeWorkMac", isDirectory: true)),
        ]
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    static let audioExtensions: Set<String> = ["amr", "silk", "mp3", "m4a", "aac", "wav"]
    /// Files that are certainly not media; everything else with an unknown extension gets a signature check.
    static let textLikeExtensions: Set<String> = ["db", "sqlite", "sqlite3", "wal", "shm", "journal", "plist", "json", "js", "css", "html", "htm", "txt", "log", "xml", "lock", "md", "ttf", "otf", "woff", "woff2", "strings", "nib", "car", "dylib", "so", "zip", "gz", "pb", "idx", "map"]
    /// Directories that are never message media and only cost time.
    static let skippedDirectories: Set<String> = ["WebKit", "Cookies", "Saved Application State", "com.apple.WebKit.WebContent", "HTTPStorages", "fsCachedData", "SplashBoard"]

    public var roots: [Root]
    public var maxNodes = 400_000
    public var maxDepth = 14
    /// Extension-less / misnamed files whose first bytes are checked; capped so a huge tree stays a short scan.
    public var maxSignatureReads = 6000
    public var topDirectories = 20

    private enum State { case idle, running(Date), done(MediaCacheReport) }
    private let lock = NSLock()
    private var state: State = .idle

    public init(roots: [Root] = WeComMediaCacheScanner.defaultRoots()) { self.roots = roots }

    /// Never blocks: starts a scan when none exists (or `refresh`), reports `pending` until it is done.
    public func report(limit: Int, refresh: Bool = false) -> MediaCacheReport {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .done(let r) where !refresh:
            return r.trimmed(to: limit)
        case .running(let since):
            return MediaCacheReport(status: "pending", roots: roots.map(\.label), elapsedMs: Int(Date().timeIntervalSince(since) * 1000),
                                    notes: ["scan running; if a system prompt \"access data from other apps\" is showing, allow it for imctld"])
        default:
            let started = Date()
            state = .running(started)
            Thread { [self] in
                let result = scan(started: started)
                lock.lock(); state = .done(result); lock.unlock()
            }.start()
            return MediaCacheReport(status: "pending", roots: roots.map(\.label), notes: ["scan started"])
        }
    }

    /// Synchronous scan (tests, or callers that accept the blocking prompt).
    public func scan(started: Date = Date()) -> MediaCacheReport {
        var files: [MediaCacheFile] = []
        var dirs: [String: (root: String, path: String, images: Int, newest: Int64)] = [:]
        var notes: [String] = []
        var scanned = 0
        var signatureReads = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        for root in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.url.path, isDirectory: &isDir), isDir.boolValue else { notes.append("\(root.label): absent"); continue }
            let errors = ErrorBox()
            let handler: (URL, Error) -> Bool = { url, error in
                if errors.first == nil { errors.first = "\(url.lastPathComponent): \((error as NSError).localizedDescription)" }
                return true
            }
            guard let e = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: Array(keys), options: [.skipsPackageDescendants], errorHandler: handler) else {
                notes.append("\(root.label): cannot enumerate"); continue
            }
            let base = root.url.standardizedFileURL.path
            while let url = e.nextObject() as? URL {
                scanned += 1
                if scanned > maxNodes { notes.append("stopped at \(maxNodes) nodes"); break }
                if e.level > maxDepth { e.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: keys) else { continue }
                if v.isDirectory == true {
                    if Self.skippedDirectories.contains(url.lastPathComponent) { e.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                let size = Int64(v.fileSize ?? 0)
                let modified = Int64((v.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
                let ext = url.pathExtension.lowercased()
                var kind: String?
                var signature: String?
                if Self.imageExtensions.contains(ext) { kind = "image" }
                else if Self.videoExtensions.contains(ext) { kind = "video" }
                else if Self.audioExtensions.contains(ext) { kind = "audio" }
                else if !Self.textLikeExtensions.contains(ext), size >= 1024, size <= 60_000_000, signatureReads < maxSignatureReads {
                    // anything else the client may have renamed (.pic / .dat / no extension …) is judged by its first bytes
                    signatureReads += 1
                    if let sig = Self.signature(of: url) { kind = sig.kind; signature = sig.name }
                }
                guard let kind else { continue }
                let rel = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                files.append(MediaCacheFile(root: root.label, path: rel, size: size, modifiedMs: modified, kind: kind, signature: signature))
                if kind == "image" {
                    let dir = (rel as NSString).deletingLastPathComponent
                    let key = root.label + ":" + dir
                    var d = dirs[key] ?? (root.label, dir, 0, 0)
                    d.images += 1; d.newest = max(d.newest, modified); dirs[key] = d
                }
            }
            if let first = errors.first { notes.append("\(root.label): \(first)") }
        }
        let directories = dirs.values.sorted { $0.images != $1.images ? $0.images > $1.images : $0.newest > $1.newest }.prefix(topDirectories)
            .map { MediaCacheDirectory(root: $0.root, path: $0.path, images: $0.images, newestMs: $0.newest) }
        notes.append("signature reads: \(signatureReads)")
        return MediaCacheReport(status: "ready", roots: roots.map(\.label), elapsedMs: Int(Date().timeIntervalSince(started) * 1000), scanned: scanned,
                                files: files.sorted { $0.modifiedMs > $1.modifiedMs }, directories: Array(directories), notes: notes)
    }

    /// Diagnostic listing of one directory inside a root (no `..`, no absolute paths): names, sizes, dates,
    /// first bytes as hex and the media signature when there is one. Blocks on the system prompt like `scan`.
    public func list(root label: String?, dir: String, limit: Int = 400) throws -> MediaCacheReport {
        guard let root = roots.first(where: { label == nil || $0.label == label }) else { throw ControlError.invalidParams("unknown root \(label ?? "-")") }
        let clean = dir.split(separator: "/").map(String.init)
        guard !clean.contains(".."), !dir.hasPrefix("/") else { throw ControlError.invalidParams("dir must be relative to the root") }
        let url = clean.reduce(root.url) { $0.appendingPathComponent($1) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let children: [URL]
        do { children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: []) }
        catch { throw ControlError.clientUnavailable("cannot list \(root.label):\(dir): \((error as NSError).localizedDescription)") }
        var entries: [MediaCacheEntry] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(limit) {
            let v = try? child.resourceValues(forKeys: keys)
            let isDir = v?.isDirectory == true
            let size = Int64(v?.fileSize ?? 0)
            let modified = Int64((v?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
            var head: String?
            var signature: String?
            if !isDir, size > 0, let h = FileHandle(forReadingAtPath: child.path) {
                let bytes = [UInt8]((try? h.read(upToCount: 16)) ?? Data())
                try? h.close()
                head = bytes.map { String(format: "%02x", $0) }.joined()
                signature = Self.signature(of: bytes)?.name
            }
            entries.append(MediaCacheEntry(name: child.lastPathComponent, isDirectory: isDir, size: size, modifiedMs: modified, head: head, signature: signature))
        }
        return MediaCacheReport(status: "ready", roots: [root.label], scanned: children.count, notes: children.count > limit ? ["truncated to \(limit) of \(children.count)"] : [], entries: entries)
    }

    final class ErrorBox { var first: String? }

    /// First bytes → (kind, name); nil when not a known media signature.
    public static func signature(of url: URL) -> (kind: String, name: String)? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        let head = [UInt8]((try? h.read(upToCount: 16)) ?? Data())
        return signature(of: head)
    }

    public static func signature(of head: [UInt8]) -> (kind: String, name: String)? {
        guard head.count >= 12 else { return nil }
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return ("image", "jpeg") }
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return ("image", "png") }
        if head[0] == 0x47, head[1] == 0x49, head[2] == 0x46, head[3] == 0x38 { return ("image", "gif") }
        if head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46, head[8] == 0x57, head[9] == 0x45, head[10] == 0x42, head[11] == 0x50 { return ("image", "webp") }
        if head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 {
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            return brand.hasPrefix("hei") || brand.hasPrefix("mif") ? ("image", "heic") : ("video", "mp4")
        }
        return nil
    }
}
