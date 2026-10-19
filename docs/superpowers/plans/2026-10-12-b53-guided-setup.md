# B53 初始化向导与快捷修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 体检结果里的每条修复带一个有类型的动作；控制台新增体检页和首次启动向导，点按钮、确认后就修；命令行 `imctl doctor --fix` 用同一套动作逐项询问；新增安装一致性、运行健康、对接状态和本机客户端几类检查。

**Architecture:**
- **ControlCore**：动作类型（`ReadinessAction`）、确认文字与分类（`ReadinessActionText`）、本机客户端判断（`ReadinessClient`）。
- **守护进程**：在判定规则里给每条修复写定动作，并提供新事实：build 号、命令计数、watcher 近一小时出错、MQTT 最近一次命令。
- **控制台**：按动作类型执行，执行类先确认，重启类先查有没有命令在执行；体检页、向导和设置表单组件共用这一入口。
- **命令行**：`DoctorFix` 用同样的类型和文字逐项询问。
- 任何客户端都不执行报告里的命令文字。

**Tech Stack:** Swift 6 工具链 / Swift 5 语言模式、SwiftPM、swift-testing、SwiftUI（控制台）、swift-argument-parser（命令行）。

**Spec:** `docs/superpowers/specs/2026-10-12-b53-guided-setup.md`

## Global Constraints

- 不新增包依赖。
- 新文件（含注释）不得出现 `ForbiddenAPITests` 的标记：`CGEvent`、`CGWarpMouseCursor`、`CGPostKeyboardEvent`、`IOHIDPostEvent`、`CGPreflightListenEventAccess`、`CGRequestListenEventAccess`、`CGRequestScreenCaptureAccess`、`CGPreflightScreenCaptureAccess`、`ScreenCaptureKit`、`SCScreenshotManager`、`CGWindowListCreateImage`、`CGDisplayCreateImage`、`CGWindowListCopyWindowInfo`、`NSPasteboard`。
- 动作只认 `ReadinessAction.Kind` 的 12 种：`openSystemSettings`、`openWeCom`、`setup`、`reinstallDaemon`、`restartDaemon`、`resumeDaemon`、`registerAgents`、`installSkills`、`retest`、`openSettings`、`openPolicy`、`openLogs`。客户端不执行 `ReadinessFix.command` 的文字，也不接受报告里的路径或地址。
- 规则：
  - 执行类动作一律先确认；`openSettings`、`openPolicy`、`openLogs` 只换页，不确认；
  - `setup`、`reinstallDaemon`、`restartDaemon` 在 `runningCommands > 0` 时拒绝，确认那一刻再查一次；
  - `runningCommands` 为 nil（旧守护进程）或守护进程连不上时按 0 处理，因为没有可打断的命令。
- `controller.readiness` 仍是分发器查询：不新增 RPC 方法，MCP `tools/list` 仍为 45。报告只新增 `build`（String?）与 `runningCommands`（Int?）；修复只新增 `action`。新增内容都是 build 号、计数和时间。
- 控制台从不自动联网实测：打开体检页、向导，以及启动时，只调 `online:false`；定时刷新不调用体检。联网实测只在点「运行体检」、完成页按钮，或确认 `retest` 后进行。
- 系统设置只打开三个写死的地址：`Privacy_Accessibility`、`Privacy_ScreenCapture`、`Privacy_AllFiles`。
- 向导不改策略；密钥只在 `SecureField` 输入，沿用现有保存函数。
- 文字约定：面向使用者的文字用中文；代码、注释、提交信息用英文（仓库现有风格）。修复命令以 `imctl ` 开头，由渲染方换成实际路径。
- 版本 `IMCTLVersion.string = "1.0.16-dev"`。
- 构建与测试一律 `swift test --scratch-path <会话 scratchpad>/b53-build`，命令里写作 `$BUILD`。
- 每个任务结束前：`swift build` 通过、相关测试通过；提交前跑 `bash scripts/check-secrets.sh`（不得新增提醒）和 `git diff --check`。提交信息最后一行为 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

- 全新的 Mac，守护进程还没装（体检请求连不上）：控制台启动应弹出向导；第 1 步和体检页显示兜底信息并给「安装并请求授权」按钮，不能空白或崩溃。→ Task 8 `startupWithoutADaemonOpensTheWizard`、`fallbackLinesOfferSetup`。
- 弹出确认框之后、点「确认」之前，有命令开始执行：确认那一刻要再查一次，拒绝重启。→ Task 6 `aCommandThatStartsBeforeConfirmationBlocksTheRestart`。
- 正在运行的是 B52 守护进程（报告里没有 `action`、`build`、`runningCommands`）：页面仍能显示，没有动作的修复不出按钮，重启类按 0 处理，可以执行。→ Task 1 `aB52ReportDecodes`、Task 6 `aReportWithoutRunningCommandsAllowsTheRestart`。
- 向导中途按 Esc 关掉：记下标记，以后不再自动弹出；从菜单重新打开时，从第 1 步开始，已配置的功能默认勾上。→ Task 9 `closingMarksDoneAndReopeningStartsOver`。
- `imctl doctor --fix` 在管道或定时任务里跑（stdin 不是终端），或与 `--json` 同用：直接拒绝，不执行任何动作。→ Task 5 `fixNeedsATerminalAndNoJSON`。

---

## 文件结构

| 文件 | 职责 | 任务 |
|---|---|---|
| `Sources/ControlCore/Readiness/ReadinessAction.swift`（新） | 动作类型、确认文字、分类、系统设置地址 | 1 |
| `Sources/ControlCore/Protocol/ReadinessTypes.swift`（改） | `ReadinessFix.action`、`ReadinessReport.build`、`runningCommands` | 1 |
| `Sources/ControlCore/Readiness/ReadinessFacts.swift`（改） | 新事实：build、命令计数、近一小时出错、MQTT 最近命令 | 2 |
| `Sources/ControlCore/Readiness/ReadinessEvaluator.swift`（改） | 每条修复带动作；build 检查；运行健康；MQTT 最近命令 | 2 |
| `Sources/ControlCore/Readiness/ReadinessClient.swift`（新） | 读 app 的 build 号、判断终端能否直接用 imctl、build 比较 | 3 |
| `Sources/ControlCore/Store/ControlStore.swift`（改） | 按状态与时间计数命令 | 3 |
| `Sources/imctld/WatchHealth.swift`、`DaemonWatcher.swift`（改） | 近一小时 watcher 出错 | 3 |
| `Sources/MQTTTransport/MQTTBinding.swift`（改） | 最近一次 MQTT 命令时间 | 3 |
| `Sources/imctld/DaemonReadiness.swift`、`DaemonRuntime.swift`、`main.swift`（改） | 新事实装配 | 3 |
| `Sources/imctl/Host/Doctor.swift`、`Commands/DoctorCommand.swift`（改） | 渲染修正、本机客户端组、`--fix` 入口 | 4、5 |
| `Sources/imctl/Host/DoctorFix.swift`（新） | `--fix` 逐项询问与执行 | 5 |
| `Sources/imctl-console/Model/ConsoleModel.swift`（改） | 导航状态、动作入口、启动行为、向导状态 | 6、8、9 |
| `Sources/imctl-console/Views/SettingsForms.swift`（新）、`SettingsView.swift`（改） | 四个设置表单组件 | 7 |
| `Sources/imctl-console/Views/ReadinessPageView.swift`（新）、`ReadinessComponents.swift`（新） | 体检页与共用组件（能力列表、动作按钮、确认框） | 8 |
| `Sources/imctl-console/Model/ReadinessText.swift`（改） | 本机客户端与兜底文字 | 8 |
| `Sources/imctl-console/Views/ConsoleWindow.swift`、`StatusView.swift`、`MenuBarMenu.swift`（改），`DiagnosticsView.swift`（删） | 侧栏、状态页瘦身、菜单 | 8 |
| `Sources/imctl-console/Model/SetupWizard.swift`（新） | 向导步骤与完成判断（纯逻辑） | 9 |
| `Sources/imctl-console/Views/SetupWizardView.swift`（新） | 向导界面 | 10 |
| 文档、`IMCTLVersion.swift`（改） | 协议 §6.45、智能体文档、运维文档、版本 | 11 |

---

### Task 1: 动作类型与报告字段

**Files:**
- Create: `Sources/ControlCore/Readiness/ReadinessAction.swift`
- Modify: `Sources/ControlCore/Protocol/ReadinessTypes.swift`
- Test: `Tests/ControlCoreTests/ReadinessActionTests.swift`（新）

**Interfaces:**
- Produces:
  - `ReadinessAction`：`kind: String`、`target: String?`、`init(_ kind: Kind, target: String? = nil)`、`init(kind: String, target: String? = nil)`、`known: Kind?`、`restartsDaemon: Bool`、`navigatesOnly: Bool`；
  - `ReadinessAction.Kind`（12 个 case）；
  - `ReadinessActionText.button(_:) -> String?`、`confirmation(_:) -> String?`、`busy: String`、`systemSettingsURL(_ target: String?) -> URL?`；
  - `ReadinessFix.action: ReadinessAction?`，以及 `ReadinessFix(text:command:action:)`；
  - `ReadinessReport.build: String?`、`runningCommands: Int?`，`init` 末尾新增两个默认为 nil 的参数。

- [ ] **Step 1：写失败测试** `Tests/ControlCoreTests/ReadinessActionTests.swift`

```swift
import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness actions")
struct ReadinessActionTests {
    @Test func aFixCarriesItsActionOnTheWire() throws {
        let fix = ReadinessFix(text: "t", command: "imctl setup", action: ReadinessAction(.restartDaemon))
        let json = String(decoding: try JSONEncoder().encode(fix), as: UTF8.self)
        #expect(json.contains(#""action":{"kind":"restartDaemon"}"#))
        #expect(try JSONDecoder().decode(ReadinessFix.self, from: Data(json.utf8)) == fix)
    }

    @Test func anUnknownKindDecodesAndOffersNothing() throws {
        let fix = try JSONDecoder().decode(ReadinessFix.self, from: Data(#"{"text":"x","action":{"kind":"somethingNew"}}"#.utf8))
        let action = try #require(fix.action)
        #expect(action.known == nil && !action.restartsDaemon && !action.navigatesOnly)
        #expect(ReadinessActionText.button(action) == nil && ReadinessActionText.confirmation(action) == nil)
    }

    @Test func onlyTheThreeDaemonKindsRestartAndOnlyThreeKindsNavigate() {
        let restarts = ReadinessAction.Kind.allCases.filter { ReadinessAction($0).restartsDaemon }
        #expect(Set(restarts) == [.setup, .reinstallDaemon, .restartDaemon])
        let navigates = ReadinessAction.Kind.allCases.filter { ReadinessAction($0).navigatesOnly }
        #expect(Set(navigates) == [.openSettings, .openPolicy, .openLogs])
    }

    @Test func everyExecutingKindIsConfirmedAndNavigationIsNot() {
        for kind in ReadinessAction.Kind.allCases {
            let action = ReadinessAction(kind, target: kind == .openSystemSettings ? "screenRecording" : nil)
            #expect(ReadinessActionText.button(action) != nil, "\(kind)")
            let question = ReadinessActionText.confirmation(action)
            #expect((question == nil) == action.navigatesOnly, "\(kind)")
            if action.restartsDaemon { #expect(question?.contains("守护进程会重启") == true, "\(kind)") }
        }
    }

    @Test func systemSettingsOpensOnlyTheThreeFixedPages() {
        #expect(ReadinessActionText.systemSettingsURL("accessibility")?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        #expect(ReadinessActionText.systemSettingsURL("screenRecording")?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        #expect(ReadinessActionText.systemSettingsURL("fullDiskAccess")?.absoluteString.hasSuffix("Privacy_AllFiles") == true)
        #expect(ReadinessActionText.systemSettingsURL("x-apple.systempreferences:anything") == nil)
        #expect(ReadinessActionText.systemSettingsURL(nil) == nil)
    }

    /// A B52 daemon answers without `build`, `runningCommands` or any `action`.
    @Test func aB52ReportDecodes() throws {
        let json = #"{"ready":false,"nextStep":{"text":"打开企业微信并登录","command":"open -b com.tencent.WeWorkMac"},"capabilities":[],"online":{"state":"skipped"},"version":"1.0.15-dev","generatedMs":1}"#
        let report = try JSONDecoder().decode(ReadinessReport.self, from: Data(json.utf8))
        #expect(report.build == nil && report.runningCommands == nil && report.nextStep?.action == nil)
    }
}
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter ReadinessActionTests`
Expected: 编译失败，找不到 `ReadinessAction`。

- [ ] **Step 3：实现** `Sources/ControlCore/Readiness/ReadinessAction.swift`

```swift
import Foundation

/// B53: what a fix button does. Typed — clients run only these kinds and never execute a fix's command text.
/// `kind` stays a string on the wire, so a client that does not know a newer kind shows the fix without a button.
public struct ReadinessAction: Codable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case openSystemSettings, openWeCom, setup, reinstallDaemon, restartDaemon, resumeDaemon,
             registerAgents, installSkills, retest, openSettings, openPolicy, openLogs
    }

    public var kind: String
    public var target: String?

    public init(_ kind: Kind, target: String? = nil) { self.kind = kind.rawValue; self.target = target }
    /// A kind by name, as it arrives on the wire (forward compatibility and tests).
    public init(kind: String, target: String? = nil) { self.kind = kind; self.target = target }

    /// nil for a kind this build does not know: show the fix text only.
    public var known: Kind? { Kind(rawValue: kind) }

    /// Restarts the daemon: refused while a command is running, then confirmed.
    public var restartsDaemon: Bool {
        guard let known else { return false }
        return [.setup, .reinstallDaemon, .restartDaemon].contains(known)
    }

    /// Changes nothing by itself (another page or the log): no confirmation.
    public var navigatesOnly: Bool {
        guard let known else { return false }
        return [.openSettings, .openPolicy, .openLogs].contains(known)
    }
}

/// Words for actions, shared by the console and `imctl doctor --fix` so both ask the same question.
public enum ReadinessActionText {
    public static let busy = "有命令正在执行，现在不能重启守护进程；稍后再试"

    public static func button(_ action: ReadinessAction) -> String? {
        switch action.known {
        case .openSystemSettings?: return "打开系统设置"
        case .openWeCom?: return "打开企业微信"
        case .setup?: return "安装并请求授权"
        case .reinstallDaemon?: return "重装守护进程"
        case .restartDaemon?: return "重启守护进程"
        case .resumeDaemon?: return "解除暂停"
        case .registerAgents?: return "注册并安装技能"
        case .installSkills?: return "更新技能文件"
        case .retest?: return "重新实测"
        case .openSettings?: return "去配置"
        case .openPolicy?: return "去策略页"
        case .openLogs?: return "看日志"
        case nil: return nil
        }
    }

    /// The question asked before an action runs; nil for navigation and unknown kinds.
    public static func confirmation(_ action: ReadinessAction) -> String? {
        guard let kind = action.known, !action.navigatesOnly else { return nil }
        let restart = "守护进程会重启，几秒内不可用。"
        switch kind {
        case .openSystemSettings: return "将打开系统设置的「\(paneName(action.target))」页。"
        case .openWeCom: return "将打开企业微信。"
        case .setup: return "将安装或更新后台常驻，并请求系统授权（会弹出系统对话框）。" + restart
        case .reinstallDaemon: return "将按当前配置重装后台常驻（已配置 MQTT 就以 MQTT 模式运行）。" + restart
        case .restartDaemon: return "将重启守护进程。" + restart
        case .resumeDaemon: return "将解除手动（api）暂停，守护进程恢复执行命令。"
        case .registerAgents: return "将在 Claude Code 和 Codex 里注册 imctl，并安装技能文件。"
        case .installSkills: return "将用应用里的版本覆盖两边的技能文件。"
        case .retest: return "将重新联网实测，可能包含一次视觉模型调用。"
        case .openSettings, .openPolicy, .openLogs: return nil
        }
    }

    /// The three System Settings pages a fix may open. Fixed here, never taken from a report.
    public static func systemSettingsURL(_ target: String?) -> URL? {
        let anchor: String
        switch target {
        case "accessibility": anchor = "Privacy_Accessibility"
        case "screenRecording": anchor = "Privacy_ScreenCapture"
        case "fullDiskAccess": anchor = "Privacy_AllFiles"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    static func paneName(_ target: String?) -> String {
        switch target {
        case "accessibility": return "辅助功能"
        case "screenRecording": return "屏幕与系统录音"
        case "fullDiskAccess": return "完全磁盘访问权限"
        default: return "隐私与安全性"
        }
    }
}
```

修改 `Sources/ControlCore/Protocol/ReadinessTypes.swift`：

```swift
/// What to do about a capability. `command` starts with `imctl ` when it is this CLI; renderers swap in
/// the path the reader can run (`ReadinessCommandText`). `action` (B53) is what a fix button does.
public struct ReadinessFix: Codable, Equatable, Sendable {
    public var text: String
    public var command: String?
    public var action: ReadinessAction?
    public init(text: String, command: String? = nil, action: ReadinessAction? = nil) {
        self.text = text; self.command = command; self.action = action
    }
}
```

`ReadinessReport` 在 `generatedMs` 之后加两个字段，`init` 末尾加参数：

```swift
    /// B53: the build the daemon is running (CFBundleVersion read at its start); nil outside an app bundle.
    public var build: String?
    /// B53: commands accepted or running when the report was made; clients refuse a daemon restart while > 0.
    public var runningCommands: Int?
    public init(ready: Bool, nextStep: ReadinessFix?, nextStepCapability: String?, capabilities: [ReadinessCapability],
                online: ReadinessOnlineInfo, version: String, generatedMs: Int64, build: String? = nil, runningCommands: Int? = nil) {
        self.ready = ready; self.nextStep = nextStep; self.nextStepCapability = nextStepCapability
        self.capabilities = capabilities; self.online = online; self.version = version; self.generatedMs = generatedMs
        self.build = build; self.runningCommands = runningCommands
    }
```

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "ReadinessActionTests|ReadinessTypesTests"`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/ControlCore/Readiness/ReadinessAction.swift Sources/ControlCore/Protocol/ReadinessTypes.swift Tests/ControlCoreTests/ReadinessActionTests.swift
git commit -m "feat(readiness): typed fix actions, their confirmation words, and report build and running-command fields" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 新事实、新检查与每条修复的动作

**Files:**
- Modify: `Sources/ControlCore/Readiness/ReadinessFacts.swift`
- Modify: `Sources/ControlCore/Readiness/ReadinessEvaluator.swift`
- Test: `Tests/ControlCoreTests/ReadinessEvaluatorTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `ReadinessAction`。
- Produces:
  - `ReadinessFacts.runningBuild`、`installedBuild: String?`；`runningCommands: Int`；`health: ReadinessFacts.Health(failedLastHour:unknownLastHour:)`；`Watch.errorsLastHour: Int`；`MQTT.lastCommandMs: Int64?`。以上均有默认值，`init` 参数加在末尾。
  - 新能力 `health`（标题「运行健康」，排在最后，只出提醒）；
  - `ReadinessEvaluator.kickstartCommand`；
  - 报告带上 `build`、`runningCommands`。

计划阶段核实后的一处修正：规格写的 `watchErrors` 是「启动以来」的出错次数。长期运行的守护进程只要出过一次错就会一直提醒，所以改为**最近一小时**出错次数（`Watch.errorsLastHour`），与另外两项计数口径一致。

**动作对照表**（逐条写进判定规则）：

| 能力 | 情形 | 动作 |
|---|---|---|
| daemon | 不是 launchd 启动 | `setup`（文字改为先停掉手动运行的那个） |
| daemon | build 不一致（新） | `restartDaemon` |
| daemon | api 暂停 | `resumeDaemon` |
| daemon | 其它保护暂停 | `openLogs` |
| wecom | 没运行 / 主窗口读不到 | `openWeCom` |
| read | 辅助功能 | `setup` |
| media | 屏幕录制 | `openSystemSettings(screenRecording)` |
| media | 访问企微数据：absent | `openWeCom` |
| media | 访问企微数据：pending | 无 |
| media | 访问企微数据：其它 | `openSystemSettings(fullDiskAccess)` |
| contactAdd | 未配置 | `openPolicy(phones)` |
| autoAccept | 未配置 | `openPolicy(autoAccept)` |
| autoAccept | 角标不能归属 | 无 |
| vision | 未配置 / 无效 / 已关闭 / 没密钥 / 被拒（http、auth、http4xx、config） | `openSettings(vision)` |
| vision | 屏幕录制 | `openSystemSettings(screenRecording)` |
| vision | 实测其它失败 | `retest` |
| mqtt | 未配置 / 无效 / 没连上 | `openSettings(mqtt)` |
| mqtt | 没有以 MQTT 模式运行 | `reinstallDaemon` |
| mqtt | 发布失败 | `retest` |
| oss | 未配置 / 无效 / 被拒（auth、http4xx）/ 往返其它失败 | `openSettings(oss)` |
| oss | 不是启动时读到的那份 | `restartDaemon` |
| oss | 探测对象没删掉（cleanup） | 无 |
| agents | 两边都没登记 | `registerAgents` |
| agents | 技能缺失或过期 | `installSkills` |
| agents | 登记路径不对 | 无（要先手动删除旧登记） |
| agents | 握手失败 | `retest` |
| wecomApi | 未配置 / 无效 | `openSettings(proxy)` |
| wecomApi | 不是启动时读到的那份 | `restartDaemon` |
| wecomApi | 健康检查失败 | `retest` |
| health | 有提醒 | `openLogs` |

- [ ] **Step 1：写失败测试**（加进 `ReadinessEvaluatorTests`；同时把 `capabilitiesComeInFixOrder` 的期望末尾加上 `"health"`）

```swift
    func action(_ r: ReadinessReport, _ id: String) throws -> ReadinessAction? { try cap(r, id).fix?.action }

    @Test func aBuildTheDaemonIsNotRunningFailsItWithARestart() throws {
        var f = Self.healthy(); f.runningBuild = "268"; f.installedBuild = "269"
        let daemon = try cap(evaluate(f), "daemon")
        #expect(daemon.status == .fail && daemon.fix?.action == ReadinessAction(.restartDaemon))
        #expect(daemon.checks.contains { $0.id == "build" && $0.status == .fail && $0.detail.contains("268") && $0.detail.contains("269") })
        f.installedBuild = "268"
        #expect(try cap(evaluate(f), "daemon").checks.contains { $0.id == "build" && $0.status == .ok })
        f.runningBuild = nil; f.installedBuild = nil
        #expect(try !cap(evaluate(f), "daemon").checks.contains { $0.id == "build" })
    }

    /// B52 deferred minor: a manually run daemon must be stopped before `setup` installs the agent.
    @Test func aManualRunSaysToStopItFirst() throws {
        var f = Self.healthy(); f.launchedByLaunchd = false
        let fix = try #require(try cap(evaluate(f), "daemon").fix)
        #expect(fix.text.contains("先停掉手动运行的那个") && fix.action == ReadinessAction(.setup))
    }

    @Test func everyFixCarriesTheAgreedAction() throws {
        var f = Self.healthy(); f.pauseReasons = ["api"]
        #expect(try action(evaluate(f), "daemon") == ReadinessAction(.resumeDaemon))
        f = Self.healthy(); f.pauseReasons = ["local_guard"]
        #expect(try action(evaluate(f), "daemon") == ReadinessAction(.openLogs))
        f = Self.healthy(); f.clientRunning = false
        #expect(try action(evaluate(f), "wecom") == ReadinessAction(.openWeCom))
        f = Self.healthy(); f.watch.clientAvailable = false
        #expect(try action(evaluate(f), "wecom") == ReadinessAction(.openWeCom))
        f = Self.healthy(); f.accessibilityTrusted = false
        #expect(try action(evaluate(f), "read") == ReadinessAction(.setup))
        f = Self.healthy(); f.screenRecordingGranted = false
        #expect(try action(evaluate(f), "media") == ReadinessAction(.openSystemSettings, target: "screenRecording"))
        f = Self.healthy(); f.wecomData = "absent"
        #expect(try action(evaluate(f), "media") == ReadinessAction(.openWeCom))
        f = Self.healthy(); f.wecomData = "pending"
        #expect(try action(evaluate(f), "media") == nil)
        f = Self.healthy(); f.fullDiskAccess = false; f.wecomData = "unknown (pass prompt:true to probe; probing shows the system dialog once)"
        #expect(try action(evaluate(f), "media") == ReadinessAction(.openSystemSettings, target: "fullDiskAccess"))
        f = Self.healthy()
        #expect(try action(evaluate(f), "contactAdd") == ReadinessAction(.openPolicy, target: "phones"))
        #expect(try action(evaluate(f), "autoAccept") == ReadinessAction(.openPolicy, target: "autoAccept"))
        f.policy.autoAccept = "all"; f.watch.railProblem = "slot"
        #expect(try action(evaluate(f), "autoAccept") == nil)
        f = Self.healthy()
        #expect(try action(evaluate(f), "vision") == ReadinessAction(.openSettings, target: "vision"))
        f.vision = Self.visionOn(); f.vision.keyPresent = false
        #expect(try action(evaluate(f), "vision") == ReadinessAction(.openSettings, target: "vision"))
        f.vision = Self.visionOn()
        #expect(try action(evaluate(f, [.vision: .failure("auth", latencyMs: 9)]), "vision") == ReadinessAction(.openSettings, target: "vision"))
        #expect(try action(evaluate(f, [.vision: .failure("timeout", latencyMs: 9)]), "vision") == ReadinessAction(.retest))
        f = Self.healthy()
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.openSettings, target: "mqtt"))
        f.mqtt = .init(config: .init(present: true, valid: false))
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.openSettings, target: "mqtt"))
        f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: false, connected: false)
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.reinstallDaemon))
        f.mqtt.daemonMode = true
        #expect(try action(evaluate(f), "mqtt") == ReadinessAction(.openSettings, target: "mqtt"))
        f.mqtt.connected = true
        #expect(try action(evaluate(f, [.mqtt: .failure("rejected", latencyMs: 9)]), "mqtt") == ReadinessAction(.retest))
        f = Self.healthy()
        #expect(try action(evaluate(f), "oss") == ReadinessAction(.openSettings, target: "oss"))
        f.oss = .init(present: true, valid: true, loaded: false)
        #expect(try action(evaluate(f), "oss") == ReadinessAction(.restartDaemon))
        f.oss = .init(present: true, valid: true)
        #expect(try action(evaluate(f, [.oss: .failure("auth", latencyMs: 9)]), "oss") == ReadinessAction(.openSettings, target: "oss"))
        #expect(try action(evaluate(f, [.oss: .failure("cleanup", latencyMs: 9)]), "oss") == nil)
        f = Self.healthy()
        #expect(try action(evaluate(f), "agents") == ReadinessAction(.registerAgents))
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .stale), cliPresent: true)
        #expect(try action(evaluate(f), "agents") == ReadinessAction(.installSkills))
        f.agents = .init(claude: .init(registered: true, commandMatches: false, skill: .current), cliPresent: true)
        #expect(try action(evaluate(f), "agents") == nil)
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .current), cliPresent: true)
        #expect(try action(evaluate(f, [.agents: .failure("launch", latencyMs: 9)]), "agents") == ReadinessAction(.retest))
        f = Self.healthy()
        #expect(try action(evaluate(f), "wecomApi") == ReadinessAction(.openSettings, target: "proxy"))
        f.wecomApi = .init(present: true, valid: true, loaded: false)
        #expect(try action(evaluate(f), "wecomApi") == ReadinessAction(.restartDaemon))
        f.wecomApi = .init(present: true, valid: true)
        #expect(try action(evaluate(f, [.wecomApi: .failure("network", latencyMs: 9)]), "wecomApi") == ReadinessAction(.retest))
    }

    @Test func runtimeHealthWarnsWithoutBlockingReady() throws {
        var f = Self.healthy(); f.health = .init(failedLastHour: 2, unknownLastHour: 1); f.watch.errorsLastHour = 4
        let r = evaluate(f)
        let health = try cap(r, "health")
        #expect(health.status == .ok && !health.required && health.warnings.count == 3)
        #expect(health.fix?.action == ReadinessAction(.openLogs) && r.ready)
        #expect(try cap(evaluate(Self.healthy()), "health").fix == nil)
    }

    @Test func mqttShowsWhenTheLastCommandArrived() throws {
        var f = Self.healthy(); f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: true, connected: true, lastCommandMs: 2_000 - 180_000)
        #expect(try cap(evaluate(f), "mqtt").checks.contains { $0.id == "lastCommand" && $0.detail == "最近一次收到命令：3 分钟前" })
        f.mqtt.lastCommandMs = nil
        #expect(try cap(evaluate(f), "mqtt").checks.contains { $0.id == "lastCommand" && $0.detail == "守护进程启动后还没收到过命令" })
    }

    @Test func theReportCarriesTheBuildAndRunningCommands() {
        var f = Self.healthy(); f.runningBuild = "269"; f.installedBuild = "269"; f.runningCommands = 2
        let r = evaluate(f)
        #expect(r.build == "269" && r.runningCommands == 2)
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter ReadinessEvaluatorTests`
Expected: 编译失败（`runningBuild`、`health`、`errorsLastHour`、`lastCommandMs` 不存在）。

- [ ] **Step 3：实现事实**（`ReadinessFacts.swift`）

`Watch` 末尾加字段与参数：

```swift
        /// B53: watcher polls that failed with the client unreachable or degraded in the last hour.
        public var errorsLastHour: Int
        public init(lastPollAgeMs: Int64? = nil, lastPollOK: Bool = false, clientAvailable: Bool? = nil,
                    conversationCount: Int = 0, railRead: Bool = false, railProblem: String? = nil, errorsLastHour: Int = 0) {
            self.lastPollAgeMs = lastPollAgeMs; self.lastPollOK = lastPollOK; self.clientAvailable = clientAvailable
            self.conversationCount = conversationCount; self.railRead = railRead; self.railProblem = railProblem
            self.errorsLastHour = errorsLastHour
        }
```

`MQTT` 末尾加 `lastCommandMs`：

```swift
        /// B53: when a command last arrived over MQTT (since this daemon started); nil = none yet.
        public var lastCommandMs: Int64?
        public init(config: Config = Config(), daemonMode: Bool = false, connected: Bool = false, lastCommandMs: Int64? = nil) {
            self.config = config; self.daemonMode = daemonMode; self.connected = connected; self.lastCommandMs = lastCommandMs
        }
```

新增 `Health` 和顶层字段（`init` 末尾加 `runningBuild: String? = nil, installedBuild: String? = nil, runningCommands: Int = 0, health: Health = Health()` 并赋值）：

```swift
    /// B53: command outcomes in the last hour.
    public struct Health: Equatable, Sendable {
        public var failedLastHour: Int
        public var unknownLastHour: Int
        public init(failedLastHour: Int = 0, unknownLastHour: Int = 0) {
            self.failedLastHour = failedLastHour; self.unknownLastHour = unknownLastHour
        }
    }

    /// B53: CFBundleVersion the daemon read at its start, and the one on disk now; nil outside an app bundle.
    public var runningBuild: String?
    public var installedBuild: String?
    /// B53: commands accepted or running.
    public var runningCommands: Int
    public var health: Health
```

- [ ] **Step 4：实现判定**（`ReadinessEvaluator.swift`）

常量与 `restartDaemon` 修复：

```swift
    static let kickstartCommand = "launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl"
    static let restartDaemon = ReadinessFix(text: "这个配置是守护进程启动后才写入或改过的，重启守护进程才会生效（先确认没有命令在执行）",
                                            command: kickstartCommand, action: ReadinessAction(.restartDaemon))
```

`evaluate`：能力列表末尾加 `healthCapability(f)`；`mqttCapability` 多传 `nowMs`；报告带上 build 与 runningCommands：

```swift
            agentsCapability(f, live: live[.agents]),
            wecomApiCapability(f, live: live[.wecomApi]),
            healthCapability(f),
        ]
        ...
        return ReadinessReport(ready: ready, nextStep: first?.fix, nextStepCapability: first?.id,
                               capabilities: capabilities, online: info, version: f.version, generatedMs: nowMs,
                               build: f.runningBuild, runningCommands: f.runningCommands)
```

（`mqttCapability(f, live: live[.mqtt], nowMs: nowMs)`）

`daemonCapability` 整体替换为：

```swift
    static func daemonCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        let manual = f.pauseReasons.filter { $0 != PauseReason.system.rawValue }
        var checks = [
            ReadinessCheck(id: "launchd", status: f.launchedByLaunchd ? .ok : .fail,
                           detail: f.launchedByLaunchd ? "由 launchd 常驻" : "不是由 launchd 启动（手动运行或调试）"),
            ReadinessCheck(id: "version", status: .ok, detail: f.version),
            ReadinessCheck(id: "paused", status: manual.isEmpty ? .ok : .fail,
                           detail: f.pauseReasons.isEmpty ? "未暂停" : "暂停原因：\(f.pauseReasons.joined(separator: ","))"),
        ]
        var stale = false
        if let running = f.runningBuild, let installed = f.installedBuild {
            stale = running != installed
            checks.append(ReadinessCheck(id: "build", status: stale ? .fail : .ok,
                                         detail: stale ? "守护进程在跑 build \(running)，已安装的是 build \(installed)" : "build \(running)，与已安装版本一致"))
        }
        var fix: ReadinessFix?
        if !f.launchedByLaunchd {
            fix = ReadinessFix(text: "守护进程不是由后台常驻启动的（手动运行或调试）：先停掉手动运行的那个，再安装后台常驻并请求授权",
                               command: "imctl setup", action: ReadinessAction(.setup))
        } else if stale {
            fix = ReadinessFix(text: "升级后守护进程还没重启：重启后才会用上新版本（先确认没有命令在执行）",
                               command: kickstartCommand, action: ReadinessAction(.restartDaemon))
        } else if manual.contains(PauseReason.api.rawValue) {
            fix = ReadinessFix(text: "守护进程被手动暂停（api）；确认可以恢复后执行", command: "imctl call controller.resume",
                               action: ReadinessAction(.resumeDaemon))
        } else if !manual.isEmpty {
            fix = ReadinessFix(text: "守护进程处于保护暂停（\(manual.joined(separator: ","))）；先看日志找原因", command: "imctl call controller.logs",
                               action: ReadinessAction(.openLogs))
        }
        return ReadinessCapability(id: "daemon", title: "守护进程", required: true, status: fix == nil ? .ok : .fail, checks: checks, fix: fix)
    }
```

其余各处只在现有 `ReadinessFix(...)` 上补 `action:`，按上面的对照表逐条加：
- `wecomCapability`：`打开企业微信并登录` 与 `把企业微信主窗口打开…` 两处加 `action: ReadinessAction(.openWeCom)`；
- `readCapability`：`.setup`；
- `mediaCapability`：屏幕录制 `.openSystemSettings, target: "screenRecording"`，absent `.openWeCom`，default `.openSystemSettings, target: "fullDiskAccess"`，pending 不加；
- `contactAddCapability`：`.openPolicy, target: "phones"`；
- `autoAcceptCapability`：disabled 时 `.openPolicy, target: "autoAccept"`；rail 那条不加；
- `visionCapability`：未配置、无效、已关闭、没密钥、`http/auth/http4xx/config` 五处加 `.openSettings, target: "vision"`；屏幕录制 `.openSystemSettings, target: "screenRecording"`；`timeout/network` 与 default 加 `.retest`；
- `mqttCapability`：未配置、无效、没连上加 `.openSettings, target: "mqtt"`；`!daemonMode` 加 `.reinstallDaemon`；发布失败两处加 `.retest`；
- `ossCapability`：未配置、无效、`auth/http4xx`、default 加 `.openSettings, target: "oss"`；cleanup 不加；
- `agentsCapability`：两边都没登记 `.registerAgents`；技能 `.installSkills`；握手失败 `.retest`；登记路径不对不加；
- `wecomApiCapability`：未配置、无效 `.openSettings, target: "proxy"`；健康检查失败 `.retest`。

`mqttCapability` 签名改为 `(_ f: ReadinessFacts, live: ReadinessProbeResult?, nowMs: Int64)`。`checks` 改成 `var`，在 `connected` 与 `publish` 之间插入：

```swift
        if m.daemonMode {
            checks.insert(ReadinessCheck(id: "lastCommand", status: .ok,
                                         detail: m.lastCommandMs.map { "最近一次收到命令：\(ago(nowMs - $0))" } ?? "守护进程启动后还没收到过命令"),
                          at: checks.count - 1)
        }
```

新增：

```swift
    /// "刚刚 / N 分钟前 / N 小时前 / N 天前".
    static func ago(_ ms: Int64) -> String {
        if ms < 60_000 { return "刚刚" }
        if ms < 3_600_000 { return "\(ms / 60_000) 分钟前" }
        if ms < 86_400_000 { return "\(ms / 3_600_000) 小时前" }
        return "\(ms / 86_400_000) 天前"
    }

    /// B53: warnings only — never `fail`, so it never blocks `ready`.
    static func healthCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        let h = f.health
        let checks = [
            ReadinessCheck(id: "failed", status: .ok, detail: "最近一小时失败的命令 \(h.failedLastHour) 条"),
            ReadinessCheck(id: "unknown", status: .ok, detail: "最近一小时结果未知的命令 \(h.unknownLastHour) 条"),
            ReadinessCheck(id: "watchErrors", status: .ok, detail: "最近一小时读取企业微信出错 \(f.watch.errorsLastHour) 次"),
        ]
        var warnings: [String] = []
        if h.failedLastHour > 0 { warnings.append("最近一小时有 \(h.failedLastHour) 条命令失败") }
        if h.unknownLastHour > 0 { warnings.append("最近一小时有 \(h.unknownLastHour) 条命令结果未知：按原幂等键对账，不要换键重试") }
        if f.watch.errorsLastHour > 0 { warnings.append("最近一小时读取企业微信出错 \(f.watch.errorsLastHour) 次") }
        let fix = warnings.isEmpty ? nil : ReadinessFix(text: "看守护进程日志找原因", command: "tail -n 50 ~/Library/Logs/imctl/imctld.log",
                                                        action: ReadinessAction(.openLogs))
        return ReadinessCapability(id: "health", title: "运行健康", required: false, status: .ok, checks: checks, fix: fix, warnings: warnings)
    }
```

- [ ] **Step 5：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "ReadinessEvaluatorTests|DaemonReadinessTests|DoctorTests|ConsoleReadinessTests"`
Expected: 全部 PASS（其它套件只受新增能力影响；若有断言能力个数为 12 的测试，改为 13）。

- [ ] **Step 6：提交**

```bash
git add Sources/ControlCore/Readiness/ReadinessFacts.swift Sources/ControlCore/Readiness/ReadinessEvaluator.swift Tests/ControlCoreTests/ReadinessEvaluatorTests.swift
git commit -m "feat(readiness): every fix carries its action; build, runtime-health and last-MQTT-command checks" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 守护进程侧的新事实

**Files:**
- Create: `Sources/ControlCore/Readiness/ReadinessClient.swift`
- Modify: `Sources/ControlCore/Store/ControlStore.swift`、`Sources/imctld/WatchHealth.swift`、`Sources/imctld/DaemonWatcher.swift`、`Sources/MQTTTransport/MQTTBinding.swift`、`Sources/imctld/DaemonRuntime.swift`、`Sources/imctld/DaemonReadiness.swift`、`Sources/imctld/main.swift`
- Test: `Tests/ControlCoreTests/ReadinessClientTests.swift`（新）、`Tests/ControlCoreTests/ControlStoreTests.swift`、`Tests/imctldTests/WatchHealthTests.swift`、`Tests/MQTTTransportTests/MQTTBindingTests.swift`、`Tests/imctldTests/DaemonReadinessTests.swift`

**Interfaces:**
- Consumes: Task 2 的事实字段。
- Produces:
  - `ReadinessClient.bundleBuild(at: URL?) -> String?`、`ReadinessClient.cliLinked(cliPath:candidates:resolve:) -> Bool`、`ReadinessClient.isOlder(_:than:) -> Bool`；
  - `ControlStore.countCommands(states: [CommandStateV1], sinceMs: Int64 = 0) throws -> Int`；
  - `WatchHealth.noteError(nowMs:)`；
  - `MQTTBinding.lastCommandMs: Int64?`；
  - `DaemonRuntime.mqttBinding`；
  - `DaemonReadiness.Sources.builds`、`.commands`（都有默认值）；
  - `DaemonReadiness.commandCounts(store:nowMs:)`、`mqttFacts(url:link:lastCommandMs:)`。

- [ ] **Step 1：写失败测试**

`Tests/ControlCoreTests/ReadinessClientTests.swift`：

```swift
import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness client facts")
struct ReadinessClientTests {
    func app(build: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": build], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// Read from disk every time: an app replaced while the daemon runs must show its new build.
    @Test func theBuildIsReadFromDiskEachTime() throws {
        let url = try app(build: "268")
        #expect(ReadinessClient.bundleBuild(at: url) == "268")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "269"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        #expect(ReadinessClient.bundleBuild(at: url) == "269")
        #expect(ReadinessClient.bundleBuild(at: url.deletingLastPathComponent()) == nil)
        #expect(ReadinessClient.bundleBuild(at: nil) == nil)
    }

    @Test func theCLIIsLinkedOnlyWhenACandidateResolvesToIt() {
        let cli = "/Apps/imctl.app/Contents/MacOS/imctl"
        #expect(ReadinessClient.cliLinked(cliPath: cli, candidates: ["/usr/local/bin/imctl"], resolve: { _ in cli }))
        #expect(!ReadinessClient.cliLinked(cliPath: cli, candidates: ["/usr/local/bin/imctl"], resolve: { _ in "/Other/imctl" }))
        #expect(!ReadinessClient.cliLinked(cliPath: cli, candidates: ["/usr/local/bin/imctl"], resolve: { _ in nil }))
    }

    @Test func buildsCompareAsNumbers() {
        #expect(ReadinessClient.isOlder("99", than: "268") && !ReadinessClient.isOlder("268", than: "268"))
        #expect(!ReadinessClient.isOlder("x", than: "268"))
    }
}
```

`ControlStoreTests` 加：

```swift
    @Test func commandsAreCountedByStateAndTime() throws {
        let store = try ControlStore(path: ":memory:")
        func add(_ state: CommandStateV1, at ms: Int64) throws {
            var record = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: ms)
            record.state = state; record.updatedMs = ms
            _ = try store.insertCommand(record)
        }
        try add(.running, at: 10); try add(.accepted, at: 20); try add(.failed, at: 5); try add(.failed, at: 500); try add(.unknown, at: 600)
        #expect(try store.countCommands(states: [.accepted, .running]) == 2)
        #expect(try store.countCommands(states: [.failed], sinceMs: 100) == 1)
        #expect(try store.countCommands(states: [.unknown], sinceMs: 100) == 1)
    }
```

`WatchHealthTests` 加：

```swift
    @Test func errorsOlderThanAnHourDropOut() {
        let health = WatchHealth()
        health.noteError(nowMs: 1_000)
        health.noteError(nowMs: 3_000_000)
        #expect(health.facts(nowMs: 3_000_000).errorsLastHour == 2)
        #expect(health.facts(nowMs: 3_700_000).errorsLastHour == 1)
    }
```

`MQTTBindingTests` 加：

```swift
    @Test func theLastCommandTimeIsKept() throws {
        let (binding, _, _) = try make()
        #expect(binding.lastCommandMs == nil)
        _ = try binding.handleCommand(payload: Data(#"{"jsonrpc":"2.0","id":1,"method":"event.replay"}"#.utf8), responseTopic: nil, correlationData: nil)
        #expect(binding.lastCommandMs != nil)
    }
```

`DaemonReadinessTests` 加：

```swift
    @Test func buildsAndCountsReachTheReport() throws {
        var sources = Self.sources()
        sources.builds = { ("268", "269") }
        sources.commands = { _ in (running: 2, failedLastHour: 1, unknownLastHour: 0) }
        let report = DaemonReadiness(sources: sources).readiness(online: false, refresh: false)
        #expect(report.build == "268" && report.runningCommands == 2)
        #expect(report.capabilities.first { $0.id == "daemon" }?.fix?.action == ReadinessAction(.restartDaemon))
        #expect(report.capabilities.first { $0.id == "health" }?.warnings.count == 1)
    }

    @Test func commandCountsComeFromTheStore() throws {
        let store = try ControlStore(path: ":memory:")
        var record = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: 9_999_000)
        record.state = .failed; record.updatedMs = 9_999_000
        _ = try store.insertCommand(record)
        let counts = DaemonReadiness.commandCounts(store: store, nowMs: 10_000_000)
        #expect(counts.running == 0 && counts.failedLastHour == 1 && counts.unknownLastHour == 0)
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter "ReadinessClientTests|ControlStoreTests|WatchHealthTests|MQTTBindingTests|DaemonReadinessTests"`
Expected: 编译失败。

- [ ] **Step 3：实现**

`Sources/ControlCore/Readiness/ReadinessClient.swift`：

```swift
import Foundation

/// B53: facts only the reader's own process knows (its build, whether `imctl` is on the terminal's PATH).
public enum ReadinessClient {
    /// CFBundleVersion of the app at `appURL`, read from disk each time (`Bundle` caches its Info.plist);
    /// nil outside an `.app` (development builds).
    public static func bundleBuild(at appURL: URL?) -> String? {
        guard let appURL, appURL.pathExtension == "app",
              let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleVersion"] as? String
    }

    public static let linkCandidates = ["/usr/local/bin/imctl", "/opt/homebrew/bin/imctl"]

    /// A standard PATH directory has an `imctl` that resolves to this bundle's CLI.
    public static func cliLinked(cliPath: String, candidates: [String] = linkCandidates,
                                 resolve: (String) -> String? = { path in
                                     FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : nil
                                 }) -> Bool {
        let target = URL(fileURLWithPath: cliPath).resolvingSymlinksInPath().path
        return candidates.contains { resolve($0) == target }
    }

    /// Numeric build comparison; false when either is not a number.
    public static func isOlder(_ build: String, than other: String) -> Bool {
        guard let a = Int(build), let b = Int(other) else { return false }
        return a < b
    }
}
```

`ControlStore`（`commandCounts()` 之后）：

```swift
    /// B53 readiness: commands in any of `states` whose last update is at or after `sinceMs`, all methods.
    public func countCommands(states: [CommandStateV1], sinceMs: Int64 = 0) throws -> Int {
        try dbQueue.read { db in
            try CommandRecord.filter(states.map(\.rawValue).contains(Column("state"))).filter(Column("updated_ms") >= sinceMs).fetchCount(db)
        }
    }
```

`WatchHealth`：`Snapshot` 加 `var errorTimes: [Int64] = []`，新增方法，`facts` 带上计数：

```swift
    /// A failed poll with the client unreachable or degraded (not the Contacts tab); kept for one hour.
    func noteError(nowMs: Int64) {
        update { s in
            s.errorTimes.append(nowMs)
            s.errorTimes.removeAll { nowMs - $0 > 3_600_000 }
        }
    }
```

`facts(nowMs:)` 的 `Watch(...)` 末尾加：

```swift
errorsLastHour: s.errorTimes.filter { nowMs - $0 <= 3_600_000 }.count
```

`DaemonWatcher` 失败分支：在 `let verdict = ...` 之后加：

```swift
            if verdict != .available { health.noteError(nowMs: Clock.nowMs()) }
```

`MQTTBinding`：

```swift
    private let activityLock = NSLock()
    private var lastCommandValue: Int64?
    /// B53 readiness: when the last command arrived over MQTT; nil before the first.
    public var lastCommandMs: Int64? {
        activityLock.lock(); defer { activityLock.unlock() }
        return lastCommandValue
    }
```

`handleCommand` 第一行加：

```swift
        activityLock.lock(); lastCommandValue = Clock.nowMs(); activityLock.unlock()
```

`DaemonRuntime` 加 `var mqttBinding: MQTTBinding?`。

`DaemonReadiness.Sources` 加：

```swift
        /// (running at start, installed on disk now).
        var builds: () -> (running: String?, installed: String?) = { (nil, nil) }
        var commands: (Int64) -> (running: Int, failedLastHour: Int, unknownLastHour: Int) = { _ in (0, 0, 0) }
```

`facts(nowMs:)` 的 `ReadinessFacts(...)` 末尾加：

```swift
            runningBuild: builds.running, installedBuild: builds.installed, runningCommands: counts.running,
            health: .init(failedLastHour: counts.failedLastHour, unknownLastHour: counts.unknownLastHour))
```

方法开头取值：

```swift
        let builds = sources.builds()
        let counts = sources.commands(nowMs)
```

新增静态方法；`mqttFacts` 加参数：

```swift
    static func commandCounts(store: ControlStore, nowMs: Int64) -> (running: Int, failedLastHour: Int, unknownLastHour: Int) {
        let hour = nowMs - 3_600_000
        return ((try? store.countCommands(states: [.accepted, .running])) ?? 0,
                (try? store.countCommands(states: [.failed], sinceMs: hour)) ?? 0,
                (try? store.countCommands(states: [.unknown], sinceMs: hour)) ?? 0)
    }

    static func mqttFacts(url: URL, link: MQTTNIOLink?, lastCommandMs: Int64? = nil) -> ReadinessFacts.MQTT {
        let present = FileManager.default.fileExists(atPath: url.path)
        return ReadinessFacts.MQTT(config: .init(present: present, valid: present && (try? MQTTSettings.load(from: url)) != nil),
                                   daemonMode: link != nil, connected: link?.isConnected ?? false, lastCommandMs: lastCommandMs)
    }
```

`main.swift`：

```swift
        let appURL = Bundle.main.bundleURL
        let runningBuild = ReadinessClient.bundleBuild(at: appURL)
```

`Sources(...)` 里：

```swift
            mqtt: { DaemonReadiness.mqttFacts(url: mqttURL, link: daemon.mqttLink, lastCommandMs: daemon.mqttBinding?.lastCommandMs) },
            ...
            configStamp: { ... },
            builds: { (runningBuild, ReadinessClient.bundleBuild(at: appURL)) },
            commands: { DaemonReadiness.commandCounts(store: store, nowMs: $0) }))
```

MQTT 块里 `link.start(binding: binding)` 之后加 `daemon.mqttBinding = binding`。

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "ReadinessClientTests|ControlStoreTests|WatchHealthTests|MQTTBindingTests|DaemonReadinessTests"`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/ControlCore/Readiness/ReadinessClient.swift Sources/ControlCore/Store/ControlStore.swift Sources/imctld Sources/MQTTTransport/MQTTBinding.swift Tests
git commit -m "feat(imctld): readiness facts for the running build, command counts, recent watcher errors and the last MQTT command" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 命令行体检的渲染

**Files:**
- Modify: `Sources/imctl/Host/Doctor.swift`、`Sources/imctl/Commands/DoctorCommand.swift`
- Test: `Tests/imctlTests/DoctorTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `report.build`，Task 3 的 `ReadinessClient`。
- Produces:
  - `Doctor.ClientFacts(cliBuild: String?, onPath: Bool, cliPath: String)`；
  - `Doctor.render(_:cli:refreshAskedMs:timeZone:client:)`，新参数 `client: ClientFacts? = nil`；
  - `Doctor.showsFix(_ capability:) -> Bool`。

- [ ] **Step 1：写失败测试**（加进 `DoctorTests`）

```swift
    /// B52 deferred minors: --offline says so in the headline; "未实测" is not printed twice.
    @Test func anOfflineRunSaysSoAndUntestedIsNotRepeated() {
        var r = Self.report("skipped")
        r.capabilities[0].checks = [ReadinessCheck(id: "publish", status: .ok, detail: "未实测", tested: false)]
        let text = Doctor.render(r, cli: "imctl")
        #expect(text.hasPrefix("✔ 就绪：必需项都可用（只做了本机检查）"))
        #expect(!text.contains("未实测（未实测）"))
    }

    @Test func aFixIsShownForWarningsToo() {
        let health = ReadinessCapability(id: "health", title: "运行健康", required: false, status: .ok, checks: [],
                                         fix: ReadinessFix(text: "看守护进程日志找原因", action: ReadinessAction(.openLogs)), warnings: ["最近一小时有 1 条命令失败"])
        #expect(Doctor.showsFix(health))
        var quiet = health; quiet.warnings = []
        #expect(!Doctor.showsFix(quiet))
    }

    @Test func theClientGroupComparesBuildsAndPath() {
        var r = Self.report("done"); r.build = "268"
        let text = Doctor.render(r, cli: "imctl", client: Doctor.ClientFacts(cliBuild: "269", onPath: false, cliPath: "/Apps/imctl.app/Contents/MacOS/imctl"))
        #expect(text.contains("本机客户端") && text.contains("命令行是 build 269，守护进程在跑 build 268"))
        #expect(text.contains(#"sudo ln -sf "/Apps/imctl.app/Contents/MacOS/imctl" /usr/local/bin/imctl"#))
        let same = Doctor.render(r, cli: "imctl", client: Doctor.ClientFacts(cliBuild: "268", onPath: true, cliPath: "imctl"))
        #expect(same.contains("✔ 命令行与守护进程同为 build 268") && same.contains("✔ 终端里可以直接用 imctl"))
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter DoctorTests`
Expected: 编译失败（`showsFix`、`ClientFacts` 不存在）。

- [ ] **Step 3：实现**（`Doctor.swift`）

```swift
    /// B53: what this CLI knows about itself.
    struct ClientFacts: Equatable {
        var cliBuild: String?
        var onPath: Bool
        var cliPath: String
    }

    /// A fix is shown for `fail` and `disabled`, and for an ok capability that has warnings (runtime health).
    static func showsFix(_ capability: ReadinessCapability) -> Bool {
        guard capability.fix != nil else { return false }
        return capability.status == .fail || capability.status == .disabled || !capability.warnings.isEmpty
    }
```

`render` 签名末尾加 `client: ClientFacts? = nil`。以下几处修改：
- 就绪首行：`let suffix = report.online.state == "skipped" ? "（只做了本机检查）" : (report.online.state == "done" ? "" : "（联网实测未完成）")`，然后 `lines.append("✔ 就绪：必需项都可用" + suffix)`；
- 检查行：`let untested = check.tested == false && !check.detail.contains("未实测") ? "（未实测）" : ""`；
- 修复：条件改为 `if let fix = capability.fix, showsFix(capability)`；
- 能力列表之后加：

```swift
        if let client {
            lines.append("")
            lines.append("本机客户端")
            if let mine = client.cliBuild, let daemon = report.build {
                lines.append(mine == daemon ? "    ✔ 命令行与守护进程同为 build \(mine)"
                                            : "    ! 命令行是 build \(mine)，守护进程在跑 build \(daemon)（可能开的是另一份 app，或守护进程还没重启）")
            }
            if client.onPath {
                lines.append("    ✔ 终端里可以直接用 imctl")
            } else {
                lines.append("    ○ 终端里要用完整路径；想直接打 imctl（需要管理员密码）：")
                lines.append("      $ sudo ln -sf \"\(client.cliPath)\" /usr/local/bin/imctl")
            }
        }
```

`DoctorCommand.run()` 渲染时传入：

```swift
            let me = AgentIntegration.executable()
            let clientFacts = Doctor.ClientFacts(
                cliBuild: ReadinessClient.bundleBuild(at: URL(fileURLWithPath: me).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()),
                onPath: cli == "imctl", cliPath: me)
            print(try json ? Doctor.json(report) : Doctor.render(report, cli: cli, refreshAskedMs: refresh ? askedMs : nil, client: clientFacts))
```

（`me` 是 `imctl.app/Contents/MacOS/imctl`，往上三级是 `imctl.app`。）

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter DoctorTests`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/imctl/Host/Doctor.swift Sources/imctl/Commands/DoctorCommand.swift Tests/imctlTests/DoctorTests.swift
git commit -m "feat(doctor): client group, fixes shown with warnings, offline headline and single untested mark" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `imctl doctor --fix`

**Files:**
- Create: `Sources/imctl/Host/DoctorFix.swift`
- Modify: `Sources/imctl/Commands/DoctorCommand.swift`
- Test: `Tests/imctlTests/DoctorFixTests.swift`（新）

**Interfaces:**
- Consumes: Task 1 的动作与文字。
- Produces:
  - `DoctorFix(cli:mqttEnrolled:ask:say:executor:localReport:)`，入口 `run(report:)`；
  - 顶层协议 `DoctorFixExecutor`：`open(url:)`、`openApp(bundleID:)`、`runCLI(_:) -> Int32`、`kickstart() -> Int32`、`call(_:)`；
  - `DoctorFix.LiveExecutor`；
  - `DoctorCommand.validateFix(isTerminal:json:) throws`。

- [ ] **Step 1：写失败测试** `Tests/imctlTests/DoctorFixTests.swift`

```swift
import ArgumentParser
import ControlCore
import Foundation
import Testing
@testable import imctl

final class RecordingExecutor: DoctorFixExecutor {
    var calls: [String] = []
    func open(url: URL) throws { calls.append("open \(url.absoluteString)") }
    func openApp(bundleID: String) throws { calls.append("app \(bundleID)") }
    func runCLI(_ arguments: [String]) throws -> Int32 { calls.append("cli " + arguments.joined(separator: " ")); return 0 }
    func kickstart() throws -> Int32 { calls.append("kickstart"); return 0 }
    func call(_ method: String) throws { calls.append("rpc \(method)") }
}

@Suite("imctl doctor --fix")
struct DoctorFixTests {
    static func cap(_ id: String, _ action: ReadinessAction?, command: String? = nil) -> ReadinessCapability {
        ReadinessCapability(id: id, title: id, required: true, status: .fail, checks: [],
                            fix: ReadinessFix(text: "修 \(id)", command: command, action: action))
    }

    static func report(_ caps: [ReadinessCapability], running: Int? = 0) -> ReadinessReport {
        ReadinessReport(ready: false, nextStep: caps.first?.fix, nextStepCapability: caps.first?.id, capabilities: caps,
                        online: ReadinessOnlineInfo(state: "skipped"), version: "v", generatedMs: 1, runningCommands: running)
    }

    func fixer(answers: [String], running: Int? = 0, out: @escaping (String) -> Void = { _ in }) -> (DoctorFix, RecordingExecutor) {
        var answers = answers
        let executor = RecordingExecutor()
        let fixer = DoctorFix(cli: "imctl", mqttEnrolled: true, ask: { _ in answers.isEmpty ? nil : answers.removeFirst() }, say: out,
                              executor: executor, localReport: { Self.report([], running: running) })
        return (fixer, executor)
    }

    @Test func eachItemIsAskedInOrderAndNoIsTheDefault() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["", "n"], out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("wecom", ReadinessAction(.openWeCom)), Self.cap("read", ReadinessAction(.setup))]))
        #expect(executor.calls.isEmpty)
        #expect(output.contains { $0.contains("[1/2] wecom") } && output.contains { $0.contains("[2/2] read") })
    }

    @Test func yesRunsTheAction() {
        let (fixer, executor) = fixer(answers: ["y", "y", "y"])
        fixer.run(report: Self.report([Self.cap("wecom", ReadinessAction(.openWeCom)),
                                       Self.cap("media", ReadinessAction(.openSystemSettings, target: "screenRecording")),
                                       Self.cap("mqtt", ReadinessAction(.reinstallDaemon))]))
        #expect(executor.calls == ["app com.tencent.WeWorkMac",
                                   "open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                                   "cli agent install --mqtt"])
    }

    @Test func aDaemonRestartIsSkippedWhileACommandRuns() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["y"], running: 1, out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("daemon", ReadinessAction(.restartDaemon))]))
        #expect(executor.calls.isEmpty && output.contains { $0.contains(ReadinessActionText.busy) })
    }

    @Test func navigationOnlyPrintsTheCommand() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: [], out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("mqtt", ReadinessAction(.openSettings, target: "mqtt"), command: "imctl enroll --broker <主机[:端口]>")]))
        #expect(executor.calls.isEmpty && output.contains { $0.contains("$ imctl enroll --broker <主机[:端口]>") })
    }

    @Test func fixesWithoutAKnownActionAreNotOffered() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["y"], out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("autoAccept", nil), Self.cap("x", ReadinessAction(kind: "somethingNew"))]))
        #expect(executor.calls.isEmpty && output.contains("没有可以自动处理的项目。"))
    }

    @Test func fixNeedsATerminalAndNoJSON() {
        #expect(throws: ValidationError.self) { try DoctorCommand.validateFix(isTerminal: false, json: false) }
        #expect(throws: ValidationError.self) { try DoctorCommand.validateFix(isTerminal: true, json: true) }
        #expect(throws: Never.self) { try DoctorCommand.validateFix(isTerminal: true, json: false) }
    }
}
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter DoctorFixTests`
Expected: 编译失败。

- [ ] **Step 3：实现** `Sources/imctl/Host/DoctorFix.swift`

```swift
import ControlCore
import Foundation
import MCPTransport

/// `imctl doctor --fix` (B53): offer each failing capability's typed action in fix order and ask y/N (default no).
/// Daemon restarts are skipped while a command runs; navigation kinds only print their command; the fix's
/// command text is never executed.
/// What `--fix` actually does to this Mac; tests record the calls instead.
protocol DoctorFixExecutor {
    func open(url: URL) throws
    func openApp(bundleID: String) throws
    func runCLI(_ arguments: [String]) throws -> Int32
    func kickstart() throws -> Int32
    func call(_ method: String) throws
}

struct DoctorFix {
    enum FixError: Error, CustomStringConvertible {
        case unsupported, exit(Int32)
        var description: String {
            switch self {
            case .unsupported: return "这个动作不能在命令行执行"
            case .exit(let code): return "退出码 \(code)"
            }
        }
    }

    var cli: String
    var mqttEnrolled: Bool
    var ask: (String) -> String?
    var say: (String) -> Void
    var executor: DoctorFixExecutor
    /// A fresh local report (`online:false`); nil when the daemon cannot answer.
    var localReport: () -> ReadinessReport?

    func run(report: ReadinessReport) {
        let items: [(ReadinessCapability, ReadinessFix, ReadinessAction)] = report.capabilities.compactMap { capability in
            guard capability.status == .fail, let fix = capability.fix, let action = fix.action, action.known != nil else { return nil }
            return (capability, fix, action)
        }
        guard !items.isEmpty else { say("没有可以自动处理的项目。"); return }
        for (index, item) in items.enumerated() {
            let (capability, fix, action) = item
            say("")
            say("[\(index + 1)/\(items.count)] \(capability.title)：\(fix.text)")
            if action.navigatesOnly {
                if action.known == .openLogs { say("    日志在 ~/Library/Logs/imctl/imctld.log") }
                if let command = fix.command { say("    需要填写，命令行不代为执行。请运行：\n    $ \(ReadinessCommandText.substitute(command, cli: cli))") }
                continue
            }
            if action.restartsDaemon, (localReport()?.runningCommands ?? 0) > 0 {
                say("    跳过：\(ReadinessActionText.busy)")
                continue
            }
            let question = ReadinessActionText.confirmation(action) ?? ""
            let answer = ask("    \(question)执行吗？[y/N] ")?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else { say("    未执行"); continue }
            do { try perform(action); say("    已执行") } catch { say("    执行失败：\(error)") }
        }
        if let after = localReport() {
            say("")
            say("处理后本机检查：" + (after.ready ? "✔ 就绪" : "✘ 未就绪" + (after.nextStep.map { "。下一步：\($0.text)" } ?? "")))
        }
    }

    func perform(_ action: ReadinessAction) throws {
        func check(_ status: Int32) throws { if status != 0 { throw FixError.exit(status) } }
        switch action.known {
        case .openSystemSettings?:
            guard let url = ReadinessActionText.systemSettingsURL(action.target) else { throw FixError.unsupported }
            try executor.open(url: url)
        case .openWeCom?: try executor.openApp(bundleID: "com.tencent.WeWorkMac")
        case .setup?: try check(executor.runCLI(["setup"]))
        case .reinstallDaemon?: try check(executor.runCLI(["agent", "install"] + (mqttEnrolled ? ["--mqtt"] : [])))
        case .restartDaemon?: try check(executor.kickstart())
        case .resumeDaemon?: try executor.call("controller.resume")
        case .registerAgents?: try check(executor.runCLI(["mcp", "install", "--claude-code", "--codex", "--skills"]))
        case .installSkills?: try check(executor.runCLI(["mcp", "install", "--skills"]))
        case .retest?: try check(executor.runCLI(["doctor", "--refresh"]))
        case .openSettings?, .openPolicy?, .openLogs?, nil: throw FixError.unsupported
        }
    }

    /// Real effects: `/usr/bin/open`, this binary, `launchctl`, the daemon socket. Child output goes to this terminal.
    struct LiveExecutor: DoctorFixExecutor {
        var me: String
        var socket: String

        func open(url: URL) throws { _ = try Self.status("/usr/bin/open", [url.absoluteString]) }
        func openApp(bundleID: String) throws { _ = try Self.status("/usr/bin/open", ["-b", bundleID]) }
        func runCLI(_ arguments: [String]) throws -> Int32 { try Self.status(me, arguments) }
        func kickstart() throws -> Int32 {
            try Self.status("/bin/launchctl", ["kickstart", "-k", Launchctl.serviceTarget(LaunchAgentSpec.defaultLabel)])
        }
        func call(_ method: String) throws { _ = try UnixSocketClient(path: socket, timeout: 15).call(method) }

        static func status(_ executable: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }
}
```

`DoctorCommand`：

```swift
    @Flag(help: "After the report, offer each fix that has an action, one by one (y/N, default no). Terminal only.") var fix = false

    static func validateFix(isTerminal: Bool, json: Bool) throws {
        if json { throw ValidationError("--fix 不能和 --json 一起用") }
        if !isTerminal { throw ValidationError("--fix 需要在终端里逐项确认（stdin 不是终端）") }
    }
```

`run()` 里，在打印报告之后、`if !report.ready { throw ExitCode(2) }` 之前加：

```swift
            if fix {
                try Self.validateFix(isTerminal: isatty(STDIN_FILENO) == 1, json: json)
                let fixer = DoctorFix(
                    cli: cli, mqttEnrolled: FileManager.default.fileExists(atPath: MQTTSettings.defaultURL.path),
                    ask: { prompt in print(prompt, terminator: ""); return readLine() }, say: { print($0) },
                    executor: DoctorFix.LiveExecutor(me: AgentIntegration.executable(), socket: socket),
                    localReport: {
                        try? Doctor.fetch(call: { try client.call($0, params: $1) }, sleep: { _ in }, online: false, refresh: false, wait: 0)
                    })
                fixer.run(report: report)
            }
```

（`DoctorCommand.swift` 顶部加 `import MQTTTransport`。）

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "DoctorFixTests|DoctorTests"`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/imctl/Host/DoctorFix.swift Sources/imctl/Commands/DoctorCommand.swift Sources/ControlCore/Readiness/ReadinessAction.swift Tests/imctlTests/DoctorFixTests.swift Tests/ControlCoreTests/ReadinessActionTests.swift
git commit -m "feat(doctor): --fix offers each fix's typed action one by one, never the command text" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 控制台的动作入口与导航状态

**Files:**
- Modify: `Sources/imctl-console/Model/ConsoleModel.swift`、`Sources/imctl-console/Views/ConsoleWindow.swift`、`Sources/imctl-console/Views/SettingsView.swift`
- Test: `Tests/imctl-consoleTests/ConsoleActionTests.swift`（新）

**Interfaces:**
- Consumes: Task 1 的动作、Task 2/3 的 `report.runningCommands`。
- Produces:
  - `ConsoleSection.readiness`（「体检」，排第一）；
  - `SettingsPane`（顶层枚举，`init?(target:)`）；
  - 模型新增：`section: ConsoleSection?`、`settingsPane: SettingsPane`、`pendingAction: ReadinessAction?`、`actionNotice: String?`、`performOverride: (@MainActor (ReadinessAction) async -> Void)?`；
  - 模型新增方法：`requestAction(_:) async`、`confirmPendingAction() async`、`cancelPendingAction()`、`runningCommandCount() async -> Int`。

- [ ] **Step 1：写失败测试** `Tests/imctl-consoleTests/ConsoleActionTests.swift`

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

/// Answers local readiness with a set number of running commands (nil = a B52 daemon).
final class BusyReadiness: ReadinessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Int?
    init(running: Int?) { self.running = running }
    func set(_ value: Int?) { lock.lock(); running = value; lock.unlock() }
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); defer { lock.unlock() }
        return ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                               online: ReadinessOnlineInfo(state: "skipped"), version: "t", generatedMs: 1, runningCommands: running)
    }
}

@Suite("Console readiness actions", .serialized)
@MainActor
struct ConsoleActionTests {
    func model(running: Int?) throws -> (ConsoleModel, UnixSocketServer, BusyReadiness) {
        let provider = BusyReadiness(running: running)
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: try ControlStore(path: ":memory:"), handler: SwitchingFakeHandler()))
        dispatcher.readiness = provider
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        let model = ConsoleModel()
        model.socketPathOverride = path
        return (model, server, provider)
    }

    @Test func navigationHappensAtOnceWithoutAsking() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.openSettings, target: "oss"))
        #expect(model.section == .settings && model.settingsPane == .oss && model.pendingAction == nil && performed.isEmpty)
        await model.requestAction(ReadinessAction(.openPolicy, target: "phones"))
        #expect(model.section == .policy)
    }

    @Test func anExecutingActionWaitsForConfirmation() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.openWeCom))
        #expect(model.pendingAction == ReadinessAction(.openWeCom) && performed.isEmpty)
        await model.confirmPendingAction()
        #expect(performed == [ReadinessAction(.openWeCom)] && model.pendingAction == nil)
    }

    @Test func cancellingRunsNothing() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.installSkills))
        model.cancelPendingAction()
        #expect(model.pendingAction == nil && performed.isEmpty)
    }

    @Test func aRestartIsRefusedWhileACommandRuns() async throws {
        let (model, server, _) = try model(running: 1)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.restartDaemon))
        #expect(model.pendingAction == nil && model.actionNotice == ReadinessActionText.busy && performed.isEmpty)
    }

    @Test func aCommandThatStartsBeforeConfirmationBlocksTheRestart() async throws {
        let (model, server, provider) = try model(running: 0)
        defer { server.stop() }
        var performed: [ReadinessAction] = []
        model.performOverride = { performed.append($0) }
        await model.requestAction(ReadinessAction(.reinstallDaemon))
        #expect(model.pendingAction != nil)
        provider.set(1)
        await model.confirmPendingAction()
        #expect(performed.isEmpty && model.actionNotice == ReadinessActionText.busy)
    }

    @Test func aReportWithoutRunningCommandsAllowsTheRestart() async throws {
        let (model, server, _) = try model(running: nil)
        defer { server.stop() }
        model.performOverride = { _ in }
        await model.requestAction(ReadinessAction(.restartDaemon))
        #expect(model.pendingAction == ReadinessAction(.restartDaemon))
    }

    @Test func anUnknownKindDoesNothing() async throws {
        let (model, server, _) = try model(running: 0)
        defer { server.stop() }
        await model.requestAction(ReadinessAction(kind: "somethingNew"))
        #expect(model.pendingAction == nil && model.actionNotice == nil)
    }

    @Test func settingsPanesMapFromTargets() {
        #expect(SettingsPane(target: "mqtt") == .mqtt && SettingsPane(target: "proxy") == .proxy)
        #expect(SettingsPane(target: "oss") == .oss && SettingsPane(target: "vision") == .vision && SettingsPane(target: "x") == nil)
    }
}
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter ConsoleActionTests`
Expected: 编译失败。

- [ ] **Step 3：实现**

`ConsoleWindow.swift`：
- `ConsoleSection` 加 `case readiness = "体检"`，`symbol` 为 `"checklist.checked"`，`subtitle` 为 `"逐项检查这台 Mac 能不能用，点按钮修复"`；
- `groups` 第一组改为 `("概览", [.readiness, .status])`（本任务先保留 `.diagnostics`，Task 8 再删）；
- 去掉 `@State private var section`，`body` 开头加 `@Bindable var model = model`，`List(selection: $model.section)`，`let current = model.section ?? .readiness`，`case .readiness: ReadinessPageView()`；
- 本任务先放一个占位视图 `struct ReadinessPageView: View { var body: some View { Text("体检") } }`，Task 8 替换。

`SettingsView.swift`：删掉私有的 `Pane`，改为顶层：

```swift
enum SettingsPane: String, CaseIterable {
    case mqtt = "MQTT", proxy = "企微代理", oss = "对象存储", vision = "视觉识别"

    /// The `openSettings` action's target.
    init?(target: String?) {
        switch target {
        case "mqtt": self = .mqtt
        case "proxy": self = .proxy
        case "oss": self = .oss
        case "vision": self = .vision
        default: return nil
        }
    }
}
```

`SettingsView` 去掉 `@State private var pane`，改用 `@Bindable var model = model` 的 `$model.settingsPane`。原来的 `pane == .x` 判断改为 `model.settingsPane == .x`。

`ConsoleModel.swift`：`agentAction` 去掉 `private`，并新增：

```swift
    // MARK: B53 navigation and readiness actions

    var section: ConsoleSection? = .readiness
    var settingsPane: SettingsPane = .mqtt
    /// Waiting for the person to confirm (the readiness page and the wizard show one dialog for it).
    var pendingAction: ReadinessAction?
    var actionNotice: String?
    /// Tests replace the effect of a confirmed action; production runs `performLive`.
    var performOverride: (@MainActor (ReadinessAction) async -> Void)?

    /// The single entry for fix buttons: navigation happens at once; anything else waits for `confirmPendingAction()`;
    /// a daemon restart is refused while a command runs.
    func requestAction(_ action: ReadinessAction) async {
        actionNotice = nil
        guard action.known != nil else { return }
        if action.navigatesOnly { await navigate(action); return }
        if action.restartsDaemon, await runningCommandCount() > 0 { actionNotice = ReadinessActionText.busy; return }
        pendingAction = action
    }

    /// Runs the pending action; a restart is checked again here, since a command may have started meanwhile.
    func confirmPendingAction() async {
        guard let action = pendingAction else { return }
        pendingAction = nil
        if action.restartsDaemon, await runningCommandCount() > 0 { actionNotice = ReadinessActionText.busy; return }
        if let performOverride { await performOverride(action) } else { await performLive(action) }
        await runReadiness(localOnly: true)
    }

    func cancelPendingAction() { pendingAction = nil }

    /// Commands accepted or running per a fresh local report; 0 when the daemon cannot answer or is older than B53.
    func runningCommandCount() async -> Int {
        guard let value = await rpc(RPCDispatcher.readinessMethod, ["online": .bool(false)], log: false),
              let text = try? value.serialized(),
              let report = try? JSONDecoder().decode(ReadinessReport.self, from: Data(text.utf8)) else { return 0 }
        return report.runningCommands ?? 0
    }

    func navigate(_ action: ReadinessAction) async {
        switch action.known {
        case .openSettings?:
            settingsPane = SettingsPane(target: action.target) ?? .mqtt
            section = .settings
        case .openPolicy?: section = .policy
        case .openLogs?:
            if let value = await rpc("controller.logs", ["lines": .number(50)], log: false) {
                append("守护进程日志（最近 50 行）", RPCService.pretty(value))
            }
            section = .log
        default: break
        }
    }

    func performLive(_ action: ReadinessAction) async {
        let cli = self.cli
        switch action.known {
        case .openSystemSettings?:
            if let url = ReadinessActionText.systemSettingsURL(action.target) { NSWorkspace.shared.open(url) }
        case .openWeCom?:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WeComClient.bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .setup?: await agentAction("imctl setup") { try cli.run(["setup", "--wait", "10"]) }
        case .reinstallDaemon?: await installDaemon()
        case .restartDaemon?: await restartDaemon()
        case .resumeDaemon?: await resume()
        case .registerAgents?: await agentAction("imctl mcp install") { try cli.run(["mcp", "install", "--claude-code", "--codex", "--skills"]) }
        case .installSkills?: await agentAction("imctl mcp install --skills") { try cli.run(["mcp", "install", "--skills"]) }
        case .retest?: await runReadiness(refresh: true)
        case .openSettings?, .openPolicy?, .openLogs?, nil: await navigate(action)
        }
    }
```

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "ConsoleActionTests|ConsoleReadinessTests|ConsoleModelTests"`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/imctl-console Tests/imctl-consoleTests/ConsoleActionTests.swift
git commit -m "feat(console): one confirmed entry for readiness actions, with page navigation in the model" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: 设置页拆出四个表单组件

**Files:**
- Create: `Sources/imctl-console/Views/SettingsForms.swift`
- Modify: `Sources/imctl-console/Views/SettingsView.swift`

**Interfaces:**
- Produces：`MQTTSettingsForm`、`ProxySettingsForm`、`OSSSettingsForm`、`VisionSettingsForm`，都是 `View`，都有 `var onSaved: () -> Void = {}`，各自 `@State` 与 `load()`，`.onAppear { load() }`；每个表单的 `body` 是一个 `Section`，放进调用方的 `Form` 里。

- [ ] **Step 1：搬移代码**

搬移方式：
- 每个表单只带自己用到的 `@State`；
- `load()` 只读自己的字段：`let stored = model.loadStoredSettings()`，再赋值给 `@State private var stored`；
- 原「保存」按钮在调用 `model.saveX(...)` 和 `load()` 之后，加一行 `onSaved()`；
- 其它文字与逻辑原样保留。

把 `SettingsView` 现有四段 `Section` 原样搬进 `Sources/imctl-console/Views/SettingsForms.swift` 的四个结构体：
- `MQTTSettingsForm` 用 `host port tls controllerID username password topicPrefix keepAlive stored hostDefaultID`。`load()` 里保留 B52 追加的 `ConsoleModel.formControllerID(stored:hostDefault:fileExists:)` 与 `hostDefaultID` 预填，以及「默认取本机名」和「只能用 1–64 个字母…」两条提示。
- `ProxySettingsForm` 用 `proxyURL proxyToken corpId agentId proxyTimeout stored`。
- `OSSSettingsForm` 用 `ossEndpoint ossBucket ossBaseDir ossAccessKeyId ossSecret ossViewExpire ossMaxUpload stored`，包含「测试往返」按钮与 `ResultPane`。
- `VisionSettingsForm` 用 `visionProvider visionModel visionSecret stored`，以及 `selectedVisionProvider`。三个改变配置的按钮（保存并启用、关闭云端视觉、整窗开关）都调用 `onSaved()`。

MQTT 表单：

```swift
import MQTTTransport
import SwiftUI
import WeComAdapter

/// B53: the MQTT form, shared by the settings page and the setup wizard.
struct MQTTSettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var host = ""
    @State private var port = "1883"
    @State private var tls = false
    @State private var controllerID = ""
    @State private var username = ""
    @State private var password = ""
    @State private var topicPrefix = "im"
    @State private var keepAlive = "30"
    @State private var stored = ConsoleModel.StoredSettings()
    @State private var hostDefaultID: String?

    func load() {
        stored = model.loadStoredSettings()
        host = stored.host; port = String(stored.port); tls = stored.tls
        hostDefaultID = MQTTSettings.defaultControllerID(localHostName: MQTTSettings.currentLocalHostName())
        controllerID = ConsoleModel.formControllerID(stored: stored, hostDefault: hostDefaultID, fileExists: model.mqttEnrolled)
        username = stored.username; topicPrefix = stored.topicPrefix; keepAlive = String(stored.keepAliveSeconds)
        password = ""
    }

    var body: some View {
        Section("MQTT \(model.mqttEnrolled ? "· 已配置" : "· 未配置")") {
            TextField("broker 主机", text: $host)
            TextField("端口", text: $port)
            Toggle("TLS", isOn: $tls)
            TextField("controller id（一机一号一 id）", text: $controllerID)
            if model.mqttEnrolled && stored.controllerID.isEmpty {
                Text("mqtt.json 读不了：填回原来的 controller id（Java 端按它发命令），或删掉这个文件后重新配置")
                    .font(.caption).foregroundStyle(.orange)
            } else if stored.controllerID.isEmpty && hostDefaultID != nil && controllerID == hostDefaultID {
                Text("默认取本机名，可改；同一 broker 上每台 Mac 要不同。Java 端按这个 id 发命令，EMQX 开了认证时用户名也用它")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !MQTTSettings.isValidControllerID(controllerID) {
                Text(controllerID.isEmpty ? "要填 controller id：1–64 个字母、数字或 . _ -" : "只能用 1–64 个字母、数字或 . _ -（它是 topic 的一段）")
                    .font(.caption).foregroundStyle(.red)
            }
            TextField("用户名（可选）", text: $username)
            SecureField(stored.hasPassword ? "密码：已保存（留空则保留原值）" : "密码（可选）", text: $password)
            TextField("topic 前缀", text: $topicPrefix)
            TextField("keepAlive（秒）", text: $keepAlive)
            if !controllerID.isEmpty {
                Text("topics：" + ["cmd", "rsp", "evt", "state"].map { "\((topicPrefix.isEmpty ? "im" : topicPrefix))/\(controllerID)/\($0)" }.joined(separator: "  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("保存 MQTT 设置") {
                    model.saveMQTT(host: host, port: Int(port) ?? (tls ? 8883 : 1883), tls: tls, controllerID: controllerID,
                                   username: username, password: password, topicPrefix: topicPrefix,
                                   keepAliveSeconds: Int(keepAlive) ?? 30)
                    load()
                    onSaved()
                }
                .disabled(host.isEmpty || !MQTTSettings.isValidControllerID(controllerID))
                Button("重新读取") { load() }
            }
        }
        .onAppear { load() }
    }
}
```

同一文件里另外三个表单：

```swift
/// B53: the WeCom token proxy form.
struct ProxySettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var proxyURL = ""
    @State private var proxyToken = ""
    @State private var corpId = ""
    @State private var agentId = ""
    @State private var proxyTimeout = "15"
    @State private var stored = ConsoleModel.StoredSettings()

    func load() {
        stored = model.loadStoredSettings()
        proxyURL = stored.proxyURL; corpId = stored.corpId; agentId = stored.agentId.map(String.init) ?? ""
        proxyTimeout = String(Int(stored.proxyTimeoutSeconds)); proxyToken = ""
    }

    var body: some View {
        Section("企微令牌代理 \(model.proxyEnrolled ? "· 已配置" : "· 未配置")") {
            TextField("代理地址 https://…", text: $proxyURL)
            SecureField(stored.hasProxyToken ? "Bearer token：已保存（留空则保留原值）" : "Bearer token", text: $proxyToken)
            TextField("corpId（可选，代理侧也可配置）", text: $corpId)
            TextField("agentId（可选）", text: $agentId)
            TextField("超时（秒）", text: $proxyTimeout)
            Button("保存代理设置") {
                model.saveProxy(baseURL: proxyURL, token: proxyToken, corpId: corpId, agentId: Int(agentId), timeoutSeconds: Double(proxyTimeout) ?? 15)
                load()
                onSaved()
            }
            .disabled(proxyURL.isEmpty || (proxyToken.isEmpty && !stored.hasProxyToken))
        }
        .onAppear { load() }
    }
}

/// B53: the OSS form.
struct OSSSettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var ossEndpoint = ""
    @State private var ossBucket = ""
    @State private var ossBaseDir = "imctl"
    @State private var ossAccessKeyId = ""
    @State private var ossSecret = ""
    @State private var ossViewExpire = "1800"
    @State private var ossMaxUpload = "52428800"
    @State private var stored = ConsoleModel.StoredSettings()

    func load() {
        stored = model.loadStoredSettings()
        ossEndpoint = stored.ossEndpoint; ossBucket = stored.ossBucket; ossBaseDir = stored.ossBaseDir
        ossViewExpire = String(stored.ossViewExpireSeconds); ossMaxUpload = String(stored.ossMaxUploadBytes)
        ossSecret = ""; ossAccessKeyId = ""
    }

    var body: some View {
        Section("对象存储 OSS \(model.ossEnrolled ? "· 已配置" : "· 未配置")") {
            TextField("endpoint https://oss-<region>.aliyuncs.com", text: $ossEndpoint)
            TextField("bucket（私有）", text: $ossBucket)
            TextField("base-dir（对象键前缀）", text: $ossBaseDir)
            if !stored.ossAccessKeyIdMasked.isEmpty {
                Text("当前 AccessKeyId：\(stored.ossAccessKeyIdMasked)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("新的 AccessKeyId（留空保持）", text: $ossAccessKeyId)
            SecureField(stored.hasOSSSecret ? "AccessKeySecret：已保存（留空则保留原值）" : "AccessKeySecret", text: $ossSecret)
            TextField("签名地址有效期（秒）", text: $ossViewExpire)
            TextField("单文件上传上限（字节）", text: $ossMaxUpload)
            HStack {
                Button("保存 OSS 设置") {
                    model.saveOSS(endpoint: ossEndpoint, bucket: ossBucket, baseDir: ossBaseDir, accessKeyId: ossAccessKeyId, accessKeySecret: ossSecret,
                                  viewExpireSeconds: Int(ossViewExpire) ?? 1800, maxUploadBytes: Int64(ossMaxUpload) ?? 52_428_800)
                    load()
                    onSaved()
                }
                // `saveOSS` trims the base-dir of slashes before storing it, so "/" is as empty as "".
                .disabled(ossEndpoint.isEmpty || ossBucket.isEmpty || ossBaseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
                          || (ossAccessKeyId.isEmpty && stored.ossAccessKeyIdMasked.isEmpty) || (ossSecret.isEmpty && !stored.hasOSSSecret))
                Button("测试往返（1 KB 探针）") { Task { await model.ossTest() } }.disabled(!model.ossEnrolled || model.busy)
                Button("重新读取") { load() }
            }
            if !model.ossTestResult.isEmpty { ResultPane(title: "imctl oss test", text: model.ossTestResult, minHeight: 80) }
            Text("controller.describe.oss：\(model.describe["oss"] ?? "-")（守护进程是否已加载 OSS；改完设置要重启守护进程才会更新）")
                .font(.caption).foregroundStyle(.secondary)
            Text("密钥只进本机 oss.json；改完要在「状态」页重启守护进程。").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load() }
    }
}

/// B53: the cloud vision form.
struct VisionSettingsForm: View {
    @Environment(ConsoleModel.self) private var model
    var onSaved: () -> Void = {}
    @State private var visionProvider = CloudVisionProvider.qwen.rawValue
    @State private var visionModel = CloudVisionSettings.defaultModel(for: .qwen)
    @State private var visionSecret = ""
    @State private var stored = ConsoleModel.StoredSettings()

    private var selectedVisionProvider: CloudVisionProvider { CloudVisionProvider(rawValue: visionProvider) ?? .qwen }

    func load() {
        stored = model.loadStoredSettings()
        visionProvider = stored.visionProvider; visionModel = stored.visionModel; visionSecret = ""
    }

    var body: some View {
        Section("云端视觉定位 \(stored.visionEnabled ? "· 已启用" : "· 已关闭")") {
            Picker("提供商", selection: $visionProvider) {
                ForEach(CloudVisionProvider.allCases, id: \.rawValue) { provider in
                    Text(provider.rawValue).tag(provider.rawValue)
                }
            }
            .onChange(of: visionProvider) { _, newValue in
                if let provider = CloudVisionProvider(rawValue: newValue) {
                    visionModel = CloudVisionSettings.defaultModel(for: provider)
                }
                visionSecret = ""
            }
            Picker("视觉模型", selection: $visionModel) {
                ForEach(CloudVisionSettings.allowedModels(for: selectedVisionProvider), id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            SecureField(stored.visionKeysPresent[visionProvider] == true ? "API 密钥已保存（留空则保留）" : "API 密钥", text: $visionSecret)
            Text("局部按钮裁图沿用原开关。显式桌面命令若需上传完整企微窗口，须再单独启用整窗辅助；窗口可能包含其它会话预览。后台观察和自动申请不上传。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存并启用") {
                    model.saveVision(provider: visionProvider, model: visionModel, secret: visionSecret)
                    load()
                    onSaved()
                }
                .disabled(visionSecret.isEmpty && stored.visionKeysPresent[visionProvider] != true)
                Button("关闭云端视觉") { model.disableVision(); load(); onSaved() }
                    .disabled(!stored.visionEnabled)
                Button("重新读取") { load() }
            }
            HStack {
                Button(stored.visionFullWindowEnabled ? "关闭整窗辅助" : "允许整窗辅助") {
                    model.setFullWindowVision(!stored.visionFullWindowEnabled)
                    load()
                    onSaved()
                }
                .disabled(!stored.visionEnabled)
                Text(stored.visionFullWindowEnabled ? "整窗辅助已授权" : "整窗辅助未授权")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("密钥只存在本机受限配置文件中，不会显示在界面或进入 MQTT。切换后请在「状态」页重启守护进程。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { load() }
    }
}
```

`SettingsView` 改为：

```swift
struct SettingsView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            Picker("设置类别", selection: $model.settingsPane) {
                ForEach(SettingsPane.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 580)
            .padding(16)
            Divider()
            Form {
                switch model.settingsPane {
                case .mqtt: MQTTSettingsForm()
                case .proxy: ProxySettingsForm()
                case .oss: OSSSettingsForm()
                case .vision: VisionSettingsForm()
                }
                Section {
                    Text("设置保存在本机。保存后请到“状态”页重启守护进程，使新配置生效；第一次配置 MQTT 要点“守护进程维护”里的“安装 / 更新”，以 MQTT 模式重装。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}
```

- [ ] **Step 2：编译并跑控制台测试**

Run: `swift test --scratch-path $BUILD --filter imctl_consoleTests`
Expected: 全部 PASS（`settingsRoundTripKeepsEveryStoredField`、`ConsoleControllerIDTests` 不受影响）。

- [ ] **Step 3：提交**

```bash
git add Sources/imctl-console/Views/SettingsForms.swift Sources/imctl-console/Views/SettingsView.swift
git commit -m "refactor(console): the four settings forms become components with an onSaved hook" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: 体检页、侧栏、状态页、诊断并入、菜单与启动

**Files:**
- Create: `Sources/imctl-console/Views/ReadinessPageView.swift`、`Sources/imctl-console/Views/ReadinessComponents.swift`
- Modify: `Sources/imctl-console/Model/ReadinessText.swift`、`Sources/imctl-console/Model/ConsoleModel.swift`、`Sources/imctl-console/Views/ConsoleWindow.swift`、`Sources/imctl-console/Views/StatusView.swift`、`Sources/imctl-console/Views/MenuBarMenu.swift`
- Delete: `Sources/imctl-console/Views/DiagnosticsView.swift`
- Test: `Tests/imctl-consoleTests/ConsoleReadinessPageTests.swift`（新）

**Interfaces:**
- Consumes: Task 6 的动作入口与导航，Task 3 的 `ReadinessClient`，Task 9 的 `SetupWizard` 静态方法（本任务先在模型里用到 `wizardPresented`，标记读写见 Task 9；为避免先后依赖，本任务先实现 `SetupWizard.flagKey`、`flagDone(_:)`、`shouldAutoOpen(report:flagDone:)` 三个静态成员，Task 9 补全其余部分）。
- Produces：
  - `ReadinessText.ClientLine(symbol:text:action:copy:)`、`ReadinessText.clientLines(consoleTrusted:consoleBuild:daemonBuild:cliLinked:cliPath:) -> [ClientLine]`、`ReadinessText.fallbackLines(agent:clientRunning:) -> [String]`；
  - 模型 `wizardPresented: Bool`、`startupReadiness(defaults:) async`、`consoleBuild: String?`；
  - 视图 `ReadinessCapabilityList(report:)`、`ReadinessActionButton(action:)`，修饰器 `.readinessActionConfirmation()`。

- [ ] **Step 1：写失败测试** `Tests/imctl-consoleTests/ConsoleReadinessPageTests.swift`

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

@Suite("Console readiness page", .serialized)
@MainActor
struct ConsoleReadinessPageTests {
    func defaults() -> UserDefaults {
        let name = "imctl-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func theSidebarStartsWithReadinessAndHasNoDiagnosticsPage() {
        #expect(ConsoleSection.groups.first?.1 == [.readiness, .status])
        #expect(!ConsoleSection.allCases.map(\.rawValue).contains("诊断"))
    }

    @Test func startupWithoutADaemonOpensTheWizard() async {
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        await model.startupReadiness(defaults: defaults())
        #expect(model.wizardPresented && model.readiness == nil)
    }

    @Test func afterTheWizardALaunchThatIsNotReadyOpensOnTheReadinessPage() async throws {
        let scripted = ScriptedReadiness(states: ["skipped"])
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: try ControlStore(path: ":memory:"), handler: SwitchingFakeHandler()))
        dispatcher.readiness = scripted
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        defer { server.stop() }
        let d = defaults()
        d.set(true, forKey: SetupWizard.flagKey)
        let model = ConsoleModel()
        model.socketPathOverride = path
        model.section = .status
        await model.startupReadiness(defaults: d)
        #expect(!model.wizardPresented && model.section == .readiness)
        #expect(scripted.calls.allSatisfy { !$0.online })
    }

    @Test func clientLinesCoverTrustBuildAndPath() {
        let lines = ReadinessText.clientLines(consoleTrusted: false, consoleBuild: "270", daemonBuild: "269", cliLinked: false,
                                              cliPath: "/Apps/imctl.app/Contents/MacOS/imctl")
        #expect(lines[0].symbol == "✘" && lines[0].action == ReadinessAction(.openSystemSettings, target: "accessibility"))
        #expect(lines[1].text.contains("控制台是 build 270，守护进程在跑 build 269") && lines[1].action == ReadinessAction(.restartDaemon))
        #expect(lines[2].copy == #"sudo ln -sf "/Apps/imctl.app/Contents/MacOS/imctl" /usr/local/bin/imctl"#)
        let fine = ReadinessText.clientLines(consoleTrusted: true, consoleBuild: "269", daemonBuild: "269", cliLinked: true, cliPath: "x")
        #expect(fine.allSatisfy { $0.symbol == "✔" && $0.action == nil })
    }

    @Test func fallbackLinesOfferSetup() {
        let lines = ReadinessText.fallbackLines(agent: DaemonControl.AgentStatus(loaded: false, state: nil, pid: nil, plistPresent: true), clientRunning: true)
        #expect(lines.contains("后台常驻：文件在但没加载") && lines.contains("imctld：没在运行") && lines.contains("企业微信：在运行"))
        #expect(ReadinessText.fallbackLines(agent: nil, clientRunning: false).contains("后台常驻：读不到状态"))
    }
}
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter ConsoleReadinessPageTests`
Expected: 编译失败。

- [ ] **Step 3：实现**

**ReadinessText.swift**，加：

```swift
    struct ClientLine: Equatable {
        var symbol: String
        var text: String
        var action: ReadinessAction?
        var copy: String?
    }

    /// B53: what only this console knows — its own Accessibility grant, its build against the daemon's, the terminal link.
    static func clientLines(consoleTrusted: Bool, consoleBuild: String?, daemonBuild: String?, cliLinked: Bool, cliPath: String) -> [ClientLine] {
        var lines = [consoleTrusted
            ? ClientLine(symbol: "✔", text: "控制台自己的辅助功能已授权（界面诊断要用）")
            : ClientLine(symbol: "✘", text: "控制台自己的辅助功能未授权：只影响界面诊断，不影响就绪",
                         action: ReadinessAction(.openSystemSettings, target: "accessibility"))]
        if let mine = consoleBuild, let daemon = daemonBuild {
            lines.append(mine == daemon
                ? ClientLine(symbol: "✔", text: "控制台与守护进程同为 build \(mine)")
                : ClientLine(symbol: "!", text: "控制台是 build \(mine)，守护进程在跑 build \(daemon)",
                             action: ReadinessClient.isOlder(daemon, than: mine) ? ReadinessAction(.restartDaemon) : nil))
        }
        lines.append(cliLinked
            ? ClientLine(symbol: "✔", text: "终端里可以直接用 imctl")
            : ClientLine(symbol: "○", text: "终端里要用完整路径；想直接打 imctl，复制下面的命令（需要管理员密码）",
                         copy: "sudo ln -sf \"\(cliPath)\" /usr/local/bin/imctl"))
        return lines
    }

    /// B53: when the daemon cannot answer — what this Mac shows directly (same facts as `imctl doctor`'s fallback).
    static func fallbackLines(agent: DaemonControl.AgentStatus?, clientRunning: Bool) -> [String] {
        var lines: [String] = []
        if let agent {
            lines.append(agent.plistPresent == false ? "后台常驻：没安装" : (agent.loaded ? "后台常驻：已加载" : "后台常驻：文件在但没加载"))
            lines.append(agent.pid.map { "imctld：在运行（pid \($0)）" } ?? "imctld：没在运行")
        } else {
            lines.append("后台常驻：读不到状态")
        }
        lines.append(clientRunning ? "企业微信：在运行" : "企业微信：没有运行")
        return lines
    }
```

**ConsoleModel.swift**，加：

```swift
    var wizardPresented = false
    /// This console's CFBundleVersion (nil when run outside the app, e.g. `swift run`).
    var consoleBuild: String? { ReadinessClient.bundleBuild(at: Bundle.main.bundleURL) }

    /// B53: on launch, a local check only. The first launch that is not ready opens the wizard; later ones that are
    /// not ready open on the readiness page.
    func startupReadiness(defaults: UserDefaults = .standard) async {
        await runReadiness(localOnly: true, maxPolls: 0)
        if SetupWizard.shouldAutoOpen(report: readiness, flagDone: SetupWizard.flagDone(defaults)) {
            wizardPresented = true
        } else if readiness?.ready != true {
            section = .readiness
        }
    }
```

**SetupWizard.swift**，先建文件，只放三个静态成员：

```swift
import ControlCore
import Foundation

/// B53 first-run wizard (steps and done rules arrive in Task 9).
struct SetupWizard: Equatable {
    static let flagKey = "imctl.setupWizard.done"
    static func flagDone(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: flagKey) }
    /// The wizard opens by itself only on a launch that is not ready before it was ever finished or closed.
    static func shouldAutoOpen(report: ReadinessReport?, flagDone: Bool) -> Bool { !flagDone && report?.ready != true }
}
```

**ReadinessComponents.swift**：

```swift
import ControlCore
import SwiftUI

/// A fix's button: the label comes from the action's kind; tapping goes through the model's single action entry.
struct ReadinessActionButton: View {
    @Environment(ConsoleModel.self) private var model
    let action: ReadinessAction
    var body: some View {
        if let title = ReadinessActionText.button(action) {
            Button(title) { Task { await model.requestAction(action) } }
        }
    }
}

/// Capabilities with checks, warnings, fix text, action button and copyable command (readiness page, wizard finish).
struct ReadinessCapabilityList: View {
    @Environment(ConsoleModel.self) private var model
    let report: ReadinessReport
    var body: some View {
        ForEach(report.capabilities, id: \.id) { capability in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ReadinessText.symbol(capability.status)) \(capability.title)\(capability.required ? "" : "（可选）")").font(.headline)
                ForEach(capability.checks, id: \.id) { check in
                    Text("\(ReadinessText.symbol(check.status)) \(check.detail)\(check.tested == false && !check.detail.contains("未实测") ? "（未实测）" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(capability.warnings, id: \.self) { Text("! \($0)").font(.caption).foregroundStyle(.orange) }
                if let fix = capability.fix, capability.status == .fail || capability.status == .disabled || !capability.warnings.isEmpty {
                    Text(fix.text).font(.caption)
                    HStack {
                        if let action = fix.action { ReadinessActionButton(action: action) }
                        if let command = fix.command {
                            Text(model.cliCommand(command)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            CopyButton(text: model.cliCommand(command))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The one confirmation dialog for the model's pending action, plus the busy notice.
struct ReadinessActionConfirmation: ViewModifier {
    @Environment(ConsoleModel.self) private var model
    func body(content: Content) -> some View {
        content
            .confirmationDialog(model.pendingAction.flatMap { ReadinessActionText.button($0) } ?? "确认",
                                isPresented: Binding(get: { model.pendingAction != nil }, set: { if !$0 { model.cancelPendingAction() } })) {
                Button("确认执行") { Task { await model.confirmPendingAction() } }
                Button("取消", role: .cancel) { model.cancelPendingAction() }
            } message: {
                Text(model.pendingAction.flatMap { ReadinessActionText.confirmation($0) } ?? "")
            }
            .alert(model.actionNotice ?? "", isPresented: Binding(get: { model.actionNotice != nil }, set: { if !$0 { model.actionNotice = nil } })) {
                Button("好") { model.actionNotice = nil }
            }
    }
}

extension View {
    func readinessActionConfirmation() -> some View { modifier(ReadinessActionConfirmation()) }
}
```

**ReadinessPageView.swift**（替换 Task 6 的占位）：

```swift
import ControlCore
import SwiftUI

/// B53: every readiness check in one place, a button on each fix (confirmed by `.readinessActionConfirmation()`),
/// what only this console knows, and the in-console UI diagnosis that used to be its own page.
struct ReadinessPageView: View {
    @Environment(ConsoleModel.self) private var model
    @State private var localOnly = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(model.readinessRunning ? "体检中…" : "运行体检") { Task { await model.runReadiness(localOnly: localOnly) } }
                        .disabled(model.readinessRunning)
                    ReadinessActionButton(action: ReadinessAction(.retest)).disabled(model.readinessRunning || localOnly)
                    Toggle("只做本机检查", isOn: $localOnly)
                    Spacer()
                    Button("重新运行向导") { Task { await model.openWizard() } }
                }
                if let report = model.readiness {
                    Text(ReadinessText.headline(report)).font(.title3.weight(.semibold))
                    if report.online.state == "done", let tested = report.online.testedMs {
                        Text("联网实测时间：\(Date(timeIntervalSince1970: Double(tested) / 1000).formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let next = report.nextStep?.action { ReadinessActionButton(action: next) }
                    ReadinessCapabilityList(report: report)
                } else {
                    Text("连不上守护进程。本机能直接看到的情况：").font(.headline)
                    ForEach(ReadinessText.fallbackLines(agent: model.agent, clientRunning: model.clientRunning), id: \.self) { Text($0) }
                    ReadinessActionButton(action: ReadinessAction(.setup))
                }
                GroupBox("本机客户端") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ReadinessText.clientLines(consoleTrusted: model.consoleTrusted, consoleBuild: model.consoleBuild,
                                                          daemonBuild: model.readiness?.build,
                                                          cliLinked: ReadinessClient.cliLinked(cliPath: model.cli.executable.path),
                                                          cliPath: model.cli.executable.path), id: \.text) { line in
                            HStack {
                                Text("\(line.symbol) \(line.text)")
                                if let action = line.action { ReadinessActionButton(action: action) }
                                if let copy = line.copy { CopyButton(text: copy) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("界面诊断（控制台进程只读一次企业微信界面，不按任何东西）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("诊断界面") { Task { await model.runDiagnostics() } }
                        if let d = model.diagnostics {
                            LabeledContent("企业微信运行中", value: d.clientRunning ? "是" : "否")
                            LabeledContent("窗口", value: d.windowFrame ?? "-")
                            LabeledContent("会话表", value: d.conversationTable ?? "-")
                            LabeledContent("消息表", value: d.messageTable ?? "-")
                            LabeledContent("输入框", value: d.composerPresent.map { $0 ? "有" : "无（通知类会话）" } ?? "-")
                            LabeledContent("活动会话 / 类型", value: "\(d.activeTitle ?? "-") / \(d.activeType ?? "-")")
                            LabeledContent("会话行数 / 行高", value: "\(d.conversationCount ?? 0) / \(d.rowHeights?.map(String.init).joined(separator: ",") ?? "-")")
                            LabeledContent("窗口菜单", value: d.windowMenuItems?.joined(separator: " · ") ?? "-")
                            if let e = d.error { Text(e).foregroundStyle(.red) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: 1400, alignment: .leading)
        }
        .task { await model.runReadiness(localOnly: true, maxPolls: 0) }
        .readinessActionConfirmation()
    }
}
```

（`model.openWizard()` 在 Task 9 实现；本任务先加一个最小版本 `func openWizard() async { wizardPresented = true }`，Task 9 替换。）

**ConsoleWindow.swift**：
- 删 `ConsoleSection.diagnostics`，包括 `symbol`、`subtitle`、`groups`、`switch` 里的相关分支；
- `groups` 的监控组改为 `("监控", [.events, .log])`；
- 删除 `Sources/imctl-console/Views/DiagnosticsView.swift`；
- 用 `.task { await model.startupReadiness() }` 替换现有的 `.task { await model.refresh() }`，`startupReadiness` 之后再调用 `await model.refresh()`；
- 加 `.sheet(isPresented: $model.wizardPresented) { SetupWizardView().environment(model) }`。本任务先建占位 `struct SetupWizardView: View { var body: some View { Text("初始化向导") } }`，Task 10 替换。

**StatusView.swift**：
- 删除 `DisclosureGroup("授权与本机") { … }` 整段与 `DisclosureGroup("体检") { … }` 整段；
- 删除 `@State private var readinessLocalOnly` 与「常用操作」里的 `Button("检查授权")`；
- 在「常用操作」的 `HStack` 里 `Spacer()` 之前加：

```swift
                        Toggle("在程序坞显示图标", isOn: Binding(get: { DockPresence.enabled }, set: { DockPresence.enabled = $0 }))
```

**MenuBarMenu.swift**：在「打开控制台」后加：

```swift
        Button("体检…") {
            model.section = .readiness
            if !AppDelegate.showConsole() { openWindow(id: "console") }
        }
        Button("初始化向导…") {
            if !AppDelegate.showConsole() { openWindow(id: "console") }
            Task { await model.openWizard() }
        }
```

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter imctl_consoleTests`
Expected: 全部 PASS；`DocsTests`、`ConsoleModelTests` 中若有引用 `.diagnostics` 或「诊断」页的地方，改为体检页。

- [ ] **Step 5：提交**

```bash
git add Sources/imctl-console Tests/imctl-consoleTests
git rm Sources/imctl-console/Views/DiagnosticsView.swift
git commit -m "feat(console): readiness page with fix buttons, client checks and UI diagnosis; slimmer status page; startup opens the right place" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 向导逻辑

**Files:**
- Modify: `Sources/imctl-console/Model/SetupWizard.swift`、`Sources/imctl-console/Model/ConsoleModel.swift`
- Test: `Tests/imctl-consoleTests/SetupWizardTests.swift`（新）

**Interfaces:**
- Consumes: Task 8 的 `SetupWizard` 三个静态成员、Task 6 的动作入口。
- Produces：
  - `SetupWizard.Feature`（agents、mqtt、vision、oss、proxy；`title`、`capabilityID`、`needsRestartAfterSave`）；
  - `SetupWizard.Step`（install、wecom、sendScope、features、configure(Feature)、apply、finish；`title`、`required`）；
  - 实例属性 `selected`、`needsApply`、`index`、`skipped`、`steps`、`current`；方法 `next()`、`back()`、`skip()`、`featureSaved(_:)`、`applied()`；
  - 静态方法 `preselected(_:)`、`isDone(_:report:)`、`markDone(_:)`；
  - 模型 `wizard: SetupWizard`、`openWizard() async`、`closeWizard(defaults:)`、`finishWizard(defaults:)`；`confirmPendingAction` 在 `reinstallDaemon` 执行后调用 `wizard.applied()`。

- [ ] **Step 1：写失败测试** `Tests/imctl-consoleTests/SetupWizardTests.swift`

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import imctl_console

@Suite("Setup wizard")
@MainActor
struct SetupWizardTests {
    static func report(_ statuses: [String: ReadinessStatus], ready: Bool = false) -> ReadinessReport {
        ReadinessReport(ready: ready, nextStep: nil, nextStepCapability: nil,
                        capabilities: statuses.map { ReadinessCapability(id: $0.key, title: $0.key, required: false, status: $0.value, checks: []) },
                        online: ReadinessOnlineInfo(state: "skipped"), version: "v", generatedMs: 1)
    }

    @Test func onlySelectedFeaturesGetASteps() {
        var w = SetupWizard()
        #expect(w.steps == [.install, .wecom, .sendScope, .features, .finish])
        w.selected = [.vision, .agents]
        #expect(w.steps == [.install, .wecom, .sendScope, .features, .configure(.agents), .configure(.vision), .finish])
    }

    @Test func theApplyStepAppearsOnlyAfterASaveThatNeedsARestart() {
        var w = SetupWizard(); w.selected = [.agents, .mqtt]
        w.featureSaved(.agents)
        #expect(!w.steps.contains(.apply))
        w.featureSaved(.mqtt)
        #expect(w.steps.suffix(2) == [.apply, .finish])
        w.applied()
        #expect(!w.steps.contains(.apply))
    }

    @Test func skippingARequiredStepIsRemembered() {
        var w = SetupWizard()
        w.skip(); w.skip(); w.skip()
        #expect(w.skipped == [.install, .wecom] && w.current == .features)
        w.back()
        #expect(w.current == .sendScope)
    }

    @Test func doneIsReadFromTheReport() {
        let fine = Self.report(["daemon": .ok, "read": .ok, "media": .ok, "wecom": .ok, "agents": .ok, "mqtt": .fail, "oss": .disabled])
        #expect(SetupWizard.isDone(.install, report: fine) && SetupWizard.isDone(.wecom, report: fine))
        #expect(SetupWizard.isDone(.configure(.agents), report: fine) && SetupWizard.isDone(.configure(.mqtt), report: fine))
        #expect(!SetupWizard.isDone(.configure(.oss), report: fine))
        #expect(!SetupWizard.isDone(.install, report: Self.report(["daemon": .ok, "read": .fail, "media": .ok])))
        #expect(!SetupWizard.isDone(.install, report: nil) && SetupWizard.isDone(.sendScope, report: nil))
    }

    @Test func configuredFeaturesArePreselected() {
        let r = Self.report(["agents": .ok, "mqtt": .fail, "vision": .disabled, "oss": .disabled, "wecomApi": .ok])
        #expect(SetupWizard.preselected(r) == [.agents, .mqtt, .proxy])
        #expect(SetupWizard.preselected(nil).isEmpty)
    }

    @Test func theWizardOpensByItselfOnlyBeforeItWasEverClosed() {
        #expect(SetupWizard.shouldAutoOpen(report: nil, flagDone: false))
        #expect(!SetupWizard.shouldAutoOpen(report: Self.report([:], ready: true), flagDone: false))
        #expect(!SetupWizard.shouldAutoOpen(report: nil, flagDone: true))
    }

    @Test func closingMarksDoneAndReopeningStartsOver() async {
        let name = "imctl-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        await model.openWizard()
        model.wizard.next(); model.wizard.next()
        model.closeWizard(defaults: defaults)
        #expect(!model.wizardPresented && SetupWizard.flagDone(defaults))
        await model.openWizard()
        #expect(model.wizardPresented && model.wizard.index == 0)
    }

    @Test func aConfirmedReinstallClearsTheApplyStep() async {
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        model.performOverride = { _ in }
        model.wizard.selected = [.oss]
        model.wizard.featureSaved(.oss)
        await model.requestAction(ReadinessAction(.reinstallDaemon))
        await model.confirmPendingAction()
        #expect(!model.wizard.needsApply)
    }
}
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter SetupWizardTests`
Expected: 编译失败。

- [ ] **Step 3：实现**

`SetupWizard.swift` 补全：

```swift
import ControlCore
import Foundation

/// B53 first-run wizard: the steps, what counts as done (read from a local readiness report), and the stored flag.
struct SetupWizard: Equatable {
    enum Feature: String, CaseIterable, Hashable {
        case agents, mqtt, vision, oss, proxy
        var title: String {
            switch self {
            case .agents: "Claude Code / Codex 接入"
            case .mqtt: "MQTT（Java / 远端调用）"
            case .vision: "视觉兜底"
            case .oss: "OSS 文件"
            case .proxy: "企微官方 API 代理"
            }
        }
        var capabilityID: String {
            switch self {
            case .agents: "agents"
            case .mqtt: "mqtt"
            case .vision: "vision"
            case .oss: "oss"
            case .proxy: "wecomApi"
            }
        }
        /// Saved settings take effect only after the daemon restarts (a reinstall also switches MQTT mode on).
        var needsRestartAfterSave: Bool { self != .agents }
    }

    enum Step: Equatable, Hashable {
        case install, wecom, sendScope, features, configure(Feature), apply, finish
        var title: String {
            switch self {
            case .install: "安装与授权"
            case .wecom: "企业微信"
            case .sendScope: "发送范围"
            case .features: "要用哪些功能"
            case .configure(let f): f.title
            case .apply: "应用配置"
            case .finish: "完成"
            }
        }
        var required: Bool { self == .install || self == .wecom }
    }

    static let flagKey = "imctl.setupWizard.done"
    static func flagDone(_ defaults: UserDefaults) -> Bool { defaults.bool(forKey: flagKey) }
    static func markDone(_ defaults: UserDefaults) { defaults.set(true, forKey: flagKey) }
    /// The wizard opens by itself only on a launch that is not ready before it was ever finished or closed.
    static func shouldAutoOpen(report: ReadinessReport?, flagDone: Bool) -> Bool { !flagDone && report?.ready != true }

    var selected: Set<Feature> = []
    var needsApply = false
    var index = 0
    var skipped: [Step] = []

    var steps: [Step] {
        var s: [Step] = [.install, .wecom, .sendScope, .features]
        s += Feature.allCases.filter { selected.contains($0) }.map { .configure($0) }
        if needsApply { s.append(.apply) }
        s.append(.finish)
        return s
    }
    var current: Step { steps[min(index, steps.count - 1)] }

    mutating func next() { index = min(index + 1, steps.count - 1) }
    mutating func back() { index = max(index - 1, 0) }
    mutating func skip() {
        if current.required, !skipped.contains(current) { skipped.append(current) }
        next()
    }
    mutating func featureSaved(_ feature: Feature) { if feature.needsRestartAfterSave { needsApply = true } }
    mutating func applied() { needsApply = false }

    static func preselected(_ report: ReadinessReport?) -> Set<Feature> {
        guard let report else { return [] }
        return Set(Feature.allCases.filter { f in report.capabilities.first { $0.id == f.capabilityID }.map { $0.status != .disabled } ?? false })
    }

    static func isDone(_ step: Step, report: ReadinessReport?) -> Bool {
        if step == .sendScope || step == .features { return true }
        guard let report else { return false }
        func capability(_ id: String) -> ReadinessCapability? { report.capabilities.first { $0.id == id } }
        switch step {
        case .install:
            return ["daemon", "read", "media"].allSatisfy { capability($0).map { $0.status != .fail } ?? false }
        case .wecom:
            return capability("wecom")?.status == .ok
        case .configure(let feature):
            guard let c = capability(feature.capabilityID) else { return false }
            if feature == .agents { return c.status == .ok }
            return c.status != .disabled && !c.checks.contains { $0.id == "config" && $0.status == .fail }
        case .sendScope, .features, .apply, .finish:
            return false
        }
    }
}
```

`ConsoleModel.swift`：

```swift
    var wizard = SetupWizard()

    /// From the readiness page, the menu bar or the first launch: start at step 1 with configured features ticked.
    func openWizard() async {
        await runReadiness(localOnly: true, maxPolls: 0)
        wizard = SetupWizard()
        wizard.selected = SetupWizard.preselected(readiness)
        wizardPresented = true
    }

    /// Closed before the end: remembered too, so it does not open by itself again.
    func closeWizard(defaults: UserDefaults = .standard) {
        SetupWizard.markDone(defaults)
        wizardPresented = false
    }

    func finishWizard(defaults: UserDefaults = .standard) {
        closeWizard(defaults: defaults)
        section = .readiness
    }
```

删除 Task 8 的最小版 `openWizard`。`confirmPendingAction` 在执行之后、`runReadiness` 之前加一行：

```swift
        if action.known == .reinstallDaemon { wizard.applied() }
```

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "SetupWizardTests|ConsoleReadinessPageTests|ConsoleActionTests"`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/imctl-console/Model Tests/imctl-consoleTests/SetupWizardTests.swift
git commit -m "feat(console): setup wizard steps, done rules from the readiness report, and the stored flag" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: 向导界面

**Files:**
- Modify: `Sources/imctl-console/Views/SetupWizardView.swift`（替换 Task 8 的占位）

**Interfaces:**
- Consumes：Task 7 的四个表单（带 `onSaved`），Task 8 的 `ReadinessCapabilityList`、`ReadinessActionButton`、`.readinessActionConfirmation()`、`ReadinessText.fallbackLines`，Task 9 的 `SetupWizard` 与模型方法。

- [ ] **Step 1：实现**

```swift
import AppKit
import ControlCore
import SwiftUI

/// B53 first-run wizard. Every step reads the last local readiness report; actions go through the model's
/// confirmed entry; the configure steps embed the settings page's own forms and only save.
struct SetupWizardView: View {
    @Environment(ConsoleModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(Array(model.wizard.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1) \(step.title)")
                        .font(.caption.weight(index == model.wizard.index ? .bold : .regular))
                        .foregroundStyle(index == model.wizard.index ? .primary : .secondary)
                }
            }
            Divider()
            ScrollView { stepBody.frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            HStack {
                Button("上一步") { model.wizard.back() }.disabled(model.wizard.index == 0)
                Button("重新检查") { Task { await model.runReadiness(localOnly: true, maxPolls: 0) } }
                Spacer()
                if model.wizard.current == .finish {
                    Button("完成") { model.finishWizard() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("跳过") { model.wizard.skip() }
                    Button("下一步") { model.wizard.next() }.keyboardShortcut(.defaultAction)
                }
                Button("关闭") { model.closeWizard() }
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .readinessActionConfirmation()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.runReadiness(localOnly: true, maxPolls: 0) }
        }
    }

    @ViewBuilder private var stepBody: some View {
        let report = model.readiness
        let step = model.wizard.current
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title).font(.title2.weight(.semibold))
            Text(SetupWizard.isDone(step, report: report) ? "✔ 这一步已完成" : (step.required ? "这一步是必需的" : ""))
                .foregroundStyle(.secondary)
            switch step {
            case .install:
                if let report {
                    ReadinessCapabilityList(report: filtered(report, ["daemon", "read", "media"]))
                } else {
                    Text("守护进程还没装好。本机能直接看到的情况：")
                    ForEach(ReadinessText.fallbackLines(agent: model.agent, clientRunning: model.clientRunning), id: \.self) { Text($0) }
                    ReadinessActionButton(action: ReadinessAction(.setup))
                }
            case .wecom:
                if let report { ReadinessCapabilityList(report: filtered(report, ["wecom"])) }
            case .sendScope:
                if let report { ReadinessCapabilityList(report: filtered(report, ["send"])) }
                Text("默认只能发给文件传输助手。要放开别的会话，完成向导后到「策略」页设置。").foregroundStyle(.secondary)
            case .features:
                ForEach(SetupWizard.Feature.allCases, id: \.self) { feature in
                    Toggle(feature.title, isOn: Binding(
                        get: { model.wizard.selected.contains(feature) },
                        set: { on in if on { model.wizard.selected.insert(feature) } else { model.wizard.selected.remove(feature) } }))
                }
                Text("按手机号加人、自动接受好友申请属于策略，完成后在「策略」页按需开启。").foregroundStyle(.secondary)
            case .configure(let feature):
                configure(feature, report: report)
            case .apply:
                Text("刚才保存的配置要重启守护进程才生效（已配置 MQTT 会以 MQTT 模式重装）。")
                ReadinessActionButton(action: ReadinessAction(.reinstallDaemon))
            case .finish:
                Button(model.readinessRunning ? "体检中…" : "运行完整体检（联网实测，含一次视觉模型调用）") {
                    Task { await model.runReadiness() }
                }
                .disabled(model.readinessRunning)
                if !model.wizard.skipped.isEmpty {
                    Text("跳过的必需步骤：\(model.wizard.skipped.map(\.title).joined(separator: "、"))").foregroundStyle(.orange)
                }
                if let report {
                    Text(ReadinessText.headline(report)).font(.headline)
                    ReadinessCapabilityList(report: report)
                }
            }
        }
    }

    @ViewBuilder private func configure(_ feature: SetupWizard.Feature, report: ReadinessReport?) -> some View {
        switch feature {
        case .agents:
            if let report { ReadinessCapabilityList(report: filtered(report, ["agents"])) }
        case .mqtt: Form { MQTTSettingsForm(onSaved: { model.wizard.featureSaved(.mqtt) }) }.formStyle(.grouped)
        case .vision: Form { VisionSettingsForm(onSaved: { model.wizard.featureSaved(.vision) }) }.formStyle(.grouped)
        case .oss: Form { OSSSettingsForm(onSaved: { model.wizard.featureSaved(.oss) }) }.formStyle(.grouped)
        case .proxy: Form { ProxySettingsForm(onSaved: { model.wizard.featureSaved(.proxy) }) }.formStyle(.grouped)
        }
    }

    private func filtered(_ report: ReadinessReport, _ ids: [String]) -> ReadinessReport {
        var r = report
        r.capabilities = report.capabilities.filter { ids.contains($0.id) }
        return r
    }
}
```

`ConsoleWindow` 里 Task 8 加的 sheet 改为（按 Esc 关闭也记下标记；`closeWizard` / `finishWizard` 已记过，再记一次无害）：

```swift
        .sheet(isPresented: $model.wizardPresented, onDismiss: { SetupWizard.markDone(.standard) }) {
            SetupWizardView().environment(model)
        }
```

- [ ] **Step 2：编译并跑控制台测试**

Run: `swift test --scratch-path $BUILD --filter imctl_consoleTests`
Expected: 全部 PASS。

- [ ] **Step 3：提交**

```bash
git add Sources/imctl-console/Views/SetupWizardView.swift Sources/imctl-console/Views/ConsoleWindow.swift
git commit -m "feat(console): the setup wizard sheet — install and grants, WeCom, send scope, features, one apply, full check" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: 文档、协议与版本

**Files:**
- Modify: `docs/protocol/im-control-protocol.md`（§6.45、§12 变更表）、`docs/protocol/agents-mcp.md`、`docs/agents/skills/imctl/SKILL.md`、`README.md`、`docs/ops/installer.md`、`docs/ops/permissions.md`、`docs/ai-coding/AI_DIRECTORY_STRUCTURE_GUIDE.md`、`AGENTS.md`、`packaging/pkg/companion/README-另一台Mac.txt`、`Sources/ControlCore/IMCTLVersion.swift`、`Tests/ControlCoreTests/IMCTLVersionTests.swift`

- [ ] **Step 1：版本**

`IMCTLVersion.swift` 改为：

```swift
    /// 1.0.16-dev (2026-10-12): B53 — setup wizard, readiness page and confirmed quick fixes; `imctl doctor --fix`.
    public static let string = "1.0.16-dev"
```

`IMCTLVersionTests` 的期望改为 `"1.0.16-dev"`。

- [ ] **Step 2：协议 §6.45**：在返回结构说明之后加一段：

```markdown
B53：`fix` 可带 `action: {kind, target?}`，是给人点的快捷操作类型（`openSystemSettings`（`accessibility` / `screenRecording` / `fullDiskAccess`）、`openWeCom`、`setup`、`reinstallDaemon`、`restartDaemon`、`resumeDaemon`、`registerAgents`、`installSkills`、`retest`、`openSettings`（`mqtt` / `oss` / `proxy` / `vision`）、`openPolicy`（`phones` / `autoAccept` / `allowlist`）、`openLogs`）。客户端只执行认识的类型，从不执行 `command` 的文字；不认识的 `kind` 只显示文字。报告另带 `build`（守护进程启动时的 `CFBundleVersion`，开发构建为空）与 `runningCommands`（已接受或执行中的命令数）；`setup` / `reinstallDaemon` / `restartDaemon` 在 `runningCommands > 0` 时由客户端拒绝。新增可选能力 `health`（运行健康：最近一小时失败、结果未知的命令数与读取企业微信出错次数），只出提醒，不影响 `ready`。智能体可以读 `action`，但只报告，不执行。
```

§12 变更表加一行：

```markdown
| 2026-10-12 | B53：`controller.readiness` 的 `fix.action`、报告 `build` / `runningCommands`、可选能力 `health`；`daemon` 增加 build 一致性检查，`mqtt` 增加最近一次收到命令的时间。方法、错误码集合不变。 |
```

- [ ] **Step 3：其余文档**（每处一到两句）：
- `agents-mcp.md` 体检工具段：「结果里的 `fix.action` 是给人点的快捷操作类型，智能体只转告，不执行」；
- `SKILL.md` 体检段：加一句 "`fix.action` is a quick-action type for a person to click in the console or `imctl doctor --fix`; relay it, never run it."；
- `README.md`：控制台「体检」页与首次启动向导、`imctl doctor --fix`；
- `installer.md`：首次打开控制台会弹出初始化向导；体检页可重新运行；
- `permissions.md`：授权步骤可在向导第 1 步或体检页按按钮完成（按钮先确认）；
- `AI_DIRECTORY_STRUCTURE_GUIDE.md`：登记新文件；
- `AGENTS.md`：在 B52 那句之后加「B53：控制台与 `imctl doctor --fix` 的快捷修复只执行预定义的动作类型，执行类先确认，会重启守护进程的在有命令执行时拒绝；不执行报告里的命令文字」；
- companion README：首次打开控制台按向导做。

- [ ] **Step 4：全量测试与检查**

Run: `swift test --scratch-path $BUILD` 与 `bash scripts/check-secrets.sh`、`git diff --check`
Expected: 全部 PASS；check-secrets 仍为 11 条既有提醒。

- [ ] **Step 5：提交**

```bash
git add -A docs AGENTS.md README.md packaging Sources/ControlCore/IMCTLVersion.swift Tests/ControlCoreTests/IMCTLVersionTests.swift
git commit -m "docs: B53 readiness actions, setup wizard and doctor --fix; 1.0.16-dev" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: 变异验证、独立审查、安装与活体门报告

**Files:**
- Create: `docs/gates/<日期>-b53-guided-setup.md`

- [ ] **Step 1：变异验证**

在临时副本里逐条删掉下列保证，各跑对应测试，都应变红：

| 删去的保证 | 应变红的测试 |
|---|---|
| `requestAction` 不设 `pendingAction`，直接执行 | `anExecutingActionWaitsForConfirmation` |
| `requestAction` 里重启类不查 `runningCommandCount` | `aRestartIsRefusedWhileACommandRuns` |
| `confirmPendingAction` 里不再查一次 | `aCommandThatStartsBeforeConfirmationBlocksTheRestart` |
| `navigatesOnly` 恒为 false | `navigationHappensAtOnceWithoutAsking`、`everyExecutingKindIsConfirmedAndNavigationIsNot` |
| `DoctorFix` 把空回答当作同意 | `eachItemIsAskedInOrderAndNoIsTheDefault` |
| `DoctorFix` 不查 `runningCommands` | `aDaemonRestartIsSkippedWhileACommandRuns` |
| `DoctorFix` 接受未知类型 | `fixesWithoutAKnownActionAreNotOffered` |
| `validateFix` 不查终端 | `fixNeedsATerminalAndNoJSON` |
| `needsRestartAfterSave` 对 agents 也为 true | `theApplyStepAppearsOnlyAfterASaveThatNeedsARestart` |
| `closeWizard` 不写标记 | `closingMarksDoneAndReopeningStartsOver` |
| daemon 的 build 比较恒为相等 | `aBuildTheDaemonIsNotRunningFailsItWithARestart` |
| health 状态改为 `fail` | `runtimeHealthWarnsWithoutBlockingReady` |
| `systemSettingsURL` 接受任意 target | `systemSettingsOpensOnlyTheThreeFixedPages` |
| `startupReadiness` 调联网实测 | `afterTheWizardALaunchThatIsNotReadyOpensOnTheReadinessPage` |

- [ ] **Step 2：独立审查**

派一个新的审查代理，只读审查本分支相对 `main` 的全部改动。重点：
- 不执行命令文字；执行类必须确认，重启类在有命令执行时拒绝；
- 系统设置只开三个固定地址；
- 控制台不自动联网实测；向导不改策略；
- 新报告字段不含路径或内容；`ForbiddenAPITests` 未放宽；
- 文档与代码一致。

严重与重要问题在一轮修复里改完，每项 RED→GREEN，然后跑全量测试。

- [ ] **Step 3：构建、打包、安装**

```bash
IMCTL_SIGN_TEAM=<证书名括号里的 ID> IMCTL_SIGN_TEAM_ID=<团队 ID> IMCTL_OUT_DIR=out/b53-build$(git rev-list --count HEAD) scripts/build-pkg.sh release
```

- 展开 pkg，核对载荷哈希，严格验签；
- `installer -pkg <pkg> -target CurrentUserHomeDirectory` 安装（证书不变，授权应保留）；
- **先不重启守护进程**，用于下一步的活体验收。

- [ ] **Step 4：活体验收（这台 Mac）**

1. 安装后不重启：`imctl doctor` 的 `daemon` 显示 build 不一致，下一步是重启守护进程。在控制台体检页点「重启守护进程」→ 确认 → 重启后 build 一致。
2. 退出企业微信（征得用户同意），打开向导（菜单「初始化向导…」）：第 2 步显示 ✘ 和「打开企业微信」，点按钮、确认后企业微信打开，「重新检查」显示 ✔。
3. 向导完整走一遍：已配置的功能默认勾上（agents、MQTT、视觉）；完成页点「运行完整体检」，结果与 `imctl doctor` 一致；点「完成」后回到体检页。
4. `imctl doctor --fix`：制造一项可修的失败（例如 api 暂停：`imctl call controller.pause`），`--fix` 询问「解除暂停」，回 y 后执行，处理后本机检查恢复。
5. 体检页：本机客户端组显示控制台与守护进程同版本、终端链接状态；「诊断界面」能读到会话表；守护进程连不上时（`launchctl bootout`）显示兜底信息和「安装并请求授权」，再用 `imctl setup` 恢复。
6. 全新环境（另一台 Mac 或新建的 macOS 用户）是否做由用户决定，不做就标「待活体」。

- [ ] **Step 5：写门报告并提交**

按 `docs/ai-coding/TESTING_SPEC.md` 模板写 `docs/gates/<日期>-b53-guided-setup.md`，包括：条件、实现、单测数（与 1076 对比）、变异表、审查结论、制品哈希、活体逐项结果、未闭环项。

```bash
git add docs/gates
git commit -m "docs(gates): B53 guided setup on build <N>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

合入 `main` 与推送前先 `git fetch`，等用户确认。合入后从 main 重建安装，并提议用户归档到 Wiki。
