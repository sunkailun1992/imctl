import Foundation

/// The nine primitives every accessibility backend provides. `LiveAXBackend`
/// talks to ApplicationServices; `FakeAXBackend` serves a recorded `AXNode`
/// tree. Everything above this protocol is backend-agnostic and unit-testable.
///
/// `setAttribute` and `performAction` are the only primitives that change
/// client state. Callers must go through a policy layer before invoking them;
/// AXKit itself enforces nothing.
public protocol AXBackend: AnyObject {
    var name: String { get }
    func isProcessTrusted(prompt: Bool) -> Bool
    func applicationElement(pid: pid_t) -> AXElementHandle
    func attributeNames(of element: AXElementHandle) throws -> [String]
    /// Returns nil when the attribute exists but has no value; throws
    /// `AXKitError.attributeUnsupported` when the element lacks the attribute.
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue?
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws
    func actionNames(of element: AXElementHandle) throws -> [String]
    func performAction(_ name: String, on element: AXElementHandle) throws
    func pid(of element: AXElementHandle) throws -> pid_t
    /// Read-only observation; see `AXObserving`.
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving
}
