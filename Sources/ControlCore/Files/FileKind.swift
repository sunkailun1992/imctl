import Foundation

/// B13: what `message.sendFile` may fetch and paste. The extension picks the kind and content type; where the
/// format has a signature, the first bytes must agree (a `.png` that starts like a JPEG is refused).
public enum FileKind {
    public struct Info: Equatable {
        /// image | video | file
        public var kind: String
        public var contentType: String
        public var ext: String
        public init(kind: String, contentType: String, ext: String) { self.kind = kind; self.contentType = contentType; self.ext = ext }
    }

    static let table: [String: (kind: String, contentType: String)] = [
        "png": ("image", "image/png"), "jpg": ("image", "image/jpeg"), "jpeg": ("image", "image/jpeg"), "gif": ("image", "image/gif"), "webp": ("image", "image/webp"),
        "heic": ("image", "image/heic"),
        "mp4": ("video", "video/mp4"), "mov": ("video", "video/quicktime"),
        "pdf": ("file", "application/pdf"), "doc": ("file", "application/msword"),
        "docx": ("file", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        "xls": ("file", "application/vnd.ms-excel"), "xlsx": ("file", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        "ppt": ("file", "application/vnd.ms-powerpoint"), "pptx": ("file", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        "zip": ("file", "application/zip"), "txt": ("file", "text/plain"),
    ]

    /// Signatures each extension accepts; an empty set means "no check" (txt).
    static let accepted: [String: Set<String>] = [
        "png": ["png"], "jpg": ["jpeg"], "jpeg": ["jpeg"], "gif": ["gif"], "webp": ["webp"], "heic": ["heic"],
        "mp4": ["mp4", "mov"], "mov": ["mp4", "mov"], "pdf": ["pdf"],
        "doc": ["ole", "zip"], "xls": ["ole", "zip"], "ppt": ["ole", "zip"],
        "docx": ["zip"], "xlsx": ["zip"], "pptx": ["zip"], "zip": ["zip"], "txt": [],
    ]

    public static func info(forFileName name: String, allowHEICPreview: Bool = false) -> Info? {
        let ext = (name as NSString).pathExtension.lowercased()
        // HEIC is read-only media from WeCom's cache. Keep message.sendFile's existing type allowlist.
        if ext == "heic" && !allowHEICPreview { return nil }
        guard !ext.isEmpty, let entry = table[ext] else { return nil }
        return Info(kind: entry.kind, contentType: entry.contentType, ext: ext)
    }

    /// png | jpeg | gif | webp | heic | mp4 | mov | pdf | zip | ole, from the first 16 bytes.
    public static func signature(of head: [UInt8]) -> String? {
        guard head.count >= 4 else { return nil }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return "ole" }
        guard head.count >= 12 else { return nil }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] {   // "ftyp"
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") { return "heic" }
            return brand.hasPrefix("qt") ? "mov" : "mp4"
        }
        return nil
    }

    /// nil when accepted; otherwise the SOURCE_UNSUPPORTED message.
    public static func rejection(fileName: String, head: [UInt8], allowHEICPreview: Bool = false) -> String? {
        guard let info = info(forFileName: fileName, allowHEICPreview: allowHEICPreview) else {
            return "\"\(fileName)\": extension is not in the allowlist (png jpg jpeg gif webp mp4 mov pdf doc docx xls xlsx ppt pptx zip txt)"
        }
        let wanted = accepted[info.ext] ?? []
        guard !wanted.isEmpty else { return nil }
        guard let found = signature(of: head) else { return "\"\(fileName)\": the file head is not a \(wanted.sorted().joined(separator: " / ")) signature" }
        guard wanted.contains(found) else { return "\"\(fileName)\": extension \(info.ext) but the file head says \(found)" }
        return nil
    }
}
