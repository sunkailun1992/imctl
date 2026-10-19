import CoreGraphics
import Foundation

/// Convenience wrapper pairing a handle with its backend. Named getters
/// (`role()`, `title()`, …) return nil when the attribute is unsupported and
/// propagate every other error; `attribute(_:)` is the raw primitive.
public struct AXElement {
    public let handle: AXElementHandle
    public let backend: AXBackend

    public init(handle: AXElementHandle, backend: AXBackend) {
        self.handle = handle
        self.backend = backend
    }

    // MARK: Raw primitives

    public func attributeNames() throws -> [String] { try backend.attributeNames(of: handle) }
    public func attribute(_ name: String) throws -> AXAttributeValue? { try backend.attribute(name, of: handle) }
    public func isSettable(_ name: String) throws -> Bool { try backend.isAttributeSettable(name, of: handle) }
    public func setAttribute(_ name: String, to value: AXAttributeValue) throws {
        try backend.setAttribute(name, to: value, of: handle)
    }
    public func actions() throws -> [String] { try backend.actionNames(of: handle) }
    public func perform(_ action: String) throws { try backend.performAction(action, on: handle) }
    public func pid() throws -> pid_t { try backend.pid(of: handle) }

    /// Like `attribute(_:)` but treats "unsupported" as nil.
    public func attributeIfSupported(_ name: String) throws -> AXAttributeValue? {
        do { return try backend.attribute(name, of: handle) } catch AXKitError.attributeUnsupported { return nil }
    }

    // MARK: Typed getters

    public func string(_ name: String) throws -> String? { try attributeIfSupported(name)?.stringValue }
    public func bool(_ name: String) throws -> Bool? { try attributeIfSupported(name)?.boolValue }
    public func element(_ name: String) throws -> AXElement? {
        try attributeIfSupported(name)?.elementValue.map { AXElement(handle: $0, backend: backend) }
    }
    public func elements(_ name: String) throws -> [AXElement] {
        (try attributeIfSupported(name)?.elementsValue ?? []).map { AXElement(handle: $0, backend: backend) }
    }

    /// Retry one transient, read-only AXRole failure while the client rebuilds its tree.
    public func role() throws -> String? { try readAttributeOnceAfterTransientFailure(AXAttribute.role)?.stringValue }
    public func subrole() throws -> String? { try string(AXAttribute.subrole) }
    public func title() throws -> String? { try string(AXAttribute.title) }
    /// WeCom occasionally answers a single AXValue read with -25201 while
    /// rebuilding a row. Retrying the read is safe: no client action is sent.
    /// A second failure still reaches the caller for explicit handling.
    public func value() throws -> AXAttributeValue? {
        do { return try attributeIfSupported(AXAttribute.value) }
        catch AXKitError.apiFailure(let code, let operation) where code == -25201 && operation == "get AXValue" {
            return try attributeIfSupported(AXAttribute.value)
        }
    }
    public func valueString() throws -> String? { try value()?.stringValue }
    public func axDescription() throws -> String? { try string(AXAttribute.description) }
    public func identifier() throws -> String? { try string(AXAttribute.identifier) }
    public func isEnabled() throws -> Bool? { try bool(AXAttribute.enabled) }
    public func isSelected() throws -> Bool? { try bool(AXAttribute.selected) }
    public func isFocused() throws -> Bool? { try bool(AXAttribute.focused) }
    public func children() throws -> [AXElement] { try elements(AXAttribute.children) }
    public func parent() throws -> AXElement? { try element(AXAttribute.parent) }

    /// `AXFrame` when the target exposes it, otherwise `AXPosition` + `AXSize`.
    public func frame() throws -> CGRect? {
        if let rect = try readAttributeOnceAfterTransientFailure(AXAttribute.frame)?.rectValue { return rect }
        guard let origin = try readAttributeOnceAfterTransientFailure(AXAttribute.position)?.pointValue,
              let size = try readAttributeOnceAfterTransientFailure(AXAttribute.size)?.sizeValue else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Only the failing property is read again; unsupported and the second error retain their usual semantics.
    private func readAttributeOnceAfterTransientFailure(_ name: String) throws -> AXAttributeValue? {
        do { return try attributeIfSupported(name) }
        catch AXKitError.apiFailure(let code, let operation) where code == -25201 && operation == "get \(name)" {
            return try attributeIfSupported(name)
        }
    }
}
