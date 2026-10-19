import CoreGraphics
import Foundation

/// Serializable snapshot of an accessibility subtree. Produced by
/// `AXTreeDumper` (dump-tree, fixtures) and consumed by `FakeAXBackend`, so a
/// recorded real-client tree can drive adapter unit tests.
public struct AXNode: Codable, Equatable {
    public var role: String?
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var value: AXNodeValue?
    public var description: String?
    public var identifier: String?
    public var help: String?
    public var placeholder: String?
    public var frame: AXFrame?
    public var enabled: Bool?
    public var selected: Bool?
    public var focused: Bool?
    public var actions: [String]
    /// Attribute names the element reported as settable.
    public var settable: [String]
    /// Additional attributes captured as their `summary` string.
    public var extra: [String: String]
    public var children: [AXNode]
    /// True when depth or child limits cut this node's children.
    public var truncated: Bool

    public init(
        role: String? = nil, subrole: String? = nil, roleDescription: String? = nil, title: String? = nil,
        value: AXNodeValue? = nil, description: String? = nil, identifier: String? = nil, help: String? = nil,
        placeholder: String? = nil, frame: CGRect? = nil, enabled: Bool? = nil, selected: Bool? = nil,
        focused: Bool? = nil, actions: [String] = [], settable: [String] = [], extra: [String: String] = [:],
        children: [AXNode] = [], truncated: Bool = false
    ) {
        self.role = role; self.subrole = subrole; self.roleDescription = roleDescription; self.title = title
        self.value = value; self.description = description; self.identifier = identifier; self.help = help
        self.placeholder = placeholder; self.frame = frame.map(AXFrame.init); self.enabled = enabled
        self.selected = selected; self.focused = focused; self.actions = actions; self.settable = settable
        self.extra = extra; self.children = children; self.truncated = truncated
    }

    /// Number of nodes including self.
    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    /// Depth of the deepest leaf, root = 0.
    public var maxDepth: Int { children.map { $0.maxDepth + 1 }.max() ?? 0 }

    public func first(where predicate: (AXNode) -> Bool) -> AXNode? {
        if predicate(self) { return self }
        for child in children { if let hit = child.first(where: predicate) { return hit } }
        return nil
    }

    public func all(where predicate: (AXNode) -> Bool) -> [AXNode] {
        var out: [AXNode] = []
        if predicate(self) { out.append(self) }
        for child in children { out += child.all(where: predicate) }
        return out
    }

    public static func load(from url: URL) throws -> AXNode {
        try JSONDecoder().decode(AXNode.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Plain-JSON rectangle so fixtures stay readable and diffable.
public struct AXFrame: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// The AXValue attribute, kept typed so a fake can hand back the same kind.
/// Encoded as a single-key object: `{"string":"…"}`, `{"bool":true}`,
/// `{"number":1.5}`, `{"other":"<description>"}`.
public enum AXNodeValue: Codable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case other(String)

    private enum Keys: String, CodingKey { case string, bool, number, other }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .string) { self = .string(s) }
        else if let b = try c.decodeIfPresent(Bool.self, forKey: .bool) { self = .bool(b) }
        else if let n = try c.decodeIfPresent(Double.self, forKey: .number) { self = .number(n) }
        else if let o = try c.decodeIfPresent(String.self, forKey: .other) { self = .other(o) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "AXNodeValue needs one of string/bool/number/other"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string(let s): try c.encode(s, forKey: .string)
        case .bool(let b): try c.encode(b, forKey: .bool)
        case .number(let n): try c.encode(n, forKey: .number)
        case .other(let o): try c.encode(o, forKey: .other)
        }
    }

    public init(_ value: AXAttributeValue) {
        switch value {
        case .string(let s): self = .string(s)
        case .bool(let b): self = .bool(b)
        case .integer(let i): self = .number(Double(i))
        case .double(let d): self = .number(d)
        default: self = .other(value.summary)
        }
    }

    public var attributeValue: AXAttributeValue {
        switch self {
        case .string(let s): return .string(s)
        case .bool(let b): return .bool(b)
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? .integer(Int(n)) : .double(n)
        case .other(let o): return .unknown(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}
