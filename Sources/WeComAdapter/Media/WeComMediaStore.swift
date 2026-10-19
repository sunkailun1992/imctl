import ControlCore
import Foundation

/// Where the 5.0.11 client keeps message pictures (live 2026-09-16, through
/// the daemon's own "access data from other apps" grant):
/// `Documents/Profiles/<profile>/Caches/Images/<yyyy-MM>/<id>/<id>` — a plain
/// JPEG / PNG per picture message, `<id>_HD/<id>_HD` next to it once the
/// original was opened; stickers under `Caches/Emotions`, video posters under
/// `Caches/Video_Thumbnail`. The message database itself is encrypted, so the
/// only handle on a picture is its file: its modification time is the moment
/// it arrived.
public struct WeComMediaStore {
    public var containerData: URL
    public var profilesDirectory: URL { containerData.appendingPathComponent("Documents/Profiles", isDirectory: true) }
    public static let cacheKinds = ["Images", "Video_Thumbnail", "Emotions", "Link_Thumbnail"]
    /// Picture-only caches: every `cacheKind` except `Video_Thumbnail`, which holds video posters and must stay
    /// reserved for `video` rows — a `media` (picture) row searching it could take (and permanently assign) the
    /// poster a video row still needs (review 2026-09-23).
    public static let pictureKinds = ["Images", "Emotions", "Link_Thumbnail"]
    public static let rootLabel = "container"

    public init(containerData: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.tencent.WeWorkMac/Data", isDirectory: true)) {
        self.containerData = containerData
    }

    /// `Documents/Profiles/setting.json` names the current profile; otherwise the profile whose image cache changed last.
    public func currentProfile() -> URL? {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: profilesDirectory.appendingPathComponent("setting.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for value in object.values {
                if let id = value as? String, id.count == 32, fm.fileExists(atPath: profilesDirectory.appendingPathComponent(id).path) {
                    return profilesDirectory.appendingPathComponent(id, isDirectory: true)
                }
            }
        }
        let profiles = ((try? fm.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        func stamp(_ url: URL) -> Date {
            (try? url.appendingPathComponent("Caches/Images").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return profiles.max { stamp($0) < stamp($1) }
    }

    /// Picture-like files of the current profile modified in `[sinceMs, untilMs]`, newest first; `_HD` originals excluded
    /// (they are the same picture opened at full size — see `hdSibling`). Cheap: only month folders in range are visited.
    public func candidates(sinceMs: Int64, untilMs: Int64 = Int64.max, kinds: [String] = WeComMediaStore.cacheKinds) -> [MediaCacheFile] {
        guard let profile = currentProfile() else { return [] }
        let fm = FileManager.default
        var out: [MediaCacheFile] = []
        let base = containerData.standardizedFileURL.path
        for kind in kinds {
            let kindDir = profile.appendingPathComponent("Caches/\(kind)", isDirectory: true)
            for month in (try? fm.contentsOfDirectory(at: kindDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [] {
                guard let modified = try? month.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      Int64(modified.timeIntervalSince1970 * 1000) >= sinceMs - 40 * 86_400_000 else { continue }
                for item in (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [])) ?? [] {
                    guard !item.lastPathComponent.hasSuffix("_HD") else { continue }
                    let files = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        ? ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [])) ?? []) : [item]
                    for file in files {
                        guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
                        let ms = Int64((v.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
                        guard ms >= sinceMs, ms <= untilMs, let sig = WeComMediaCacheScanner.signature(of: file) else { continue }
                        let rel = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
                        out.append(MediaCacheFile(root: Self.rootLabel, path: rel, size: Int64(v.fileSize ?? 0), modifiedMs: ms, kind: sig.kind, signature: sig.name))
                    }
                }
            }
        }
        return out.sorted { $0.modifiedMs > $1.modifiedMs }
    }

    public func url(of file: MediaCacheFile) -> URL { containerData.appendingPathComponent(file.path) }

    /// `<id>_HD/<id>_HD` next to `<id>/<id>` when the original was downloaded.
    public func hdSibling(of file: MediaCacheFile) -> MediaCacheFile? {
        let url = self.url(of: file)
        let name = url.lastPathComponent
        let hd = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(name + "_HD").appendingPathComponent(name + "_HD")
        guard let v = try? hd.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true,
              let sig = WeComMediaCacheScanner.signature(of: hd) else { return nil }
        let rel = String(hd.standardizedFileURL.path.dropFirst(containerData.standardizedFileURL.path.count + 1))
        return MediaCacheFile(root: Self.rootLabel, path: rel, size: Int64(v.fileSize ?? 0),
                              modifiedMs: Int64((v.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000), kind: sig.kind, signature: sig.name)
    }

    /// Files the client cached under `Caches/Files/<yyyy-MM>/<id>/<name>` (live 2026-09-22: the original name and size are kept),
    /// the exact name first and the client's own duplicate copies after it, each newest first; `sizeLabel`
    /// ("74K") narrows same-name files to the one the row shows.
    public func fileCandidates(name: String, sizeLabel: String?) -> [MediaCacheFile] {
        // `name` is whatever the client's AX tree put on the row, so it is untrusted: appended as-is, a name
        // like `../../x` walks straight out of the cache tree and hands `message.media` a file from a
        // directory this never searched. Only a name that survives sanitising unchanged is a plain file name
        // (review 2026-09-23). The `<stem> (<n>)<ext>` copies below are derived from that sanitised name and
        // matched against what the directory actually holds, so nothing new comes in off the row.
        guard !name.isEmpty, name == FileNames.sanitize(name, fallback: "") else { return [] }
        guard let profile = currentProfile() else { return [] }
        let fm = FileManager.default
        let base = containerData.standardizedFileURL.path
        var exact: [MediaCacheFile] = []
        var copies: [MediaCacheFile] = []
        let filesDir = profile.appendingPathComponent("Caches/Files", isDirectory: true)
        for month in (try? fm.contentsOfDirectory(at: filesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [] {
            for item in (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [] {
                let siblings = ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [])) ?? [])
                    .filter { Self.duplicateNumber(of: $0.lastPathComponent, for: name) != nil }
                for file in [item.appendingPathComponent(name)] + siblings {
                    guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
                    let size = Int64(v.fileSize ?? 0)
                    if let sizeLabel, !FileSizeLabel.matches(size: size, label: sizeLabel) { continue }
                    let ms = Int64((v.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
                    let rel = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
                    let hit = MediaCacheFile(root: Self.rootLabel, path: rel, size: size, modifiedMs: ms, kind: "file", signature: nil)
                    if file.lastPathComponent == name { exact.append(hit) } else { copies.append(hit) }
                }
            }
        }
        return exact.sorted { $0.modifiedMs > $1.modifiedMs } + copies.sorted { $0.modifiedMs > $1.modifiedMs }
    }

    /// The client's own name for a file it receives again while it still has the first one: `x.pdf`,
    /// `x (1).pdf`, `x (2).pdf` … side by side in the same `<id>` directory, while every row keeps showing the
    /// original name (live 2026-09-23, 5.0.11). Returns the copy's number, so those copies can be handed out
    /// one per row; nil for anything that is not such a copy of `name` (`n` ≥ 1, and the space before the
    /// parenthesis exactly as the client writes it).
    static func duplicateNumber(of candidate: String, for name: String) -> Int? {
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let prefix = String(name.dropLast(suffix.count)) + " ("
        guard candidate.hasPrefix(prefix), candidate.hasSuffix(")" + suffix), candidate.count > prefix.count + suffix.count + 1 else { return nil }
        let digits = candidate.dropFirst(prefix.count).dropLast(suffix.count + 1)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 1 else { return nil }
        return n
    }

    /// Video bodies the client downloaded, in a time window. Unverified 2026-09-22 observation (from the cache
    /// layout, not from a watched download): the body only appears under `Caches/Videos` once the video was
    /// played, so a row often has a poster and no body — live confirmation pending.
    public func videoBodyCandidates(sinceMs: Int64, untilMs: Int64) -> [MediaCacheFile] {
        candidates(sinceMs: sinceMs, untilMs: untilMs, kinds: ["Videos"]).filter { $0.kind == "video" }
    }

    /// Content type from the sniffed signature, else from the file name's extension, else octet-stream.
    public static func contentType(for file: MediaCacheFile, fileName: String) -> String {
        if let sig = file.signature, let type = ["jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic", "mp4": "video/mp4"][sig] { return type }
        return FileKind.info(forFileName: fileName)?.contentType ?? "application/octet-stream"
    }
}
