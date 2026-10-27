import CoreGraphics
import Foundation

/// The results of one batched read (`AXElement.read(_:)`). Accessors mirror
/// `AXElement`'s named getters: "unsupported" reads as nil, any other failure
/// is thrown only when that attribute is asked for, and AXRole / AXValue /
/// frame keep the one-shot retry of a transient -25201 (the batch counts as
/// the first read). An attribute missing from the batch is read on its own.
public struct AXAttributeSnapshot {
    public let element: AXElement
    private let results: [String: AXAttributeResult]

    public init(element: AXElement, results: [String: AXAttributeResult]) {
        self.element = element
        self.results = results
    }

    public func attributeIfSupported(_ name: String) throws -> AXAttributeValue? {
        guard let result = results[name] else { return try element.attributeIfSupported(name) }
        switch result {
        case .success(let value): return value
        case .failure(.attributeUnsupported): return nil
        case .failure(let error): throw error
        }
    }

    public func string(_ name: String) throws -> String? { try attributeIfSupported(name)?.stringValue }
    public func bool(_ name: String) throws -> Bool? { try attributeIfSupported(name)?.boolValue }
    public func elements(_ name: String) throws -> [AXElement] {
        (try attributeIfSupported(name)?.elementsValue ?? []).map { AXElement(handle: $0, backend: element.backend) }
    }

    public func role() throws -> String? { try readAgainAfterTransientFailure(AXAttribute.role)?.stringValue }
    public func subrole() throws -> String? { try string(AXAttribute.subrole) }
    public func title() throws -> String? { try string(AXAttribute.title) }
    public func value() throws -> AXAttributeValue? { try readAgainAfterTransientFailure(AXAttribute.value) }
    public func valueString() throws -> String? { try value()?.stringValue }
    public func axDescription() throws -> String? { try string(AXAttribute.description) }
    public func identifier() throws -> String? { try string(AXAttribute.identifier) }
    public func isEnabled() throws -> Bool? { try bool(AXAttribute.enabled) }
    public func isSelected() throws -> Bool? { try bool(AXAttribute.selected) }
    public func isFocused() throws -> Bool? { try bool(AXAttribute.focused) }
    public func children() throws -> [AXElement] { try elements(AXAttribute.children) }

    /// `AXFrame` when present, otherwise `AXPosition` + `AXSize`, like `AXElement.frame()`.
    public func frame() throws -> CGRect? {
        if let rect = try readAgainAfterTransientFailure(AXAttribute.frame)?.rectValue { return rect }
        guard let origin = try readAgainAfterTransientFailure(AXAttribute.position)?.pointValue,
              let size = try readAgainAfterTransientFailure(AXAttribute.size)?.sizeValue else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Only the failing attribute is read again, once; a second failure reaches the caller.
    private func readAgainAfterTransientFailure(_ name: String) throws -> AXAttributeValue? {
        do { return try attributeIfSupported(name) }
        catch AXKitError.apiFailure(let code, let operation) where code == -25201 && operation == "get \(name)" {
            return try element.attributeIfSupported(name)
        }
    }
}

public extension AXElement {
    /// B61: `names` in one round trip where the backend supports it.
    func read(_ names: [String]) throws -> AXAttributeSnapshot {
        AXAttributeSnapshot(element: self, results: try backend.attributes(names, of: handle))
    }
}
