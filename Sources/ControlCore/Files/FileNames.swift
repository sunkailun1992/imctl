import Foundation

/// File names as pasted into the client: the URL's last path component (percent-decoded), no path separators,
/// no control characters, at most 120 characters with the extension kept — unless the extension itself
/// (including its dot) is longer than 40 characters, in which case it no longer counts as an extension and
/// the whole name is truncated to 120.
public enum FileNames {
    public static let maxLength = 120

    public static func name(from url: URL) -> String {
        let last = url.lastPathComponent
        let decoded = last.removingPercentEncoding ?? last
        return sanitize(decoded == "/" ? "" : decoded, fallback: "file")
    }

    /// Caps `raw` at `maxLength` (120) characters after stripping path separators, control characters and
    /// `:`, and dropping leading dots. The result is never longer than `maxLength`. The extension normally
    /// survives truncation by shortening the stem first (down to at least 1 character); but when the
    /// extension plus its dot is itself longer than 40 characters, it is treated as no extension at all and
    /// the whole string is truncated to `maxLength` instead — otherwise a long enough extension could leave
    /// no room to shorten and the cap would silently stop working. Falls back to `fallback` if nothing is
    /// left after stripping.
    public static func sanitize(_ raw: String, fallback: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "")
        s = s.split(separator: "/").last.map(String.init) ?? ""
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        guard !s.isEmpty else { return fallback }
        guard s.count > maxLength else { return s }
        let ext = (s as NSString).pathExtension
        guard !ext.isEmpty, ext.count < 40 else { return String(s.prefix(maxLength)) }
        let stem = String(s.dropLast(ext.count + 1))
        let room = max(1, maxLength - ext.count - 1)
        return String(stem.prefix(room)) + "." + ext
    }
}
