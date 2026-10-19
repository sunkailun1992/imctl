import CoreGraphics
import Foundation

/// A typed accessibility attribute value. `LiveAXBackend` converts CFTypeRef
/// into this; `FakeAXBackend` stores these directly. Nothing outside the
/// live backend ever sees a CFTypeRef.
public enum AXAttributeValue: Equatable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case double(Double)
    case point(CGPoint)
    case size(CGSize)
    case rect(CGRect)
    case range(NSRange)
    case url(URL)
    case element(AXElementHandle)
    case elements([AXElementHandle])
    case strings([String])
    /// A value type AXKit does not model; payload is a human-readable description.
    case unknown(String)

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? { if case .integer(let i) = self { return i }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
    public var pointValue: CGPoint? { if case .point(let p) = self { return p }; return nil }
    public var sizeValue: CGSize? { if case .size(let s) = self { return s }; return nil }
    public var rectValue: CGRect? { if case .rect(let r) = self { return r }; return nil }
    public var rangeValue: NSRange? { if case .range(let r) = self { return r }; return nil }
    public var urlValue: URL? { if case .url(let u) = self { return u }; return nil }
    public var elementValue: AXElementHandle? { if case .element(let e) = self { return e }; return nil }
    public var elementsValue: [AXElementHandle]? { if case .elements(let e) = self { return e }; return nil }
    public var stringsValue: [String]? { if case .strings(let s) = self { return s }; return nil }

    /// Short, log-friendly rendering. Element payloads are never expanded.
    public var summary: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .point(let p): return "(\(p.x), \(p.y))"
        case .size(let s): return "\(s.width)x\(s.height)"
        case .rect(let r): return "(\(r.origin.x), \(r.origin.y), \(r.width), \(r.height))"
        case .range(let r): return "\(r.location)..<\(r.location + r.length)"
        case .url(let u): return u.absoluteString
        case .element: return "<element>"
        case .elements(let e): return "<\(e.count) elements>"
        case .strings(let s): return s.joined(separator: ",")
        case .unknown(let d): return "<unknown: \(d)>"
        }
    }
}
