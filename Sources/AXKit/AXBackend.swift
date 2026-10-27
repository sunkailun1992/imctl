import Foundation

/// Outcome of one attribute in a batched read: `.success(nil)` means present
/// without a value (a live batch also reports an unsupported attribute this way).
public typealias AXAttributeResult = Result<AXAttributeValue?, AXKitError>

/// The primitives every accessibility backend provides. `LiveAXBackend`
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
    /// B61: several attributes of one element in one round trip. Per-attribute failures
    /// (unsupported included) are returned, not thrown; it throws only when the call as a
    /// whole failed. An empty result means nothing was batched: `AXAttributeSnapshot` then
    /// reads each attribute when it is asked for, exactly as before batching existed.
    func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult]
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws
    func actionNames(of element: AXElementHandle) throws -> [String]
    func performAction(_ name: String, on element: AXElementHandle) throws
    func pid(of element: AXElementHandle) throws -> pid_t
    /// Read-only observation; see `AXObserving`.
    func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving
}

public extension AXBackend {
    /// Backends without a batch primitive batch nothing; attributes are read on access.
    func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult] {
        [:]
    }

    /// Every name read now, one `attribute(_:of:)` at a time (a fake that emulates a
    /// batching backend): each failure becomes that name's `.failure`, in request order;
    /// only a non-`AXKitError` is rethrown.
    func attributesBySingleReads(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult] {
        var results: [String: AXAttributeResult] = [:]
        for name in names where results[name] == nil {
            do { results[name] = .success(try attribute(name, of: element)) }
            catch let error as AXKitError { results[name] = .failure(error) }
        }
        return results
    }
}
