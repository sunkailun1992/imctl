# S3 imctl CLI 只读骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `imctl permission` / `env` / `dump-tree` / `version` 四个只读子命令，对真实企微执行 `dump-tree` 不做任何动作；输出经脱敏后存为 `Tests/Fixtures/ax-trees/` 夹具，统计写入 `docs/gates/`。

**Architecture:** CLI 逻辑留在 `imctl` 可执行 target（用 `@testable import imctl` 测试），主机环境探测拆为纯数据结构 `HostEnvironment`（可测渲染/JSON）与 live 探针 `HostProbe`（IOKit / CoreGraphics session / Security，不可测但薄）。脱敏放在 AXKit（`AXRedactionPolicy` + `AXNode.redacted(_:)`），因为它是夹具机制的一部分，且与企微无关。企微常量（bundle id、应用名）放进 `WeComAdapter.WeComClient`。`dump-tree --from-fixture` 让整条命令管线不依赖 live AX 即可测试。

**Tech Stack:** swift-argument-parser 1.8.2、AppKit（NSRunningApplication / NSScreen / NSWorkspace）、IOKit（IOPMrootDomain `AppleClamshellState`、`IOPMCopySystemPowerSettings`）、CoreGraphics（`CGSessionCopyCurrentDictionary`、`CGDisplayIsAsleep`）、Security（`SecCodeCopySelf`）。

## Global Constraints

- 四个子命令都不调用 `setAttribute` / `performAction`；`permission --prompt` 是唯一会弹系统对话的路径，`env` 永不弹窗。
- `dump-tree` 默认脱敏；`--raw` 才输出原文，且原文文件名必须以 `.raw.json` 结尾（已被 `.gitignore` 忽略）。
- 夹具只保留「文件传输助手」这一真实标题；其余文本替换为加盐哈希占位符（同一次 dump 内一致，不可逆）。
- 禁用 API 守卫继续生效（`CGSessionCopyCurrentDictionary`、`CGDisplayIsAsleep` 不含被禁 token）。

---

### Task 1: `WeComClient` 常量与 `HostEnvironment` 数据结构

**Files:**
- Modify: `Sources/WeComAdapter/WeComAdapter.swift` → 重命名为 `Sources/WeComAdapter/WeComClient.swift`
- Create: `Sources/imctl/Host/HostEnvironment.swift`
- Modify: `Package.swift`（加 `testTarget(name: "imctlTests", dependencies: ["imctl"])`，`imctl` 加 `WeComAdapter` 已有）
- Test: `Tests/WeComAdapterTests/WeComClientTests.swift`、`Tests/imctlTests/HostEnvironmentTests.swift`

**Interfaces:**
- Produces:

```swift
// WeComAdapter
public enum WeComClient {
    public static let bundleID = "com.tencent.WeWorkMac"
    public static let displayName = "企业微信"
    /// The only send target allowed in phases 0/1. Compiled in on purpose.
    public static let fileTransferAssistantTitle = "文件传输助手"
}

// imctl
struct HostEnvironment: Codable, Equatable {
    var timestamp: String            // ISO8601
    var macOSVersion: String
    var architecture: String
    var accessibilityTrusted: Bool
    var clamshellClosed: Bool?
    var sleepDisabled: Bool?
    var onACPower: Bool?
    var screenLocked: Bool?
    var displayAsleep: Bool?
    var displayCount: Int
    var client: ClientInfo?          // nil = not running
    var process: ProcessInfoSnapshot

    struct ClientInfo: Codable, Equatable { var bundleID: String; var version: String?; var pid: Int32; var hidden: Bool; var active: Bool }
    struct ProcessInfoSnapshot: Codable, Equatable { var executablePath: String; var signingIdentifier: String?; var signingTeam: String?; var signed: Bool }

    func render() -> String      // 人类可读多行文本，键对齐
    func jsonString() throws -> String   // pretty + sortedKeys
}
```

- [ ] **Step 1: 写失败测试**

```swift
// Tests/WeComAdapterTests/WeComClientTests.swift
import Testing
@testable import WeComAdapter

@Suite("WeComClient")
struct WeComClientTests {
    @Test func constantsAreTheAgreedOnes() {
        #expect(WeComClient.bundleID == "com.tencent.WeWorkMac")
        #expect(WeComClient.fileTransferAssistantTitle == "文件传输助手")
    }
}
```

```swift
// Tests/imctlTests/HostEnvironmentTests.swift
import Testing
@testable import imctl

@Suite("HostEnvironment")
struct HostEnvironmentTests {
    static func sample() -> HostEnvironment {
        HostEnvironment(
            timestamp: "2026-09-11T05:00:00Z", macOSVersion: "26.6.2", architecture: "arm64",
            accessibilityTrusted: false, clamshellClosed: true, sleepDisabled: true, onACPower: true,
            screenLocked: false, displayAsleep: false, displayCount: 2,
            client: .init(bundleID: "com.tencent.WeWorkMac", version: "5.0.10", pid: 123, hidden: true, active: false),
            process: .init(executablePath: "/tmp/imctl", signingIdentifier: "com.sunkailun.imctl", signingTeam: nil, signed: true)
        )
    }

    @Test func renderListsEveryFieldOnItsOwnLine() {
        let text = Self.sample().render()
        #expect(text.contains("accessibility_trusted: false"))
        #expect(text.contains("clamshell_closed: true"))
        #expect(text.contains("client: com.tencent.WeWorkMac 5.0.10 pid=123 hidden=true active=false"))
        #expect(text.contains("signing: com.sunkailun.imctl (team: -)"))
    }

    @Test func renderShowsUnknownForNilProbes() {
        var env = Self.sample()
        env.clamshellClosed = nil
        env.client = nil
        let text = env.render()
        #expect(text.contains("clamshell_closed: unknown"))
        #expect(text.contains("client: not running"))
    }

    @Test func jsonRoundTrips() throws {
        let env = Self.sample()
        let json = try env.jsonString()
        #expect(json.contains("\"accessibilityTrusted\" : false"))
        let back = try JSONDecoder().decode(HostEnvironment.self, from: Data(json.utf8))
        #expect(back == env)
    }
}
```

- [ ] **Step 2: 确认失败** `swift build --build-tests` → `cannot find 'HostEnvironment'`。
- [ ] **Step 3: 实现两文件 + Package.swift；`swift test`** → PASS。
- [ ] **Step 4: 提交** `git commit -m "feat(cli): add WeComClient constants and HostEnvironment model"`

### Task 2: `AXRedactionPolicy` 与 `AXNode.redacted`

**Files:**
- Create: `Sources/AXKit/AXRedaction.swift`
- Test: `Tests/AXKitTests/AXRedactionTests.swift`

**Interfaces:**
- Produces:

```swift
public struct AXRedactionPolicy {
    public var keepTexts: Set<String>          // 原样保留的文本（如 文件传输助手）
    public var keepRoles: Set<String>          // 这些角色的 title/value/description 视为 UI 骨架，原样保留
    public var keepPattern: NSRegularExpression? // 匹配即保留（时间/日期/纯数字标签）
    public var salt: String                    // 每次 dump 随机；占位符 = "«" + sha256(salt+text) 前 8 hex + "»"
    public static func `default`(keepTexts: Set<String>, salt: String = UUID().uuidString) -> AXRedactionPolicy
    public func redact(_ text: String) -> String   // 保留或替换
}
public extension AXNode {
    func redacted(_ policy: AXRedactionPolicy) -> AXNode   // 递归；不改 role/subrole/roleDescription/identifier/frame/actions/settable/extra 键；extra 值也走 redact
}
```

默认 `keepRoles`：`AXButton AXRadioButton AXCheckBox AXPopUpButton AXMenuButton AXMenu AXMenuItem AXMenuBar AXMenuBarItem AXTabGroup AXToolbar AXSplitter AXScrollBar AXSearchField AXApplication`；默认 `keepPattern`：`^[0-9０-９:：/\-\.\s年月日时分秒昨天今天前天上午下午周星期一二三四五六日]+$`。`placeholder` 字段（输入框占位文案）始终保留，`help` 走 redact。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/AXKitTests/AXRedactionTests.swift
import Testing
@testable import AXKit

@Suite("AXRedaction")
struct AXRedactionTests {
    let policy = AXRedactionPolicy.default(keepTexts: ["文件传输助手"], salt: "fixed-salt")

    @Test func keepsAllowlistedRolesAndTexts() {
        #expect(policy.redact("文件传输助手") == "文件传输助手")
        #expect(policy.redact("14:32") == "14:32")
        #expect(policy.redact("昨天 上午9:05") == "昨天 上午9:05")
        #expect(policy.redact("3") == "3")
    }

    @Test func replacesOtherTextDeterministicallyAndIrreversibly() {
        let a = policy.redact("张三")
        let b = policy.redact("张三")
        let c = policy.redact("李四")
        #expect(a == b)
        #expect(a != c)
        #expect(a.hasPrefix("«") && a.hasSuffix("»") && a.count == 10)
        #expect(!a.contains("张"))
        #expect(AXRedactionPolicy.default(keepTexts: [], salt: "other").redact("张三") != a)
    }

    @Test func redactsTreeButKeepsStructureAndChrome() {
        let tree = AXNode(role: AXRole.application, title: "企业微信", children: [
            AXNode(role: AXRole.window, title: "张三", children: [
                AXNode(role: AXRole.row, title: "张三", description: "未读 2", extra: ["AXSelectedRows": "张三"]),
                AXNode(role: AXRole.row, title: "文件传输助手"),
                AXNode(role: AXRole.button, title: "发送", help: "张三的按钮"),
                AXNode(role: AXRole.textArea, value: .string("hello 张三"), placeholder: "输入消息"),
            ]),
        ])
        let out = tree.redacted(policy)
        #expect(out.title == "企业微信")                              // AXApplication 在 keepRoles
        #expect(out.children[0].title != "张三")                       // 窗口标题脱敏
        let rows = out.children[0].children
        #expect(rows[0].title == out.children[0].title)                // 同文本同占位符
        #expect(rows[0].description != "未读 2")
        #expect(rows[0].extra["AXSelectedRows"] == rows[0].title)
        #expect(rows[1].title == "文件传输助手")
        #expect(rows[2].title == "发送")                               // 按钮标题保留
        #expect(rows[2].help != "张三的按钮")
        #expect(rows[3].value?.stringValue != "hello 张三")
        #expect(rows[3].placeholder == "输入消息")
        #expect(out.count == tree.count)
    }
}
```

- [ ] **Step 2: 确认失败 → 实现（sha256 用 CryptoKit）→ PASS。**
- [ ] **Step 3: 提交** `git commit -m "feat(axkit): add fixture redaction policy"`

### Task 3: 子命令 `version` / `permission` / `env` 与 `HostProbe`

**Files:**
- Modify: `Sources/imctl/IMCTL.swift`（`subcommands: [VersionCommand.self, PermissionCommand.self, EnvCommand.self, DumpTreeCommand.self]`）
- Create: `Sources/imctl/Commands/VersionCommand.swift`
- Create: `Sources/imctl/Commands/PermissionCommand.swift`
- Create: `Sources/imctl/Commands/EnvCommand.swift`
- Create: `Sources/imctl/Host/HostProbe.swift`
- Create: `Sources/imctl/Host/CodeSigningInfo.swift`
- Test: `Tests/imctlTests/CommandParsingTests.swift`

**Interfaces:**
- `imctl version [--json]` → `imctl 0.1.0-dev (com.sunkailun.imctl)`。
- `imctl permission [--prompt] [--open-settings] [--json]` → 退出码 0 已授权 / 2 未授权；`--prompt` 用 `AXIsProcessTrustedWithOptions` 弹系统对话；`--open-settings` 用 `NSWorkspace.shared.open(AXPermission.accessibilitySettingsURL)`。
- `imctl env [--json] [--bundle <id>]`（默认 `WeComClient.bundleID`）→ `HostProbe.snapshot(bundleID:backend:)` 渲染。
- `HostProbe`：`static func snapshot(bundleID: String, backend: AXBackend) -> HostEnvironment`；内部 `clamshellClosed()`（IOKit `IOPMrootDomain` 的 `AppleClamshellState`）、`sleepDisabled()`（`IOPMCopySystemPowerSettings()["SleepDisabled"]`）、`onACPower()`（`IOPSGetProvidingPowerSourceType` == AC）、`screenLocked()`（`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`）、`displayAsleep()`（`CGDisplayIsAsleep(CGMainDisplayID())`）、`displayCount`（`NSScreen.screens.count`）、`client(bundleID:)`（`NSRunningApplication` + `Bundle(url:)`）。每个探针失败返回 nil，不抛。
- `CodeSigningInfo.current()` → `(identifier: String?, team: String?, signed: Bool)`，用 `SecCodeCopySelf` + `SecCodeCopySigningInformation(kSecCSSigningInformation)`。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/imctlTests/CommandParsingTests.swift
import ArgumentParser
import Testing
@testable import imctl

@Suite("Command parsing")
struct CommandParsingTests {
    @Test func rootListsFourSubcommands() {
        let names = IMCTL.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names == ["version", "permission", "env", "dump-tree"])
    }

    @Test func dumpTreeDefaultsAreReadOnlyAndRedacted() throws {
        let cmd = try DumpTreeCommand.parse([])
        #expect(cmd.bundle == "com.tencent.WeWorkMac")
        #expect(cmd.depth == 12)
        #expect(cmd.raw == false)
        #expect(cmd.output == nil)
    }

    @Test func rawOutputMustUseRawSuffix() {
        #expect(throws: (any Error).self) { try DumpTreeCommand.parse(["--raw", "--output", "x.json"]).validate() }
        #expect(throws: Never.self) { try DumpTreeCommand.parse(["--raw", "--output", "x.raw.json"]).validate() }
    }

    @Test func envDefaultsToWeCom() throws {
        #expect(try EnvCommand.parse([]).bundle == "com.tencent.WeWorkMac")
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS；手工 `swift run imctl version`、`swift run imctl env`（不得弹窗）、`swift run imctl permission`。**
- [ ] **Step 3: 提交** `git commit -m "feat(cli): add version, permission and env commands with host probes"`

### Task 4: `dump-tree`

**Files:**
- Create: `Sources/imctl/Commands/DumpTreeCommand.swift`
- Create: `Sources/imctl/Host/TreeReport.swift`（统计：节点数、深度、角色直方图、truncated、errors；`render()`）
- Test: `Tests/imctlTests/DumpTreeCommandTests.swift`

**Interfaces:**
- `imctl dump-tree [--bundle <id>] [--pid <n>] [--depth 12] [--max-children 400] [--extra AXSelectedRows ...] [--from-fixture <path>] [--raw] [--keep <text> ...] [--output <path>] [--summary]`
  - 默认 `--extra` 为 `["AXSelectedRows", "AXSelectedChildren", "AXNumberOfCharacters"]`。
  - `--keep` 默认 `[WeComClient.fileTransferAssistantTitle]`。
  - 无 `--output` 时 JSON 打到 stdout；`--summary` 只打 `TreeReport`（永远打到 stderr 一份）。
  - `--from-fixture`：读 `AXNode` → `FakeAXBackend` → 同样的 dumper/脱敏/报告管线；用于测试与重脱敏。
- `TreeReport.make(from: AXNode, stats: AXTreeDumper.Stats) -> TreeReport`；`render()`。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/imctlTests/DumpTreeCommandTests.swift
import Foundation
import Testing
@testable import AXKit
@testable import imctl

@Suite("dump-tree pipeline")
struct DumpTreeCommandTests {
    func fixtureURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tree = AXNode(role: AXRole.application, title: "企业微信", children: [
            AXNode(role: AXRole.window, title: "张三", children: [
                AXNode(role: AXRole.row, title: "张三"),
                AXNode(role: AXRole.row, title: "文件传输助手"),
            ]),
        ])
        let url = dir.appendingPathComponent("in.json")
        try tree.write(to: url)
        return url
    }

    @Test func fixtureRoundTripRedactsByDefault() throws {
        let input = try fixtureURL()
        let output = input.deletingLastPathComponent().appendingPathComponent("out.json")
        var cmd = try DumpTreeCommand.parse(["--from-fixture", input.path, "--output", output.path])
        let report = try cmd.runPipeline()
        let node = try AXNode.load(from: output)
        #expect(node.children[0].title != "张三")
        #expect(node.children[0].children[1].title == "文件传输助手")
        #expect(report.nodes == 4)
        #expect(report.roles["AXRow"] == 2)
    }

    @Test func rawKeepsText() throws {
        let input = try fixtureURL()
        let output = input.deletingLastPathComponent().appendingPathComponent("out.raw.json")
        var cmd = try DumpTreeCommand.parse(["--from-fixture", input.path, "--output", output.path, "--raw"])
        _ = try cmd.runPipeline()
        #expect(try AXNode.load(from: output).children[0].title == "张三")
    }
}
```

- [ ] **Step 2: 确认失败 → 实现 → PASS。**
- [ ] **Step 3: 对真实企微执行（只读）：**

```bash
swift build
.build/debug/imctl permission            # 未授权则退出码 2，按提示授权后重试
.build/debug/imctl env
.build/debug/imctl dump-tree --summary
.build/debug/imctl dump-tree --output Tests/Fixtures/ax-trees/wecom-5.0.10-main.json
```

  记录：`docs/gates/2026-09-11-s3-dump-tree.md`（环境快照、TreeReport、观察到的关键角色/标识符，不含任何联系人文本）。检查夹具 `grep -c "«" 夹具` > 0 且不含真实姓名。

- [ ] **Step 4: 提交** `git commit -m "feat(cli): add dump-tree with redacted fixtures and gate notes"`

## Self-Review

- 规格覆盖：`permission --prompt`（T3）、`env` 合盖/显示/锁屏/AX 授权/客户端版本（T1+T3）、`dump-tree --bundle --depth --json`（T4，JSON 是默认格式）、`version`（T3）、夹具与 `docs/gates`（T4 Step 3）。
- 类型一致：`HostEnvironment` 字段名在 T1 定义，T3 `HostProbe.snapshot` 填充同名字段；`AXRedactionPolicy.default(keepTexts:salt:)` 在 T2 定义，T4 以 `--keep` 传入。
- `DumpTreeCommand.runPipeline()` 返回 `TreeReport`，`run()` 只是 `runPipeline()` + 打印。

## 执行结果（2026-09-11）

- 4 个任务完成，`swift test` 34 个测试通过。live 运行见 `docs/gates/2026-09-11-s3-dump-tree.md`。
- 偏离：`IOPMCopySystemPowerSettings` 未暴露给 Swift，`SleepDisabled` 改读 `/Library/Preferences/com.apple.PowerManagement.plist`；企微窗口在另一 Space 时 `AXChildren`/`AXWindows` 为空，新增 `--root main-window|focused-window`；脱敏模式补充保留 `true/false/<element>/<n elements>` 结构摘要。
