import CoreGraphics
import Foundation

/// One of the client's top-level windows as the window server numbers it.
/// Window numbers, layers and bounds need no Screen Recording grant; titles
/// are never read. A command uses them to tell a window it opened itself from
/// the one it opened it from when both share one frame — live 2026-09-28
/// (5.0.11, macOS 27.0) the 添加客户 panel is a second layer-0 window exactly
/// the main window's size `(0, 30, 1920×1170)`, its card drawn in the middle,
/// so a capture that matches by geometry alone refuses the pair.
public struct WeComWindowIdentity: Equatable {
    public let id: CGWindowID
    public let layer: Int
    public let bounds: CGRect
    public let onScreen: Bool

    public init(id: CGWindowID, layer: Int, bounds: CGRect, onScreen: Bool) {
        self.id = id; self.layer = layer; self.bounds = bounds; self.onScreen = onScreen
    }

    /// Every window of `pid`, on screen or not.
    public static func list(pid: pid_t) -> [WeComWindowIdentity] {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return WeComWindowIdentity(id: CGWindowID(number), layer: layer, bounds: bounds,
                                       onScreen: (window[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        }
    }

    /// The one on-screen layer-0 window that is in `after` but not in `before`
    /// and covers nearly the same area as `frame`; nil when none or several.
    public static func newWindow(matching frame: CGRect, before: [WeComWindowIdentity],
                                 after: [WeComWindowIdentity]) -> CGWindowID? {
        let existing = Set(before.map(\.id))
        let matches = after.filter { !existing.contains($0.id) && $0.layer == 0 && $0.onScreen && sameArea($0.bounds, frame) }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// The one on-screen layer-0 window of `windows` covering nearly the same
    /// area as `frame` — the window a command started from; nil when none or several.
    public static func existingWindow(matching frame: CGRect, in windows: [WeComWindowIdentity]) -> CGWindowID? {
        let matches = windows.filter { $0.layer == 0 && $0.onScreen && sameArea($0.bounds, frame) }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// The capture's own tolerance: each rectangle covers at least 97% of the other.
    static func sameArea(_ a: CGRect, _ b: CGRect) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return false }
        let area = overlap.width * overlap.height
        return area / (a.width * a.height) >= 0.97 && area / (b.width * b.height) >= 0.97
    }
}
