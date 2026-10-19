# S2 AXKit 原语 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 imctl 一个不知道企微的通用 Accessibility 层：`AXBackend` 协议（live 与 fake 两个实现）、`AXElement` 便利包装、`AXNode` 可编码树快照与 `AXTreeDumper`、`AXApp.byBundleID`、`AXPermission.isTrusted(prompt:)`。所有解析逻辑后续都对 fake 跑，fake 由录制的 `AXNode` JSON 构造。

**Architecture:** `AXBackend` 只暴露 9 个原语（trusted / applicationElement / attributeNames / attribute / isAttributeSettable / setAttribute / actionNames / performAction / pid），元素以 `AXElementHandle`（`AnyHashable` 身份）传递，值以 `AXAttributeValue` 枚举传递，所以 `AXUIElement` 与 `CFTypeRef` 只出现在 `LiveAXBackend.swift` 一个文件里。`AXNode` 既是 `dump-tree` 的输出，也是 `FakeAXBackend` 的输入，二者互为逆运算（用测试锁定）。改变客户端状态的两个原语（`setAttribute`、`performAction`）在本层可用，但 CLI 在 S6 之前不会调用；策略层在 S6 加。

**Tech Stack:** Swift 5 语言模式，ApplicationServices（AXUIElement*），AppKit（NSRunningApplication），Swift Testing。

## Global Constraints

- 不出现 `CGEvent`、录屏/输入监控 API（守卫测试）。
- 不用 `!` 强解包与 `unsafeBitCast`；CF 类型转换用 `as?` + 回退 `.unknown`。
- live 测试用 `.enabled(if: ProcessInfo.processInfo.environment["IMCTL_LIVE"] == "1")`，否则跳过。
- AXKit 不 import ControlCore、不含 "企业微信"/"WeWork" 字面量（`byBundleID` 由调用方传入）。
- 文件按职责拆：一个类型一个文件。

---

### Task 1: 值类型与错误：`AXAttributeValue`、`AXElementHandle`、`AXKitError`、常量

**Files:**
- Create: `Sources/AXKit/AXAttributeValue.swift`
- Create: `Sources/AXKit/AXElementHandle.swift`
- Create: `Sources/AXKit/AXKitError.swift`
- Create: `Sources/AXKit/AXConstants.swift`
- Delete: `Sources/AXKit/AXKit.swift`（占位）
- Test: `Tests/AXKitTests/AXAttributeValueTests.swift`

**Interfaces:**
- Produces:
  - `enum AXAttributeValue: Equatable { string, bool, integer, double, point, size, rect, range, url, element, elements, strings, unknown }` + 访问器 `stringValue/boolValue/intValue/doubleValue/rectValue/elementValue/elementsValue/stringsValue`。
  - `struct AXElementHandle: Hashable { let id: AnyHashable }`。
  - `enum AXKitError: Error, Equatable { notTrusted, applicationNotRunning(bundleID:), invalidElement, attributeUnsupported(String), attributeNotSettable(String), actionUnsupported(String), cannotComplete(String), notImplemented(String), valueNotConvertible(String), apiFailure(code: Int32, operation: String) }`。
  - `enum AXAttribute`、`enum AXAction`、`enum AXRole` 字符串常量。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/AXKitTests/AXAttributeValueTests.swift
import CoreGraphics
import Testing
@testable import AXKit

@Suite("AXAttributeValue")
struct AXAttributeValueTests {
    @Test func accessorsReturnMatchingPayloadOnly() {
        let h = AXElementHandle(id: 7)
        #expect(AXAttributeValue.string("a").stringValue == "a")
        #expect(AXAttributeValue.bool(true).stringValue == nil)
        #expect(AXAttributeValue.bool(true).boolValue == true)
        #expect(AXAttributeValue.integer(3).intValue == 3)
        #expect(AXAttributeValue.double(1.5).doubleValue == 1.5)
        #expect(AXAttributeValue.integer(3).doubleValue == 3.0)
        #expect(AXAttributeValue.rect(CGRect(x: 1, y: 2, width: 3, height: 4)).rectValue?.width == 3)
        #expect(AXAttributeValue.element(h).elementValue == h)
        #expect(AXAttributeValue.elements([h]).elementsValue == [h])
        #expect(AXAttributeValue.strings(["x"]).stringsValue == ["x"])
    }

    @Test func handleEqualityIsByIdentity() {
        #expect(AXElementHandle(id: 1) == AXElementHandle(id: 1))
        #expect(AXElementHandle(id: 1) != AXElementHandle(id: "1"))
    }

    @Test func errorsAreEquatable() {
        #expect(AXKitError.attributeUnsupported("AXFoo") == .attributeUnsupported("AXFoo"))
        #expect(AXKitError.apiFailure(code: -25204, operation: "get AXRole").description.contains("-25204"))
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `swift test --filter AXAttributeValueTests`
Expected: 编译错误 `cannot find 'AXAttributeValue'`。

- [ ] **Step 3: 实现**

```swift
// Sources/AXKit/AXAttributeValue.swift
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
```

```swift
// Sources/AXKit/AXElementHandle.swift
/// Opaque identity of an accessibility element inside one backend.
/// Live: wraps the AXUIElement. Fake: an Int node id. Never compare handles
/// across backends.
public struct AXElementHandle: Hashable, CustomStringConvertible {
    public let id: AnyHashable
    public init(id: AnyHashable) { self.id = id }
    public var description: String { "AXElementHandle(\(id))" }
}
```

```swift
// Sources/AXKit/AXKitError.swift
public enum AXKitError: Error, Equatable, CustomStringConvertible {
    case notTrusted
    case applicationNotRunning(bundleID: String)
    case invalidElement
    case attributeUnsupported(String)
    case attributeNotSettable(String)
    case actionUnsupported(String)
    case cannotComplete(String)
    case notImplemented(String)
    case valueNotConvertible(String)
    case apiFailure(code: Int32, operation: String)

    public var description: String {
        switch self {
        case .notTrusted: return "process is not trusted for Accessibility"
        case .applicationNotRunning(let b): return "application \(b) is not running"
        case .invalidElement: return "invalid or stale AX element"
        case .attributeUnsupported(let a): return "attribute \(a) unsupported"
        case .attributeNotSettable(let a): return "attribute \(a) not settable"
        case .actionUnsupported(let a): return "action \(a) unsupported"
        case .cannotComplete(let op): return "cannot complete \(op) (target not responding)"
        case .notImplemented(let op): return "not implemented by target: \(op)"
        case .valueNotConvertible(let d): return "value not convertible: \(d)"
        case .apiFailure(let code, let op): return "AX API failure \(code) during \(op)"
        }
    }
}
```

```swift
// Sources/AXKit/AXConstants.swift
/// Attribute, action and role names as raw strings so AXKit callers never
/// import ApplicationServices.
public enum AXAttribute {
    public static let role = "AXRole"
    public static let subrole = "AXSubrole"
    public static let roleDescription = "AXRoleDescription"
    public static let title = "AXTitle"
    public static let value = "AXValue"
    public static let description = "AXDescription"
    public static let help = "AXHelp"
    public static let identifier = "AXIdentifier"
    public static let placeholderValue = "AXPlaceholderValue"
    public static let children = "AXChildren"
    public static let parent = "AXParent"
    public static let windows = "AXWindows"
    public static let mainWindow = "AXMainWindow"
    public static let focusedWindow = "AXFocusedWindow"
    public static let focusedUIElement = "AXFocusedUIElement"
    public static let enabled = "AXEnabled"
    public static let focused = "AXFocused"
    public static let selected = "AXSelected"
    public static let hidden = "AXHidden"
    public static let position = "AXPosition"
    public static let size = "AXSize"
    public static let frame = "AXFrame"
    public static let rows = "AXRows"
    public static let selectedRows = "AXSelectedRows"
    public static let selectedChildren = "AXSelectedChildren"
    public static let visibleChildren = "AXVisibleChildren"
    public static let selectedText = "AXSelectedText"
    public static let numberOfCharacters = "AXNumberOfCharacters"
    public static let minimized = "AXMinimized"
}

public enum AXAction {
    public static let press = "AXPress"
    public static let confirm = "AXConfirm"
    public static let raise = "AXRaise"
    public static let showMenu = "AXShowMenu"
    public static let scrollToVisible = "AXScrollToVisible"
}

public enum AXRole {
    public static let application = "AXApplication"
    public static let window = "AXWindow"
    public static let group = "AXGroup"
    public static let scrollArea = "AXScrollArea"
    public static let table = "AXTable"
    public static let outline = "AXOutline"
    public static let list = "AXList"
    public static let row = "AXRow"
    public static let cell = "AXCell"
    public static let staticText = "AXStaticText"
    public static let textArea = "AXTextArea"
    public static let textField = "AXTextField"
    public static let button = "AXButton"
    public static let image = "AXImage"
    public static let unknown = "AXUnknown"
}
```

- [ ] **Step 4: 跑测试** `swift test --filter AXAttributeValueTests` → PASS（守卫测试仍 PASS）。
- [ ] **Step 5: 提交** `git commit -m "feat(axkit): add attribute value, handle, error and constant types"`

### Task 2: `AXBackend` 协议与 `AXElement` 包装

**Files:**
- Create: `Sources/AXKit/AXBackend.swift`
- Create: `Sources/AXKit/AXElement.swift`
- Test: 与 Task 3 的 fake 一起测（协议本身无行为）。

**Interfaces:**
- Produces:

```swift
public protocol AXBackend: AnyObject {
    var name: String { get }
    func isProcessTrusted(prompt: Bool) -> Bool
    func applicationElement(pid: pid_t) -> AXElementHandle
    func attributeNames(of element: AXElementHandle) throws -> [String]
    func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue?
    func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool
    func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws
    func actionNames(of element: AXElementHandle) throws -> [String]
    func performAction(_ name: String, on element: AXElementHandle) throws
    func pid(of element: AXElementHandle) throws -> pid_t
}
```

```swift
public struct AXElement {
    public let handle: AXElementHandle
    public let backend: AXBackend
    public init(handle: AXElementHandle, backend: AXBackend)
    public func attributeNames() throws -> [String]
    public func attribute(_ name: String) throws -> AXAttributeValue?
    public func string(_ name: String) throws -> String?
    public func bool(_ name: String) throws -> Bool?
    public func element(_ name: String) throws -> AXElement?
    public func elements(_ name: String) throws -> [AXElement]
    public func role() throws -> String?
    public func subrole() throws -> String?
    public func title() throws -> String?
    public func value() throws -> AXAttributeValue?
    public func valueString() throws -> String?
    public func axDescription() throws -> String?
    public func identifier() throws -> String?
    public func isEnabled() throws -> Bool?
    public func isSelected() throws -> Bool?
    public func children() throws -> [AXElement]
    public func parent() throws -> AXElement?
    public func frame() throws -> CGRect?
    public func isSettable(_ name: String) throws -> Bool
    public func setAttribute(_ name: String, to value: AXAttributeValue) throws
    public func actions() throws -> [String]
    public func perform(_ action: String) throws
    public func pid() throws -> pid_t
}
```

- [ ] **Step 1: 实现**（`frame()` 先取 `AXFrame`，缺则由 `AXPosition`+`AXSize` 合成）。
- [ ] **Step 2: `swift build`** 通过。
- [ ] **Step 3: 提交** `git commit -m "feat(axkit): define AXBackend protocol and AXElement wrapper"`

### Task 3: `AXNode` 快照 + `FakeAXBackend`

**Files:**
- Create: `Sources/AXKit/AXNode.swift`
- Create: `Sources/AXKit/FakeAXBackend.swift`
- Test: `Tests/AXKitTests/FakeAXBackendTests.swift`

**Interfaces:**
- Produces:

```swift
public struct AXNode: Codable, Equatable {
    public var role: String?, subrole: String?, roleDescription: String?, title: String?
    public var value: AXNodeValue?, description: String?, identifier: String?, help: String?, placeholder: String?
    public var frame: CGRect?, enabled: Bool?, selected: Bool?, focused: Bool?
    public var actions: [String], settable: [String], extra: [String: String], children: [AXNode], truncated: Bool
    public init(role: String? = nil, ... children: [AXNode] = [])   // 全部有默认值
    public var count: Int          // 含自身的节点数
    public var maxDepth: Int
    public static func load(from url: URL) throws -> AXNode
    public func write(to url: URL) throws   // pretty, sortedKeys
    public func first(where predicate: (AXNode) -> Bool) -> AXNode?
}
public enum AXNodeValue: Codable, Equatable { case string(String), bool(Bool), number(Double), other(String) }
```

```swift
public final class FakeAXBackend: AXBackend {
    public let name = "fake"
    public var trusted: Bool
    public let pid: pid_t
    public private(set) var rootHandle: AXElementHandle
    public private(set) var recordedSets: [(handle: AXElementHandle, attribute: String, value: AXAttributeValue)]
    public private(set) var recordedActions: [(handle: AXElementHandle, action: String)]
    public var injectedFailures: [String: AXKitError]   // key "<op>:<attr-or-action>"，如 "get:AXValue"、"set:AXValue"、"action:AXPress"，或 "get:*"
    public init(root: AXNode, pid: pid_t = 4242, trusted: Bool = true)
    public var rootElement: AXElement
    public func handle(atPath path: [Int]) -> AXElementHandle?   // 子索引路径，[] 为根
    public func element(atPath path: [Int]) -> AXElement?
    /// 直接改树（不记录），模拟客户端自身变化；S6 的 watch 测试用。
    public func mutate(_ handle: AXElementHandle, attribute: String, to value: AXAttributeValue?)
    public func replaceChildren(of handle: AXElementHandle, with nodes: [AXNode])
}
```

Fake 语义：`AXRole/AXSubrole/AXRoleDescription/AXTitle/AXValue/AXDescription/AXIdentifier/AXHelp/AXPlaceholderValue/AXFrame/AXPosition/AXSize/AXEnabled/AXSelected/AXFocused` 从节点字段映射；`AXChildren`→`.elements`；`AXParent`→`.element`；`extra` 每项为 `.string`；不存在的属性抛 `.attributeUnsupported`（若节点根本没有该键）或返回 nil（键存在值为 nil 不会发生，fake 用"字段为 nil 即 unsupported"）；`setAttribute` 需在 `settable` 内否则 `.attributeNotSettable`，成功则更新节点并记录；`performAction` 需在 `actions` 内否则 `.actionUnsupported`，成功只记录；`injectedFailures` 命中即抛。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/AXKitTests/FakeAXBackendTests.swift
import CoreGraphics
import Foundation
import Testing
@testable import AXKit

enum SampleTree {
    static func make() -> AXNode {
        AXNode(role: AXRole.application, title: "SampleApp", children: [
            AXNode(role: AXRole.window, title: "Main", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
                AXNode(role: AXRole.table, identifier: "conversations", settable: [AXAttribute.selectedRows], extra: ["AXSelectedRows": "<0 elements>"], children: [
                    AXNode(role: AXRole.row, title: "Row A", selected: true, actions: [AXAction.press]),
                    AXNode(role: AXRole.row, title: "Row B", selected: false, actions: [AXAction.press]),
                ]),
                AXNode(role: AXRole.textArea, value: .string(""), placeholder: "Type here", settable: [AXAttribute.value], actions: []),
                AXNode(role: AXRole.button, title: "Send", enabled: false, actions: [AXAction.press]),
            ]),
        ])
    }
}

@Suite("FakeAXBackend")
struct FakeAXBackendTests {
    @Test func readsMappedAttributesAndChildren() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let root = fake.rootElement
        #expect(try root.role() == AXRole.application)
        #expect(try root.title() == "SampleApp")
        let window = try #require(try root.children().first)
        #expect(try window.frame() == CGRect(x: 0, y: 0, width: 800, height: 600))
        let table = try #require(fake.element(atPath: [0, 0]))
        #expect(try table.identifier() == "conversations")
        #expect(try table.children().count == 2)
        #expect(try table.parent()?.handle == window.handle)
        #expect(try table.string("AXSelectedRows") == "<0 elements>")
        #expect(try fake.element(atPath: [0, 0, 0])?.isSelected() == true)
        #expect(try fake.element(atPath: [0, 2])?.isEnabled() == false)
        #expect(try root.pid() == 4242)
    }

    @Test func missingAttributeThrowsUnsupported() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        #expect(throws: AXKitError.attributeUnsupported("AXURL")) {
            try fake.rootElement.attribute("AXURL")
        }
    }

    @Test func setAttributeRecordsAndUpdatesOnlyWhenSettable() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let input = try #require(fake.element(atPath: [0, 1]))
        #expect(try input.isSettable(AXAttribute.value))
        try input.setAttribute(AXAttribute.value, to: .string("hello"))
        #expect(try input.valueString() == "hello")
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].attribute == AXAttribute.value)
        #expect(fake.recordedSets[0].value == .string("hello"))

        let button = try #require(fake.element(atPath: [0, 2]))
        #expect(throws: AXKitError.attributeNotSettable(AXAttribute.title)) {
            try button.setAttribute(AXAttribute.title, to: .string("x"))
        }
        #expect(fake.recordedSets.count == 1)
    }

    @Test func performRecordsOnlySupportedActions() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let button = try #require(fake.element(atPath: [0, 2]))
        #expect(try button.actions() == [AXAction.press])
        try button.perform(AXAction.press)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
        let input = try #require(fake.element(atPath: [0, 1]))
        #expect(throws: AXKitError.actionUnsupported(AXAction.press)) { try input.perform(AXAction.press) }
        #expect(fake.recordedActions.count == 1)
    }

    @Test func injectedFailuresAreThrown() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.injectedFailures["get:AXTitle"] = .cannotComplete("get AXTitle")
        #expect(throws: AXKitError.cannotComplete("get AXTitle")) { try fake.rootElement.title() }
        #expect(try fake.rootElement.role() == AXRole.application)
        fake.injectedFailures["get:*"] = .invalidElement
        #expect(throws: AXKitError.invalidElement) { try fake.rootElement.role() }
    }

    @Test func mutateAndReplaceChildrenChangeTreeWithoutRecording() throws {
        let fake = FakeAXBackend(root: SampleTree.make())
        let table = try #require(fake.handle(atPath: [0, 0]))
        fake.replaceChildren(of: table, with: [AXNode(role: AXRole.row, title: "Row C")])
        let rows = try fake.rootElement.children()[0].children()[0].children()
        #expect(try rows.map { try $0.title() } == ["Row C"])
        fake.mutate(rows[0].handle, attribute: AXAttribute.title, to: .string("Row C'"))
        #expect(try rows[0].title() == "Row C'")
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func trustedFlagIsReported() {
        #expect(FakeAXBackend(root: SampleTree.make(), trusted: false).isProcessTrusted(prompt: true) == false)
    }
}

@Suite("AXNode")
struct AXNodeTests {
    @Test func codableRoundTripAndCounts() throws {
        let node = SampleTree.make()
        let data = try JSONEncoder().encode(node)
        let back = try JSONDecoder().decode(AXNode.self, from: data)
        #expect(back == node)
        #expect(node.count == 7)
        #expect(node.maxDepth == 3)
        #expect(node.first { $0.role == AXRole.button }?.title == "Send")
    }

    @Test func valueEncodesAsTaggedObject() throws {
        let json = String(decoding: try JSONEncoder().encode(AXNodeValue.bool(true)), as: UTF8.self)
        #expect(json == #"{"bool":true}"#)
        let s = try JSONDecoder().decode(AXNodeValue.self, from: Data(#"{"string":"hi"}"#.utf8))
        #expect(s == .string("hi"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败** `swift test --filter "FakeAXBackendTests|AXNodeTests"` → 编译错误。
- [ ] **Step 3: 实现 `AXNode.swift` 与 `FakeAXBackend.swift`**（完整代码见实现提交；要点：`AXNode` 所有属性有默认值的 memberwise `init`；`AXNodeValue` 手写 `Codable`，单键对象；fake 内部 `FakeNode` 类（`attributes: [String: AXAttributeValue]`, `settable: Set<String>`, `actions: [String]`, `children: [Int]`, `parent: Int?`），`init(root:)` 递归展开分配 Int id。）
- [ ] **Step 4: 跑测试** → PASS。
- [ ] **Step 5: 提交** `git commit -m "feat(axkit): add AXNode snapshot and FakeAXBackend"`

### Task 4: `AXTreeDumper`（AXElement → AXNode）与 fake 往返测试

**Files:**
- Create: `Sources/AXKit/AXTreeDumper.swift`
- Test: `Tests/AXKitTests/AXTreeDumperTests.swift`

**Interfaces:**
- Produces:

```swift
public struct AXTreeDumper {
    public var maxDepth: Int          // 根为深度 0；children 超过 maxDepth 时 truncated = true
    public var maxChildren: Int       // 每节点最多展开数，超出 truncated = true
    public var extraAttributes: [String]   // 额外读入 extra（如 AXSelectedRows）
    public init(maxDepth: Int = 12, maxChildren: Int = 400, extraAttributes: [String] = [])
    public func dump(_ element: AXElement) -> AXNode   // 尽力而为：单属性错误 → 字段 nil；不抛
    public struct Stats { public var nodes: Int; public var errors: Int; public var truncated: Int }
    public func dumpWithStats(_ element: AXElement) -> (node: AXNode, stats: Stats)
}
```

- [ ] **Step 1: 写失败测试**

```swift
// Tests/AXKitTests/AXTreeDumperTests.swift
import Testing
@testable import AXKit

@Suite("AXTreeDumper")
struct AXTreeDumperTests {
    @Test func dumpOfFakeReproducesSourceTree() {
        let source = SampleTree.make()
        let fake = FakeAXBackend(root: source)
        let dumped = AXTreeDumper(extraAttributes: ["AXSelectedRows"]).dump(fake.rootElement)
        #expect(dumped == source)
    }

    @Test func depthAndChildLimitsMarkTruncation() {
        let fake = FakeAXBackend(root: SampleTree.make())
        let shallow = AXTreeDumper(maxDepth: 1).dump(fake.rootElement)
        #expect(shallow.children.count == 1)
        #expect(shallow.children[0].children.isEmpty)
        #expect(shallow.children[0].truncated)
        let narrow = AXTreeDumper(maxChildren: 2).dump(fake.rootElement)
        #expect(narrow.children[0].children.count == 2)
        #expect(narrow.children[0].truncated)
    }

    @Test func attributeErrorsBecomeNilAndAreCounted() {
        let fake = FakeAXBackend(root: SampleTree.make())
        fake.injectedFailures["get:AXTitle"] = .cannotComplete("title")
        let (node, stats) = AXTreeDumper().dumpWithStats(fake.rootElement)
        #expect(node.title == nil)
        #expect(stats.nodes == 7)
        #expect(stats.errors >= 1)
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS。** 注意往返相等要求 dumper 只在属性"存在"时写字段（`attributeUnsupported` → nil 且不计 error；其他错误计 error），`actions`/`settable` 用 `actionNames` 与对已知可设属性列表 `[AXValue, AXSelectedRows, AXSelectedChildren, AXFocused, AXSelectedText, AXMinimized, AXHidden]` 逐个 `isAttributeSettable`。
- [ ] **Step 3: 提交** `git commit -m "feat(axkit): add AXTreeDumper with fake round-trip tests"`

### Task 5: `LiveAXBackend`、`AXApp`、`AXPermission` 与 live 测试

**Files:**
- Create: `Sources/AXKit/LiveAXBackend.swift`
- Create: `Sources/AXKit/AXApp.swift`
- Create: `Sources/AXKit/AXPermission.swift`
- Test: `Tests/AXKitTests/LiveAXBackendTests.swift`

**Interfaces:**
- Produces:

```swift
public final class LiveAXBackend: AXBackend {
    public init(messagingTimeoutSeconds: Float = 2)
}
public enum AXApp {
    public static func runningApplication(bundleID: String) -> NSRunningApplication?
    public static func byBundleID(_ bundleID: String, backend: AXBackend) throws -> AXElement   // .applicationNotRunning
    public static func byPID(_ pid: pid_t, backend: AXBackend) -> AXElement
}
public enum AXPermission {
    public static func isTrusted(prompt: Bool = false, backend: AXBackend) -> Bool
    public static var accessibilitySettingsURL: URL?   // x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility
}
```

Live 实现要点：
- 句柄：`final class LiveRef: Hashable { let element: AXUIElement }`，`==` 用 `CFEqual`，`hash` 用 `CFHash`。
- `applicationElement(pid:)`：`AXUIElementCreateApplication` + `AXUIElementSetMessagingTimeout`。
- 错误映射：`.success`→继续；`.noValue`→返回 nil；`.attributeUnsupported`/`.parameterizedAttributeUnsupported`→`attributeUnsupported`；`.actionUnsupported`；`.cannotComplete`；`.invalidUIElement`→`invalidElement`；`.apiDisabled`→`notTrusted`；`.notImplemented`；其余 `apiFailure(code:operation:)`。
- CFTypeRef→值：按 `CFGetTypeID` 分派到 `AXUIElementGetTypeID / CFStringGetTypeID / CFBooleanGetTypeID / CFNumberGetTypeID / CFArrayGetTypeID / AXValueGetTypeID / CFURLGetTypeID / CFAttributedStringGetTypeID`，其余 `.unknown(CFCopyTypeIDDescription)`。
- 值→CFTypeRef：逆映射；`AXValueCreate` 处理 point/size/rect/range；`.unknown` 抛 `valueNotConvertible`。

- [ ] **Step 1: 写 live 测试（默认跳过）**

```swift
// Tests/AXKitTests/LiveAXBackendTests.swift
import Foundation
import Testing
@testable import AXKit

let liveEnabled = ProcessInfo.processInfo.environment["IMCTL_LIVE"] == "1"
let liveBundleID = ProcessInfo.processInfo.environment["IMCTL_LIVE_BUNDLE"] ?? "com.apple.finder"

@Suite("LiveAXBackend (IMCTL_LIVE=1)", .enabled(if: liveEnabled))
struct LiveAXBackendTests {
    @Test func trustCheckDoesNotPrompt() {
        let backend = LiveAXBackend()
        _ = backend.isProcessTrusted(prompt: false)
    }

    @Test func applicationElementReadsRoleAndChildren() throws {
        let backend = LiveAXBackend()
        try #require(backend.isProcessTrusted(prompt: false), "grant Accessibility to the test runner first")
        let app = try AXApp.byBundleID(liveBundleID, backend: backend)
        #expect(try app.role() == AXRole.application)
        #expect(try app.pid() > 0)
        let (node, stats) = AXTreeDumper(maxDepth: 2).dumpWithStats(app)
        #expect(node.role == AXRole.application)
        #expect(stats.nodes >= 1)
    }

    @Test func unknownBundleThrows() {
        #expect(throws: AXKitError.applicationNotRunning(bundleID: "com.example.nope")) {
            try AXApp.byBundleID("com.example.nope", backend: LiveAXBackend())
        }
    }
}
```

- [ ] **Step 2: 实现三文件；`swift test`（无 IMCTL_LIVE）全绿且 live 套件显示 skipped。**
- [ ] **Step 3: `IMCTL_LIVE=1 swift test --filter LiveAXBackendTests`** 记录结果（测试进程未授权则 `applicationElementReadsRoleAndChildren` 以 require 失败，属预期；S4 解决签名与授权）。
- [ ] **Step 4: 提交** `git commit -m "feat(axkit): add LiveAXBackend, AXApp and AXPermission with gated live tests"`

## Self-Review

- 规格覆盖：`AXElement` 的 attribute/setAttribute/perform/children/role/title/value/frame（T2）、`AXApp.byBundleID`（T5）、`AXPermission.isTrusted(prompt:)`（T5）、`AXBackend` + `FakeAXBackend`（T2/T3）、live 门控（T5）；AXObserver 桥接按路线属 S6，不在本计划。
- 类型一致：`AXNodeValue` 在 T3 定义，T4 dumper 写入 `value: AXNodeValue?`；`injectedFailures` 键格式 `get:<attr>` / `get:*` / `set:<attr>` / `action:<name>` 在 T3、T4 一致。
- 无占位：T2、T3 "完整代码见实现提交"指同一提交内文件，接口签名已在本文列全。

## 执行结果（2026-09-11）

- 全部 5 个任务完成，`swift test` 22 个测试通过（live 套件在无 `IMCTL_LIVE` 时显示 skipped）。
- `IMCTL_LIVE=1 swift test --filter LiveAXBackendTests`：`unknownBundleThrows`、`trustCheckDoesNotPrompt` 通过；`applicationElementReadsRoleAndChildren` 在 `#require(isProcessTrusted)` 处失败——测试宿主进程（Xcode `xctest`）未获辅助功能授权，属预期。S4 处理签名与授权；真实 live 验证以签名后的 `imctl` 二进制为准。
- 偏离计划：CF 类型不能条件转型（编译器报 "will always succeed"），`LiveAXBackend.convert` 在 `CFGetTypeID` 守卫后使用 `as!`，文件内有注释说明。
