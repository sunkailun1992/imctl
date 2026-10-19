import AXKit
import Foundation

public struct WeComObserverSubscription {
    public let observer: AXObserving
    public let added: Int
    public let unsupported: [String]
}

/// Subscribes one AXObserver to everything a located WeCom layout can
/// announce: application/window lifecycle, both tables, and the composer.
/// Unsupported notifications are skipped, not fatal. Read-only.
public enum WeComObserver {
    public static let applicationNotifications = [
        AXNotification.applicationActivated, AXNotification.applicationDeactivated, AXNotification.applicationHidden,
        AXNotification.applicationShown, AXNotification.windowCreated, AXNotification.mainWindowChanged,
        AXNotification.focusedWindowChanged, AXNotification.focusedUIElementChanged,
    ]
    public static let windowNotifications = [
        AXNotification.layoutChanged, AXNotification.titleChanged, AXNotification.created, AXNotification.destroyed,
    ]
    public static let conversationTableNotifications = [
        AXNotification.rowCountChanged, AXNotification.selectedRowsChanged, AXNotification.valueChanged,
        AXNotification.created, AXNotification.destroyed, AXNotification.layoutChanged,
    ]
    public static let messageTableNotifications = [
        AXNotification.rowCountChanged, AXNotification.valueChanged, AXNotification.created,
        AXNotification.destroyed, AXNotification.layoutChanged,
    ]
    public static let composerNotifications = [AXNotification.valueChanged]

    public static func targets(for layout: WeComLayout, pid: pid_t) -> [(AXElement, [String])] {
        var out: [(AXElement, [String])] = [
            (AXApp.byPID(pid, backend: layout.window.backend), applicationNotifications),
            (layout.window, windowNotifications),
            (layout.conversationTable, conversationTableNotifications),
        ]
        if let table = layout.messageTable { out.append((table, messageTableNotifications)) }
        if let composer = layout.composer { out.append((composer, composerNotifications)) }
        return out
    }

    public static func subscribe(to layout: WeComLayout, handler: @escaping (AXNotificationEvent) -> Void) throws -> WeComObserverSubscription {
        let pid = try layout.window.pid()
        let observer = try layout.window.backend.makeObserver(pid: pid, handler: handler)
        var added = 0
        var unsupported: [String] = []
        for (element, names) in targets(for: layout, pid: pid) {
            for name in names {
                do { try observer.add(name, to: element.handle); added += 1 } catch { unsupported.append(name) }
            }
        }
        return WeComObserverSubscription(observer: observer, added: added, unsupported: unsupported)
    }
}
