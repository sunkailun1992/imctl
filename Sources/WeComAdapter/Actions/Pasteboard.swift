import AppKit
import Foundation

/// The clipboard as the file paste needs it: snapshot the person's items, put one file URL on it, put the
/// snapshot back once the client took the paste. Behind a protocol so unit tests record instead of touching
/// `NSPasteboard.general`. The caller restores only while the board still holds its staged file URL, so a
/// copy made by the person during the paste window is preserved (docs/ops/permissions.md).
public protocol PasteboardHandling {
    func snapshot() -> [[String: Data]]
    func setFileURL(_ url: URL)
    /// Confirm the clipboard still contains only the file this action staged.
    func matchesFileURL(_ url: URL) -> Bool
    func restore(_ snapshot: [[String: Data]])
}

public final class GeneralPasteboard: PasteboardHandling {
    public init() {}

    public func snapshot() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var out: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type.rawValue] = data } }
            return out
        }
    }

    public func setFileURL(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    public func matchesFileURL(_ url: URL) -> Bool {
        let pb = NSPasteboard.general
        guard pb.pasteboardItems?.count == 1,
              let objects = pb.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]),
              objects.count == 1,
              let current = objects[0] as? URL else { return false }
        return current.isFileURL && current.standardizedFileURL == url.standardizedFileURL
    }

    public func restore(_ snapshot: [[String: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
