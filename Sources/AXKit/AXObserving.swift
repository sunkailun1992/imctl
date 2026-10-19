import Foundation

public struct AXNotificationEvent: Equatable {
    public var name: String
    public var element: AXElementHandle
    public var timestamp: Date

    public init(name: String, element: AXElementHandle, timestamp: Date = Date()) {
        self.name = name
        self.element = element
        self.timestamp = timestamp
    }
}

/// Subscription to accessibility notifications from one process. Live
/// delivery happens on the main run loop; callers must be running it.
public protocol AXObserving: AnyObject {
    func add(_ notification: String, to element: AXElementHandle) throws
    func remove(_ notification: String, from element: AXElementHandle) throws
    func stop()
}

public enum AXNotification {
    public static let valueChanged = "AXValueChanged"
    public static let rowCountChanged = "AXRowCountChanged"
    public static let selectedRowsChanged = "AXSelectedRowsChanged"
    public static let selectedChildrenChanged = "AXSelectedChildrenChanged"
    public static let created = "AXCreated"
    public static let destroyed = "AXUIElementDestroyed"
    public static let layoutChanged = "AXLayoutChanged"
    public static let focusedUIElementChanged = "AXFocusedUIElementChanged"
    public static let titleChanged = "AXTitleChanged"
    public static let windowCreated = "AXWindowCreated"
    public static let applicationActivated = "AXApplicationActivated"
    public static let applicationDeactivated = "AXApplicationDeactivated"
    public static let applicationHidden = "AXApplicationHidden"
    public static let applicationShown = "AXApplicationShown"
    public static let mainWindowChanged = "AXMainWindowChanged"
    public static let focusedWindowChanged = "AXFocusedWindowChanged"
}
