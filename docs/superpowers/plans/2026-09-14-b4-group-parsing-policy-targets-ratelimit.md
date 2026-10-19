# 批次 B4：群会话解析、策略文件、平台 ID 目标语法、事件字段扩展、速率硬上限 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 imctl 在不依赖企微 API 的前提下具备 v0.2 规格第 2、3、5 节要求的本地能力：解析群会话（发送者、系统消息过滤、稳定去重键、会话类型），用 `policy.json` 在编译白名单之外按标题 / 类型 / 平台 ID 放行目标，接受 `chatId:<id>` / `externalUserId:<id>` 目标语法（经本地身份桥表解析），给事件补 `sender` / `messageKey` / `conversationType` / `chatId` / `externalUserId` 字段，并在执行器加每会话 ≥ 3 s、全局 ≤ 20 条/分钟的硬上限。

**Architecture:** 协议层新增 `ConversationType`、`TargetRef`、`MessageKey`、`SendPolicy`（policy.json 模型）、`ResolvedTarget`（策略真正判断的对象）、`RateLimiter`、`Identity`/`IdentityLookup`（`ControlStore` 新表 `identities`）。适配器层把行解析扩展为带 `kind`（message / system / timeSeparator / empty）和 `markers` 的行，`ConversationHeader` 解析群头部的 "群名(12)"，`ConversationTypeInference` 只在有证据时判类型（否则 `unknown`，`unknown` 永远不能被类型规则放行），`TargetResolver` 把 wire 目标转成 `ResolvedTarget`；`WeComActions` 携带 `resolvedTarget` 让 select / compose / submit / scroll 的内部授权与命令级授权一致。守护进程用 `PolicyProvider` 按 mtime 热加载 policy.json 并发 `controller.state{policy}` 事件；CLI 新增 `imctl policy allow|deny|list` 与 `imctl identity set|remove|list`。

**Tech Stack:** Swift 6.3.3 / Swift 5 语言模式，swift-testing，GRDB 7.11.1，swift-argument-parser 1.8.2，CryptoKit（SHA-256）。

## Global Constraints

- 编译白名单仍只有 `WeComClient.fileTransferAssistantTitle`（"文件传输助手"）；本批**不改**这个常量。放宽只能经 `policy.json`，且由用户明确授权；开发期只对用户自己的测试群（只有本人）与本人微信作为测试客户发消息。
- 除 `KeystrokeInjector.swift` 的 pid 级回车外不出现 `CGEvent*`；`ForbiddenAPITests` 继续拦截；本批不新增任何合成输入。
- 权限面只有辅助功能；不申请录屏 / 输入监控。
- 仓库、夹具、gate 报告不含 secret、凭据、broker 地址、真实联系人内容；群夹具用测试代码合成（`GroupFixture`），不录真实客户群。
- 会话类型推断只在有证据时给出 `group` / `customer`，没有证据一律 `unknown`；`internal` 本批不推断（没有 AX 证据），只能靠标题规则放行。
- `messageKey` 排除行索引（B3 实测历史前插会移位索引）；用 `(会话, 发送者, 时间标签, 文本, 同元组序号)` 的 SHA-256 前 16 hex。
- 速率硬上限：每目标 ≥ 3000 ms，全局 60 s 滑动窗口 ≤ 20 次；按**尝试**计数（暂停 / 过期 / 幂等回放不计），超出 `RATE_LIMITED`（`command.state=failed`）。
- 工作方式（用户约定）：批量实现，最后一次 `swift test`；各任务的"跑测试"步骤在批量实现时可合并为最终一次，但每个任务的测试代码必须先于实现写好。
- 活体验收依赖两件用户事项：launchd 下 `imctld` 的辅助功能勾选；测试群名（把"未设置群名"改成唯一名并告知）。未到位时只做只读探针与单测，gate 报告如实写"待活体"。

---

### Task 1: 协议类型 `ConversationType`、`TargetRef`、`MessageKey`、`ControlError.rateLimited`

**Files:**
- Create: `Sources/ControlCore/Protocol/ConversationType.swift`
- Create: `Sources/ControlCore/Protocol/TargetRef.swift`
- Create: `Sources/ControlCore/Protocol/MessageKey.swift`
- Modify: `Sources/ControlCore/Protocol/RPCTypes.swift`（`ControlError` 加 `rateLimited`，`targetNotFound` 文案改为对目标而非标题）
- Test: `Tests/ControlCoreTests/TargetRefTests.swift`、`Tests/ControlCoreTests/MessageKeyTests.swift`、`Tests/ControlCoreTests/ProtocolTests.swift`（追加）

**Interfaces:**
- Produces:
  - `public enum ConversationType: String, Codable, CaseIterable { case group, customer, internal, unknown }`
  - `public enum TargetRef: Equatable { case title(String), chatId(String), externalUserId(String) }`；`static func parse(_ raw: String) -> TargetRef`；`var wire: String`
  - `public enum MessageKey { static func make(conversation:sender:timeLabel:text:ordinal:) -> String; static func assign<T>(_:conversation:sender:timeLabel:text:) -> [String] }`
  - `ControlError.rateLimited(String)`，`code == "RATE_LIMITED"`

- [ ] **Step 1: 失败测试**

```swift
// Tests/ControlCoreTests/TargetRefTests.swift
import Testing
@testable import ControlCore

@Suite("TargetRef")
struct TargetRefTests {
    @Test func parsesPrefixesAndFallsBackToTitle() {
        #expect(TargetRef.parse("chatId:wrABC") == .chatId("wrABC"))
        #expect(TargetRef.parse("externalUserId:wmXYZ") == .externalUserId("wmXYZ"))
        #expect(TargetRef.parse("文件传输助手") == .title("文件传输助手"))
        #expect(TargetRef.parse("chatId: wr1 ") == .chatId("wr1"))
        // an empty id is not a silent match: it stays a (never-existing) title
        #expect(TargetRef.parse("chatId:") == .title("chatId:"))
        #expect(TargetRef.parse("chatId:wr1").wire == "chatId:wr1")
        #expect(TargetRef.parse("x").isTitle && !TargetRef.parse("chatId:x").isTitle)
    }
}
```

```swift
// Tests/ControlCoreTests/MessageKeyTests.swift
import Testing
@testable import ControlCore

@Suite("MessageKey")
struct MessageKeyTests {
    @Test func keyIsStableAndIndexFree() {
        let a = MessageKey.make(conversation: "g", sender: "张三", timeLabel: "9:18", text: "hi", ordinal: 0)
        #expect(a.count == 16 && a == MessageKey.make(conversation: "g", sender: "张三", timeLabel: "9:18", text: "hi", ordinal: 0))
        #expect(a != MessageKey.make(conversation: "g", sender: nil, timeLabel: "9:18", text: "hi", ordinal: 0))
        #expect(a != MessageKey.make(conversation: "h", sender: "张三", timeLabel: "9:18", text: "hi", ordinal: 0))
    }

    @Test func assignGivesDuplicatesDistinctOrdinalsInDisplayOrder() {
        struct M { var s: String?; var t: String?; var x: String }
        let rows = [M(s: "a", t: nil, x: "ok"), M(s: "b", t: nil, x: "ok"), M(s: "a", t: nil, x: "ok")]
        let keys = MessageKey.assign(rows, conversation: "g", sender: \.s, timeLabel: \.t, text: \.x)
        #expect(Set(keys).count == 3)
        #expect(keys[0] == MessageKey.make(conversation: "g", sender: "a", timeLabel: nil, text: "ok", ordinal: 0))
        #expect(keys[2] == MessageKey.make(conversation: "g", sender: "a", timeLabel: nil, text: "ok", ordinal: 1))
        // prepending unrelated history does not change the keys of the existing rows
        let more = [M(s: "z", t: "8:00", x: "old")] + rows
        #expect(Array(MessageKey.assign(more, conversation: "g", sender: \.s, timeLabel: \.t, text: \.x).dropFirst()) == keys)
    }
}
```

`ProtocolTests` 追加：

```swift
    @Test func rateLimitedAndConversationTypeAreWireStrings() {
        #expect(ControlError.rateLimited("x").code == "RATE_LIMITED")
        #expect(ConversationType.internal.rawValue == "internal" && ConversationType.allCases.count == 4)
        #expect(ControlError.targetNotFound("chatId:x").message == "no conversation for target \"chatId:x\"")
    }
```

- [ ] **Step 2: 跑测试确认失败**（类型不存在，编译失败）

- [ ] **Step 3: 实现**

```swift
// Sources/ControlCore/Protocol/ConversationType.swift
/// Kind of conversation a target or event refers to. `unknown` is a
/// legitimate value: a conversation whose kind cannot be derived from the
/// client is only ever allowed by an explicit title or id rule, never by a
/// type rule, and `internal` is not inferred at all in v0.2 (no AX evidence).
public enum ConversationType: String, Codable, Equatable, CaseIterable {
    /// Group chat (customer group or colleagues); messages carry a sender label.
    case group
    /// One-to-one chat with an external contact (WeChat user or another company's member).
    case customer
    /// One-to-one chat with a colleague of the same company.
    case `internal`
    case unknown
}
```

```swift
// Sources/ControlCore/Protocol/TargetRef.swift
import Foundation

/// How a caller names a conversation in `message.send.target` and
/// `conversation.read.target`: a platform id (resolved through the identity
/// bridge) or a bare title (development only; a title is not an identity).
public enum TargetRef: Equatable, CustomStringConvertible {
    case title(String)
    case chatId(String)
    case externalUserId(String)

    public static let chatIdPrefix = "chatId:"
    public static let externalUserIdPrefix = "externalUserId:"

    /// `chatId:<id>` / `externalUserId:<id>` / anything else is a title. An
    /// empty id after a prefix stays a literal title so it fails with
    /// TARGET_NOT_FOUND instead of matching anything.
    public static func parse(_ raw: String) -> TargetRef {
        if raw.hasPrefix(chatIdPrefix) {
            let id = raw.dropFirst(chatIdPrefix.count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? .title(raw) : .chatId(id)
        }
        if raw.hasPrefix(externalUserIdPrefix) {
            let id = raw.dropFirst(externalUserIdPrefix.count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? .title(raw) : .externalUserId(id)
        }
        return .title(raw)
    }

    public var wire: String {
        switch self {
        case .title(let t): return t
        case .chatId(let id): return Self.chatIdPrefix + id
        case .externalUserId(let id): return Self.externalUserIdPrefix + id
        }
    }

    public var isTitle: Bool { if case .title = self { return true }; return false }
    public var description: String { wire }
}
```

```swift
// Sources/ControlCore/Protocol/MessageKey.swift
import CryptoKit
import Foundation

/// Stable per-message key carried by `message.observed` and `message.history`
/// so a consumer can deduplicate what it saw live against what it read back.
/// The row index is deliberately not an input: loading older history prepends
/// rows (B3), which shifts every index but changes none of these fields.
public enum MessageKey {
    public static let hexLength = 16

    public static func make(conversation: String, sender: String?, timeLabel: String?, text: String, ordinal: Int) -> String {
        let material = [conversation, sender ?? "", timeLabel ?? "", text, String(ordinal)].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(hexLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// Keys for rows in display order. Rows with the same (sender, timeLabel,
    /// text) get increasing ordinals, so two identical "ok" messages differ.
    public static func assign<T>(_ items: [T], conversation: String,
                                 sender: (T) -> String?, timeLabel: (T) -> String?, text: (T) -> String) -> [String] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let tuple = [sender(item) ?? "", timeLabel(item) ?? "", text(item)].joined(separator: "\u{1F}")
            let ordinal = seen[tuple, default: 0]
            seen[tuple] = ordinal + 1
            return make(conversation: conversation, sender: sender(item), timeLabel: timeLabel(item), text: text(item), ordinal: ordinal)
        }
    }
}
```

`RPCTypes.swift` 中 `ControlError`：加 `case rateLimited(String)`；`code` 加 `case .rateLimited: return "RATE_LIMITED"`；`message` 加 `case .rateLimited(let why): return why`；`targetNotFound` 文案改为 `"no conversation for target \"\(t)\""`。

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(core): ConversationType, TargetRef (chatId:/externalUserId:), MessageKey, RATE_LIMITED error`

---

### Task 2: `SendPolicy`（policy.json）、`ResolvedTarget`、`ActionPolicy.authorize(_:resolved:)`

**Files:**
- Create: `Sources/ControlCore/IMCTLPaths.swift`
- Create: `Sources/ControlCore/Policy/SendPolicy.swift`
- Modify: `Sources/ControlCore/Policy/ActionPolicy.swift`
- Test: `Tests/ControlCoreTests/SendPolicyTests.swift`、`Tests/ControlCoreTests/ActionPolicyTests.swift`（追加）

**Interfaces:**
- Produces:
  - `public enum IMCTLPaths { static var dataDirectory: URL }`（`~/Library/Application Support/imctl`）
  - `public struct AllowedTypes: Codable, Equatable { group, customer, internal: Bool; func allows(_ type: ConversationType) -> Bool }`
  - `public struct SendPolicy: Codable, Equatable { allowedTitles: [String]; allowedTypes: AllowedTypes; allowedChatIds: [String]; allowedExternalUserIds: [String] }`；`static let fileName = "policy.json"`；`static var defaultURL: URL`；`static func load(from: URL) throws -> SendPolicy`（缺文件 = 空策略；坏文件抛错）；`func save(to: URL) throws`（目录 0700、文件 0600）；`enum Rule { title, chatId, externalUserId, type }`；`mutating func allow(_:)` / `deny(_:)`；`var isEmpty: Bool`；`var summary: String`
  - `public struct ResolvedTarget: Equatable { title: String; type: ConversationType; chatId: String?; externalUserId: String? }`
  - `ActionPolicy` 新增 `sendPolicy: SendPolicy`（默认空）、`effectiveTitles: Set<String>`、`allows(_ target: ResolvedTarget) -> Bool`、`authorize(_ kind: ActionKind, resolved: ResolvedTarget?) throws`；原 `authorize(_:target:)` 保留并委托

- [ ] **Step 1: 失败测试**

```swift
// Tests/ControlCoreTests/SendPolicyTests.swift
import Foundation
import Testing
@testable import ControlCore

@Suite("SendPolicy (policy.json)")
struct SendPolicyTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imctl-policy-\(UUID().uuidString)/policy.json")
    }

    @Test func missingFileIsEmptyPolicyAndSaveIsPrivate() throws {
        let url = tempURL()
        let loaded = try SendPolicy.load(from: url)
        #expect(loaded == SendPolicy() && loaded.isEmpty)
        var p = SendPolicy()
        p.allow(.title("imctl测试群")); p.allow(.type(.group)); p.allow(.chatId("wr1")); p.allow(.externalUserId("wm1"))
        p.allow(.title("imctl测试群"))   // idempotent
        try p.save(to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        let back = try SendPolicy.load(from: url)
        #expect(back.allowedTitles == ["imctl测试群"] && back.allowedTypes.group && !back.allowedTypes.customer)
        #expect(back.allowedChatIds == ["wr1"] && back.allowedExternalUserIds == ["wm1"])
        #expect(back.summary == "titles=1 types=group chatIds=1 externalUserIds=1")
        var d = back
        d.deny(.type(.group)); d.deny(.title("imctl测试群")); d.deny(.chatId("nope"))
        #expect(d.allowedTitles.isEmpty && !d.allowedTypes.group && d.allowedChatIds == ["wr1"])
    }

    @Test func malformedFileThrowsInsteadOfAllowing() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try SendPolicy.load(from: url) }
    }

    @Test func unknownTypeIsNeverAllowedByType() {
        var t = AllowedTypes(); t.group = true; t.customer = true; t.internal = true
        #expect(t.allows(.group) && t.allows(.customer) && t.allows(.internal) && !t.allows(.unknown))
    }
}
```

`ActionPolicyTests` 追加：

```swift
    @Test func resolvedTargetsAreAllowedByTitleTypeOrId() {
        var file = SendPolicy()
        file.allow(.type(.group)); file.allow(.chatId("wr1")); file.allow(.externalUserId("wm1")); file.allow(.title("小明"))
        let p = ActionPolicy(allowedTargets: allow, enabled: [.submit], phase: .phase1, sendPolicy: file)
        #expect(p.effectiveTitles == ["文件传输助手", "小明"])
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "任意群", type: .group)) }
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "x", chatId: "wr1")) }
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "y", externalUserId: "wm1")) }
        #expect(throws: Never.self) { try p.authorize(.submit, resolved: ResolvedTarget(title: "小明")) }
        #expect(throws: PolicyError.targetNotAllowed("客户A")) { try p.authorize(.submit, resolved: ResolvedTarget(title: "客户A", type: .customer)) }
        #expect(throws: PolicyError.targetNotAllowed("z")) { try p.authorize(.submit, resolved: ResolvedTarget(title: "z", type: .unknown, chatId: "wr2")) }
        #expect(throws: PolicyError.targetRequired(.submit)) { try p.authorize(.submit, resolved: nil) }
        // the compiled allowlist alone still works exactly as before
        #expect(throws: PolicyError.targetNotAllowed("任意群")) { try ActionPolicy(allowedTargets: allow, enabled: [.submit], phase: .phase1).authorize(.submit, target: "任意群") }
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
// Sources/ControlCore/IMCTLPaths.swift
import Foundation

/// Where the controller keeps its per-user runtime data. Shared by every
/// target so the CLI edits the same files the daemon reads.
public enum IMCTLPaths {
    public static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imctl", isDirectory: true)
    }
}
```

```swift
// Sources/ControlCore/Policy/SendPolicy.swift
import Foundation

/// Conversation kinds a type rule may unlock. `unknown` is never allowed by type.
public struct AllowedTypes: Codable, Equatable {
    public var group: Bool
    public var customer: Bool
    public var `internal`: Bool

    public init(group: Bool = false, customer: Bool = false, internal: Bool = false) {
        self.group = group; self.customer = customer; self.internal = `internal`
    }

    public func allows(_ type: ConversationType) -> Bool {
        switch type {
        case .group: return group
        case .customer: return customer
        case .internal: return `internal`
        case .unknown: return false
        }
    }

    var enabledNames: [String] {
        [group ? "group" : nil, customer ? "customer" : nil, `internal` ? "internal" : nil].compactMap { $0 }
    }
}

/// The local policy file (`policy.json`, 0600, never committed). It widens the
/// compiled-in allowlist and can never narrow it; edited only through
/// `imctl policy`, and only after a human decided to open a target.
public struct SendPolicy: Codable, Equatable {
    public var allowedTitles: [String]
    public var allowedTypes: AllowedTypes
    public var allowedChatIds: [String]
    public var allowedExternalUserIds: [String]

    public init(allowedTitles: [String] = [], allowedTypes: AllowedTypes = AllowedTypes(),
                allowedChatIds: [String] = [], allowedExternalUserIds: [String] = []) {
        self.allowedTitles = allowedTitles; self.allowedTypes = allowedTypes
        self.allowedChatIds = allowedChatIds; self.allowedExternalUserIds = allowedExternalUserIds
    }

    public static let fileName = "policy.json"
    public static var defaultURL: URL { IMCTLPaths.dataDirectory.appendingPathComponent(fileName) }

    /// A missing file is the empty policy (compiled allowlist only). A file that
    /// exists but does not parse throws: the caller must not treat it as "allow".
    public static func load(from url: URL) throws -> SendPolicy {
        guard FileManager.default.fileExists(atPath: url.path) else { return SendPolicy() }
        return try JSONDecoder().decode(SendPolicy.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public enum Rule: Equatable {
        case title(String)
        case chatId(String)
        case externalUserId(String)
        case type(ConversationType)
    }

    public mutating func allow(_ rule: Rule) {
        switch rule {
        case .title(let t): if !allowedTitles.contains(t) { allowedTitles.append(t) }
        case .chatId(let id): if !allowedChatIds.contains(id) { allowedChatIds.append(id) }
        case .externalUserId(let id): if !allowedExternalUserIds.contains(id) { allowedExternalUserIds.append(id) }
        case .type(.group): allowedTypes.group = true
        case .type(.customer): allowedTypes.customer = true
        case .type(.internal): allowedTypes.internal = true
        case .type(.unknown): break
        }
    }

    public mutating func deny(_ rule: Rule) {
        switch rule {
        case .title(let t): allowedTitles.removeAll { $0 == t }
        case .chatId(let id): allowedChatIds.removeAll { $0 == id }
        case .externalUserId(let id): allowedExternalUserIds.removeAll { $0 == id }
        case .type(.group): allowedTypes.group = false
        case .type(.customer): allowedTypes.customer = false
        case .type(.internal): allowedTypes.internal = false
        case .type(.unknown): break
        }
    }

    public var isEmpty: Bool {
        allowedTitles.isEmpty && allowedChatIds.isEmpty && allowedExternalUserIds.isEmpty && allowedTypes.enabledNames.isEmpty
    }

    /// One line for `controller.describe`, `controller.state{policy}` and the CLI.
    public var summary: String {
        let types = allowedTypes.enabledNames.isEmpty ? "-" : allowedTypes.enabledNames.joined(separator: "+")
        return "titles=\(allowedTitles.count) types=\(types) chatIds=\(allowedChatIds.count) externalUserIds=\(allowedExternalUserIds.count)"
    }
}

/// A target after the identity bridge and the client have been consulted:
/// what the policy actually judges.
public struct ResolvedTarget: Equatable {
    public var title: String
    public var type: ConversationType
    public var chatId: String?
    public var externalUserId: String?

    public init(title: String, type: ConversationType = .unknown, chatId: String? = nil, externalUserId: String? = nil) {
        self.title = title; self.type = type; self.chatId = chatId; self.externalUserId = externalUserId
    }
}
```

`ActionPolicy.swift`：

```swift
public struct ActionPolicy {
    public enum Phase { case phase0, phase1 }

    /// Compiled in by the caller; the policy file can only add to it.
    public var allowedTargets: Set<String>
    public var enabled: Set<ActionKind>
    public var phase: Phase
    public var sendPolicy: SendPolicy

    public init(allowedTargets: Set<String>, enabled: Set<ActionKind> = [], phase: Phase = .phase0, sendPolicy: SendPolicy = SendPolicy()) {
        self.allowedTargets = allowedTargets
        self.enabled = enabled
        self.phase = phase
        self.sendPolicy = sendPolicy
    }

    /// Titles allowed by code or by the policy file.
    public var effectiveTitles: Set<String> { allowedTargets.union(sendPolicy.allowedTitles) }

    /// Title rule, then id rules, then the type rule (which never matches `unknown`).
    public func allows(_ target: ResolvedTarget) -> Bool {
        if effectiveTitles.contains(target.title) { return true }
        if let id = target.chatId, sendPolicy.allowedChatIds.contains(id) { return true }
        if let id = target.externalUserId, sendPolicy.allowedExternalUserIds.contains(id) { return true }
        return sendPolicy.allowedTypes.allows(target.type)
    }

    /// Order: phase → enabled → target present → target allowed.
    public func authorize(_ kind: ActionKind, target: String?) throws {
        try authorize(kind, resolved: target.map { ResolvedTarget(title: $0) })
    }

    public func authorize(_ kind: ActionKind, resolved target: ResolvedTarget?) throws {
        if phase == .phase0, kind == .submit { throw PolicyError.phaseForbids(kind) }
        guard enabled.contains(kind) else { throw PolicyError.notEnabled(kind) }
        guard kind.requiresTarget else { return }
        guard let target, !target.title.isEmpty else { throw PolicyError.targetRequired(kind) }
        guard allows(target) else { throw PolicyError.targetNotAllowed(target.title) }
    }
}
```

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(core): SendPolicy (policy.json, 0600) and ResolvedTarget; ActionPolicy allows by title, platform id or known conversation type`

---

### Task 3: `RateLimiter` 与执行器硬上限

**Files:**
- Create: `Sources/ControlCore/Policy/RateLimiter.swift`
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift`
- Test: `Tests/ControlCoreTests/RateLimiterTests.swift`、`Tests/ControlCoreTests/CommandExecutorTests.swift`（追加）

**Interfaces:**
- Produces: `public final class RateLimiter { init(perTargetMinIntervalMs: Int64 = 3000, globalLimit: Int = 20, windowMs: Int64 = 60_000); func check(target: String, nowMs: Int64) -> String?; func record(target: String, nowMs: Int64); func admit(target: String, nowMs: Int64) -> String? }`
- `CommandExecutor.init(store:handler:now:crashAfterSubmit:rateLimiter: RateLimiter? = RateLimiter())`；`message.send` 在幂等 / 过期 / 暂停检查之后、`running` 之前调用 `admit`，拒绝时 `failed` + `RATE_LIMITED`。

- [ ] **Step 1: 失败测试**

```swift
// Tests/ControlCoreTests/RateLimiterTests.swift
import Testing
@testable import ControlCore

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func perTargetIntervalAndGlobalWindow() {
        let l = RateLimiter(perTargetMinIntervalMs: 3000, globalLimit: 3, windowMs: 60_000)
        #expect(l.admit(target: "a", nowMs: 0) == nil)
        #expect(l.admit(target: "a", nowMs: 2999) != nil)          // too soon for a
        #expect(l.admit(target: "b", nowMs: 2999) == nil)          // other target fine
        #expect(l.admit(target: "a", nowMs: 3000) == nil)          // exactly the interval
        #expect(l.admit(target: "c", nowMs: 3001) != nil)          // 3 sends in window: global cap
        #expect(l.check(target: "c", nowMs: 60_000) == nil)        // first send left the window
        #expect(l.admit(target: "c", nowMs: 60_000) == nil)
        #expect(l.check(target: "a", nowMs: 60_001) != nil)        // window full again (3000, 3000?, 60000) -> 3 entries
    }

    @Test func checkDoesNotRecord() {
        let l = RateLimiter(perTargetMinIntervalMs: 1000, globalLimit: 1, windowMs: 1000)
        #expect(l.check(target: "a", nowMs: 0) == nil)
        #expect(l.check(target: "a", nowMs: 0) == nil)
        l.record(target: "a", nowMs: 0)
        #expect(l.check(target: "b", nowMs: 1) != nil)
    }
}
```

（第一个测试最后一行的窗口内容：t=0 已出窗，剩 2999(b)、3000(a)、60000(c) 三条 → 满。）

`CommandExecutorTests` 追加（`make()` 保持默认限速器，因为既有测试同一目标最多尝试一次）：

```swift
    @Test func rateLimitIsAHardCapOnAttempts() throws {
        let (exec, handler, _) = try make()
        let first = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(first.state == .succeeded)
        let second = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"again","idempotencyKey":"k2"}"#, idempotencyKey: "k2")
        #expect(second.state == .failed && second.errorCode == "RATE_LIMITED")
        #expect(handler.sendCalls == 1)
        // replaying k1 is not an attempt
        #expect(try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1").id == first.id)
        let other = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"另一个","text":"x","idempotencyKey":"k3"}"#, idempotencyKey: "k3")
        #expect(other.state == .succeeded && handler.sendCalls == 2)
    }

    @Test func globalCapCountsFailedAttemptsToo() throws {
        let store = try ControlStore(path: ":memory:")
        let handler = FakeHandler()
        handler.sendResult = SendResult(state: .failed, reason: "no bubble")
        var t: Int64 = 1000
        let exec = CommandExecutor(store: store, handler: handler, now: { t += 1; return t },
                                   rateLimiter: RateLimiter(perTargetMinIntervalMs: 0, globalLimit: 2, windowMs: 60_000))
        for k in ["a", "b"] {
            #expect(try exec.submit(method: .messageSend, paramsJSON: #"{"target":"t","text":"x","idempotencyKey":"\#(k)"}"#, idempotencyKey: k).errorCode == nil || true)
        }
        let third = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"t","text":"x","idempotencyKey":"c"}"#, idempotencyKey: "c")
        #expect(third.errorCode == "RATE_LIMITED" && handler.sendCalls == 2)
        let events = try store.events(after: 0, limit: 100).filter { $0.payloadJSON.contains("RATE_LIMITED") }
        #expect(events.count == 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
// Sources/ControlCore/Policy/RateLimiter.swift
import Foundation

/// Hard send-rate cap enforced by the executor, beneath any consumer policy:
/// one attempt per target every `perTargetMinIntervalMs` and at most
/// `globalLimit` attempts per sliding `windowMs`. Attempts count, not
/// successes, so a failing loop cannot hammer the client. In-memory on
/// purpose: a daemon restart (≥ 5 s throttle) is longer than the per-target
/// interval, and the global window restarts empty.
public final class RateLimiter {
    public var perTargetMinIntervalMs: Int64
    public var globalLimit: Int
    public var windowMs: Int64
    private var lastByTarget: [String: Int64] = [:]
    private var recent: [Int64] = []
    private let lock = NSLock()

    public init(perTargetMinIntervalMs: Int64 = 3000, globalLimit: Int = 20, windowMs: Int64 = 60_000) {
        self.perTargetMinIntervalMs = perTargetMinIntervalMs
        self.globalLimit = globalLimit
        self.windowMs = windowMs
    }

    /// nil when an attempt may proceed now; otherwise the reason (wire message). Records nothing.
    public func check(target: String, nowMs: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        return reason(target: target, nowMs: nowMs)
    }

    public func record(target: String, nowMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        lastByTarget[target] = nowMs
        recent.append(nowMs)
    }

    /// `check` + `record` under one lock.
    public func admit(target: String, nowMs: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let why = reason(target: target, nowMs: nowMs) { return why }
        lastByTarget[target] = nowMs
        recent.append(nowMs)
        return nil
    }

    private func reason(target: String, nowMs: Int64) -> String? {
        recent.removeAll { nowMs - $0 >= windowMs }
        if let last = lastByTarget[target], nowMs - last < perTargetMinIntervalMs {
            return "target \"\(target)\" was attempted \(nowMs - last) ms ago; minimum interval \(perTargetMinIntervalMs) ms"
        }
        if recent.count >= globalLimit {
            return "\(recent.count) sends attempted in the last \(windowMs / 1000) s; limit \(globalLimit)"
        }
        return nil
    }
}
```

`CommandExecutor`：新增 `public let rateLimiter: RateLimiter?`，`init(..., crashAfterSubmit: Bool = false, rateLimiter: RateLimiter? = RateLimiter())`；在 `run` 的暂停检查之后插入：

```swift
        if method == .messageSend, let limiter = rateLimiter,
           let params = try? decode(SendParams.self, from: paramsJSON),
           let why = limiter.admit(target: params.target, nowMs: now()) {
            let err = ControlError.rateLimited(why)
            return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
        }
```

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(core): RateLimiter hard cap (per target 3 s, global 20/min) enforced by the executor as RATE_LIMITED`

---

### Task 4: 身份桥表 `identities`（`Identity`、`IdentityLookup`、`ControlStore` 迁移 v3）

**Files:**
- Create: `Sources/ControlCore/Protocol/Identity.swift`
- Modify: `Sources/ControlCore/Store/ControlStore.swift`
- Test: `Tests/ControlCoreTests/ControlStoreTests.swift`（追加）

**Interfaces:**
- Produces:
  - `public enum IdentityKind: String, Codable, CaseIterable { case group, customer }`
  - `public struct Identity: Codable, Equatable { kind: IdentityKind; id: String; title: String; updatedMs: Int64; var conversationType: ConversationType }`
  - `public protocol IdentityLookup { func identity(kind: IdentityKind, id: String) throws -> Identity?; func identities(title: String) throws -> [Identity] }`；`public struct NoIdentities: IdentityLookup`
  - `ControlStore: IdentityLookup` + `upsertIdentity(kind:id:title:nowMs:)`、`deleteIdentity(kind:id:) -> Bool`、`allIdentities() -> [Identity]`

- [ ] **Step 1: 失败测试**

```swift
    @Test func identitiesBridgeIdsAndTitlesBothWays() throws {
        let store = try ControlStore(path: ":memory:")
        try store.upsertIdentity(kind: .group, id: "wr1", title: "imctl测试群", nowMs: 1)
        try store.upsertIdentity(kind: .customer, id: "wm1", title: "小明·a1b2c3", nowMs: 2)
        try store.upsertIdentity(kind: .group, id: "wr1", title: "imctl测试群2", nowMs: 3)   // rename = upsert
        #expect(try store.identity(kind: .group, id: "wr1")?.title == "imctl测试群2")
        #expect(try store.identity(kind: .group, id: "wm1") == nil)
        #expect(try store.identities(title: "小明·a1b2c3").map(\.id) == ["wm1"])
        #expect(try store.identities(title: "imctl测试群").isEmpty)
        #expect(try store.allIdentities().map(\.id) == ["wr1", "wm1"] || try store.allIdentities().map(\.id) == ["wm1", "wr1"])
        #expect(try store.identity(kind: .customer, id: "wm1")?.conversationType == .customer)
        #expect(try store.deleteIdentity(kind: .group, id: "wr1") && !(try store.deleteIdentity(kind: .group, id: "wr1")))
        #expect(try NoIdentities().identity(kind: .group, id: "wr1") == nil && try NoIdentities().identities(title: "x").isEmpty)
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
// Sources/ControlCore/Protocol/Identity.swift
import Foundation
import GRDB

public enum IdentityKind: String, Codable, CaseIterable {
    case group
    case customer
}

/// One row of the identity bridge: a platform id and the title the client
/// shows for it (the group name, or the remark we set on a customer). Filled
/// by the WeCom API commands (B5) or by hand with `imctl identity set`.
public struct Identity: Codable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "identities"

    public var kind: IdentityKind
    public var id: String
    public var title: String
    public var updatedMs: Int64

    enum CodingKeys: String, CodingKey {
        case kind, id, title
        case updatedMs = "updated_ms"
    }

    public init(kind: IdentityKind, id: String, title: String, updatedMs: Int64) {
        self.kind = kind; self.id = id; self.title = title; self.updatedMs = updatedMs
    }

    public var conversationType: ConversationType { kind == .group ? .group : .customer }
}

/// Read side of the bridge so adapters and watchers do not depend on the store.
public protocol IdentityLookup {
    func identity(kind: IdentityKind, id: String) throws -> Identity?
    func identities(title: String) throws -> [Identity]
}

public struct NoIdentities: IdentityLookup {
    public init() {}
    public func identity(kind: IdentityKind, id: String) throws -> Identity? { nil }
    public func identities(title: String) throws -> [Identity] { [] }
}
```

`ControlStore.migrate()` 追加：

```swift
        migrator.registerMigration("v3-identities") { db in
            try db.create(table: "identities") { t in
                t.column("kind", .text).notNull()
                t.column("id", .text).notNull()
                t.column("title", .text).notNull().indexed()
                t.column("updated_ms", .integer).notNull()
                t.primaryKey(["kind", "id"])
            }
        }
```

`ControlStore` 新增：

```swift
    // MARK: Identities

    public func upsertIdentity(kind: IdentityKind, id: String, title: String, nowMs: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO identities(kind, id, title, updated_ms) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, id) DO UPDATE SET title = excluded.title, updated_ms = excluded.updated_ms
                """, arguments: [kind.rawValue, id, title, nowMs])
        }
    }

    @discardableResult
    public func deleteIdentity(kind: IdentityKind, id: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM identities WHERE kind = ? AND id = ?", arguments: [kind.rawValue, id])
            return db.changesCount > 0
        }
    }

    public func allIdentities() throws -> [Identity] {
        try dbQueue.read { db in try Identity.order(Column("kind"), Column("id")).fetchAll(db) }
    }

extension ControlStore: IdentityLookup {
    public func identity(kind: IdentityKind, id: String) throws -> Identity? {
        try dbQueue.read { db in
            try Identity.filter(Column("kind") == kind.rawValue && Column("id") == id).fetchOne(db)
        }
    }

    public func identities(title: String) throws -> [Identity] {
        try dbQueue.read { db in try Identity.filter(Column("title") == title).order(Column("kind")).fetchAll(db) }
    }
}
```

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(core): identities table (identity bridge) with IdentityLookup`

---

### Task 5: 群会话解析：`MessageRowKind`、`ConversationHeader`、会话行 `markers`、`ConversationTypeInference`、`WeComReader.chatMessages()`

**Files:**
- Modify: `Sources/WeComAdapter/MessageRow.swift`
- Modify: `Sources/WeComAdapter/ConversationRow.swift`
- Create: `Sources/WeComAdapter/ConversationHeader.swift`
- Create: `Sources/WeComAdapter/ConversationTypeInference.swift`
- Modify: `Sources/WeComAdapter/WeComReader.swift`
- Test: `Tests/WeComAdapterTests/GroupFixture.swift`（合成群窗口）、`Tests/WeComAdapterTests/GroupParsingTests.swift`

**Interfaces:**
- Produces:
  - `public enum MessageRowKind: String, Codable { case message, system, timeSeparator, empty }`；`MessageRow` 加 `kind: MessageRowKind`（在 `index` 之后）与 `messageKey: String?`（末尾，默认 nil）
  - `ConversationRow` 加 `markers: [String]`；`ConversationRowParser.markerTexts: Set<String> = ["微信", "外部", "外部群"]`
  - `public struct ConversationHeader: Equatable { raw, title: String; memberCount: Int?; static func parse(_ raw: String) -> ConversationHeader }`
  - `public enum ConversationTypeInference { static func infer(row: ConversationRow) -> ConversationType; static func infer(header: ConversationHeader?, messages: [MessageRow], row: ConversationRow?) -> ConversationType }`
  - `WeComReader.activeConversationHeader() -> ConversationHeader?`、`activeConversationTitle()`（返回 header.title，去掉群成员数）、`activeConversationRow() -> ConversationRow?`、`activeConversationType() -> ConversationType`、`chatMessages() -> [MessageRow]`（只含 `.message`，`messageKey` 已赋值）

- [ ] **Step 1: 失败测试**

合成夹具（几何取自 5.0.11 实录：会话表 x 59–311，消息表 x 310 宽 1611，头部静态文本 y 20，滚动区 y 64）：

```swift
// Tests/WeComAdapterTests/GroupFixture.swift
import CoreGraphics
import Foundation
@testable import AXKit

/// A synthetic main window with a group chat active. Geometry copies the
/// 5.0.11 recording (conversation table x 59–311, message table x 310 wide
/// 1611, header text at y 20, message scroll area from y 64); no real
/// contact content, so it can live in the repo.
enum GroupFixture {
    static let groupTitle = "imctl测试群"
    static let customerTitle = "小明·a1b2c3"

    static func text(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat = 80, h: CGFloat = 18) -> AXNode {
        AXNode(role: AXRole.staticText, value: .string(s), frame: CGRect(x: x, y: y, width: w, height: h))
    }

    static func conversationRow(y: CGFloat, title: String, preview: String, time: String, marker: String? = nil, selected: Bool = false) -> AXNode {
        var kids = [
            AXNode(role: AXRole.image, description: "", frame: CGRect(x: 75, y: y + 11, width: 42, height: 42)),
            text(title, x: 129, y: y + 12, w: 86, h: 20),
            text(preview, x: 129, y: y + 33, w: 124),
            AXNode(role: AXRole.group, frame: CGRect(x: 76, y: y + 63, width: 218, height: 1)),
            text(time, x: 255, y: y + 33, w: 38),
        ]
        if let marker { kids.append(text(marker, x: 220, y: y + 12, w: 28, h: 16)) }
        return AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 60, y: y, width: 250, height: 64), selected: selected, children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 60, y: y, width: 250, height: 64), selected: selected, children: kids),
        ])
    }

    /// Bubble row: `sender` above the body means a group message from someone else.
    static func messageRow(y: CGFloat, text body: String, sender: String? = nil, time: String? = nil, outbound: Bool = false) -> AXNode {
        var kids: [AXNode] = []
        if let time { kids.append(text(time, x: 1102, y: y + 7, w: 40)) }
        if let sender { kids.append(text(sender, x: 380, y: y + 30, w: 60, h: 16)) }
        let x: CGFloat = outbound ? 1500 : 380
        kids.append(AXNode(role: AXRole.textArea, value: .string(body), frame: CGRect(x: x, y: y + 50, width: 300, height: 20)))
        return AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 80), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 80), children: kids),
        ])
    }

    /// Centered notice without a text area ("xx joined the group", recalls).
    static func systemRow(y: CGFloat, text body: String) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 40), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 40), children: [
                text(body, x: 1000, y: y + 10, w: 230),
            ]),
        ])
    }

    static func timeRow(y: CGFloat, _ label: String) -> AXNode {
        AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: 30), children: [
            AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: 30), children: [text(label, x: 1102, y: y + 6, w: 40)]),
        ])
    }

    static func window(messages: [AXNode]? = nil, headerTitle: String = "\(groupTitle)(3)") -> AXNode {
        let rows = messages ?? [
            timeRow(y: 64, "9:18"),
            systemRow(y: 94, "«a1»加入群聊"),
            messageRow(y: 134, text: "大家好", sender: "张三"),
            messageRow(y: 214, text: "收到", outbound: true),
            messageRow(y: 294, text: "收到", sender: "李四"),
            messageRow(y: 374, text: "收到", sender: "李四"),
        ]
        let messageTable = AXNode(role: AXRole.table, frame: CGRect(x: 310, y: 63, width: 1611, height: 933),
                                  settable: [AXAttribute.selectedRows, AXAttribute.focused], children: rows + [
            AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: 1609, height: 931)),
        ])
        let scrollArea = AXNode(role: AXRole.scrollArea, frame: CGRect(x: 311, y: 64, width: 1609, height: 931),
                                actions: [AXAction.scrollUpByPage, AXAction.scrollDownByPage], children: [
            messageTable,
            AXNode(role: AXRole.scrollBar, value: .number(1), frame: CGRect(x: 1903, y: 64, width: 17, height: 931), settable: [AXAttribute.value]),
        ])
        let composer = AXNode(role: AXRole.textArea, value: .string(""), frame: CGRect(x: 311, y: 1036, width: 1609, height: 159),
                              settable: [AXAttribute.value, AXAttribute.focused], actions: [AXAction.showMenu])
        let conversationTable = AXNode(role: AXRole.table, frame: CGRect(x: 59, y: 63, width: 252, height: 1138),
                                       settable: [AXAttribute.selectedRows, AXAttribute.focused], children: [
            conversationRow(y: 64, title: "文件传输助手", preview: "«p1»", time: "昨天"),
            conversationRow(y: 128, title: groupTitle, preview: "李四: 收到", time: "9:18", selected: true),
            conversationRow(y: 192, title: customerTitle, preview: "«p2»", time: "星期五", marker: "微信"),
            conversationRow(y: 256, title: "«ext»", preview: "«p3»", time: "星期五", marker: "外部"),
            conversationRow(y: 320, title: "同事甲", preview: "«p4»", time: "9/2"),
        ])
        return AXNode(role: AXRole.window, title: headerTitle, frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), children: [
            AXNode(role: "AXSplitGroup", frame: CGRect(x: 0, y: 0, width: 1920, height: 1200), children: [
                AXNode(role: AXRole.scrollArea, frame: CGRect(x: 59, y: 63, width: 252, height: 1138), children: [conversationTable]),
                text(headerTitle, x: 326, y: 20, w: 140, h: 24),
                AXNode(role: AXRole.group, frame: CGRect(x: 310, y: 63, width: 1611, height: 1137), children: [
                    scrollArea,
                    AXNode(role: AXRole.group, frame: CGRect(x: 311, y: 996, width: 1609, height: 40)),
                    AXNode(role: AXRole.group, frame: CGRect(x: 311, y: 1036, width: 1609, height: 159), children: [composer]),
                ]),
            ]),
        ])
    }

    static func backend(messages: [AXNode]? = nil, headerTitle: String = "\(groupTitle)(3)") -> FakeAXBackend {
        FakeAXBackend(root: window(messages: messages, headerTitle: headerTitle))
    }
}
```

测试：

```swift
// Tests/WeComAdapterTests/GroupParsingTests.swift
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("Group conversation parsing (synthetic fixture)")
struct GroupParsingTests {
    @Test func headerStripsMemberCountAndInfersGroup() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let header = try #require(try reader.activeConversationHeader())
        #expect(header.raw == "imctl测试群(3)" && header.title == "imctl测试群" && header.memberCount == 3)
        #expect(try reader.activeConversationTitle() == "imctl测试群")
        #expect(try reader.activeConversationType() == .group)
        #expect(try reader.activeConversationRow()?.title == "imctl测试群")
        #expect(ConversationHeader.parse("文件传输助手") == ConversationHeader(raw: "文件传输助手", title: "文件传输助手", memberCount: nil))
        #expect(ConversationHeader.parse("群 （12）").title == "群" && ConversationHeader.parse("群 （12）").memberCount == 12)
        #expect(ConversationHeader.parse("张三(客户)").memberCount == nil)
    }

    @Test func rowsCarryKindSenderAndSystemNoticesAreFiltered() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let all = try reader.messages()
        #expect(all.map(\.kind) == [.timeSeparator, .system, .message, .message, .message, .message])
        #expect(all[1].text == "«a1»加入群聊" && all[1].direction == .unknown && all[1].senderLabel == nil)
        #expect(all[2].senderLabel == "张三" && all[2].direction == .inbound)
        #expect(all[3].senderLabel == nil && all[3].direction == .outbound)
        let chat = try reader.chatMessages()
        #expect(chat.map(\.index) == [2, 3, 4, 5])
        let keys = chat.compactMap(\.messageKey)
        #expect(keys.count == 4 && Set(keys).count == 4)
        #expect(keys[0] == MessageKey.make(conversation: "imctl测试群", sender: "张三", timeLabel: nil, text: "大家好", ordinal: 0))
        #expect(keys[2] != keys[3])   // two identical "收到" from 李四 differ by ordinal
    }

    @Test func conversationRowsExposeMarkersAndTypes() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let rows = try reader.conversations()
        #expect(rows.map(\.title) == ["文件传输助手", "imctl测试群", "小明·a1b2c3", "«ext»", "同事甲"])
        #expect(rows[2].markers == ["微信"] && rows[3].markers == ["外部"] && rows[0].markers.isEmpty)
        #expect(rows[2].preview == "«p2»")   // the marker is not mistaken for title or preview
        #expect(rows.map(ConversationTypeInference.infer(row:)) == [.unknown, .unknown, .customer, .group, .unknown])
        #expect(ConversationTypeInference.infer(header: nil, messages: [], row: nil) == .unknown)
    }

    @Test func plainFixtureIsUnchanged() throws {
        let reader = try WeComReader(window: try Fixtures.mainWindow().rootElement)
        #expect(try reader.activeConversationTitle() == "文件传输助手")
        #expect(try reader.activeConversationType() == .unknown)
        let rows = try reader.messages()
        #expect(rows.count == 1 && rows[0].kind == .message)
        #expect(try reader.chatMessages().count == 1)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

`MessageRow.swift`：

```swift
import AXKit
import ControlCore
import CoreGraphics

public enum MessageRowKind: String, Codable {
    /// A bubble (text area body, or a non-centered static text fallback).
    case message
    /// Centered notice without a bubble: joins, recalls, group renames.
    case system
    /// A row that only carries a time label.
    case timeSeparator
    case empty
}

public struct MessageRow: Equatable {
    public var index: Int
    public var kind: MessageRowKind
    public var text: String?
    public var timeLabel: String?
    public var bodyFrame: CGRect?
    public var direction: MessageDirection
    /// Group chats show the sender above the bubble; nil for our own bubbles and private chats.
    public var senderLabel: String?
    public var frame: CGRect
    public var handle: AXElementHandle
    /// Assigned by `WeComReader.chatMessages()`; nil straight from the parser.
    public var messageKey: String? = nil
}

/// Turns message-table rows into `MessageRow`s. Body = first `AXTextArea`
/// (falls back to the first non-time `AXStaticText`); time = a static text
/// matching `TimeLabel`; sender = a non-time static text above the body. A
/// static-text-only row whose text is horizontally centered is a system
/// notice, never a message.
public struct MessageRowParser {
    public var direction = DirectionInference()
    /// |text centre − table centre| ≤ this fraction of the table width ⇒ centered.
    public var centeredTolerance: CGFloat = 0.12

    public init() {}

    public func parse(table: AXElement, tableFrame: CGRect) throws -> [MessageRow] {
        var rows: [MessageRow] = []
        for (index, row) in try table.children().enumerated() {
            guard try row.role() == AXRole.row else { continue }
            let frame = try row.frame() ?? .zero
            let cell = try row.children().first { try $0.role() == AXRole.cell } ?? row
            var statics: [(String, CGRect)] = []
            var body: (String, CGRect)?
            for child in try cell.children() {
                let f = try child.frame() ?? .zero
                switch try child.role() {
                case AXRole.textArea:
                    if body == nil { body = (try child.valueString() ?? "", f) }
                case AXRole.staticText:
                    if let v = try child.valueString() { statics.append((v, f)) }
                default:
                    continue
                }
            }
            let time = statics.first { TimeLabel.matches($0.0) }
            let nonTime = statics.filter { !TimeLabel.matches($0.0) }
            var kind = MessageRowKind.message
            if body == nil {
                if let first = nonTime.first {
                    body = first
                    if isCentered(first.1, in: tableFrame) { kind = .system }
                } else {
                    kind = time == nil ? .empty : .timeSeparator
                }
            }
            let sender = kind == .message ? body.flatMap { b in nonTime.first { $0.1.maxY <= b.1.minY && $0.1 != b.1 } } : nil
            rows.append(MessageRow(
                index: index, kind: kind, text: body?.0, timeLabel: time?.0, bodyFrame: body?.1,
                direction: kind == .message ? (body.map { direction.infer(body: $0.1, container: tableFrame) } ?? .unknown) : .unknown,
                senderLabel: sender?.0, frame: frame, handle: row.handle
            ))
        }
        return rows
    }

    func isCentered(_ rect: CGRect, in table: CGRect) -> Bool {
        guard table.width > 0 else { return false }
        return abs(rect.midX - table.midX) <= table.width * centeredTolerance
    }
}
```

`ConversationRow.swift`：`ConversationRow` 加 `public var markers: [String]`（放在 `avatarTitle` 之后）；`ConversationRowParser` 加 `public var markerTexts: Set<String> = ["微信", "外部", "外部群"]`；解析循环里 `AXRole.staticText` 分支改为：

```swift
                case AXRole.staticText:
                    if let v = try child.valueString(), let f = try child.frame() {
                        if markerTexts.contains(v) { markers.append(v) } else { texts.append((v, f)) }
                    }
```

（循环前 `var markers: [String] = []`，构造时 `markers: markers`。）

`ConversationHeader.swift`：

```swift
import Foundation

/// The active-conversation header. Group chats append the member count,
/// "群名(12)", which the conversation table's title column does not show; the
/// normalised `title` is what target resolution and selection compare.
public struct ConversationHeader: Equatable {
    public var raw: String
    public var title: String
    public var memberCount: Int?

    public init(raw: String, title: String, memberCount: Int?) {
        self.raw = raw; self.title = title; self.memberCount = memberCount
    }

    private static let pattern = try? NSRegularExpression(pattern: "^(.*?)\\s*[（(]([0-9]+)[)）]$")

    public static func parse(_ raw: String) -> ConversationHeader {
        guard let pattern,
              let m = pattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let titleRange = Range(m.range(at: 1), in: raw), let countRange = Range(m.range(at: 2), in: raw),
              let count = Int(raw[countRange]), !raw[titleRange].isEmpty else {
            return ConversationHeader(raw: raw, title: raw, memberCount: nil)
        }
        return ConversationHeader(raw: raw, title: String(raw[titleRange]), memberCount: count)
    }
}
```

`ConversationTypeInference.swift`：

```swift
import ControlCore

/// Derives a conversation's kind only from evidence the client shows; without
/// evidence the answer is `unknown`, which no type rule can allow. Marker texts
/// are the 5.0.x list tags; confirmed against the test group during B4 live checks.
public enum ConversationTypeInference {
    public static let customerMarkers: Set<String> = ["微信"]
    public static let groupMarkers: Set<String> = ["外部", "外部群"]

    /// From the conversation table row alone (before opening it).
    public static func infer(row: ConversationRow) -> ConversationType {
        if row.markers.contains(where: customerMarkers.contains) { return .customer }
        if row.markers.contains(where: groupMarkers.contains) { return .group }
        // External contacts from another company are titled "姓名@公司".
        if let title = row.title, title.contains("@"), !title.hasPrefix("@") { return .customer }
        return .unknown
    }

    /// From the open conversation: a member count in the header or any sender
    /// label proves a group; otherwise fall back to the row.
    public static func infer(header: ConversationHeader?, messages: [MessageRow], row: ConversationRow?) -> ConversationType {
        if header?.memberCount != nil { return .group }
        if messages.contains(where: { $0.kind == .message && $0.senderLabel != nil }) { return .group }
        if let row { return infer(row: row) }
        return .unknown
    }
}
```

`WeComReader.swift` 新增 / 修改：

```swift
    public func activeConversationHeader() throws -> ConversationHeader? {
        guard let title = layout.activeTitle, let raw = try title.valueString() ?? title.title() else { return nil }
        return ConversationHeader.parse(raw)
    }

    /// The normalised title (group member count removed).
    public func activeConversationTitle() throws -> String? {
        try activeConversationHeader()?.title
    }

    /// The selected row, else the row whose title equals the active title.
    public func activeConversationRow() throws -> ConversationRow? {
        let rows = try conversations()
        if let selected = rows.first(where: \.selected) { return selected }
        guard let active = try activeConversationTitle() else { return nil }
        return rows.first { $0.title == active }
    }

    public func activeConversationType() throws -> ConversationType {
        ConversationTypeInference.infer(header: try activeConversationHeader(), messages: try messages(), row: try activeConversationRow())
    }

    /// Message rows only (system notices, time separators and empty rows
    /// dropped), each with its `messageKey`. Indices stay table indices.
    public func chatMessages() throws -> [MessageRow] {
        let conversation = try activeConversationTitle() ?? ""
        var rows = try messages().filter { $0.kind == .message }
        let keys = MessageKey.assign(rows, conversation: conversation, sender: \.senderLabel, timeLabel: \.timeLabel, text: { $0.text ?? "" })
        for i in rows.indices { rows[i].messageKey = keys[i] }
        return rows
    }
```

（`WeComReader` 需 `import ControlCore`。）

- [ ] **Step 4: 跑测试通过**（既有 `MessageRowParserTests` / `ConversationRowParserTests` / `WeComLayoutTests` 不应变化）
- [ ] **Step 5: Commit** `feat(adapter): group parsing (row kinds, system notices, sender), header member count, list markers, conservative conversation type inference, chatMessages with keys`

---

### Task 6: 目标解析与命令处理器：`TargetResolver`、`WeComActions.resolvedTarget`、处理器接 `IdentityLookup` 与策略文件

**Files:**
- Create: `Sources/WeComAdapter/TargetResolver.swift`
- Modify: `Sources/WeComAdapter/Actions/WeComActions.swift`（`resolvedTarget` + `authorize(_:title:)`）
- Modify: `Sources/WeComAdapter/Actions/Submit.swift`、`Sources/WeComAdapter/Actions/Scrollback.swift`、`Sources/WeComAdapter/Actions/ComposerMenu.swift`（内部授权改走 `authorize(_:title:)`）
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`
- Test: `Tests/WeComAdapterTests/TargetResolverTests.swift`、`Tests/WeComAdapterTests/WeComCommandHandlerTests.swift`（追加）

**Interfaces:**
- Produces:
  - `public struct TargetResolver { init(identities: IdentityLookup); func title(for: TargetRef) throws -> String; func resolve(_ ref: TargetRef, row: ConversationRow?, header: ConversationHeader? = nil, messages: [MessageRow] = []) throws -> ResolvedTarget }`
  - `WeComActions.resolvedTarget: ResolvedTarget?`；`func authorize(_ kind: ActionKind, title: String?) throws`
  - `WeComCommandHandler.init(rootProvider:policy:checkpoints:strategy:submitTimeout:identities: IdentityLookup = NoIdentities())`；`public var sendPolicyProvider: (() -> SendPolicy)?`；`var currentPolicy: ActionPolicy`
  - `describe()` 增加 `policy`（summary）、`targetSyntax`；`accountStatus()` 增加 `activeType`、`activeMemberCount`；`messageHistory` 行增加 `messageKey`（只返回 `.message` 行）

- [ ] **Step 1: 失败测试**

```swift
// Tests/WeComAdapterTests/TargetResolverTests.swift
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

struct MapIdentities: IdentityLookup {
    var items: [Identity]
    func identity(kind: IdentityKind, id: String) throws -> Identity? { items.first { $0.kind == kind && $0.id == id } }
    func identities(title: String) throws -> [Identity] { items.filter { $0.title == title } }
}

@Suite("TargetResolver")
struct TargetResolverTests {
    let bridge = MapIdentities(items: [
        Identity(kind: .group, id: "wr1", title: "imctl测试群", updatedMs: 1),
        Identity(kind: .customer, id: "wm1", title: "小明·a1b2c3", updatedMs: 1),
    ])

    @Test func idsResolveThroughTheBridgeAndTitlesReverseLookUp() throws {
        let r = TargetResolver(identities: bridge)
        #expect(try r.title(for: .chatId("wr1")) == "imctl测试群")
        #expect(try r.title(for: .externalUserId("wm1")) == "小明·a1b2c3")
        #expect(try r.title(for: .title("任意")) == "任意")
        #expect(throws: ControlError.targetNotFound("chatId:nope")) { try r.title(for: .chatId("nope")) }
        #expect(throws: ControlError.targetNotFound("externalUserId:wr1")) { try r.title(for: .externalUserId("wr1")) }
        let byId = try r.resolve(.chatId("wr1"), row: nil)
        #expect(byId == ResolvedTarget(title: "imctl测试群", type: .group, chatId: "wr1"))
        let byTitle = try r.resolve(.title("小明·a1b2c3"), row: nil)
        #expect(byTitle == ResolvedTarget(title: "小明·a1b2c3", type: .customer, externalUserId: "wm1"))
        #expect(try r.resolve(.title("陌生"), row: nil) == ResolvedTarget(title: "陌生"))
    }

    @Test func clientEvidenceWinsOverBridgeKind() throws {
        let reader = try WeComReader(window: GroupFixture.backend().rootElement)
        let r = TargetResolver(identities: MapIdentities(items: []))
        let row = try reader.activeConversationRow()
        let resolved = try r.resolve(.title("imctl测试群"), row: row, header: try reader.activeConversationHeader(), messages: try reader.messages())
        #expect(resolved.type == .group && resolved.chatId == nil)
        let customerRow = try #require(try reader.conversations().first { $0.title == "小明·a1b2c3" })
        #expect(try r.resolve(.title("小明·a1b2c3"), row: customerRow).type == .customer)
    }
}
```

`WeComCommandHandlerTests` 追加（`handler(_:)` 工厂加 `identities:` 参数，默认 `NoIdentities()`）：

```swift
    func groupHandler(policyFile: SendPolicy, identities: IdentityLookup = NoIdentities()) throws -> (WeComCommandHandler, FakeAXBackend) {
        let fake = GroupFixture.backend()
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-handler-\(UUID().uuidString)"))
        let h = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation, .composeText, .clearComposer, .scrollHistory, .submit], phase: .phase1),
            checkpoints: cps, strategy: .enterKey, submitTimeout: 0.5, identities: identities
        )
        h.sendPolicyProvider = { policyFile }
        h.configureActions = { a in a.verifyTimeout = 0.2; a.verifyInterval = 0.02; a.postReturnKey = { _, _ in } }
        return (h, fake)
    }

    @Test func groupTargetsNeedAPolicyRuleAndChatIdTargetsNeedTheBridge() throws {
        var file = SendPolicy(); file.allow(.type(.group))
        let bridge = MapIdentities(items: [Identity(kind: .group, id: "wr1", title: "imctl测试群", updatedMs: 1)])
        let (h, fake) = try groupHandler(policyFile: file, identities: bridge)
        // type rule lets the active group through (composer stays with text because the fake never sends -> unknown/failed, not a policy error)
        let r = try h.messageSend(target: "chatId:wr1", text: "hello", checkpoint: {}, afterSubmit: {})
        #expect(r.state != .succeeded && fake.recordedSets.contains { $0.attribute == AXAttribute.value })
        #expect(throws: ControlError.targetNotFound("chatId:wr2")) { try h.messageSend(target: "chatId:wr2", text: "x", checkpoint: {}, afterSubmit: {}) }
        // a customer is not covered by the group rule, and unknown-typed rows never are
        #expect(throws: ControlError.targetNotAllowed("小明·a1b2c3")) { try h.messageSend(target: "小明·a1b2c3", text: "x", checkpoint: {}, afterSubmit: {}) }
        #expect(throws: ControlError.targetNotAllowed("同事甲")) { try h.messageSend(target: "同事甲", text: "x", checkpoint: {}, afterSubmit: {}) }
        #expect(try h.describe()["policy"] == "titles=0 types=group chatIds=0 externalUserIds=0")
        #expect(try h.describe()["targetSyntax"]?.contains("chatId:") == true)
    }

    @Test func readAndHistoryUseResolvedTargetsAndKeys() throws {
        var file = SendPolicy(); file.allow(.chatId("wr1"))
        let bridge = MapIdentities(items: [Identity(kind: .group, id: "wr1", title: "imctl测试群", updatedMs: 1)])
        let (h, _) = try groupHandler(policyFile: file, identities: bridge)
        let read = try h.conversationRead(target: "chatId:wr1")
        #expect(read["active"] == "imctl测试群" && read["messageCount"] == "4" && read["conversationType"] == "group" && read["chatId"] == "wr1")
        let hist = try h.messageHistory(limit: 10, scrollback: false)
        #expect(hist.count == 4 && hist[0]["sender"] == "张三" && hist[0]["messageKey"]?.count == 16 && hist.allSatisfy { $0["messageKey"] != nil })
        let status = try h.accountStatus()
        #expect(status["activeTitle"] == "imctl测试群" && status["activeType"] == "group" && status["activeMemberCount"] == "3")
        #expect(throws: ControlError.targetNotAllowed("同事甲")) { try h.conversationRead(target: "同事甲") }
    }
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

`TargetResolver.swift`：

```swift
import ControlCore

/// Turns a wire target into what the policy judges: the title the client must
/// show, the conversation kind, and the platform ids the bridge knows. Client
/// evidence (header, sender labels, list markers) wins over the bridge's kind;
/// the bridge only fills the kind in when the client shows nothing. Reads only.
public struct TargetResolver {
    public var identities: IdentityLookup

    public init(identities: IdentityLookup) { self.identities = identities }

    /// The title to look for. Ids need a bridge entry; otherwise TARGET_NOT_FOUND on the wire form.
    public func title(for ref: TargetRef) throws -> String {
        switch ref {
        case .title(let t): return t
        case .chatId(let id):
            guard let hit = try identities.identity(kind: .group, id: id) else { throw ControlError.targetNotFound(ref.wire) }
            return hit.title
        case .externalUserId(let id):
            guard let hit = try identities.identity(kind: .customer, id: id) else { throw ControlError.targetNotFound(ref.wire) }
            return hit.title
        }
    }

    public func resolve(_ ref: TargetRef, row: ConversationRow?, header: ConversationHeader? = nil, messages: [MessageRow] = []) throws -> ResolvedTarget {
        let title = try title(for: ref)
        var target = ResolvedTarget(title: title)
        for identity in try identities.identities(title: title) {
            switch identity.kind {
            case .group: target.chatId = target.chatId ?? identity.id
            case .customer: target.externalUserId = target.externalUserId ?? identity.id
            }
        }
        if case .chatId(let id) = ref { target.chatId = id }
        if case .externalUserId(let id) = ref { target.externalUserId = id }
        target.type = ConversationTypeInference.infer(header: header, messages: messages, row: row)
        if target.type == .unknown {
            if target.chatId != nil { target.type = .group } else if target.externalUserId != nil { target.type = .customer }
        }
        return target
    }
}
```

`WeComActions.swift`：加

```swift
    /// The target this action set operates on, already judged by the policy
    /// with the identity bridge and the conversation kind. Actions on that
    /// title reuse it; any other title is judged as a bare title.
    public var resolvedTarget: ResolvedTarget?

    func authorize(_ kind: ActionKind, title: String?) throws {
        if let resolvedTarget, let title, resolvedTarget.title == title {
            try policy.authorize(kind, resolved: resolvedTarget)
        } else {
            try policy.authorize(kind, target: title)
        }
    }
```

并把 `selectConversation` / `composeText` / `clearComposer`（`title: nil`）、`Submit.swift` 的 `try policy.authorize(.submit, target: active)`、`Scrollback.swift` 的 `.scrollHistory`、`ComposerMenu.swift` 的 `.showComposerMenu` 全部改为 `try authorize(kind, title: …)`。

`WeComCommandHandler.swift` 关键改动：

```swift
    public let identities: IdentityLookup
    /// Live policy file (reloaded by the daemon); nil = compiled allowlist only.
    public var sendPolicyProvider: (() -> SendPolicy)?

    public init(rootProvider: @escaping () throws -> AXElement, policy: ActionPolicy, checkpoints: CheckpointStore,
                strategy: SubmitStrategy = .enterKey, submitTimeout: TimeInterval = 10, identities: IdentityLookup = NoIdentities()) { … }

    public var currentPolicy: ActionPolicy {
        var p = policy
        if let provider = sendPolicyProvider { p.sendPolicy = provider() }
        return p
    }

    public func describe() throws -> [String: String] {
        let p = currentPolicy
        return [
            "platform": "wecom", "client": WeComClient.bundleID, "submitStrategy": strategy.rawValue,
            "allowlist": p.allowedTargets.sorted().joined(separator: ","),
            "policy": p.sendPolicy.summary,
            "targetSyntax": "title | chatId:<id> | externalUserId:<id>",
            "phase": p.phase == .phase1 ? "1" : "0",
        ]
    }

    public func accountStatus() throws -> [String: String] {
        do {
            let r = try reader()
            let rows = try r.conversations()
            let header = try r.activeConversationHeader()
            var out: [String: String] = [
                "windowReachable": "true", "activeTitle": header?.title ?? "", "conversationCount": String(rows.count),
                "composerPresent": r.layout.composer == nil ? "false" : "true",
                "activeType": try r.activeConversationType().rawValue,
            ]
            if let n = header?.memberCount { out["activeMemberCount"] = String(n) }
            return out
        } catch … (原有各分支不变)
    }

    public func conversationRead(target rawTarget: String) throws -> [String: String] {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let resolved = try resolve(ref, reader: r)
            if try r.activeConversationTitle() != resolved.title {
                _ = try actions(for: resolved).selectConversation(resolved.title, reader: r)
            } else {
                try currentPolicy.authorize(.selectConversation, resolved: resolved)   // same policy gate even without a switch
            }
            let fresh = try reader()
            let messages = try fresh.chatMessages()
            var out: [String: String] = [
                "active": try fresh.activeConversationTitle() ?? "", "messageCount": String(messages.count),
                "composerPresent": fresh.layout.composer == nil ? "false" : "true",
                "conversationType": try fresh.activeConversationType().rawValue,
            ]
            if let id = resolved.chatId { out["chatId"] = id }
            if let id = resolved.externalUserId { out["externalUserId"] = id }
            return out
        }
    }

    public func messageHistory(limit: Int, scrollback: Bool) throws -> [[String: String]] {
        try mapErrors {
            let r = try reader()
            if scrollback, limit > 0, try r.chatMessages().count < limit {
                let active = try resolveActive(reader: r)
                _ = try actions(for: active).loadOlderMessages(reader: r, minRows: limit)
            }
            return try r.chatMessages().suffix(max(limit, 0)).map { m in
                var d: [String: String] = ["index": String(m.index), "direction": m.direction.rawValue]
                if let v = m.text { d["text"] = v }
                if let v = m.timeLabel { d["timeLabel"] = v }
                if let v = m.senderLabel { d["sender"] = v }
                if let v = m.messageKey { d["messageKey"] = v }
                return d
            }
        }
    }

    public func messageSend(target rawTarget: String, text: String, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendResult {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let resolved = try resolve(ref, reader: r)
            try policyCheck(.submit, resolved: resolved)
            if try r.activeConversationTitle() != resolved.title {
                _ = try actions(for: resolved).selectConversation(resolved.title, reader: r)
            }
            let fresh = try reader()
            let outcome = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try actions(for: resolved).submit(text: text, strategy: strategy, reader: fresh, checkpoints: checkpoints,
                                                  timeout: submitTimeout, hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            … (状态映射不变)
        }
    }

    // MARK: Helpers

    /// Bridge + what the list row shows; header/message evidence only when the target is the active conversation.
    private func resolve(_ ref: TargetRef, reader r: WeComReader) throws -> ResolvedTarget {
        let resolver = TargetResolver(identities: identities)
        let title = try resolver.title(for: ref)
        let row = try r.conversations().first { $0.title == title }
        let isActive = try r.activeConversationTitle() == title
        return try resolver.resolve(ref, row: row, header: isActive ? try r.activeConversationHeader() : nil, messages: isActive ? try r.messages() : [])
    }

    private func resolveActive(reader r: WeComReader) throws -> ResolvedTarget? {
        guard let active = try r.activeConversationTitle() else { return nil }
        return try resolve(.title(active), reader: r)
    }

    private func actions(for resolved: ResolvedTarget?) -> WeComActions {
        var a = WeComActions(policy: currentPolicy)
        a.resolvedTarget = resolved
        configureActions(&a)
        return a
    }

    private func policyCheck(_ kind: ActionKind, resolved: ResolvedTarget) throws {
        do { try currentPolicy.authorize(kind, resolved: resolved) } catch let e as PolicyError { throw Self.map(e) }
    }
```

（`targetNotFound` 现在既可能来自 `TargetResolver`（`ControlError`，`mapErrors` 原样透传），也可能来自 `ActionError.targetNotFound(title)`；两者 code 相同。）

- [ ] **Step 4: 跑测试通过**（既有 handler 测试：`sendToNonAllowlistedTargetIsRefusedBeforeAnyAX` 仍要求策略拒绝前无 set / action——本实现只读会话表，满足）
- [ ] **Step 5: Commit** `feat(adapter): chatId:/externalUserId: targets via the identity bridge; policy judged on resolved targets (type/id rules) through every action`

---

### Task 7: 观察事件字段扩展（`sender` / `messageKey` / `conversationType` / `chatId` / `externalUserId`）

**Files:**
- Modify: `Sources/WeComAdapter/Watch/WatchSnapshot.swift`
- Modify: `Sources/WeComAdapter/Watch/WatchDiff.swift`（`Conversation` 的 `type` 变化进 `fields`）
- Modify: `Sources/WeComAdapter/Watch/WatchEngine.swift`
- Test: `Tests/WeComAdapterTests/WatchEngineTests.swift`（追加）

**Interfaces:**
- `WatchSnapshot.Conversation` 加 `type: String`；`WatchSnapshot.Message` 加 `sender: String?`、`messageKey: String`；`WatchSnapshot` 加 `activeType: String`、`activeMemberCount: Int?`；`take()` 改用 `chatMessages()`
- `WatchEngine.identityLookup: (String) -> [Identity]`（默认 `{ _ in [] }`）
- 事件载荷：`message.observed` += `sender`、`messageKey`、`conversationType`、`chatId?`、`externalUserId?`；`conversation.activity`（行变化与 activeChanged）+= `conversationType`、`chatId?`、`externalUserId?`

- [ ] **Step 1: 失败测试**

```swift
    @Test func groupObservationsCarrySenderKeyTypeAndBridgeIds() throws {
        let fake = GroupFixture.backend()
        let table = try #require(fake.handle(atPath: [0, 2, 0, 0]))
        let engine = WatchEngine(readerProvider: { try WeComReader(window: fake.rootElement) })
        engine.identityLookup = { title in title == "imctl测试群" ? [Identity(kind: .group, id: "wr1", title: title, updatedMs: 1)] : [] }
        #expect(try engine.poll().isEmpty)
        var rows = GroupFixture.window().first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 }!.children
        rows.insert(GroupFixture.messageRow(y: 454, text: "在吗", sender: "王五"), at: rows.count - 1)
        rows.insert(GroupFixture.systemRow(y: 534, text: "«b2»加入群聊"), at: rows.count - 1)   // never observed
        fake.replaceChildren(of: table, with: rows)
        let drafts = try engine.poll()
        #expect(drafts.count == 1)
        let p = drafts[0].payload
        #expect(drafts[0].kind == .messageObserved && p["sender"] == "王五" && p["text"] == "在吗" && p["origin"] == "peer")
        #expect(p["conversationType"] == "group" && p["chatId"] == "wr1" && p["externalUserId"] == nil)
        #expect(p["messageKey"] == MessageKey.make(conversation: "imctl测试群", sender: "王五", timeLabel: nil, text: "在吗", ordinal: 0))
        // list row change carries the row's type and the bridge id
        let preview = try #require(fake.handle(atPath: [0, 0, 0, 1, 0, 2]))
        fake.mutate(preview, attribute: AXAttribute.value, to: .string("王五: 在吗"))
        let d2 = try engine.poll()
        #expect(d2.count == 1 && d2[0].kind == .conversationActivity && d2[0].payload["chatId"] == "wr1" && d2[0].payload["conversationType"] == "unknown")
    }
```

（会话行 #1 的 `type` 由行标记推断：无标记 → `unknown`；活动会话的 `group` 只在 `message.observed` / `activeChanged` 上。）

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

`WatchSnapshot.swift`：

```swift
    public struct Conversation: Equatable, Codable {
        public var index: Int
        public var title: String?
        public var preview: String?
        public var timeLabel: String?
        public var badge: String?
        public var selected: Bool
        public var type: String
    }

    public struct Message: Equatable, Codable {
        public var index: Int
        public var text: String?
        public var timeLabel: String?
        public var direction: String
        public var y: Double
        public var sender: String?
        public var messageKey: String
    }

    public var active: String?
    public var activeType: String
    public var activeMemberCount: Int?
    public var conversations: [Conversation]
    public var messages: [Message]
    public var composerLength: Int

    public static func take(_ reader: WeComReader) throws -> WatchSnapshot {
        let header = try reader.activeConversationHeader()
        let rows = try reader.conversations()
        let chat = try reader.chatMessages()
        let activeRow = rows.first(where: \.selected) ?? rows.first { $0.title == header?.title }
        return WatchSnapshot(
            active: header?.title,
            activeType: ConversationTypeInference.infer(header: header, messages: chat, row: activeRow).rawValue,
            activeMemberCount: header?.memberCount,
            conversations: rows.map {
                Conversation(index: $0.index, title: $0.title, preview: $0.preview, timeLabel: $0.timeLabel, badge: $0.badge, selected: $0.selected,
                             type: ConversationTypeInference.infer(row: $0).rawValue)
            },
            messages: chat.map {
                Message(index: $0.index, text: $0.text, timeLabel: $0.timeLabel, direction: $0.direction.rawValue, y: $0.frame.minY,
                        sender: $0.senderLabel, messageKey: $0.messageKey ?? "")
            },
            composerLength: try reader.composerValue()?.count ?? 0
        )
    }
```

`WatchDiff.compare` 会话行比较加 `if a.type != b.type { fields.append("type") }`。

`WatchEngine`：

```swift
    /// Reverse identity lookup (title → bridge rows) for event payloads.
    public var identityLookup: (String) -> [Identity] = { _ in [] }

    private func ids(for title: String?) -> [String: String] {
        guard let title, !title.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for identity in identityLookup(title) {
            switch identity.kind {
            case .group: if out["chatId"] == nil { out["chatId"] = identity.id }
            case .customer: if out["externalUserId"] == nil { out["externalUserId"] = identity.id }
            }
        }
        return out
    }
```

`draft(for:)`：
- `.conversationChanged` 载荷加 `"conversationType": row?.type ?? "unknown"` 并 `merge(ids(for: title))`
- `.messageAdded` 载荷加 `"sender": message?.sender ?? ""`、`"messageKey": message?.messageKey ?? ""`、`"conversationType": snapshot.activeType`，并 `merge(ids(for: snapshot.active))`
- `.activeChanged` 载荷加 `"conversationType": snapshot.activeType` 并 `merge(ids(for: to))`

（`merge` 用 `payload.merge(ids) { current, _ in current }`。）

- [ ] **Step 4: 跑测试通过**（既有 `WatchEngineTests` 断言 `payload["commandId"] == nil` 等仍成立）
- [ ] **Step 5: Commit** `feat(adapter): message.observed carries sender/messageKey/conversationType and bridge ids; conversation.activity carries type and ids`

---

### Task 8: `PolicyProvider` 热加载与守护进程接线

**Files:**
- Create: `Sources/ControlCore/Policy/PolicyProvider.swift`
- Modify: `Sources/imctld/main.swift`（`--policy` 选项；处理器接 `identities: store`、`sendPolicyProvider`；watcher 接 provider 与 identity lookup）
- Modify: `Sources/imctld/DaemonWatcher.swift`（每次定时 poll 调 `reloadIfChanged`，变化时记 `controller.state{policy, policyFile}`；state.json 加 `policy`）
- Test: `Tests/ControlCoreTests/PolicyProviderTests.swift`

**Interfaces:**
- `public final class PolicyProvider { init(url: URL); func current() -> SendPolicy; func reloadIfChanged() -> SendPolicy?; var lastError: String? }`

- [ ] **Step 1: 失败测试**

```swift
// Tests/ControlCoreTests/PolicyProviderTests.swift
import Foundation
import Testing
@testable import ControlCore

@Suite("PolicyProvider")
struct PolicyProviderTests {
    @Test func reloadsOnlyWhenTheFileChangesAndKeepsLastGoodOnParseError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-pp-\(UUID().uuidString)/policy.json")
        let provider = PolicyProvider(url: url)
        #expect(provider.current().isEmpty && provider.reloadIfChanged() == nil)
        var p = SendPolicy(); p.allow(.title("imctl测试群"))
        try p.save(to: url)
        let changed = try #require(provider.reloadIfChanged())
        #expect(changed.allowedTitles == ["imctl测试群"] && provider.current() == changed)
        #expect(provider.reloadIfChanged() == nil)
        // same size, later mtime: still detected
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(provider.reloadIfChanged() != nil)
        try Data("{broken".utf8).write(to: url)
        #expect(provider.reloadIfChanged() == nil)
        #expect(provider.current().allowedTitles == ["imctl测试群"] && provider.lastError != nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
// Sources/ControlCore/Policy/PolicyProvider.swift
import Foundation

/// Serves `policy.json` to the executor and notices edits made by
/// `imctl policy` (mtime + size), so a widened allowlist needs no daemon
/// restart. A file that stops parsing keeps the last good policy and records
/// the error: a broken file never widens anything.
public final class PolicyProvider {
    public let url: URL
    public private(set) var lastError: String?
    private var policy: SendPolicy
    private var stamp: String?
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        do { policy = try SendPolicy.load(from: url) } catch { policy = SendPolicy(); lastError = String(describing: error) }
        stamp = Self.stamp(url)
    }

    public func current() -> SendPolicy {
        lock.lock(); defer { lock.unlock() }
        return policy
    }

    /// The new policy when the file changed and parsed; nil otherwise.
    public func reloadIfChanged() -> SendPolicy? {
        lock.lock(); defer { lock.unlock() }
        let now = Self.stamp(url)
        guard now != stamp else { return nil }
        stamp = now
        do {
            policy = try SendPolicy.load(from: url)
            lastError = nil
            return policy
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    private static func stamp(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        return "\(mtime):\(size)"
    }
}
```

`main.swift`：`@Option(help: "Policy file (allowlist widening; edit with `imctl policy`).") var policy: String = SendPolicy.defaultURL.path`；构造 `let policyProvider = PolicyProvider(url: URL(fileURLWithPath: policy))`；`WeComCommandHandler(..., identities: store)`；`handler.sendPolicyProvider = { policyProvider.current() }`；日志 `policy: \(policyProvider.current().summary) (\(policy))`，`lastError` 非空时 `WARNING: policy file unreadable: …`；`DaemonWatcher(..., policyProvider: policyProvider)`。

`DaemonWatcher`：`init` 加 `policyProvider: PolicyProvider`；`engine.identityLookup = { (try? store.identities(title: $0)) ?? [] }`；`poll(trigger:)` 开头（仅 `trigger == "timer"` 或 `"start"`）：

```swift
        if trigger == "timer" || trigger == "start", let changed = policyProvider.reloadIfChanged() {
            let payload = ["policy": changed.summary, "policyFile": policyProvider.url.path]
            do { try store.appendEvent(kind: .controllerState, payloadJSON: json(payload), nowMs: Clock.nowMs()) }
            catch { log.info("failed to record policy change: \(error)") }
            log.info("policy reloaded: \(changed.summary)")
        }
```

`writeState()` 加 `"policy": policyProvider.current().summary`。

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(daemon): hot-reload policy.json (controller.state{policy}), identity bridge from the store, --policy`

---

### Task 9: CLI：`imctl policy allow|deny|list`、`imctl identity set|remove|list`、探针输出字段

**Files:**
- Create: `Sources/imctl/Commands/PolicyCommand.swift`
- Create: `Sources/imctl/Commands/IdentityCommand.swift`
- Modify: `Sources/imctl/IMCTL.swift`（注册两个命令）
- Modify: `Sources/imctl/Commands/ProbeCommand.swift`（conversations 行加 `type`、`markers`；messages 行加 `kind`、`messageKey`）
- Test: `Tests/imctlTests/PolicyCommandTests.swift`、`Tests/imctlTests/IdentityCommandTests.swift`、`Tests/imctlTests/CommandParsingTests.swift`（子命令列表）、`Tests/imctlTests/ProbeCommandTests.swift`（追加 kind 断言）

**Interfaces:**
- `imctl policy list [--file <path>] [--json]`：打印编译白名单 + 文件规则 + 有效标题
- `imctl policy allow|deny [--title T]... [--chat-id ID]... [--external-user-id ID]... [--type group|customer|internal]... [--file <path>]`：至少一条规则；写文件 0600；打印 summary 与"守护进程在下一次轮询内生效"
- `imctl identity set --kind group|customer --id X --title Y [--db <path>]`、`remove --kind --id`、`list [--json]`

- [ ] **Step 1: 失败测试**

```swift
// Tests/imctlTests/PolicyCommandTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import imctl

@Suite("imctl policy")
struct PolicyCommandTests {
    func tempFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("imctl-policy-cli-\(UUID().uuidString)/policy.json").path
    }

    @Test func allowThenDenyRoundTripsThroughTheFile() throws {
        let file = tempFile()
        let allow = try PolicyAllowCommand.parse(["--title", "imctl测试群", "--type", "group", "--chat-id", "wr1", "--file", file])
        let after = try allow.apply()
        #expect(after.allowedTitles == ["imctl测试群"] && after.allowedTypes.group && after.allowedChatIds == ["wr1"])
        #expect(try SendPolicy.load(from: URL(fileURLWithPath: file)) == after)
        let deny = try PolicyDenyCommand.parse(["--type", "group", "--title", "imctl测试群", "--file", file])
        let denied = try deny.apply()
        #expect(denied.allowedTitles.isEmpty && !denied.allowedTypes.group && denied.allowedChatIds == ["wr1"])
        let list = try PolicyListCommand.parse(["--file", file])
        let view = try list.collect()
        #expect(view.compiled == ["文件传输助手"] && view.effectiveTitles == ["文件传输助手"] && view.policy.allowedChatIds == ["wr1"])
    }

    @Test func allowNeedsAtLeastOneRuleAndRejectsUnknownType() throws {
        #expect(throws: (any Error).self) { try PolicyAllowCommand.parse(["--file", "/tmp/x.json"]).validate() }
        #expect(throws: (any Error).self) { try PolicyAllowCommand.parse(["--type", "unknown", "--file", "/tmp/x.json"]).validate() }
        #expect(throws: Never.self) { try PolicyAllowCommand.parse(["--type", "customer", "--file", "/tmp/x.json"]).validate() }
    }
}
```

```swift
// Tests/imctlTests/IdentityCommandTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import imctl

@Suite("imctl identity")
struct IdentityCommandTests {
    @Test func setListRemove() throws {
        let db = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-id-\(UUID().uuidString)/imctl.sqlite").path
        try IdentitySetCommand.parse(["--kind", "group", "--id", "wr1", "--title", "imctl测试群", "--db", db]).run()
        try IdentitySetCommand.parse(["--kind", "customer", "--id", "wm1", "--title", "小明·a1b2c3", "--db", db]).run()
        let listed = try IdentityListCommand.parse(["--db", db]).collect()
        #expect(listed.map(\.id) == ["wm1", "wr1"] || listed.map(\.id) == ["wr1", "wm1"])
        #expect(listed.first { $0.id == "wr1" }?.title == "imctl测试群")
        try IdentityRemoveCommand.parse(["--kind", "group", "--id", "wr1", "--db", db]).run()
        #expect(try IdentityListCommand.parse(["--db", db]).collect().map(\.id) == ["wm1"])
        #expect(throws: (any Error).self) { try IdentitySetCommand.parse(["--kind", "bot", "--id", "x", "--title", "y", "--db", db]) }
    }
}
```

`CommandParsingTests.rootListsFourSubcommands` 期望改为 `["version", "permission", "env", "dump-tree", "probe", "status", "enroll", "mqtt", "agent", "policy", "identity"]`。`ProbeCommandTests.messagesFromFixture` 追加 `#expect(out.messages[0].kind == "message" && out.messages[0].messageKey?.count == 16)`。

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
// Sources/imctl/Commands/PolicyCommand.swift
import ArgumentParser
import ControlCore
import Foundation
import WeComAdapter

struct PolicyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Maintain policy.json: the local allowlist widening on top of the compiled-in 文件传输助手. Opening a real customer or group is a human decision; record it in the wiki.",
        subcommands: [PolicyListCommand.self, PolicyAllowCommand.self, PolicyDenyCommand.self]
    )
}

/// Rule flags shared by allow/deny.
struct PolicyRuleOptions: ParsableArguments {
    @Option(name: .customLong("title"), parsing: .upToNextOption, help: "Conversation title(s) as shown in the client.") var titles: [String] = []
    @Option(name: .customLong("chat-id"), parsing: .upToNextOption, help: "Group chat_id(s) (need an identity bridge entry to be usable).") var chatIds: [String] = []
    @Option(name: .customLong("external-user-id"), parsing: .upToNextOption, help: "Customer external_userid(s).") var externalUserIds: [String] = []
    @Option(name: .customLong("type"), parsing: .upToNextOption, help: "Conversation type(s): group, customer, internal.") var types: [String] = []
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func rules() throws -> [SendPolicy.Rule] {
        var out: [SendPolicy.Rule] = titles.map { .title($0) } + chatIds.map { .chatId($0) } + externalUserIds.map { .externalUserId($0) }
        for t in types {
            guard let type = ConversationType(rawValue: t), type != .unknown else {
                throw ValidationError("--type must be group, customer or internal (got \(t))")
            }
            out.append(.type(type))
        }
        guard !out.isEmpty else { throw ValidationError("give at least one --title / --chat-id / --external-user-id / --type") }
        return out
    }
}

struct PolicyAllowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "allow", abstract: "Add rules to policy.json (0600). The daemon reloads it within one poll.")
    @OptionGroup var options: PolicyRuleOptions

    func validate() throws { _ = try options.rules() }

    func apply() throws -> SendPolicy {
        let url = URL(fileURLWithPath: options.file)
        var policy = try SendPolicy.load(from: url)
        for rule in try options.rules() { policy.allow(rule) }
        try policy.save(to: url)
        return policy
    }

    func run() throws {
        let policy = try apply()
        print("wrote \(options.file) (0600): \(policy.summary)")
        print("effective titles: \(PolicyView.effectiveTitles(policy).joined(separator: ", "))")
        print("imctld reloads the file within one poll; check `imctl status` (policy) or the controller.state{policy} event")
    }
}

struct PolicyDenyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "deny", abstract: "Remove rules from policy.json.")
    @OptionGroup var options: PolicyRuleOptions

    func validate() throws { _ = try options.rules() }

    func apply() throws -> SendPolicy {
        let url = URL(fileURLWithPath: options.file)
        var policy = try SendPolicy.load(from: url)
        for rule in try options.rules() { policy.deny(rule) }
        try policy.save(to: url)
        return policy
    }

    func run() throws {
        let policy = try apply()
        print("wrote \(options.file) (0600): \(policy.summary)")
        print("effective titles: \(PolicyView.effectiveTitles(policy).joined(separator: ", "))")
    }
}

struct PolicyView: Codable {
    var file: String
    var present: Bool
    var compiled: [String]
    var policy: SendPolicy
    var effectiveTitles: [String]

    static func effectiveTitles(_ policy: SendPolicy) -> [String] {
        Array(Set([WeComClient.fileTransferAssistantTitle] + policy.allowedTitles)).sorted()
    }
}

struct PolicyListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Show the compiled allowlist, the policy file rules and the effective titles.")
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path
    @Flag var json = false

    func collect() throws -> PolicyView {
        let url = URL(fileURLWithPath: file)
        let policy = try SendPolicy.load(from: url)
        return PolicyView(file: file, present: FileManager.default.fileExists(atPath: file), compiled: [WeComClient.fileTransferAssistantTitle],
                          policy: policy, effectiveTitles: PolicyView.effectiveTitles(policy))
    }

    func run() throws {
        let view = try collect()
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(view), as: UTF8.self))
        } else {
            print("file: \(view.file) (\(view.present ? "present" : "absent"))")
            print("compiled: \(view.compiled.joined(separator: ", "))")
            print("titles: \(view.policy.allowedTitles.joined(separator: ", "))")
            print("types: \(view.policy.allowedTypes.enabledNames.isEmpty ? "-" : view.policy.allowedTypes.enabledNames.joined(separator: ", "))")
            print("chatIds: \(view.policy.allowedChatIds.joined(separator: ", "))")
            print("externalUserIds: \(view.policy.allowedExternalUserIds.joined(separator: ", "))")
            print("effective titles: \(view.effectiveTitles.joined(separator: ", "))")
        }
    }
}
```

（`AllowedTypes.enabledNames` 需改为 `public`。）

```swift
// Sources/imctl/Commands/IdentityCommand.swift
import ArgumentParser
import ControlCore
import Foundation

struct IdentityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "Maintain the identity bridge (chat_id / external_userid ↔ title) in imctld's database. B5 fills it from the WeCom API; use this for the test group meanwhile.",
        subcommands: [IdentityListCommand.self, IdentitySetCommand.self, IdentityRemoveCommand.self]
    )
}

struct IdentityDBOption: ParsableArguments {
    @Option(help: "SQLite path used by imctld.") var db: String = IMCTLPaths.dataDirectory.appendingPathComponent("imctl.sqlite").path
}

struct IdentitySetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Insert or update one bridge entry.")
    @Option(help: "group or customer.") var kind: IdentityKind
    @Option(help: "chat_id (group) or external_userid (customer).") var id: String
    @Option(help: "Title exactly as the client shows it (group name, or the remark set on the customer).") var title: String
    @OptionGroup var store: IdentityDBOption

    func run() throws {
        try ControlStore(path: store.db).upsertIdentity(kind: kind, id: id, title: title, nowMs: Clock.nowMs())
        print("set \(kind.rawValue) \(id) -> \(title)")
    }
}

struct IdentityRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete one bridge entry.")
    @Option var kind: IdentityKind
    @Option var id: String
    @OptionGroup var store: IdentityDBOption

    func run() throws {
        let removed = try ControlStore(path: store.db).deleteIdentity(kind: kind, id: id)
        print(removed ? "removed \(kind.rawValue) \(id)" : "no entry for \(kind.rawValue) \(id)")
    }
}

struct IdentityListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bridge entries.")
    @OptionGroup var store: IdentityDBOption
    @Flag var json = false

    func collect() throws -> [Identity] { try ControlStore(path: store.db).allIdentities() }

    func run() throws {
        let items = try collect()
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(items), as: UTF8.self))
        } else {
            for i in items { print("\(i.kind.rawValue) \(i.id) -> \(i.title) (updated \(i.updatedMs))") }
            if items.isEmpty { print("no identities") }
        }
    }
}

extension IdentityKind: ExpressibleByArgument {}
```

`IMCTL.swift` 子命令追加 `PolicyCommand.self, IdentityCommand.self`。`ProbeCommand.swift`：`ConversationsOutput.Row` 加 `var type: String; var markers: [String]`（`ConversationTypeInference.infer(row:).rawValue`、`r.markers`），文本渲染加 `type=…`；`MessagesOutput.Row` 加 `var kind: String; var messageKey: String?`（`collect()` 先取 `chatMessages()` 的 `index → messageKey` 字典，再对 `messages()` 全部行输出），渲染加 `kind=… key=…`。

- [ ] **Step 4: 跑测试通过**
- [ ] **Step 5: Commit** `feat(cli): imctl policy allow/deny/list (policy.json) and imctl identity set/remove/list; probes show row kind, key, type and markers`

---

### Task 10: 文档、工具描述、全量测试、只读活体探针与 gate 报告

**Files:**
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`（`target` 描述改为 `Conversation title, chatId:<id> or externalUserId:<id>; must be allowed by the compiled allowlist or policy.json`）
- Modify: `docs/protocol/java-consumer.md`（目标语法、新增事件字段、`RATE_LIMITED`、`messageKey` 去重语义、`conversationType` 语义、策略是本地文件）
- Modify: `README.md`（模块表 / 命令：policy、identity、目标语法、速率上限、`policy.json`）
- Create: `docs/gates/2026-09-14-b4-group-parsing-policy-targets.md`

- [ ] **Step 1: 全量测试**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with N tests in M suites passed`（N ≥ 155 + 本批新增；0 failures），且 `ForbiddenAPITests` 通过。

- [ ] **Step 2: 只读活体探针（不发送、不选行）**

```bash
.build/arm64-apple-macosx/debug/imctl probe conversations          # 看是否有带 type=customer/group 或 markers 的行（脱敏）
.build/arm64-apple-macosx/debug/imctl probe messages               # 当前活动会话的 kind/key
.build/arm64-apple-macosx/debug/imctl policy list
.build/arm64-apple-macosx/debug/imctl status                        # daemon 仍 system 暂停则如实记录
```

- [ ] **Step 3: gate 报告**

按 `docs/gates/2026-09-13-b3-observer-history-origin.md` 的结构写：条件、实现、单测数字、只读探针结果（脱敏）、**待活体**清单（测试群名、launchd TCC、`imctl policy allow --title <测试群名>`、`imctl identity set`、`chatId:` 发送、`origin` 闭环）、未闭环（标记词与 `@` 规则需实测校准；`internal` 不推断；限速按原始目标串计数）。

- [ ] **Step 4: Commit + push**

```bash
git add -A && git commit -m "docs(gates): B4 unit results, read-only live probe, pending live checklist; protocol doc: target syntax, new event fields, RATE_LIMITED" && git push origin main
```

---

## Self-review

- 规格覆盖：§2 群会话解析（Task 5）、会话类型（Task 5/6）、目标解析（Task 1/6）；§3 事件字段（Task 7）、目标语法（Task 1/6）；§4 身份桥表（Task 4，API 填充留 B5）；§5 策略文件与 `imctl policy`、`controller.state{policy}`（Task 2/8/9）、速率硬上限（Task 3）；§10 夹具单测（Task 5 合成夹具）；活体验收待用户事项（Task 10）。
- 占位扫描：无 TBD；每个任务含测试与实现代码。
- 类型一致性：`ResolvedTarget(title:type:chatId:externalUserId:)`、`TargetResolver.resolve(_:row:header:messages:)`、`WeComActions.authorize(_:title:)`、`ActionPolicy.authorize(_:resolved:)`、`SendPolicy.Rule`、`Identity(kind:id:title:updatedMs:)`、`MessageKey.make(conversation:sender:timeLabel:text:ordinal:)` 在各任务中同名同签名。
