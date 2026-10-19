/// Opaque identity of an accessibility element inside one backend.
/// Live: wraps the AXUIElement. Fake: an Int node id. Never compare handles
/// across backends.
public struct AXElementHandle: Hashable, CustomStringConvertible {
    public let id: AnyHashable
    public init(id: AnyHashable) { self.id = id }
    public var description: String { "AXElementHandle(\(id))" }
}
