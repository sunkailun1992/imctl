# B52 就绪体检 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 守护进程提供查询 `controller.readiness`，逐项回答这台 Mac 上 imctl 的每个功能能不能用、卡在哪、怎么修；`imctl doctor` 与控制台状态页「体检」都调用它。

**Architecture:** 纯逻辑放在 `ControlCore/Readiness`（事实 → 判定规则 → 报告；联网实测的缓存状态机与并发执行器）。各联网探测放在各自模块（视觉在 WeComAdapter、MQTT 在 MQTTTransport、OSS 在 OSSClient、代理在 WeComAPI、MCP 握手与注册检查在 MCPTransport）。守护进程 `DaemonReadiness` 从自己的状态采集事实、在后台队列跑实测；分发器把 `controller.readiness` 当查询处理（与 `event.replay` 同一路径，不进执行器、不写命令记录）。

**Tech Stack:** Swift 6 工具链 / Swift 5 语言模式、SwiftPM、swift-testing、mqtt-nio、URLSession、CoreGraphics + ImageIO、SwiftUI（控制台）。

**Spec:** `docs/superpowers/specs/2026-10-10-b52-readiness-doctor.md`（含 2026-10-11「计划阶段核实后的修正」一节）

## Global Constraints

- 不新增包依赖；只在 `Package.swift` 给测试 target 补已有模块的依赖。
- 新文件（含注释）不得出现 `ForbiddenAPITests` 的任何标记：`CGEvent`、`CGWarpMouseCursor`、`CGPostKeyboardEvent`、`IOHIDPostEvent`、`CGPreflightListenEventAccess`、`CGRequestListenEventAccess`、`CGRequestScreenCaptureAccess`、`CGPreflightScreenCaptureAccess`、`ScreenCaptureKit`、`SCScreenshotManager`、`CGWindowListCreateImage`、`CGDisplayCreateImage`、`CGWindowListCopyWindowInfo`、`NSPasteboard`（后者只允许在 `ResultPane.swift` 等三个文件）。屏幕录制状态只经 `handler.permissions(prompt:false, probe:false)["screenRecording"]` 取得。
- 体检从不弹框（`permissions(prompt:false, probe:false)`）、从不读 AX 树、从不碰企微界面、从不写配置。
- 报告与日志只含状态、计数、固定类别与固定中文说明：不得出现密钥、手机号、会话名、群名、broker 地址或用户名、桶名、对象名、corpId；外部错误原文只用于归类。
- `controller.readiness` 是分发器查询：不建命令记录、不产生事件、不进执行器队列；MCP `tools/list` 44 → 45；`RPCMethod.allCases.count` 保持 42。
- 联网实测同一时间最多一轮；结果在内存保留 300 000 ms；`refresh` 距上一轮开始须 ≥ 60 000 ms（所有调用方共用）；一轮总期限 40 s；视觉沿用客户端固定 8 s、MQTT 10 s、OSS 每请求 15 s、MCP 握手 10 s、代理健康检查 10 s。
- MQTT 探测主题 `<topicPrefix>/<controllerID>/readiness`；OSS 探测对象 `<baseDir>/imctl-readiness/<uuid>.txt`。
- 已校准企业微信版本常量 `5.0.11`；非此版本只提示，不判失败。
- 面向使用者的文字用中文；代码、注释、提交信息用英文（仓库现有风格）；修复命令以 `imctl ` 开头，由渲染方换成实际路径（含空格时加引号）。
- 每个任务结束前：`swift build` 通过、相关测试通过；提交前跑 `bash scripts/check-secrets.sh`（不得新增提醒）与 `git diff --check`。提交信息以 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` 结尾。

## Review Focus

- 执行器正被一条长命令占着（或一轮实测正在跑）时请求体检：应在约 1 秒内答复，而不是排队。→ Task 4 `answersWhileTheExecutorIsBusy`、Task 11 `answersImmediatelyWhileTheLiveTestsRun`。
- 某个探测永远不返回（MQTT 收不到 PUBACK、OSS 卡住）：到 40 s 期限记 `timeout`，其余结果照常，之后还能起下一轮。→ Task 3 `aProbeThatNeverFinishesTimesOutWithoutHidingTheOthers`、Task 11 `aStuckProbeEndsTheRoundAtTheDeadline`。
- 外部错误原文带着主机名、桶名、对象名或密钥：只能变成固定类别，报告里一个字都不出现。→ Task 8 `categoryNeverCarriesTheMessage`、Task 11 `reportCarriesNoSecretsFromRealConfigFiles`。
- 升级到一半，正在运行的守护进程还是 B52 之前的版本（答 `method not found`）：`imctl doctor` 要说「守护进程版本过旧，重新安装」并以 3 退出，而不是报错崩溃。→ Task 12 `anOldDaemonIsReportedAsTooOld`。
- 控制台和命令行同时在轮询：只起一轮付费实测；60 秒内的 `refresh` 返回上一轮结果。→ Task 3 `oneRunAtATimeThenCachedForFiveMinutes`、Task 11 `concurrentCallersStartOneRound`。

---

## 文件结构

| 文件 | 职责 | 任务 |
|---|---|---|
| `Sources/ControlCore/Protocol/ReadinessTypes.swift`（新） | 报告、检查项、修复指引、探测结果、`ReadinessProviding` 协议 | 1 |
| `Sources/ControlCore/Readiness/ReadinessFacts.swift`（新） | 判定所需事实（只含状态与计数） | 1 |
| `Sources/ControlCore/Readiness/ReadinessCommandText.swift`（新） | 修复命令里 `imctl` 换成实际路径 | 1 |
| `Sources/ControlCore/Readiness/ReadinessEvaluator.swift`（新） | 事实 → 12 项能力 → 就绪与下一步 | 2 |
| `Sources/ControlCore/Readiness/ReadinessOnlineState.swift`（新） | 联网实测的缓存、最短间隔、单轮状态机 | 3 |
| `Sources/ControlCore/Readiness/ReadinessProbeRunner.swift`（新） | 并发跑探测、总期限 | 3 |
| `Sources/MCPTransport/RPCDispatcher.swift`（改） | `controller.readiness` 查询分支与工具描述 | 4 |
| `docs/protocol/im-control-protocol.md` 等（改） | §6.45、变更表、工具数 | 4 |
| `Sources/imctld/WatchHealth.swift`（新） | watcher 最近一次轮询的线程安全快照 | 5 |
| `Sources/imctld/DaemonWatcher.swift`（改） | 每次轮询后更新快照 | 5 |
| `Sources/MCPTransport/AgentRegistration.swift`（新） | 两边智能体的注册与技能文件检查（只读） | 6 |
| `Sources/MCPTransport/MCPHandshakeProbe.swift`（新） | 启动包内 `imctl mcp serve` 握手 | 6 |
| `Sources/imctl/Host/AgentIntegration.swift`（改） | 路径改用 `AgentPaths` | 6 |
| `Sources/MQTTTransport/ProbeWait.swift`（新）、`MQTTSettings.swift`、`MQTTNIOLink.swift`（改） | 有界等待、探测主题、QoS 1 探测发布 | 7 |
| `Sources/OSSClient/OSSRoundTrip.swift`（新）、`Sources/imctl/Commands/OSSCommand.swift`（改） | 1 KB 往返（CLI 与体检共用）与类别映射 | 8 |
| `Sources/WeComAPI/WeComProxyHealth.swift`（新） | 代理 `/healthz` 探测 | 9 |
| `Sources/WeComAdapter/ReadinessVisionProbe.swift`（新） | 合成图 + B16 客户端 | 10 |
| `Sources/imctld/DaemonReadiness.swift`（新）、`main.swift`（改） | 事实采集、后台实测、装配 | 11 |
| `Sources/imctl/Host/Doctor.swift`（新）、`Sources/imctl/Commands/DoctorCommand.swift`（新）、`IMCTL.swift`、`SetupCommand.swift`（改） | `imctl doctor` 与兜底报告 | 12 |
| `Sources/imctl-console/Model/ReadinessText.swift`（新）、`ConsoleModel.swift`、`Views/StatusView.swift`、`Views/ResultPane.swift`（改） | 控制台「体检」区 | 13 |
| 文档与规则、`IMCTLVersion.swift`（改） | 安全边界、目录规范、运维文档、版本 | 14 |
| `docs/gates/<日期>-b52-readiness-doctor.md`（新） | 门报告 | 15 |

---

### Task 1: 报告类型、事实与命令路径替换（ControlCore）

**Files:**
- Create: `Sources/ControlCore/Protocol/ReadinessTypes.swift`
- Create: `Sources/ControlCore/Readiness/ReadinessFacts.swift`
- Create: `Sources/ControlCore/Readiness/ReadinessCommandText.swift`
- Test: `Tests/ControlCoreTests/ReadinessTypesTests.swift`

**Interfaces:**
- Produces: `ReadinessStatus`、`ReadinessFix(text:command:)`、`ReadinessCheck(id:status:detail:tested:latencyMs:)`、`ReadinessCapability(id:title:required:status:checks:fix:warnings:)`、`ReadinessOnlineInfo(state:testedMs:nextRefreshAllowedMs:)`、`ReadinessReport(ready:nextStep:nextStepCapability:capabilities:online:version:generatedMs:)`、`ReadinessProbeKind`（`.vision .mqtt .oss .agents .wecomApi`）、`ReadinessProbeResult.success(latencyMs:)` / `.failure(_:latencyMs:)` / `.elapsedMs(since:now:)`、`protocol ReadinessProviding: AnyObject { func readiness(online: Bool, refresh: Bool) -> ReadinessReport }`、`ReadinessFacts`（及嵌套 `Watch`、`Policy`、`Config`、`Vision`、`MQTT`、`SkillState`、`Agent`、`Agents`）、`ReadinessCommandText.substitute(_:cli:) -> String`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/ControlCoreTests/ReadinessTypesTests.swift
import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness types")
struct ReadinessTypesTests {
    @Test func reportRoundTripsThroughJSON() throws {
        let report = ReadinessReport(
            ready: false,
            nextStep: ReadinessFix(text: "打开企业微信并登录", command: "open -b com.tencent.WeWorkMac"),
            nextStepCapability: "wecom",
            capabilities: [ReadinessCapability(id: "wecom", title: "企业微信", required: true, status: .fail,
                                               checks: [ReadinessCheck(id: "running", status: .fail, detail: "没有运行")],
                                               fix: ReadinessFix(text: "打开企业微信并登录", command: "open -b com.tencent.WeWorkMac"),
                                               warnings: ["w"])],
            online: ReadinessOnlineInfo(state: "running", testedMs: nil, nextRefreshAllowedMs: 60_000),
            version: "1.0.15-dev", generatedMs: 42)
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(ReadinessReport.self, from: data) == report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"status\":\"fail\"") && text.contains("\"state\":\"running\""))
    }

    @Test func probeResultsCarryOnlyACategory() {
        #expect(ReadinessProbeResult.success(latencyMs: 12) == ReadinessProbeResult(ok: true, category: nil, latencyMs: 12))
        #expect(ReadinessProbeResult.failure("timeout", latencyMs: 9).category == "timeout")
        let start = Date(timeIntervalSince1970: 100)
        #expect(ReadinessProbeResult.elapsedMs(since: start, now: Date(timeIntervalSince1970: 100.25)) == 250)
        #expect(ReadinessProbeResult.elapsedMs(since: start, now: Date(timeIntervalSince1970: 99)) == 0)
    }

    @Test func commandsKeepImctlWhenItIsOnPath() {
        #expect(ReadinessCommandText.substitute("imctl setup", cli: "imctl") == "imctl setup")
    }

    @Test func commandsGetTheFullPathOtherwise() {
        let cli = "/Apps/imctl.app/Contents/MacOS/imctl"
        #expect(ReadinessCommandText.substitute("imctl setup", cli: cli) == "\(cli) setup")
        #expect(ReadinessCommandText.substitute("pbpaste | imctl vision set --provider qwen --secret-stdin", cli: cli)
                == "pbpaste | \(cli) vision set --provider qwen --secret-stdin")
        #expect(ReadinessCommandText.substitute("open -b com.tencent.WeWorkMac", cli: cli) == "open -b com.tencent.WeWorkMac")
        #expect(ReadinessCommandText.substitute("imctl setup", cli: "/tmp/my dir/imctl") == "\"/tmp/my dir/imctl\" setup")
    }

    @Test func factsDefaultToAHealthyCore() {
        let f = ReadinessFacts(version: "v")
        #expect(f.accessibilityTrusted && f.clientRunning && f.wecomData == "granted" && f.policy.autoAccept == "off")
        #expect(!f.vision.config.present && !f.mqtt.config.present && !f.agents.claude.registered)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter ReadinessTypesTests`
Expected: 编译失败，`cannot find 'ReadinessReport' in scope`。

- [ ] **Step 3: 写最小实现**

```swift
// Sources/ControlCore/Protocol/ReadinessTypes.swift
import Foundation

/// B52 `controller.readiness`: how ready this Mac is, capability by capability. A query like
/// `event.replay`: no command record, no events. Every string is a state, a count, a fixed category or
/// fixed advice — never a key, phone number, conversation title, broker host or bucket name.
public enum ReadinessStatus: String, Codable, Equatable, Sendable {
    case ok, fail, disabled, unknown
}

/// What to do about a capability. `command` starts with `imctl ` when it is this CLI; renderers swap in
/// the path the reader can run (`ReadinessCommandText`).
public struct ReadinessFix: Codable, Equatable, Sendable {
    public var text: String
    public var command: String?
    public init(text: String, command: String? = nil) { self.text = text; self.command = command }
}

public struct ReadinessCheck: Codable, Equatable, Sendable {
    public var id: String
    public var status: ReadinessStatus
    public var detail: String
    /// Live checks only: true when this report carries a live result, false when it does not.
    public var tested: Bool?
    public var latencyMs: Int?
    public init(id: String, status: ReadinessStatus, detail: String, tested: Bool? = nil, latencyMs: Int? = nil) {
        self.id = id; self.status = status; self.detail = detail; self.tested = tested; self.latencyMs = latencyMs
    }
}

public struct ReadinessCapability: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var required: Bool
    public var status: ReadinessStatus
    public var checks: [ReadinessCheck]
    /// For `fail`: how to fix it. For `disabled`: how to enable it.
    public var fix: ReadinessFix?
    public var warnings: [String]
    public init(id: String, title: String, required: Bool, status: ReadinessStatus, checks: [ReadinessCheck],
                fix: ReadinessFix? = nil, warnings: [String] = []) {
        self.id = id; self.title = title; self.required = required; self.status = status
        self.checks = checks; self.fix = fix; self.warnings = warnings
    }
}

public struct ReadinessOnlineInfo: Codable, Equatable, Sendable {
    /// `skipped` (online:false) | `running` | `done`.
    public var state: String
    /// When the last finished round ended.
    public var testedMs: Int64?
    /// Earliest time a `refresh` starts a new round.
    public var nextRefreshAllowedMs: Int64?
    public init(state: String, testedMs: Int64? = nil, nextRefreshAllowedMs: Int64? = nil) {
        self.state = state; self.testedMs = testedMs; self.nextRefreshAllowedMs = nextRefreshAllowedMs
    }
}

public struct ReadinessReport: Codable, Equatable, Sendable {
    public var ready: Bool
    public var nextStep: ReadinessFix?
    public var nextStepCapability: String?
    public var capabilities: [ReadinessCapability]
    public var online: ReadinessOnlineInfo
    public var version: String
    public var generatedMs: Int64
    public init(ready: Bool, nextStep: ReadinessFix?, nextStepCapability: String?, capabilities: [ReadinessCapability],
                online: ReadinessOnlineInfo, version: String, generatedMs: Int64) {
        self.ready = ready; self.nextStep = nextStep; self.nextStepCapability = nextStepCapability
        self.capabilities = capabilities; self.online = online; self.version = version; self.generatedMs = generatedMs
    }
}

/// Which live test a result belongs to.
public enum ReadinessProbeKind: String, Codable, CaseIterable, Sendable {
    case vision, mqtt, oss, agents, wecomApi
}

/// One live test's outcome: a fixed category on failure, never remote text.
public struct ReadinessProbeResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var category: String?
    public var latencyMs: Int
    public init(ok: Bool, category: String?, latencyMs: Int) { self.ok = ok; self.category = category; self.latencyMs = latencyMs }
    public static func success(latencyMs: Int) -> ReadinessProbeResult { ReadinessProbeResult(ok: true, category: nil, latencyMs: latencyMs) }
    public static func failure(_ category: String, latencyMs: Int) -> ReadinessProbeResult {
        ReadinessProbeResult(ok: false, category: category, latencyMs: latencyMs)
    }
    /// Milliseconds since `start`, never negative.
    public static func elapsedMs(since start: Date, now: Date = Date()) -> Int { max(0, Int((now.timeIntervalSince(start) * 1000).rounded())) }
}

/// Answers `controller.readiness`. Must return quickly: no AX tree reads and no network on the caller's thread.
public protocol ReadinessProviding: AnyObject {
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport
}
```

```swift
// Sources/ControlCore/Readiness/ReadinessFacts.swift
import Foundation

/// Everything `ReadinessEvaluator` needs, already reduced by the daemon to states and counts (B52).
/// Defaults describe a healthy core with every optional module unconfigured; the daemon sets every field.
public struct ReadinessFacts: Equatable, Sendable {
    public struct Watch: Equatable, Sendable {
        /// nil = the watcher has not finished a poll yet.
        public var lastPollAgeMs: Int64?
        /// The last poll read the conversation list.
        public var lastPollOK: Bool
        /// The watcher's availability verdict; nil before the first one.
        public var clientAvailable: Bool?
        public var conversationCount: Int
        /// The navigation rail was read at least once (B49).
        public var railRead: Bool
        /// Why the 通讯录 badge is not attributed; nil when it is.
        public var railProblem: String?
        public init(lastPollAgeMs: Int64? = nil, lastPollOK: Bool = false, clientAvailable: Bool? = nil,
                    conversationCount: Int = 0, railRead: Bool = false, railProblem: String? = nil) {
            self.lastPollAgeMs = lastPollAgeMs; self.lastPollOK = lastPollOK; self.clientAvailable = clientAvailable
            self.conversationCount = conversationCount; self.railRead = railRead; self.railProblem = railProblem
        }
    }

    public struct Policy: Equatable, Sendable {
        public var readable: Bool
        public var titleCount: Int
        public var typesEnabled: Bool
        public var chatIdCount: Int
        public var externalUserIdCount: Int
        public var allowAll: Bool
        public var phoneCount: Int
        public var maxAddsPerHour: Int
        /// `off` | `all` | `rules` | `remote`
        public var autoAccept: String
        public init(readable: Bool = true, titleCount: Int = 0, typesEnabled: Bool = false, chatIdCount: Int = 0,
                    externalUserIdCount: Int = 0, allowAll: Bool = false, phoneCount: Int = 0, maxAddsPerHour: Int = 20,
                    autoAccept: String = "off") {
            self.readable = readable; self.titleCount = titleCount; self.typesEnabled = typesEnabled
            self.chatIdCount = chatIdCount; self.externalUserIdCount = externalUserIdCount; self.allowAll = allowAll
            self.phoneCount = phoneCount; self.maxAddsPerHour = maxAddsPerHour; self.autoAccept = autoAccept
        }
    }

    /// A local settings file: present on disk, and parsed when present.
    public struct Config: Equatable, Sendable {
        public var present: Bool
        public var valid: Bool
        public init(present: Bool = false, valid: Bool = false) { self.present = present; self.valid = valid }
    }

    public struct Vision: Equatable, Sendable {
        public var config: Config
        public var cloudEnabled: Bool
        public var keyPresent: Bool
        public var provider: String
        public var model: String
        public var fullWindowEnabled: Bool
        public init(config: Config = Config(), cloudEnabled: Bool = false, keyPresent: Bool = false, provider: String = "qwen",
                    model: String = "", fullWindowEnabled: Bool = false) {
            self.config = config; self.cloudEnabled = cloudEnabled; self.keyPresent = keyPresent
            self.provider = provider; self.model = model; self.fullWindowEnabled = fullWindowEnabled
        }
    }

    public struct MQTT: Equatable, Sendable {
        public var config: Config
        /// The daemon was started with `--mqtt`.
        public var daemonMode: Bool
        public var connected: Bool
        public init(config: Config = Config(), daemonMode: Bool = false, connected: Bool = false) {
            self.config = config; self.daemonMode = daemonMode; self.connected = connected
        }
    }

    public enum SkillState: String, Codable, Equatable, Sendable { case missing, current, stale, unknown }

    public struct Agent: Equatable, Sendable {
        public var registered: Bool
        /// The registered command is the bundle's `imctl`.
        public var commandMatches: Bool
        public var skill: SkillState
        public init(registered: Bool = false, commandMatches: Bool = false, skill: SkillState = .missing) {
            self.registered = registered; self.commandMatches = commandMatches; self.skill = skill
        }
    }

    public struct Agents: Equatable, Sendable {
        public var claude: Agent
        public var codex: Agent
        /// The bundle's `imctl` exists, so the handshake can run.
        public var cliPresent: Bool
        public init(claude: Agent = Agent(), codex: Agent = Agent(), cliPresent: Bool = false) {
            self.claude = claude; self.codex = codex; self.cliPresent = cliPresent
        }
    }

    public var version: String
    public var launchedByLaunchd: Bool
    public var pauseReasons: [String]
    public var accessibilityTrusted: Bool
    public var screenRecordingGranted: Bool
    /// As `controller.permissions` reports it: granted | denied | pending | absent | unknown… | error…
    public var wecomData: String
    public var fullDiskAccess: Bool
    public var clientRunning: Bool
    public var clientVersion: String?
    public var watch: Watch
    public var policy: Policy
    public var vision: Vision
    public var mqtt: MQTT
    public var oss: Config
    public var agents: Agents
    public var wecomApi: Config

    public init(version: String, launchedByLaunchd: Bool = true, pauseReasons: [String] = [], accessibilityTrusted: Bool = true,
                screenRecordingGranted: Bool = true, wecomData: String = "granted", fullDiskAccess: Bool = true,
                clientRunning: Bool = true, clientVersion: String? = "5.0.11", watch: Watch = Watch(), policy: Policy = Policy(),
                vision: Vision = Vision(), mqtt: MQTT = MQTT(), oss: Config = Config(), agents: Agents = Agents(),
                wecomApi: Config = Config()) {
        self.version = version; self.launchedByLaunchd = launchedByLaunchd; self.pauseReasons = pauseReasons
        self.accessibilityTrusted = accessibilityTrusted; self.screenRecordingGranted = screenRecordingGranted
        self.wecomData = wecomData; self.fullDiskAccess = fullDiskAccess; self.clientRunning = clientRunning
        self.clientVersion = clientVersion; self.watch = watch; self.policy = policy; self.vision = vision
        self.mqtt = mqtt; self.oss = oss; self.agents = agents; self.wecomApi = wecomApi
    }
}
```

```swift
// Sources/ControlCore/Readiness/ReadinessCommandText.swift
import Foundation

/// Fix commands are written with `imctl` as the program (B52); a renderer swaps in the path the reader can run.
public enum ReadinessCommandText {
    public static func substitute(_ command: String, cli: String) -> String {
        guard cli != "imctl" else { return command }
        let program = cli.contains(" ") ? "\"\(cli)\"" : cli
        if command.hasPrefix("imctl ") { return program + String(command.dropFirst("imctl".count)) }
        return command.replacingOccurrences(of: "| imctl ", with: "| \(program) ")
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter ReadinessTypesTests`
Expected: 5 项通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/ControlCore/Protocol/ReadinessTypes.swift Sources/ControlCore/Readiness/ReadinessFacts.swift Sources/ControlCore/Readiness/ReadinessCommandText.swift Tests/ControlCoreTests/ReadinessTypesTests.swift
git commit -m "feat(readiness): report, facts and fix-command types for controller.readiness" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 判定规则 `ReadinessEvaluator`（ControlCore）

**Files:**
- Create: `Sources/ControlCore/Readiness/ReadinessEvaluator.swift`
- Test: `Tests/ControlCoreTests/ReadinessEvaluatorTests.swift`

**Interfaces:**
- Consumes: Task 1 全部类型；`PauseReason`（`RPCTypes.swift`）。
- Produces: `ReadinessEvaluator.evaluate(_ facts: ReadinessFacts, online: [ReadinessProbeKind: ReadinessProbeResult], info: ReadinessOnlineInfo, nowMs: Int64) -> ReadinessReport`；`ReadinessEvaluator.calibratedClientVersion == "5.0.11"`；`ReadinessEvaluator.categoryLabel(_:) -> String`。能力 id 依次为 `daemon wecom read send media contactAdd autoAccept vision mqtt oss agents wecomApi`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/ControlCoreTests/ReadinessEvaluatorTests.swift
import Foundation
import Testing
@testable import ControlCore

@Suite("ReadinessEvaluator")
struct ReadinessEvaluatorTests {
    static let done = ReadinessOnlineInfo(state: "done", testedMs: 1_000)

    static func healthy() -> ReadinessFacts {
        ReadinessFacts(version: "1.0.15-dev",
                       watch: .init(lastPollAgeMs: 800, lastPollOK: true, clientAvailable: true, conversationCount: 7, railRead: true))
    }

    static func visionOn() -> ReadinessFacts.Vision {
        .init(config: .init(present: true, valid: true), cloudEnabled: true, keyPresent: true, provider: "qwen", model: "qwen3.7-plus", fullWindowEnabled: true)
    }

    func evaluate(_ f: ReadinessFacts, _ online: [ReadinessProbeKind: ReadinessProbeResult] = [:],
                  info: ReadinessOnlineInfo = Self.done) -> ReadinessReport {
        ReadinessEvaluator.evaluate(f, online: online, info: info, nowMs: 2_000)
    }

    func cap(_ r: ReadinessReport, _ id: String) throws -> ReadinessCapability {
        try #require(r.capabilities.first { $0.id == id })
    }

    @Test func capabilitiesComeInFixOrder() {
        #expect(evaluate(Self.healthy()).capabilities.map(\.id)
                == ["daemon", "wecom", "read", "send", "media", "contactAdd", "autoAccept", "vision", "mqtt", "oss", "agents", "wecomApi"])
    }

    @Test func healthyCoreWithNothingOptionalIsReady() throws {
        let r = evaluate(Self.healthy())
        #expect(r.ready && r.nextStep == nil && r.nextStepCapability == nil && r.generatedMs == 2_000)
        for id in ["daemon", "wecom", "read", "send", "media"] { #expect(try cap(r, id).status == .ok) }
        for id in ["contactAdd", "autoAccept", "vision", "mqtt", "oss", "agents", "wecomApi"] {
            let c = try cap(r, id)
            #expect(c.status == .disabled && !c.required && c.fix != nil)
        }
    }

    @Test func clientNotRunningFailsWecomAndLeavesDownstreamUnknown() throws {
        var f = Self.healthy(); f.clientRunning = false
        let r = evaluate(f)
        #expect(!r.ready && r.nextStepCapability == "wecom" && r.nextStep?.command == "open -b com.tencent.WeWorkMac")
        #expect(try cap(r, "read").status == .unknown)
        #expect(try cap(r, "send").status == .unknown)
    }

    @Test func missingAccessibilityPointsAtSetup() throws {
        var f = Self.healthy(); f.accessibilityTrusted = false
        let r = evaluate(f)
        #expect(try cap(r, "wecom").status == .unknown)
        #expect(try cap(r, "read").status == .fail)
        #expect(r.nextStepCapability == "read" && r.nextStep?.command == "imctl setup")
    }

    @Test func contactsPaneIsReachableWithAWarning() throws {
        var f = Self.healthy(); f.watch.lastPollOK = false; f.watch.clientAvailable = true
        let wecom = try cap(evaluate(f), "wecom")
        #expect(wecom.status == .ok && wecom.warnings.contains { $0.contains("「消息」") })
    }

    @Test func lostWindowFailsWecomButASystemPauseLeavesTheDaemonOK() throws {
        var f = Self.healthy(); f.watch.clientAvailable = false; f.pauseReasons = ["system"]
        let r = evaluate(f)
        #expect(try cap(r, "daemon").status == .ok)
        #expect(try cap(r, "wecom").status == .fail && r.nextStepCapability == "wecom")
    }

    @Test func aFreshDaemonIsNotReadyButHasNoNextStep() throws {
        var f = Self.healthy(); f.watch = .init()
        let r = evaluate(f)
        #expect(!r.ready && r.nextStep == nil)
        #expect(try cap(r, "wecom").status == .unknown)
    }

    @Test func anUncalibratedClientVersionOnlyWarns() throws {
        var f = Self.healthy(); f.clientVersion = "5.0.12"
        let wecom = try cap(evaluate(f), "wecom")
        #expect(wecom.status == .ok && wecom.warnings.contains { $0.contains("5.0.12") })
        f.clientVersion = nil
        #expect(try cap(evaluate(f), "wecom").status == .ok)
    }

    @Test func withoutFullDiskAccessMediaPointsAtThatPane() throws {
        var f = Self.healthy(); f.fullDiskAccess = false
        f.wecomData = "unknown (pass prompt:true to probe; probing shows the system dialog once)"
        let r = evaluate(f)
        let media = try cap(r, "media")
        #expect(media.status == .fail && media.fix?.command?.contains("Privacy_AllFiles") == true && !r.ready)
    }

    @Test func screenRecordingIsFixedBeforeClientData() throws {
        var f = Self.healthy(); f.screenRecordingGranted = false; f.wecomData = "denied"
        #expect(try cap(evaluate(f), "media").fix?.command?.contains("Privacy_ScreenCapture") == true)
    }

    @Test func manualPauseAndManualRunFailTheDaemon() {
        var f = Self.healthy(); f.pauseReasons = ["api"]
        #expect(evaluate(f).nextStep?.command == "imctl call controller.resume")
        f.pauseReasons = []; f.launchedByLaunchd = false
        #expect(evaluate(f).nextStep?.command == "imctl setup")
    }

    @Test func allowAllAndAnUnreadablePolicyOnlyWarn() throws {
        var f = Self.healthy(); f.policy.allowAll = true; f.policy.readable = false
        let send = try cap(evaluate(f), "send")
        #expect(send.status == .ok && send.warnings.count == 2)
    }

    @Test func phonesEnableContactAdd() throws {
        var f = Self.healthy(); f.policy.phoneCount = 2
        let c = try cap(evaluate(f), "contactAdd")
        #expect(c.status == .ok && c.checks.first?.detail.contains("2 个号码") == true)
    }

    @Test func autoAcceptWithAnUnattributedRailFails() throws {
        var f = Self.healthy(); f.policy.autoAccept = "all"; f.watch.railProblem = "通讯录 pair at rail slot 1, expected 9"
        let r = evaluate(f)
        let auto = try cap(r, "autoAccept")
        #expect(auto.status == .fail && auto.fix?.command == "imctl probe rail" && !r.ready)
        f.watch.railProblem = nil
        #expect(try cap(evaluate(f), "autoAccept").status == .ok)
    }

    @Test func visionUsesTheLiveResultOnlyWhenDone() throws {
        var f = Self.healthy(); f.vision = Self.visionOn()
        #expect(try cap(evaluate(f, [.vision: .success(latencyMs: 900)]), "vision").status == .ok)
        let failed = try cap(evaluate(f, [.vision: .failure("http", latencyMs: 300)]), "vision")
        #expect(failed.status == .fail && failed.fix?.command?.contains("vision set") == true)
        let running = try cap(evaluate(f, [.vision: .failure("http", latencyMs: 300)], info: .init(state: "running")), "vision")
        #expect(running.status == .ok && running.checks.last?.tested == false)
    }

    @Test func visionWithoutAKeyOrScreenRecordingFails() throws {
        var f = Self.healthy(); f.vision = Self.visionOn(); f.vision.keyPresent = false
        #expect(try cap(evaluate(f), "vision").fix?.command == "pbpaste | imctl vision set --provider qwen --secret-stdin")
        f.vision.keyPresent = true; f.screenRecordingGranted = false
        #expect(try cap(evaluate(f), "vision").fix?.command?.contains("Privacy_ScreenCapture") == true)
    }

    @Test func mqttNeedsTheDaemonInMQTTModeAndAConnection() throws {
        var f = Self.healthy(); f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: false, connected: false)
        #expect(try cap(evaluate(f), "mqtt").fix?.command == "imctl agent install --mqtt")
        f.mqtt.daemonMode = true
        #expect(try cap(evaluate(f), "mqtt").status == .fail)
        f.mqtt.connected = true
        #expect(try cap(evaluate(f, [.mqtt: .success(latencyMs: 20)]), "mqtt").status == .ok)
        let rejected = try cap(evaluate(f, [.mqtt: .failure("rejected", latencyMs: 20)]), "mqtt")
        #expect(rejected.status == .fail && rejected.fix?.text.contains("授权") == true)
    }

    @Test func agentsCheckEachRegisteredSideOnly() throws {
        var f = Self.healthy()
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .current), codex: .init(), cliPresent: true)
        let ok = try cap(evaluate(f, [.agents: .success(latencyMs: 80)]), "agents")
        #expect(ok.status == .ok && ok.warnings.contains { $0.contains("Codex") })
        f.agents.claude.skill = .stale
        #expect(try cap(evaluate(f), "agents").fix?.command == "imctl mcp install --skills")
        f.agents.claude.skill = .current; f.agents.claude.commandMatches = false
        #expect(try cap(evaluate(f), "agents").fix?.command == "imctl mcp install --claude-code --skills")
    }

    @Test func ossAndProxyFollowTheirLiveTests() throws {
        var f = Self.healthy(); f.oss = .init(present: true, valid: true); f.wecomApi = .init(present: true, valid: true)
        let r = evaluate(f, [.oss: .failure("auth", latencyMs: 50), .wecomApi: .success(latencyMs: 40)])
        #expect(try cap(r, "oss").status == .fail)
        #expect(try cap(r, "wecomApi").status == .ok)
        f.oss.valid = false
        #expect(try cap(evaluate(f), "oss").checks.first?.detail.contains("oss.json") == true)
    }

    @Test func categoriesHaveChineseLabels() {
        #expect(ReadinessEvaluator.categoryLabel("timeout") == "超时")
        #expect(ReadinessEvaluator.categoryLabel("brand-new") == "brand-new")
        #expect(ReadinessEvaluator.categoryLabel(nil) == "未知")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter ReadinessEvaluatorTests`
Expected: 编译失败，`cannot find 'ReadinessEvaluator' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/ControlCore/Readiness/ReadinessEvaluator.swift
import Foundation

/// Pure rules from `ReadinessFacts` plus the last live results to a `ReadinessReport` (B52). The order of
/// `capabilities` is the order a person should fix things in; `nextStep` is the first `fail`'s fix.
public enum ReadinessEvaluator {
    /// The client version the recorded fixtures and gates cover. Other versions are not blocked.
    public static let calibratedClientVersion = "5.0.11"
    /// A watcher poll older than this is worth a warning (the timer polls every second).
    public static let staleWatchMs: Int64 = 15_000

    static let screenRecordingPane = #"open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture""#
    static let fullDiskAccessPane = #"open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles""#

    public static func evaluate(_ f: ReadinessFacts, online: [ReadinessProbeKind: ReadinessProbeResult],
                                info: ReadinessOnlineInfo, nowMs: Int64) -> ReadinessReport {
        let live = info.state == "done" ? online : [:]
        let daemon = daemonCapability(f)
        let wecom = wecomCapability(f)
        let read = readCapability(f, upstreamOK: daemon.status == .ok && wecom.status == .ok)
        let capabilities = [
            daemon, wecom, read,
            sendCapability(f, read: read.status),
            mediaCapability(f, read: read.status),
            contactAddCapability(f, read: read.status),
            autoAcceptCapability(f, read: read.status),
            visionCapability(f, live: live[.vision]),
            mqttCapability(f, live: live[.mqtt]),
            ossCapability(f, live: live[.oss]),
            agentsCapability(f, live: live[.agents]),
            wecomApiCapability(f, live: live[.wecomApi]),
        ]
        let ready = capabilities.allSatisfy { $0.status == .ok || (!$0.required && $0.status == .disabled) }
        let first = capabilities.first { $0.status == .fail }
        return ReadinessReport(ready: ready, nextStep: first?.fix, nextStepCapability: first?.id,
                               capabilities: capabilities, online: info, version: f.version, generatedMs: nowMs)
    }

    public static func categoryLabel(_ category: String?) -> String {
        switch category {
        case "timeout": "超时"
        case "network": "网络不通"
        case "auth": "认证被拒"
        case "http": "服务未接受请求"
        case "http4xx": "请求被拒（4xx）"
        case "http5xx": "服务端错误（5xx）"
        case "response": "应答格式不对"
        case "mismatch": "往返内容不一致"
        case "cleanup": "探测对象没删掉"
        case "rejected": "broker 拒绝发布"
        case "notConnected": "未连接"
        case "launch": "程序起不来"
        case "protocol": "握手应答不对"
        case "redirect": "发生了重定向"
        case "config": "配置读不了"
        case "internal": "内部错误"
        case let other?: other
        case nil: "未知"
        }
    }

    // MARK: Core

    static func daemonCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        let manual = f.pauseReasons.filter { $0 != PauseReason.system.rawValue }
        let checks = [
            ReadinessCheck(id: "launchd", status: f.launchedByLaunchd ? .ok : .fail,
                           detail: f.launchedByLaunchd ? "由 launchd 常驻" : "不是由 launchd 启动（手动运行或调试）"),
            ReadinessCheck(id: "version", status: .ok, detail: f.version),
            ReadinessCheck(id: "paused", status: manual.isEmpty ? .ok : .fail,
                           detail: f.pauseReasons.isEmpty ? "未暂停" : "暂停原因：\(f.pauseReasons.joined(separator: ","))"),
        ]
        var fix: ReadinessFix?
        if !f.launchedByLaunchd {
            fix = ReadinessFix(text: "安装后台常驻并请求系统授权", command: "imctl setup")
        } else if manual.contains(PauseReason.api.rawValue) {
            fix = ReadinessFix(text: "守护进程被手动暂停（api）；确认可以恢复后执行", command: "imctl call controller.resume")
        } else if !manual.isEmpty {
            fix = ReadinessFix(text: "守护进程处于保护暂停（\(manual.joined(separator: ","))）；先看日志找原因", command: "imctl call controller.logs")
        }
        return ReadinessCapability(id: "daemon", title: "守护进程", required: true, status: fix == nil ? .ok : .fail, checks: checks, fix: fix)
    }

    static func wecomCapability(_ f: ReadinessFacts) -> ReadinessCapability {
        var checks = [ReadinessCheck(id: "running", status: f.clientRunning ? .ok : .fail, detail: f.clientRunning ? "在运行" : "没有运行")]
        var warnings: [String] = []
        switch f.clientVersion {
        case calibratedClientVersion?:
            checks.append(ReadinessCheck(id: "version", status: .ok, detail: "\(calibratedClientVersion)（已校准）"))
        case let version?:
            checks.append(ReadinessCheck(id: "version", status: .ok, detail: "\(version)（未在此版本校准）"))
            warnings.append("企业微信 \(version) 未在此版本校准，能否使用以下面的可读性为准")
        case nil:
            checks.append(ReadinessCheck(id: "version", status: .unknown, detail: "读不到版本"))
        }
        let reachable: ReadinessCheck
        if !f.clientRunning {
            reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "企业微信没有运行")
        } else if !f.accessibilityTrusted {
            reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "要先授予辅助功能才能读取")
        } else if f.watch.clientAvailable == false {
            reachable = ReadinessCheck(id: "reachable", status: .fail, detail: "读不到企业微信主窗口，守护进程已暂停（system）")
        } else if let age = f.watch.lastPollAgeMs {
            if f.watch.lastPollOK {
                reachable = ReadinessCheck(id: "reachable", status: .ok, detail: "会话列表 \(f.watch.conversationCount) 行")
            } else if f.watch.clientAvailable == true {
                reachable = ReadinessCheck(id: "reachable", status: .ok, detail: "主窗口可达，当前不在「消息」页")
                warnings.append("企业微信当前不在「消息」页；读取会话前请切回「消息」")
            } else {
                reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "最近一次读取失败，正在重试")
            }
            if age > staleWatchMs { warnings.append("守护进程已有 \(age / 1000) 秒没有读到企业微信") }
        } else {
            reachable = ReadinessCheck(id: "reachable", status: .unknown, detail: "守护进程还没读过企业微信（刚启动）")
        }
        checks.append(reachable)
        let fix: ReadinessFix?
        if !f.clientRunning {
            fix = ReadinessFix(text: "打开企业微信并登录", command: "open -b com.tencent.WeWorkMac")
        } else if reachable.status == .fail {
            fix = ReadinessFix(text: "把企业微信主窗口打开（不要最小化），切到左侧「消息」，几秒后重新体检")
        } else {
            fix = nil
        }
        let status: ReadinessStatus = fix != nil ? .fail : (reachable.status == .unknown ? .unknown : .ok)
        return ReadinessCapability(id: "wecom", title: "企业微信", required: true, status: status, checks: checks, fix: fix, warnings: warnings)
    }

    static func readCapability(_ f: ReadinessFacts, upstreamOK: Bool) -> ReadinessCapability {
        let check = ReadinessCheck(id: "accessibility", status: f.accessibilityTrusted ? .ok : .fail,
                                   detail: f.accessibilityTrusted ? "imctld 已获辅助功能授权" : "imctld 没有辅助功能授权")
        guard f.accessibilityTrusted else {
            return ReadinessCapability(id: "read", title: "读取会话与历史", required: true, status: .fail, checks: [check],
                                       fix: ReadinessFix(text: "系统设置 › 隐私与安全性 › 辅助功能 里打开 imctld；新安装可直接执行", command: "imctl setup"))
        }
        return ReadinessCapability(id: "read", title: "读取会话与历史", required: true, status: upstreamOK ? .ok : .unknown, checks: [check])
    }

    static func sendCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        let p = f.policy
        var scope = "文件传输助手"
        if p.titleCount > 0 { scope += " + 会话 \(p.titleCount) 个" }
        if p.chatIdCount > 0 { scope += " + chatId \(p.chatIdCount) 个" }
        if p.externalUserIdCount > 0 { scope += " + externalUserId \(p.externalUserIdCount) 个" }
        if p.typesEnabled { scope += " + 按类型放行" }
        var warnings: [String] = []
        if p.allowAll { warnings.append("allowAll 已开启：任何会话都可发送") }
        if !p.readable { warnings.append("policy.json 读不了，只用内置白名单（文件传输助手）") }
        let check = ReadinessCheck(id: "allowlist", status: .ok, detail: p.allowAll ? "全部放开（allowAll）" : "可发送：\(scope)")
        return ReadinessCapability(id: "send", title: "发送消息", required: true, status: read == .ok ? .ok : .unknown,
                                   checks: [check], warnings: warnings)
    }

    static func mediaCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        let dataOK = f.wecomData == "granted"
        let checks = [
            ReadinessCheck(id: "screenRecording", status: f.screenRecordingGranted ? .ok : .fail,
                           detail: f.screenRecordingGranted ? "屏幕录制已允许" : "屏幕录制未允许"),
            ReadinessCheck(id: "wecomData", status: dataOK ? .ok : .fail, detail: "访问企微数据：\(wecomDataLabel(f.wecomData))"),
            ReadinessCheck(id: "fullDiskAccess", status: f.fullDiskAccess ? .ok : .fail,
                           detail: f.fullDiskAccess ? "完全磁盘访问权限已加" : "完全磁盘访问权限未加"),
        ]
        let fix: ReadinessFix?
        if !f.screenRecordingGranted {
            fix = ReadinessFix(text: "系统设置 › 隐私与安全性 › 屏幕录制 里允许 imctl.app；系统提示重启时选「稍后」，再重启守护进程", command: screenRecordingPane)
        } else if !dataOK {
            switch f.wecomData {
            case "pending": fix = ReadinessFix(text: "系统对话框「访问其他 App 的数据」还开着：点「允许」后重新体检")
            case "absent": fix = ReadinessFix(text: "找不到企业微信的数据目录：先打开并登录一次企业微信")
            default: fix = ReadinessFix(text: "系统设置 › 隐私与安全性 › 完全磁盘访问权限 里加入 imctl.app 并打开（不弹框确认「访问企微数据」只能靠它）", command: fullDiskAccessPane)
            }
        } else {
            fix = nil
        }
        let status: ReadinessStatus = fix != nil ? .fail : (read == .ok ? .ok : .unknown)
        return ReadinessCapability(id: "media", title: "图片判向与取回", required: true, status: status, checks: checks, fix: fix)
    }

    static func wecomDataLabel(_ value: String) -> String {
        switch value {
        case "granted": return "已允许"
        case "denied": return "被拒绝"
        case "pending": return "系统对话框未处理"
        case "absent": return "数据目录不存在"
        default: return value.hasPrefix("unknown") ? "未确认（没有完全磁盘访问权限时不探测）" : "探测出错"
        }
    }

    // MARK: Optional, local

    static func contactAddCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        guard f.policy.phoneCount > 0 else {
            return disabled("contactAdd", "按手机号加人", detail: "号码白名单为空",
                            fix: ReadinessFix(text: "要按手机号加人，先把号码加入本机白名单（只加自己的测试号）", command: "imctl policy phones --allow <号码>"))
        }
        let check = ReadinessCheck(id: "phones", status: .ok, detail: "白名单 \(f.policy.phoneCount) 个号码，每小时最多 \(f.policy.maxAddsPerHour) 次")
        return ReadinessCapability(id: "contactAdd", title: "按手机号加人", required: false, status: read == .ok ? .ok : .unknown, checks: [check])
    }

    static func autoAcceptCapability(_ f: ReadinessFacts, read: ReadinessStatus) -> ReadinessCapability {
        guard f.policy.autoAccept != "off" else {
            return disabled("autoAccept", "自动接受好友申请", detail: "策略 autoAccept=off",
                            fix: ReadinessFix(text: "要自动接受好友申请，在本机打开策略", command: "imctl policy requests --auto-accept all"))
        }
        let mode = ReadinessCheck(id: "mode", status: .ok, detail: "策略 autoAccept=\(f.policy.autoAccept)")
        let rail: ReadinessCheck
        var fix: ReadinessFix?
        if let problem = f.watch.railProblem {
            rail = ReadinessCheck(id: "rail", status: .fail, detail: "通讯录角标无法归属：\(problem)")
            fix = ReadinessFix(text: "这台 Mac 的企业微信导航栏布局与已校准的不同，后台不会自动开始接受；下面的命令可查看布局，适配需要改代码", command: "imctl probe rail")
        } else if f.watch.railRead {
            rail = ReadinessCheck(id: "rail", status: .ok, detail: "通讯录角标已归属")
        } else {
            rail = ReadinessCheck(id: "rail", status: .unknown, detail: "还没读到导航栏")
        }
        let status: ReadinessStatus = fix != nil ? .fail : (read == .ok && rail.status == .ok ? .ok : .unknown)
        return ReadinessCapability(id: "autoAccept", title: "自动接受好友申请", required: false, status: status, checks: [mode, rail], fix: fix)
    }

    // MARK: Optional, live

    /// The live check of an enabled module: `tested:false` when this report has no result for it.
    static func liveCheck(_ id: String, _ result: ReadinessProbeResult?, ok okDetail: String) -> ReadinessCheck {
        guard let result else { return ReadinessCheck(id: id, status: .ok, detail: "未实测", tested: false) }
        return result.ok
            ? ReadinessCheck(id: id, status: .ok, detail: okDetail, tested: true, latencyMs: result.latencyMs)
            : ReadinessCheck(id: id, status: .fail, detail: "失败（\(categoryLabel(result.category))）", tested: true, latencyMs: result.latencyMs)
    }

    static func visionCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        let v = f.vision
        let setKey = "pbpaste | imctl vision set --provider \(v.provider) --secret-stdin"
        guard v.config.present else {
            return disabled("vision", "视觉兜底", detail: "未配置",
                            fix: ReadinessFix(text: "要用视觉兜底：把千问（或 Gemini）的密钥复制到剪贴板后执行；密钥只存本机",
                                              command: "pbpaste | imctl vision set --provider qwen --secret-stdin"))
        }
        guard v.config.valid else {
            return failure("vision", "视觉兜底", check: ReadinessCheck(id: "config", status: .fail, detail: "cloud-vision.json 读不了（目录须 0700、文件须 0600）"),
                           fix: ReadinessFix(text: "重新写入视觉配置", command: setKey))
        }
        guard v.cloudEnabled else {
            return disabled("vision", "视觉兜底", detail: "云端视觉已关闭",
                            fix: ReadinessFix(text: "重新开启云端视觉（沿用已存的密钥）", command: "imctl vision set --provider \(v.provider)"))
        }
        let call = v.keyPresent ? liveCheck("call", live, ok: "模型应答正常")
                                : ReadinessCheck(id: "call", status: .unknown, detail: "没有密钥，未实测", tested: false)
        let checks = [
            ReadinessCheck(id: "provider", status: .ok, detail: "\(v.provider) · \(v.model)"),
            ReadinessCheck(id: "key", status: v.keyPresent ? .ok : .fail, detail: v.keyPresent ? "密钥已存" : "当前提供商没有密钥"),
            ReadinessCheck(id: "screenRecording", status: f.screenRecordingGranted ? .ok : .fail,
                           detail: f.screenRecordingGranted ? "屏幕录制已允许" : "屏幕录制未允许"),
            ReadinessCheck(id: "fullWindow", status: .ok, detail: v.fullWindowEnabled ? "整窗辅助已开启（仅显式桌面命令）" : "整窗辅助未开启"),
            call,
        ]
        let fix: ReadinessFix?
        if !v.keyPresent {
            fix = ReadinessFix(text: "当前提供商没有密钥：复制密钥后执行", command: setKey)
        } else if !f.screenRecordingGranted {
            fix = ReadinessFix(text: "视觉兜底要截企微窗口：在 系统设置 › 隐私与安全性 › 屏幕录制 里允许 imctl.app", command: screenRecordingPane)
        } else if call.status == .fail {
            switch live?.category {
            case "http", "auth", "http4xx", "config": fix = ReadinessFix(text: "密钥被拒或额度不足：换一个有效密钥", command: setKey)
            case "timeout", "network": fix = ReadinessFix(text: "连不上视觉服务：检查网络或代理后重测", command: "imctl doctor --refresh")
            default: fix = ReadinessFix(text: "视觉服务应答异常（\(categoryLabel(live?.category))）：稍后重测", command: "imctl doctor --refresh")
            }
        } else {
            fix = nil
        }
        return ReadinessCapability(id: "vision", title: "视觉兜底", required: false, status: fix == nil ? .ok : .fail, checks: checks, fix: fix)
    }

    static func mqttCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        let m = f.mqtt
        let enroll = "imctl enroll --broker <主机[:端口]> --controller-id <本机 id>"
        guard m.config.present else {
            return disabled("mqtt", "MQTT 对接", detail: "未配置",
                            fix: ReadinessFix(text: "要让 Java 或远端经 MQTT 调用：先登记 broker 与本机 controller id，再以 MQTT 模式重装守护进程", command: enroll))
        }
        guard m.config.valid else {
            return failure("mqtt", "MQTT 对接", check: ReadinessCheck(id: "config", status: .fail, detail: "mqtt.json 读不了"),
                           fix: ReadinessFix(text: "重新登记 broker", command: enroll))
        }
        let publish = m.daemonMode && m.connected ? liveCheck("publish", live, ok: "broker 已确认探测消息")
                                                  : ReadinessCheck(id: "publish", status: .unknown, detail: "未连接，未实测", tested: false)
        let checks = [
            ReadinessCheck(id: "config", status: .ok, detail: "mqtt.json 已配置"),
            ReadinessCheck(id: "daemonMode", status: m.daemonMode ? .ok : .fail, detail: m.daemonMode ? "守护进程以 MQTT 模式运行" : "守护进程没有以 MQTT 模式运行"),
            ReadinessCheck(id: "connected", status: m.connected ? .ok : .fail, detail: m.connected ? "已连上 broker" : "没有连上 broker"),
            publish,
        ]
        let fix: ReadinessFix?
        if !m.daemonMode {
            fix = ReadinessFix(text: "以 MQTT 模式重装守护进程", command: "imctl agent install --mqtt")
        } else if !m.connected {
            fix = ReadinessFix(text: "连不上 broker：核对 mqtt.json 的地址、端口与账号；网络恢复后守护进程会自动重连", command: "imctl status")
        } else if publish.status == .fail {
            fix = live?.category == "rejected"
                ? ReadinessFix(text: "broker 拒绝发布：检查本机账号对 im/<controllerId>/# 的授权", command: "imctl doctor --refresh")
                : ReadinessFix(text: "broker 没有确认探测消息（\(categoryLabel(live?.category))）：检查网络后重测", command: "imctl doctor --refresh")
        } else {
            fix = nil
        }
        return ReadinessCapability(id: "mqtt", title: "MQTT 对接", required: false, status: fix == nil ? .ok : .fail, checks: checks, fix: fix)
    }

    static func ossCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        guard f.oss.present else {
            return disabled("oss", "OSS 对象存储", detail: "未配置",
                            fix: ReadinessFix(text: "要用 OSS 收发文件：写入 oss.json（AccessKey Secret 用 --secret-stdin 传入）", command: "imctl oss set --help"))
        }
        guard f.oss.valid else {
            return failure("oss", "OSS 对象存储", check: ReadinessCheck(id: "config", status: .fail, detail: "oss.json 无效"),
                           fix: ReadinessFix(text: "重新写入 oss.json", command: "imctl oss set --help"))
        }
        let roundTrip = liveCheck("roundTrip", live, ok: "1 KB 往返正常")
        let fix: ReadinessFix?
        if roundTrip.status == .fail {
            switch live?.category {
            case "auth", "http4xx": fix = ReadinessFix(text: "OSS 拒绝请求：检查 AccessKey 与桶的读写权限", command: "imctl oss test")
            case "cleanup": fix = ReadinessFix(text: "探测对象没删掉：在 OSS 控制台删除 imctl-readiness/ 下的对象")
            default: fix = ReadinessFix(text: "OSS 往返失败（\(categoryLabel(live?.category))）：用下面的命令看每一步", command: "imctl oss test")
            }
        } else {
            fix = nil
        }
        return ReadinessCapability(id: "oss", title: "OSS 对象存储", required: false, status: fix == nil ? .ok : .fail,
                                   checks: [ReadinessCheck(id: "config", status: .ok, detail: "oss.json 已配置"), roundTrip], fix: fix)
    }

    static func agentsCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        let a = f.agents
        guard a.claude.registered || a.codex.registered else {
            return disabled("agents", "Claude Code / Codex 接入", detail: "两边都没有登记 imctl",
                            fix: ReadinessFix(text: "接入 Claude Code / Codex（MCP 与技能文件）", command: "imctl mcp install --claude-code --codex --skills"))
        }
        struct Side { let key: String; let name: String; let agent: ReadinessFacts.Agent; let removal: String; let reinstall: String }
        let sides = [
            Side(key: "claude", name: "Claude Code", agent: a.claude, removal: "执行 claude mcp remove imctl -s user",
                 reinstall: "imctl mcp install --claude-code --skills"),
            Side(key: "codex", name: "Codex", agent: a.codex, removal: "删掉 ~/.codex/config.toml 里的 [mcp_servers.imctl] 一段",
                 reinstall: "imctl mcp install --codex --skills"),
        ]
        var checks: [ReadinessCheck] = []
        var warnings: [String] = []
        var fix: ReadinessFix?
        for side in sides {
            guard side.agent.registered else { warnings.append("\(side.name) 没有登记 imctl（可选）"); continue }
            checks.append(ReadinessCheck(id: "\(side.key).command", status: side.agent.commandMatches ? .ok : .fail,
                                         detail: side.agent.commandMatches ? "\(side.name) 登记的是当前应用" : "\(side.name) 登记的不是当前应用里的 imctl"))
            if !side.agent.commandMatches, fix == nil {
                fix = ReadinessFix(text: "\(side.name) 里登记的路径不是当前应用：先\(side.removal)，再执行", command: side.reinstall)
            }
            switch side.agent.skill {
            case .current:
                checks.append(ReadinessCheck(id: "\(side.key).skill", status: .ok, detail: "\(side.name) 技能文件是当前版本"))
            case .missing, .stale:
                checks.append(ReadinessCheck(id: "\(side.key).skill", status: .fail,
                                             detail: side.agent.skill == .missing ? "\(side.name) 缺技能文件" : "\(side.name) 技能文件不是当前版本"))
                if fix == nil { fix = ReadinessFix(text: "更新技能文件", command: "imctl mcp install --skills") }
            case .unknown:
                checks.append(ReadinessCheck(id: "\(side.key).skill", status: .unknown, detail: "\(side.name) 技能文件无法比对（应用包里没有 SKILL.md）"))
            }
        }
        let handshake = a.cliPresent ? liveCheck("handshake", live, ok: "imctl mcp serve 握手正常")
                                     : ReadinessCheck(id: "handshake", status: .unknown, detail: "应用包里找不到 imctl，未实测", tested: false)
        checks.append(handshake)
        if fix == nil, handshake.status == .fail {
            fix = ReadinessFix(text: "应用里的 imctl 起不来或版本不对（\(categoryLabel(live?.category))）：重新安装应用后重测", command: "imctl doctor --refresh")
        }
        return ReadinessCapability(id: "agents", title: "Claude Code / Codex 接入", required: false, status: fix == nil ? .ok : .fail,
                                   checks: checks, fix: fix, warnings: warnings)
    }

    static func wecomApiCapability(_ f: ReadinessFacts, live: ReadinessProbeResult?) -> ReadinessCapability {
        guard f.wecomApi.present else {
            return disabled("wecomApi", "企微官方 API 代理", detail: "未配置",
                            fix: ReadinessFix(text: "企微官方 API 要先部署令牌代理（见 docs/protocol/wecom-token-proxy.md），再登记代理地址", command: "imctl wecom enroll --help"))
        }
        guard f.wecomApi.valid else {
            return failure("wecomApi", "企微官方 API 代理", check: ReadinessCheck(id: "config", status: .fail, detail: "wecom-proxy.json 读不了"),
                           fix: ReadinessFix(text: "重新登记代理", command: "imctl wecom enroll --help"))
        }
        let health = liveCheck("health", live, ok: "代理健康检查正常")
        let fix: ReadinessFix? = health.status == .fail
            ? ReadinessFix(text: "代理健康检查失败（\(categoryLabel(live?.category))）：确认代理在运行、地址可达", command: "imctl doctor --refresh")
            : nil
        return ReadinessCapability(id: "wecomApi", title: "企微官方 API 代理", required: false, status: fix == nil ? .ok : .fail,
                                   checks: [ReadinessCheck(id: "config", status: .ok, detail: "wecom-proxy.json 已配置"), health], fix: fix)
    }

    // MARK: Helpers

    static func disabled(_ id: String, _ title: String, detail: String, fix: ReadinessFix) -> ReadinessCapability {
        ReadinessCapability(id: id, title: title, required: false, status: .disabled,
                            checks: [ReadinessCheck(id: "config", status: .disabled, detail: detail)], fix: fix)
    }

    static func failure(_ id: String, _ title: String, check: ReadinessCheck, fix: ReadinessFix) -> ReadinessCapability {
        ReadinessCapability(id: id, title: title, required: false, status: .fail, checks: [check], fix: fix)
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter ReadinessEvaluatorTests`
Expected: 20 项通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/ControlCore/Readiness/ReadinessEvaluator.swift Tests/ControlCoreTests/ReadinessEvaluatorTests.swift
git commit -m "feat(readiness): capability rules, ready verdict and next step" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 联网实测的状态机与并发执行（ControlCore）

**Files:**
- Create: `Sources/ControlCore/Readiness/ReadinessOnlineState.swift`
- Create: `Sources/ControlCore/Readiness/ReadinessProbeRunner.swift`
- Test: `Tests/ControlCoreTests/ReadinessOnlineStateTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessProbeKind`、`ReadinessProbeResult`、`ReadinessOnlineInfo`。
- Produces: `ReadinessOnlineState`（`cacheMs = 300_000`、`refreshFloorMs = 60_000`、`enum Decision { case skip, serve, start }`、`mutating func request(online:refresh:nowMs:) -> Decision`、`mutating func finish(_:nowMs:)`、`func info(online:nowMs:) -> ReadinessOnlineInfo`、`private(set) var running`、`private(set) var results`）；`ReadinessProbeRunner.run(_ probes: [ReadinessProbeKind: () -> ReadinessProbeResult], deadline: TimeInterval = 40) -> [ReadinessProbeKind: ReadinessProbeResult]`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/ControlCoreTests/ReadinessOnlineStateTests.swift
import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness live-test state")
struct ReadinessOnlineStateTests {
    @Test func offlineNeverStarts() {
        var s = ReadinessOnlineState()
        #expect(s.request(online: false, refresh: true, nowMs: 0) == .skip)
        #expect(s.info(online: false, nowMs: 0).state == "skipped" && !s.running)
    }

    @Test func oneRunAtATimeThenCachedForFiveMinutes() {
        var s = ReadinessOnlineState()
        #expect(s.request(online: true, refresh: false, nowMs: 0) == .start)
        #expect(s.request(online: true, refresh: true, nowMs: 100) == .serve)
        #expect(s.info(online: true, nowMs: 100).state == "running")
        s.finish([.mqtt: .success(latencyMs: 5)], nowMs: 2_000)
        #expect(s.info(online: true, nowMs: 2_000) == ReadinessOnlineInfo(state: "done", testedMs: 2_000, nextRefreshAllowedMs: 60_000))
        #expect(s.results?[.mqtt]?.ok == true)
        #expect(s.request(online: true, refresh: false, nowMs: 301_999) == .serve)
        #expect(s.request(online: true, refresh: false, nowMs: 302_000) == .start)
    }

    @Test func refreshWaitsSixtySecondsFromTheLastStart() {
        var s = ReadinessOnlineState()
        _ = s.request(online: true, refresh: false, nowMs: 0)
        s.finish([:], nowMs: 1_000)
        #expect(s.request(online: true, refresh: true, nowMs: 59_999) == .serve)
        #expect(s.request(online: true, refresh: true, nowMs: 60_000) == .start)
    }
}

@Suite("Readiness probe runner")
struct ReadinessProbeRunnerTests {
    @Test func probesRunConcurrently() {
        let started = Date()
        let results = ReadinessProbeRunner.run([
            .oss: { Thread.sleep(forTimeInterval: 0.3); return .success(latencyMs: 300) },
            .mqtt: { Thread.sleep(forTimeInterval: 0.3); return .success(latencyMs: 300) },
        ], deadline: 5)
        #expect(results.count == 2 && results.values.allSatisfy(\.ok))
        #expect(Date().timeIntervalSince(started) < 0.55)
    }

    @Test func aProbeThatNeverFinishesTimesOutWithoutHidingTheOthers() {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let results = ReadinessProbeRunner.run([
            .mqtt: { gate.wait(); return .success(latencyMs: 1) },
            .oss: { .success(latencyMs: 2) },
        ], deadline: 0.3)
        #expect(results[.mqtt] == .failure("timeout", latencyMs: 300))
        #expect(results[.oss]?.ok == true)
    }

    @Test func nothingToRunIsEmpty() {
        #expect(ReadinessProbeRunner.run([:], deadline: 1).isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter "ReadinessOnlineStateTests|ReadinessProbeRunnerTests"`
Expected: 编译失败，`cannot find 'ReadinessOnlineState' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/ControlCore/Readiness/ReadinessOnlineState.swift
import Foundation

/// When `controller.readiness` may start a round of live tests (B52). Pure: the caller holds a lock and
/// passes the clock. One round at a time; a finished round serves every caller for `cacheMs`; `refresh`
/// starts a new one only `refreshFloorMs` after the last start, whoever asks (socket, MQTT or MCP).
public struct ReadinessOnlineState: Equatable, Sendable {
    public static let cacheMs: Int64 = 300_000
    public static let refreshFloorMs: Int64 = 60_000

    public enum Decision: Equatable, Sendable { case skip, serve, start }

    public private(set) var running = false
    public private(set) var lastStartMs: Int64?
    public private(set) var results: [ReadinessProbeKind: ReadinessProbeResult]?
    public private(set) var testedMs: Int64?

    public init() {}

    public mutating func request(online: Bool, refresh: Bool, nowMs: Int64) -> Decision {
        guard online else { return .skip }
        if running { return .serve }
        if refresh, let lastStartMs, nowMs - lastStartMs < Self.refreshFloorMs { return .serve }
        if !refresh, results != nil, let testedMs, nowMs - testedMs < Self.cacheMs { return .serve }
        running = true
        lastStartMs = nowMs
        return .start
    }

    public mutating func finish(_ results: [ReadinessProbeKind: ReadinessProbeResult], nowMs: Int64) {
        self.results = results
        testedMs = nowMs
        running = false
    }

    public func info(online: Bool, nowMs: Int64) -> ReadinessOnlineInfo {
        let next = lastStartMs.map { $0 + Self.refreshFloorMs }
        guard online else { return ReadinessOnlineInfo(state: "skipped", testedMs: testedMs, nextRefreshAllowedMs: next) }
        return ReadinessOnlineInfo(state: running ? "running" : "done", testedMs: testedMs, nextRefreshAllowedMs: next)
    }
}
```

```swift
// Sources/ControlCore/Readiness/ReadinessProbeRunner.swift
import Foundation

/// Runs one round of live tests concurrently (B52). A probe still running at the deadline is reported as
/// `timeout`; its late result is dropped, so a stuck network call never holds the round or the next one.
public enum ReadinessProbeRunner {
    public static let deadlineSeconds: TimeInterval = 40

    public static func run(_ probes: [ReadinessProbeKind: () -> ReadinessProbeResult],
                           deadline: TimeInterval = deadlineSeconds) -> [ReadinessProbeKind: ReadinessProbeResult] {
        guard !probes.isEmpty else { return [:] }
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var results: [ReadinessProbeKind: ReadinessProbeResult] = [:]
        }
        let collected = Collected()
        let group = DispatchGroup()
        for (kind, probe) in probes {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = probe()
                collected.lock.lock(); collected.results[kind] = result; collected.lock.unlock()
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + deadline)
        collected.lock.lock()
        var out = collected.results
        collected.lock.unlock()
        for kind in probes.keys where out[kind] == nil {
            out[kind] = .failure("timeout", latencyMs: Int((deadline * 1000).rounded()))
        }
        return out
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "ReadinessOnlineStateTests|ReadinessProbeRunnerTests"`
Expected: 6 项通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/ControlCore/Readiness/ReadinessOnlineState.swift Sources/ControlCore/Readiness/ReadinessProbeRunner.swift Tests/ControlCoreTests/ReadinessOnlineStateTests.swift
git commit -m "feat(readiness): one cached live-test round at a time, bounded by a deadline" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 分发器查询、MCP 工具与协议文档

**Files:**
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`（常量与属性在 `:13-22`；`tools/call` 分支 `:58-69`；直接方法分支 `:84-92` 之后；`toolDescriptors()` 里 `controller.permissions` 一行之后）
- Modify: `Tests/MCPTransportTests/DispatcherTests.swift:72`、`Tests/MCPTransportTests/MCPProxyTests.swift:34`（44 → 45）
- Modify: `docs/protocol/im-control-protocol.md`（§2.6 `:59`、§6 末尾 `:328` 之后加 §6.45、`:332`、§12 末行之后）、`docs/protocol/agents-mcp.md`（`:17` 之后、`:64`）、`docs/agents/skills/imctl/SKILL.md`（`:14`、`:55`）、`docs/protocol/java-consumer.md:21`
- Test: `Tests/MCPTransportTests/DispatcherReadinessTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessProviding`、`ReadinessReport`。
- Produces: `RPCDispatcher.readinessMethod == "controller.readiness"`；`public var readiness: ReadinessProviding?`；查询结果即 `ReadinessReport` 的 JSON（不是命令记录）。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/MCPTransportTests/DispatcherReadinessTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

final class FakeReadiness: ReadinessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(online: Bool, refresh: Bool)] = []
    let report = ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                                 online: ReadinessOnlineInfo(state: "done", testedMs: 5), version: "t", generatedMs: 9)
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); calls.append((online, refresh)); lock.unlock()
        return report
    }
}

@Suite("controller.readiness is a dispatcher query")
struct DispatcherReadinessTests {
    func make() throws -> (RPCDispatcher, ControlStore, FakeReadiness) {
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let fake = FakeReadiness()
        dispatcher.readiness = fake
        return (dispatcher, store, fake)
    }

    @Test func directCallReturnsTheReportAndPassesTheFlags() throws {
        let (d, store, fake) = try make()
        let line = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness","params":{"online":false,"refresh":true}}"#))
        let result = try #require(try JSONValue.parse(line).objectValue?["result"]?.objectValue)
        #expect(result["ready"]?.boolValue == true && result["version"]?.stringValue == "t")
        #expect(result["commandId"] == nil)
        #expect(fake.calls.count == 1 && fake.calls[0].online == false && fake.calls[0].refresh == true)
        #expect(try store.events(after: 0, limit: 10).isEmpty)
    }

    @Test func defaultsAreOnlineWithoutRefresh() throws {
        let (d, _, fake) = try make()
        _ = d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness"}"#)
        #expect(fake.calls.first?.online == true && fake.calls.first?.refresh == false)
    }

    @Test func toolsCallAnswersWithTheReportText() throws {
        let (d, _, _) = try make()
        let line = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"controller.readiness","arguments":{}}}"#))
        let result = try #require(try JSONValue.parse(line).objectValue?["result"]?.objectValue)
        #expect(result["isError"]?.boolValue == false)
        let text = try #require(result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(try JSONValue.parse(text).objectValue?["ready"]?.boolValue == true)
    }

    @Test func withoutAProviderItIsUnsupported() throws {
        let store = try ControlStore(path: ":memory:")
        let d = RPCDispatcher(executor: CommandExecutor(store: store, handler: DispatchFakeHandler()))
        let line = try #require(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness"}"#))
        #expect(line.contains("UNSUPPORTED"))
    }

    @Test func answersWhileTheExecutorIsBusy() throws {
        let (d, _, _) = try make()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { d.executor.serialized { entered.signal(); gate.wait() } }
        entered.wait()
        defer { gate.signal() }
        let started = Date()
        #expect(d.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"controller.readiness"}"#) != nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func theToolIsListedWithItsParameters() throws {
        let tool = try #require(RPCDispatcher.toolDescriptors().first { $0.objectValue?["name"]?.stringValue == "controller.readiness" })
        let properties = try #require(tool.objectValue?["inputSchema"]?.objectValue?["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["online", "refresh"])
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter DispatcherReadinessTests`
Expected: 编译失败，`value of type 'RPCDispatcher' has no member 'readiness'`。

- [ ] **Step 3: 改分发器**

在 `RPCDispatcher` 的 `mediaMethod` 声明之后加：

```swift
    /// B52: a query like replay — no command record, no events, never on the executor queue. The daemon
    /// sets `readiness`; without it (tests, other hosts) the answer is UNSUPPORTED.
    public static let readinessMethod = "controller.readiness"
    public var readiness: ReadinessProviding?
```

在 `tools/call` 分支里，把下面几行插在 media 分支 `switch media(args) { … }` 的右花括号之后、紧接着的 `} else {` 那一行之前（插入后由原来的 `} else {` 收尾）：

```swift
            } else if name == Self.readinessMethod {
                switch readinessResult(args) {
                case .success(let value):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string((try? value.serialized()) ?? "{}")])]), "isError": .bool(false)])
                case .failure(let err):
                    response = .object(["content": .array([.object(["type": .string("text"), "text": .string("\(err.code): \(err.message)")])]), "isError": .bool(true)])
                }
```

在直接方法的 `case Self.mediaMethod:` 分支之后、`default:` 之前插入：

```swift
        case Self.readinessMethod:
            switch readinessResult(params) {
            case .success(let value): response = value
            case .failure(let err): return Self.errorResponse(id: id, code: -32000, message: err.message, data: .object(["code": .string(err.code)]))
            }
```

在 `media(_:)` 之后加：

```swift
    /// `{online?=true, refresh?=false}` → `ReadinessReport` as JSON. Answers on the caller's queue: the
    /// provider never reads the AX tree or the network here (live tests run in the daemon's background).
    func readinessResult(_ params: [String: JSONValue]) -> Result<JSONValue, ControlError> {
        guard let readiness else { return .failure(.unsupported("controller.readiness needs the daemon")) }
        let report = readiness.readiness(online: params["online"]?.boolValue ?? true, refresh: params["refresh"]?.boolValue ?? false)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return .success(try JSONValue.parse(String(decoding: try encoder.encode(report), as: UTF8.self)))
        } catch {
            return .failure(.internalError(String(describing: error)))
        }
    }
```

在 `toolDescriptors()` 的 `("controller.permissions", …)` 一行之后加：

```swift
            ("controller.readiness", "Readiness of this Mac per capability (daemon, wecom, read, send, media, contactAdd, autoAccept, vision, mqtt, oss, agents, wecomApi): ok / fail / disabled / unknown with the command that fixes it. A query: no command record. online:true (default) starts the live tests in the background — one synthetic-image vision call, MQTT publish ack, OSS 1 KB round trip, MCP handshake, proxy health — and answers online.state=running until they finish: call again a second later. refresh:true retests at most once per 60 s for every caller", schema(["online": ("boolean", "Run the live tests (default true)"), "refresh": ("boolean", "Retest instead of reusing the last round (at most once per 60 s for every caller)")], required: [])),
```

把 `Tests/MCPTransportTests/DispatcherTests.swift:72` 的 `arr.count == 44` 和 `Tests/MCPTransportTests/MCPProxyTests.swift:34` 的 `count == 44` 都改成 `45`。

- [ ] **Step 4: 写协议文档（`ProtocolDocTests` 要求工具名出现在文档里）**

`docs/protocol/im-control-protocol.md`：

1. §2.6（`:59`）把「`tools/list`（每个方法一个工具，含 `event.replay`）」改为「`tools/list`（每个方法一个工具，另含查询 `event.replay`、`message.media`、`controller.readiness`）」。
2. 在 `### 6.44 \`group.addMembers\`` 那一节之后、§7 之前插入：

```markdown
### 6.45 `controller.readiness`

**查询**（与 `event.replay` 一样：不建命令记录、不产生 `command.state` 事件、不排进执行器队列）。参数 `{online?=true, refresh?=false}`。返回本机逐项就绪情况：`{ready, nextStep?{text, command?}, nextStepCapability?, capabilities: [{id, title, required, status: ok|fail|disabled|unknown, checks: [{id, status, detail, tested?, latencyMs?}], fix?{text, command?}, warnings}], online: {state: skipped|running|done, testedMs?, nextRefreshAllowedMs?}, version, generatedMs}`。能力依次为 `daemon`、`wecom`、`read`、`send`、`media`（必需）与 `contactAdd`、`autoAccept`、`vision`、`mqtt`、`oss`、`agents`、`wecomApi`（可选，未配置为 `disabled`）。`ready` = 必需项全 `ok` 且已启用的可选项 `ok`；`nextStep` 是按上述顺序第一个 `fail` 的修复指引；`command` 以 `imctl ` 开头时由调用方换成本机可执行路径。

本机检查只用守护进程已有状态（自己的授权读回、watcher 最近一次轮询、暂停原因、策略、各配置文件、MQTT 连接、Claude Code / Codex 的注册文件），不读 AX 树、不弹框，约 1 秒内返回。`online:true` 时若没有 300 秒内的实测结果，就在后台起一轮（同一时间最多一轮，总期限 40 秒）：已开启云端视觉且有密钥时用程序画的合成图走一次 B16 请求；MQTT 模式下 QoS 1 发布到 `im/{controller_id}/readiness` 并等 broker 确认；有 `oss.json` 时做 1 KB 往返；已注册时启动包内 `imctl mcp serve` 握手；有 `wecom-proxy.json` 时 `GET <baseURL>/healthz`。本次返回 `online.state: running`，调用方隔一秒再调，直到 `done`。`refresh:true` 忽略上次结果，但距上一轮开始不足 60 秒时仍返回上次结果（不分调用方）。检查项只含状态、计数、错误类别与耗时，不含密钥、号码、会话名、broker 地址、桶名或 corpId。命令行 `imctl doctor`、控制台状态页「体检」都调它。
```

3. `:332` 段落里「诊断 = `controller.diagnose`，」之后加「体检 = `controller.readiness`，」。
4. §12 变更表末行之后加一行：

```markdown
| 2026-10-11 | B52：新增查询 `controller.readiness`（逐项就绪、修复指引、后台联网实测；不建命令记录、不发事件）；MCP `tools/list` 44 → 45；MQTT 探测主题 `im/{controller_id}/readiness` 只由控制器发布 |
```

`docs/protocol/agents-mcp.md`：`:17` 之后加一条「- `controller.readiness`：逐项就绪与修复命令（查询，不建命令记录）；联网实测在守护进程后台跑，`online.state` 为 `running` 时隔一秒再调。」；`:64` 的「应回 44 个工具」改为「应回 45 个工具」。

`docs/agents/skills/imctl/SKILL.md`：`:14` 的第 1 步末尾加「；功能不可用或刚换机时先调 `controller.readiness`，按 `nextStep` 处理」；`:55` 那一行的方法清单加上 `` `controller.readiness` ``（说明改为 "Daemon-side diagnostics, grants and readiness"）。

`docs/protocol/java-consumer.md:21` 的方法清单在 `controller.describe`（…）之后加「`controller.readiness`（查询：逐项就绪，联网实测在后台）」。

- [ ] **Step 5: 运行测试，确认通过**

Run: `swift test --filter "DispatcherReadinessTests|DispatcherTests|MCPProxyTests|ProtocolDocTests"`
Expected: 全部通过（`ProtocolDocTests` 能在文档里找到 `` `controller.readiness` ``）。

- [ ] **Step 6: 提交**

```bash
git add Sources/MCPTransport/RPCDispatcher.swift Tests/MCPTransportTests docs/protocol docs/agents/skills/imctl/SKILL.md
git commit -m "feat(protocol): controller.readiness as a dispatcher query and MCP tool" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: watcher 最近一次轮询的快照（imctld）

**Files:**
- Create: `Sources/imctld/WatchHealth.swift`
- Modify: `Sources/imctld/DaemonWatcher.swift`（init `:48-59`、`poll` `:110-131` 与 `:132-161`、`setClientAvailable` `:261-264`）
- Modify: `Package.swift:61`（`imctldTests` 依赖加 `"ControlCore"`、`"MQTTTransport"`、`"OSSClient"`、`"WeComAPI"`、`"MCPTransport"`）
- Test: `Tests/imctldTests/WatchHealthTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessFacts.Watch`。
- Produces: `final class WatchHealth`（`struct Snapshot`、`var snapshot`、`func update(_:)`、`func facts(nowMs:) -> ReadinessFacts.Watch`）；`DaemonWatcher.init(…, health: WatchHealth = WatchHealth())` 与 `let health: WatchHealth`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/imctldTests/WatchHealthTests.swift
import ControlCore
import Testing
@testable import imctld

@Suite("Watcher health snapshot")
struct WatchHealthTests {
    @Test func neverPolledHasNoAge() {
        let facts = WatchHealth().facts(nowMs: 5_000)
        #expect(facts.lastPollAgeMs == nil && !facts.lastPollOK && facts.clientAvailable == nil && !facts.railRead)
    }

    @Test func updatesAreReadBackAsFacts() {
        let health = WatchHealth()
        health.update {
            $0.lastPollMs = 4_000; $0.lastPollOK = true; $0.clientAvailable = true
            $0.conversationCount = 7; $0.railRead = true; $0.railProblem = "通讯录 pair at rail slot 1, expected 9"
        }
        #expect(health.facts(nowMs: 5_500) == ReadinessFacts.Watch(lastPollAgeMs: 1_500, lastPollOK: true, clientAvailable: true,
                                                                   conversationCount: 7, railRead: true,
                                                                   railProblem: "通讯录 pair at rail slot 1, expected 9"))
        #expect(health.facts(nowMs: 3_000).lastPollAgeMs == 0)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter WatchHealthTests`
Expected: 编译失败，`cannot find 'WatchHealth' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/imctld/WatchHealth.swift
import ControlCore
import Foundation

/// The watcher's latest poll, readable from any thread (B52 readiness). The watcher writes it on the main run
/// loop; `controller.readiness` reads it on the socket or MQTT queue. States and counts only — never titles.
final class WatchHealth: @unchecked Sendable {
    struct Snapshot: Equatable {
        /// When the last poll attempt ended (success or failure); 0 = none yet.
        var lastPollMs: Int64 = 0
        var lastPollOK = false
        var clientAvailable: Bool?
        var conversationCount = 0
        var railRead = false
        var railProblem: String?
    }

    private let lock = NSLock()
    private var value = Snapshot()

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.lock(); body(&value); lock.unlock()
    }

    func facts(nowMs: Int64) -> ReadinessFacts.Watch {
        let s = snapshot
        return ReadinessFacts.Watch(lastPollAgeMs: s.lastPollMs > 0 ? max(0, nowMs - s.lastPollMs) : nil, lastPollOK: s.lastPollOK,
                                    clientAvailable: s.clientAvailable, conversationCount: s.conversationCount,
                                    railRead: s.railRead, railProblem: s.railProblem)
    }
}
```

`DaemonWatcher.swift` 的改动：

1. 属性区（`var mediaIndex: MediaIndex?` 之后）加 `/// B52: the latest poll for controller.readiness.` 与 `let health: WatchHealth`。
2. init 签名末尾加参数 `health: WatchHealth = WatchHealth()`，函数体第一行加 `self.health = health`。
3. `poll` 的 `catch` 分支里，`switch verdict { … }` 之后、`return` 之前加：

```swift
            health.update { $0.lastPollMs = Clock.nowMs(); $0.lastPollOK = false }
```

4. 成功路径里 `automation?.noteBadge(…)` 之后加：

```swift
        let conversations = engine.conversationCount
        health.update {
            $0.lastPollMs = Clock.nowMs(); $0.lastPollOK = true; $0.conversationCount = conversations
            $0.railRead = true; $0.railProblem = railProblem
        }
```

5. `setClientAvailable` 里 `clientAvailable = available` 之后加 `health.update { $0.clientAvailable = available }`。

`Package.swift:61` 改为：

```swift
        .testTarget(name: "imctldTests", dependencies: ["imctld", "AXKit", "WeComAdapter", "ControlCore", "MCPTransport", "MQTTTransport", "OSSClient", "WeComAPI"]),
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "WatchHealthTests|DaemonWatcherAvailabilityTests"`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/imctld/WatchHealth.swift Sources/imctld/DaemonWatcher.swift Package.swift Tests/imctldTests/WatchHealthTests.swift
git commit -m "feat(imctld): thread-safe snapshot of the watcher's latest poll for readiness" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 智能体注册检查与 MCP 握手（MCPTransport）

**Files:**
- Create: `Sources/MCPTransport/AgentRegistration.swift`
- Create: `Sources/MCPTransport/MCPHandshakeProbe.swift`
- Modify: `Sources/imctl/Host/AgentIntegration.swift`（`serverName`、`skillRelativePath`、`skillTargets`、`codexConfig` 改为转调 `AgentPaths`）
- Test: `Tests/MCPTransportTests/AgentRegistrationTests.swift`、`Tests/MCPTransportTests/MCPHandshakeProbeTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessFacts.Agents`、`ReadinessProbeResult`；Task 4 `RPCDispatcher.readinessMethod`。
- Produces: `AgentPaths.serverName`、`.skillRelativePath`、`.claudeConfig(home:)`、`.codexConfig(home:)`、`.skillTargets(home:)`；`AgentRegistrationInspector(home:cliPath:bundledSkill:).inspect() -> ReadinessFacts.Agents`；`MCPHandshakeProbe.run(executable: URL, timeout: TimeInterval = 10) -> ReadinessProbeResult`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/MCPTransportTests/AgentRegistrationTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("Agent registration inspector")
struct AgentRegistrationTests {
    func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-agents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func claudeCommandIsReadFromTheUserScopeOnly() throws {
        let json = #"{"oauthAccount":{"token":"SECRET"},"mcpServers":{"other":{"command":"/bin/x","env":{"KEY":"SECRET"}},"imctl":{"type":"stdio","command":"/Apps/imctl","args":["mcp","serve"]}}}"#
        #expect(AgentRegistrationInspector.claudeCommand(in: Data(json.utf8)) == "/Apps/imctl")
        #expect(AgentRegistrationInspector.claudeCommand(in: Data(#"{"mcpServers":{}}"#.utf8)) == nil)
        #expect(AgentRegistrationInspector.claudeCommand(in: Data("not json".utf8)) == nil)
    }

    @Test func codexCommandIsReadFromItsOwnTable() {
        let toml = """
        model = "x"
        [mcp_servers.other]
        command = "/bin/other"
        [mcp_servers.imctl]
        enabled = true
        command = "/Apps/imctl"
        args = ["mcp", "serve"]
        [profiles.y]
        command = "/bin/never"
        """
        #expect(AgentRegistrationInspector.codexCommand(in: toml) == "/Apps/imctl")
        #expect(AgentRegistrationInspector.codexCommand(in: "[mcp_servers.other]\ncommand = \"/bin/other\"\n") == nil)
    }

    @Test func skillsCompareWithTheBundledCopy() throws {
        let dir = try home()
        let bundled = dir.appendingPathComponent("bundled.md"); try Data("v2".utf8).write(to: bundled)
        let target = dir.appendingPathComponent("SKILL.md")
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: bundled) == .missing)
        try Data("v1".utf8).write(to: target)
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: bundled) == .stale)
        try Data("v2".utf8).write(to: target)
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: bundled) == .current)
        #expect(AgentRegistrationInspector.skillState(target: target, bundled: nil) == .unknown)
    }

    @Test func inspectCombinesBothSides() throws {
        let dir = try home()
        let cli = dir.appendingPathComponent("imctl")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let link = dir.appendingPathComponent("imctl-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        try Data(#"{"mcpServers":{"imctl":{"command":"\#(link.path)"}}}"#.utf8).write(to: AgentPaths.claudeConfig(home: dir))
        let bundled = dir.appendingPathComponent("bundled.md"); try Data("skill".utf8).write(to: bundled)
        let claudeSkill = AgentPaths.skillTargets(home: dir)[0].url
        try FileManager.default.createDirectory(at: claudeSkill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: claudeSkill)
        let agents = AgentRegistrationInspector(home: dir, cliPath: cli.path, bundledSkill: bundled).inspect()
        #expect(agents.claude == ReadinessFacts.Agent(registered: true, commandMatches: true, skill: .current))
        #expect(agents.codex == ReadinessFacts.Agent())
        #expect(agents.cliPresent)
    }
}
```

```swift
// Tests/MCPTransportTests/MCPHandshakeProbeTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("MCP handshake probe")
struct MCPHandshakeProbeTests {
    static let good = """
    {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"imctl","version":"x"}}}
    {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"controller.describe"},{"name":"controller.readiness"}]}}
    """

    func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-mcp-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func verifyNeedsTheServerNameAndTheReadinessTool() {
        #expect(MCPHandshakeProbe.verify(Self.good))
        #expect(!MCPHandshakeProbe.verify(Self.good.replacingOccurrences(of: "controller.readiness", with: "controller.other")))
        #expect(!MCPHandshakeProbe.verify(Self.good.replacingOccurrences(of: "\"imctl\"", with: "\"other\"")))
        #expect(!MCPHandshakeProbe.verify(""))
    }

    @Test func aWorkingServerPasses() throws {
        let url = try script("cat >/dev/null\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"imctl\"}}}' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"controller.readiness\"}]}}'")
        #expect(MCPHandshakeProbe.run(executable: url, timeout: 5).ok)
    }

    @Test func failuresAreCategorised() throws {
        #expect(MCPHandshakeProbe.run(executable: URL(fileURLWithPath: "/nonexistent/imctl"), timeout: 1).category == "launch")
        #expect(MCPHandshakeProbe.run(executable: try script("cat"), timeout: 5).category == "protocol")
        #expect(MCPHandshakeProbe.run(executable: try script("sleep 5"), timeout: 0.5).category == "timeout")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter "AgentRegistrationTests|MCPHandshakeProbeTests"`
Expected: 编译失败，`cannot find 'AgentRegistrationInspector' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/MCPTransport/AgentRegistration.swift
import ControlCore
import Foundation

/// Where Claude Code and Codex keep their MCP registration and skills (B10 paths; shared with the daemon in B52).
public enum AgentPaths {
    public static let serverName = "imctl"
    public static let skillRelativePath = "agents/skills/imctl/SKILL.md"

    /// Claude Code keeps user-scope MCP servers in `~/.claude.json` → `mcpServers`.
    public static func claudeConfig(home: URL) -> URL { home.appendingPathComponent(".claude.json") }
    public static func codexConfig(home: URL) -> URL { home.appendingPathComponent(".codex/config.toml") }
    public static func skillTargets(home: URL) -> [(agent: String, url: URL)] {
        [("claude-code", home.appendingPathComponent(".claude/skills/imctl/SKILL.md")),
         ("codex", home.appendingPathComponent(".codex/skills/imctl/SKILL.md"))]
    }
}

/// Reads — never writes — how the two agents registered `imctl` (B52 readiness). Only the `imctl` entry's
/// command path is extracted: both files hold other servers and credentials, which are never read out.
public struct AgentRegistrationInspector {
    public var home: URL
    /// The CLI the agents should launch: the bundle's `imctl`.
    public var cliPath: String
    /// The bundle's SKILL.md; nil outside an app bundle (then skills are `unknown`).
    public var bundledSkill: URL?

    public init(home: URL, cliPath: String, bundledSkill: URL?) {
        self.home = home; self.cliPath = cliPath; self.bundledSkill = bundledSkill
    }

    public func inspect() -> ReadinessFacts.Agents {
        let claude = (try? Data(contentsOf: AgentPaths.claudeConfig(home: home))).flatMap(Self.claudeCommand(in:))
        let codex = (try? String(contentsOf: AgentPaths.codexConfig(home: home), encoding: .utf8)).flatMap(Self.codexCommand(in:))
        let targets = AgentPaths.skillTargets(home: home)
        return ReadinessFacts.Agents(claude: agent(command: claude, skill: targets[0].url),
                                     codex: agent(command: codex, skill: targets[1].url),
                                     cliPresent: FileManager.default.isExecutableFile(atPath: cliPath))
    }

    func agent(command: String?, skill: URL) -> ReadinessFacts.Agent {
        guard let command else { return ReadinessFacts.Agent() }
        return ReadinessFacts.Agent(registered: true, commandMatches: Self.samePath(command, cliPath),
                                    skill: Self.skillState(target: skill, bundled: bundledSkill))
    }

    static func claudeCommand(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let entry = servers[AgentPaths.serverName] as? [String: Any] else { return nil }
        return entry["command"] as? String
    }

    /// `command = "…"` inside the `[mcp_servers.imctl]` table (the form `imctl mcp install --codex` writes).
    static func codexCommand(in text: String) -> String? {
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inTable = line == "[mcp_servers.\(AgentPaths.serverName)]"; continue }
            guard inTable, line.hasPrefix("command") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func skillState(target: URL, bundled: URL?) -> ReadinessFacts.SkillState {
        guard let installed = try? Data(contentsOf: target) else { return .missing }
        guard let bundled, let reference = try? Data(contentsOf: bundled) else { return .unknown }
        return installed == reference ? .current : .stale
    }
}
```

```swift
// Sources/MCPTransport/MCPHandshakeProbe.swift
import ControlCore
import Foundation

/// Starts `<cli> mcp serve` and runs the MCP handshake (B52 readiness). Only `initialize` and `tools/list` are
/// sent: the proxy answers both itself, so the probe never calls back into the daemon socket that is serving
/// the readiness request. Passes when the server names itself `imctl` and lists `controller.readiness`.
public enum MCPHandshakeProbe {
    static let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"imctl-readiness","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
    ]

    public static func run(executable: URL, timeout: TimeInterval = 10) -> ReadinessProbeResult {
        let started = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp", "serve"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            return .failure("launch", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failure("timeout", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
        process.waitUntilExit()
        let latency = ReadinessProbeResult.elapsedMs(since: started)
        return verify(String(decoding: box.data, as: UTF8.self)) ? .success(latencyMs: latency) : .failure("protocol", latencyMs: latency)
    }

    /// The two answers in order: `initialize` names the server `imctl`; `tools/list` contains `controller.readiness`.
    static func verify(_ output: String) -> Bool {
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count >= 2,
              let hello = try? JSONValue.parse(lines[0]),
              hello.objectValue?["result"]?.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue == AgentPaths.serverName,
              let list = try? JSONValue.parse(lines[1]),
              let tools = list.objectValue?["result"]?.objectValue?["tools"]?.arrayValue else { return false }
        return tools.contains { $0.objectValue?["name"]?.stringValue == RPCDispatcher.readinessMethod }
    }
}
```

`Sources/imctl/Host/AgentIntegration.swift`：文件头加 `import MCPTransport`；把四处定义改为转调（签名与默认参数不变，现有 `MCPCommandTests` 不用改）：

```swift
    static let serverName = AgentPaths.serverName
    static let skillRelativePath = AgentPaths.skillRelativePath
    static func skillTargets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [(agent: String, url: URL)] {
        AgentPaths.skillTargets(home: home)
    }
    static func codexConfig(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AgentPaths.codexConfig(home: home)
    }
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "AgentRegistrationTests|MCPHandshakeProbeTests|MCPCommandTests"`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/MCPTransport/AgentRegistration.swift Sources/MCPTransport/MCPHandshakeProbe.swift Sources/imctl/Host/AgentIntegration.swift Tests/MCPTransportTests/AgentRegistrationTests.swift Tests/MCPTransportTests/MCPHandshakeProbeTests.swift
git commit -m "feat(mcp): read-only agent registration check and bounded MCP handshake probe" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: MQTT 探测发布（MQTTTransport）

**Files:**
- Create: `Sources/MQTTTransport/ProbeWait.swift`
- Modify: `Sources/MQTTTransport/MQTTSettings.swift`（topic 计算属性 `:22-28` 之后）
- Modify: `Sources/MQTTTransport/MQTTNIOLink.swift`（`publish(_:)` 之后）
- Modify: `Package.swift:63`（`MQTTTransportTests` 依赖加 `.product(name: "MQTTNIO", package: "mqtt-nio")`）
- Test: `Tests/MQTTTransportTests/MQTTReadinessProbeTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessProbeResult`。
- Produces: `MQTTSettings.readinessTopic`；`ProbeWait.wait(timeout:_:)`（internal）；`MQTTNIOLink.probePublish(timeout: TimeInterval = 10) -> ReadinessProbeResult`；`MQTTNIOLink.probeCategory(_:) -> String`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/MQTTTransportTests/MQTTReadinessProbeTests.swift
import Foundation
import MQTTNIO
import Testing
@testable import MQTTTransport

@Suite("MQTT readiness probe")
struct MQTTReadinessProbeTests {
    struct Boom: Error {}

    @Test func theProbeTopicIsInsideTheControllersSubtree() {
        let s = MQTTSettings(host: "h", controllerID: "mac-1")
        #expect(s.readinessTopic == "im/mac-1/readiness" && s.readinessTopic.hasPrefix(s.ownTopicPrefix))
    }

    @Test func probeWaitReturnsTheCompletion() {
        let ok: Result<Int, Error>? = ProbeWait.wait(timeout: 1) { complete in DispatchQueue.global().async { complete(.success(7)) } }
        #expect((try? ok?.get()) == 7)
        let failed: Result<Int, Error>? = ProbeWait.wait(timeout: 1) { complete in complete(.failure(Boom())) }
        if case .failure? = failed {} else { Issue.record("expected a failure") }
    }

    @Test func probeWaitGivesUpAtTheTimeout() {
        let started = Date()
        let none: Result<Int, Error>? = ProbeWait.wait(timeout: 0.2) { _ in }
        #expect(none == nil && Date().timeIntervalSince(started) < 1)
    }

    @Test func publishErrorsMapToFixedCategories() {
        #expect(MQTTNIOLink.probeCategory(MQTTError.reasonError(.notAuthorized)) == "rejected")
        #expect(MQTTNIOLink.probeCategory(MQTTError.noConnection) == "notConnected")
        #expect(MQTTNIOLink.probeCategory(Boom()) == "network")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter MQTTReadinessProbeTests`
Expected: 编译失败，`value of type 'MQTTSettings' has no member 'readinessTopic'`。

- [ ] **Step 3: 写实现**

`MQTTSettings.swift` 在 `ownTopicPrefix` 之后加：

```swift
    /// B52: readiness probe messages (a nonce only). Inside `ownTopicPrefix`; no consumer subscribes to it.
    public var readinessTopic: String { "\(topicPrefix)/\(controllerID)/readiness" }
```

```swift
// Sources/MQTTTransport/ProbeWait.swift
import Foundation

private final class ProbeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.lock(); if stored == nil { stored = value }; lock.unlock() }
    var value: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A bounded wait on a callback-style completion (B52 readiness): `publish(_:)` waits for PUBACK without any
/// limit, which a readiness probe must not. nil = no completion within `timeout`.
enum ProbeWait {
    static func wait<T>(timeout: TimeInterval, _ register: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error>? {
        let box = ProbeBox<T>()
        let done = DispatchSemaphore(value: 0)
        register { result in box.set(result); done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}
```

`MQTTNIOLink.swift` 在 `publish(_:)` 之后加：

```swift
    /// B52 readiness: one QoS 1 publish of a random nonce to `readinessTopic`, waiting at most `timeout` for
    /// the broker's PUBACK. Categories only: notConnected, rejected (a reason code ≥ 0x80, e.g. ACL), timeout, network.
    public func probePublish(timeout: TimeInterval = 10) -> ReadinessProbeResult {
        let started = Date()
        guard isConnected else { return .failure("notConnected", latencyMs: 0) }
        let payload = ByteBuffer(data: Data(#"{"nonce":"\#(UUID().uuidString)"}"#.utf8))
        let future = client.v5.publish(to: settings.readinessTopic, payload: payload, qos: .atLeastOnce, retain: false)
        let outcome: Result<MQTTAckV5?, Error>? = ProbeWait.wait(timeout: timeout) { complete in future.whenComplete(complete) }
        let latency = ReadinessProbeResult.elapsedMs(since: started)
        switch outcome {
        case nil: return .failure("timeout", latencyMs: latency)
        case .success?: return .success(latencyMs: latency)
        case .failure(let error)?: return .failure(Self.probeCategory(error), latencyMs: latency)
        }
    }

    static func probeCategory(_ error: Error) -> String {
        guard let mqtt = error as? MQTTError else { return "network" }
        switch mqtt {
        case .reasonError: return "rejected"
        case .noConnection: return "notConnected"
        default: return "network"
        }
    }
```

`Package.swift:63` 改为：

```swift
        .testTarget(name: "MQTTTransportTests", dependencies: ["MQTTTransport", .product(name: "MQTTNIO", package: "mqtt-nio")]),
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "MQTTReadinessProbeTests|MQTTBindingTests"`
Expected: 全部通过（`MQTTReasonCode.notAuthorized` 即 0x87，见 mqtt-nio `MQTTReason.swift`）。

- [ ] **Step 5: 提交**

```bash
git add Sources/MQTTTransport Package.swift Tests/MQTTTransportTests/MQTTReadinessProbeTests.swift
git commit -m "feat(mqtt): bounded QoS 1 readiness publish to im/<id>/readiness" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: OSS 往返（OSSClient，CLI 与体检共用）

**Files:**
- Create: `Sources/OSSClient/OSSRoundTrip.swift`
- Modify: `Sources/imctl/Commands/OSSCommand.swift:83-113`（`OSSTestCommand.run` 改为调用 `OSSRoundTrip.run`）
- Test: `Tests/OSSClientTests/OSSRoundTripTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessProbeResult`；现有 `OSSObjectStore`、`OSSSettings`、`URLSessionOSSTransport`、`ScriptedTransport`（测试）。
- Produces: `OSSRoundTrip.run(store:keyPrefix:step:) throws`、`OSSRoundTrip.probe(settingsURL:resourceTimeout:transport:) -> ReadinessProbeResult`、`OSSRoundTrip.category(of:) -> String`、`OSSRoundTrip.Failure`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/OSSClientTests/OSSRoundTripTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import OSSClient

@Suite("OSS round trip")
struct OSSRoundTripTests {
    static let payload = Data(repeating: 0x61, count: 1024)

    func settingsFile(bucket: String = "secret-bucket-b52") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("oss.json")
        try OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: bucket, baseDir: "imctl",
                        accessKeyId: "LTAIB52SECRETID", accessKeySecret: "B52-SECRET-VALUE").save(to: url)
        return url
    }

    /// PUT, HEAD, presigned GET (body), download HEAD (Content-Length) + GET (file), DELETE.
    func happyTransport() -> ScriptedTransport {
        let t = ScriptedTransport()
        t.downloadBody = Self.payload
        t.responses = [
            OSSResponse(status: 200, headers: [:], body: Data()),
            OSSResponse(status: 200, headers: [:], body: Data()),
            OSSResponse(status: 200, headers: [:], body: Self.payload),
            OSSResponse(status: 200, headers: ["Content-Length": "1024"], body: Data()),
            OSSResponse(status: 200, headers: [:], body: Data()),
            OSSResponse(status: 204, headers: [:], body: Data()),
        ]
        return t
    }

    @Test func aFullRoundTripPassesAndDeletesUnderTheReadinessPrefix() throws {
        let transport = happyTransport()
        let result = OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: transport)
        #expect(result.ok)
        #expect(transport.sent.first?.request.url?.path.contains("/imctl/imctl-readiness/") == true)
        #expect(transport.sent.last?.request.httpMethod == "DELETE")
    }

    @Test func aMissingFileIsAConfigProblem() {
        #expect(OSSRoundTrip.probe(settingsURL: URL(fileURLWithPath: "/nonexistent/oss.json")).category == "config")
    }

    @Test func forbiddenIsAuthAndStillCleansUp() throws {
        let t = happyTransport()
        t.responses = [OSSResponse(status: 200, headers: [:], body: Data()),
                       OSSResponse(status: 403, headers: [:], body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)),
                       OSSResponse(status: 204, headers: [:], body: Data())]
        let result = OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t)
        #expect(result.category == "auth")
        #expect(t.sent.last?.request.httpMethod == "DELETE")
    }

    @Test func aDifferentBodyIsAMismatch() throws {
        let t = happyTransport()
        t.responses[2] = OSSResponse(status: 200, headers: [:], body: Data("x".utf8))
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).category == "mismatch")
    }

    @Test func aTransportTimeoutIsTimeout() throws {
        let t = happyTransport()
        t.failure = URLError(.timedOut)
        #expect(OSSRoundTrip.probe(settingsURL: try settingsFile(), transport: t).category == "timeout")
    }

    @Test func categoryNeverCarriesTheMessage() throws {
        let message = "PUT imctl/imctl-readiness/x.txt on secret-bucket-b52.oss-cn-hangzhou.aliyuncs.com: HTTP 500 InternalError LTAIB52SECRETID"
        let category = OSSRoundTrip.category(of: ControlError.objectStore(message))
        #expect(category == "http5xx")
        let encoded = String(decoding: try JSONEncoder().encode(ReadinessProbeResult.failure(category, latencyMs: 1)), as: UTF8.self)
        for secret in ["secret-bucket-b52", "LTAIB52SECRETID", "imctl-readiness/x"] { #expect(!encoded.contains(secret)) }
        #expect(OSSRoundTrip.category(of: ControlError.objectStore("PUT k: timed out after 15 s")) == "timeout")
        #expect(OSSRoundTrip.category(of: ControlError.objectStore("PUT k: HTTP 404 NoSuchBucket")) == "http4xx")
        #expect(OSSRoundTrip.category(of: ControlError.objectStore("PUT k: The Internet connection appears to be offline.")) == "network")
    }
}
```

（应答顺序对应实际请求：`put` 一次 PUT；`exists` 一次 HEAD；`fetchPresigned` 一次 GET；`download` 先 HEAD 读 `Content-Length` 再 GET 写文件（`ScriptedTransport` 只在带目的地时写 `downloadBody`）；最后 DELETE。）

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter OSSRoundTripTests`
Expected: 编译失败，`cannot find 'OSSRoundTrip' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/OSSClient/OSSRoundTrip.swift
import ControlCore
import Foundation

/// The 1 KB round trip behind `imctl oss test` and the B52 readiness probe: PUT → HEAD → presigned GET →
/// download (HEAD + GET) → DELETE. A failure part-way still deletes the probe object once.
public enum OSSRoundTrip {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missingAfterPut, mismatch, cleanup
        public var description: String {
            switch self {
            case .missingAfterPut: "HEAD after PUT says the object is missing"
            case .mismatch: "presigned GET or download returned different bytes"
            case .cleanup: "the probe object could not be deleted"
            }
        }
    }

    public static func run(store: OSSObjectStore, keyPrefix: String, step: (String) -> Void = { _ in }) throws {
        let key = "\(store.baseDir)/\(keyPrefix)/\(UUID().uuidString.lowercased()).txt"
        let payload = Data(repeating: 0x61, count: 1024)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-probe-\(UUID().uuidString).txt")
        try payload.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        step("1/5 PUT \(key)")
        try store.put(fileURL: temp, key: key, contentType: "text/plain")
        var deleted = false
        defer {
            if !deleted {
                do { try store.delete(key: key); step("cleanup: deleted probe") }
                catch let error as ControlError { step("cleanup failed: \(error.code)") }
                catch { step("cleanup failed: \(error)") }
            }
        }
        step("2/5 HEAD")
        guard try store.exists(key: key) else { throw Failure.missingAfterPut }
        step("3/5 presigned GET")
        let fetched = try store.fetchPresigned(try store.signedGetURL(key: key, expiresIn: 60), what: "presigned GET \(key)")
        guard fetched.status == 200, fetched.body == payload else { throw Failure.mismatch }
        step("4/5 download via HEAD + GET")
        let back = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-probe-back-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: back) }
        guard try store.download(key: key, to: back, maxBytes: 4096) == 1024, (try? Data(contentsOf: back)) == payload else { throw Failure.mismatch }
        step("5/5 DELETE")
        deleted = true
        do { try store.delete(key: key) } catch { throw Failure.cleanup }
    }

    /// B52: the round trip as a readiness result; never throws, never returns remote text.
    public static func probe(settingsURL: URL, resourceTimeout: TimeInterval = 15, transport: OSSTransport? = nil) -> ReadinessProbeResult {
        let started = Date()
        guard let settings = try? OSSSettings.load(from: settingsURL) else { return .failure("config", latencyMs: 0) }
        let live: OSSTransport = transport ?? {
            let t = URLSessionOSSTransport()
            t.resourceTimeout = resourceTimeout
            return t
        }()
        do {
            try run(store: OSSObjectStore(settings: settings, transport: live), keyPrefix: "imctl-readiness")
            return .success(latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        } catch {
            return .failure(category(of: error), latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
    }

    /// A fixed category; the message (key, bucket, host) never leaves this function.
    static func category(of error: Error) -> String {
        if let failure = error as? Failure { return failure == .cleanup ? "cleanup" : "mismatch" }
        guard let control = error as? ControlError else { return "network" }
        let message = control.message
        if message.contains("timed out") { return "timeout" }
        if let range = message.range(of: #"HTTP \d{3}"#, options: .regularExpression), let code = Int(message[range].suffix(3)) {
            if code == 401 || code == 403 { return "auth" }
            if (400..<500).contains(code) { return "http4xx" }
            if (500..<600).contains(code) { return "http5xx" }
        }
        return "network"
    }
}
```

`OSSCommand.swift` 的 `OSSTestCommand.run()` 整体替换为：

```swift
    func run() throws {
        let settings = try OSSSettings.load(from: URL(fileURLWithPath: config))
        try OSSRoundTrip.run(store: OSSObjectStore(settings: settings), keyPrefix: "_probe") { print($0) }
        print("ok: \(settings.summary)")
    }
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "OSSRoundTripTests|OSSObjectStoreTests|OSSTransportTests"`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/OSSClient/OSSRoundTrip.swift Sources/imctl/Commands/OSSCommand.swift Tests/OSSClientTests/OSSRoundTripTests.swift
git commit -m "refactor(oss): one round trip for imctl oss test and the readiness probe" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: 代理健康检查（WeComAPI）

**Files:**
- Create: `Sources/WeComAPI/WeComProxyHealth.swift`
- Test: `Tests/WeComAPITests/WeComProxyHealthTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessProbeResult`；`WeComProxySettings.normalizedBaseURL`。测试用本文件自己的 `HealthStub`（不用共享的 `FakeProxyProtocol`：它的静态状态会被并行的其他测试套件改动）。
- Produces: `WeComProxyHealth.probe(settingsURL:timeout:session:) -> ReadinessProbeResult`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/WeComAPITests/WeComProxyHealthTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import WeComAPI

/// Answers every request from static fields; private to this suite, which runs serialized.
final class HealthStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = "{}"
    nonisolated(unsafe) static var seenPath: String?
    nonisolated(unsafe) static var seenAuthorization: String?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealthStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seenPath = request.url?.path
        Self.seenAuthorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("WeCom proxy health probe", .serialized)
struct WeComProxyHealthTests {
    func settingsFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("wecom-proxy.json")
        try WeComProxySettings(baseURL: "https://proxy.example.invalid/", token: "B52-SECRET-TOKEN", corpId: "wwB52SECRETCORP").save(to: url)
        return url
    }

    @Test func okNeedsHTTP200AndStatusOK() throws {
        HealthStub.status = 200
        HealthStub.body = #"{"status":"ok","tokenCached":false,"corpId":"wwB52SECRETCORP"}"#
        let result = WeComProxyHealth.probe(settingsURL: try settingsFile(), session: HealthStub.session())
        #expect(result.ok)
        #expect(HealthStub.seenPath == "/healthz" && HealthStub.seenAuthorization == nil)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!encoded.contains("wwB52SECRETCORP") && !encoded.contains("B52-SECRET-TOKEN"))
    }

    @Test func failuresAreCategorised() throws {
        HealthStub.status = 503; HealthStub.body = "down"
        #expect(WeComProxyHealth.probe(settingsURL: try settingsFile(), session: HealthStub.session()).category == "http5xx")
        HealthStub.status = 200; HealthStub.body = "{}"
        #expect(WeComProxyHealth.probe(settingsURL: try settingsFile(), session: HealthStub.session()).category == "response")
        #expect(WeComProxyHealth.probe(settingsURL: URL(fileURLWithPath: "/nonexistent/wecom-proxy.json")).category == "config")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter WeComProxyHealthTests`
Expected: 编译失败，`cannot find 'WeComProxyHealth' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/WeComAPI/WeComProxyHealth.swift
import ControlCore
import Foundation

/// B52 readiness: `GET <baseURL>/healthz` of the token proxy. No token is sent (the endpoint is outside
/// `/wecom/`), the answer's corpId is never read out, and a redirect counts as a failure.
public enum WeComProxyHealth {
    public static func probe(settingsURL: URL, timeout: TimeInterval = 10, session: URLSession? = nil) -> ReadinessProbeResult {
        let started = Date()
        guard let settings = try? WeComProxySettings.load(from: settingsURL) else { return .failure("config", latencyMs: 0) }
        let url = settings.normalizedBaseURL.appendingPathComponent("healthz")
        guard url.scheme == "https" || url.scheme == "http" else { return .failure("config", latencyMs: 0) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        let live = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            return URLSession(configuration: configuration)
        }()
        final class Box: @unchecked Sendable { var data: Data?; var response: URLResponse?; var error: Error? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let task = live.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error
            done.signal()
        }
        task.resume()
        guard done.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            return .failure("timeout", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
        let latency = ReadinessProbeResult.elapsedMs(since: started)
        if let error = box.error { return .failure((error as? URLError)?.code == .timedOut ? "timeout" : "network", latencyMs: latency) }
        guard let http = box.response as? HTTPURLResponse else { return .failure("response", latencyMs: latency) }
        guard http.url == url else { return .failure("redirect", latencyMs: latency) }
        guard http.statusCode == 200 else { return .failure(http.statusCode >= 500 ? "http5xx" : "http4xx", latencyMs: latency) }
        guard let data = box.data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["status"] as? String == "ok" else { return .failure("response", latencyMs: latency) }
        return .success(latencyMs: latency)
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter WeComProxyHealthTests`
Expected: 2 项通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/WeComAPI/WeComProxyHealth.swift Tests/WeComAPITests/WeComProxyHealthTests.swift
git commit -m "feat(wecom-api): token-free proxy health probe for readiness" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: 视觉实测（WeComAdapter）

**Files:**
- Create: `Sources/WeComAdapter/ReadinessVisionProbe.swift`
- Test: `Tests/WeComAdapterTests/ReadinessVisionProbeTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessProbeResult`；`CloudVisionClient`、`CloudVisionSettings`、`CloudVisionCandidate`、`CloudVisionError`、`AIPlannerDiagnostics.snapshot()`。
- Produces: `ReadinessVisionProbe.syntheticJPEG() -> Data?`、`ReadinessVisionProbe.probe(settings:client:) -> ReadinessProbeResult`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/WeComAdapterTests/ReadinessVisionProbeTests.swift
import Foundation
import ImageIO
import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("Readiness vision probe")
struct ReadinessVisionProbeTests {
    static func settings() throws -> CloudVisionSettings {
        var s = CloudVisionSettings()
        try s.setAPIKey("sk-B52-SECRET", for: .qwen)
        try s.enable()
        return s
    }

    static func reply(_ request: URLRequest, status: Int = 200, body: String) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    @Test func theSyntheticPictureIsASmallStableJPEG() throws {
        let a = try #require(ReadinessVisionProbe.syntheticJPEG())
        #expect(a == ReadinessVisionProbe.syntheticJPEG())
        let source = try #require(CGImageSourceCreateWithData(a as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 320 && props[kCGImagePropertyPixelHeight] as? Int == 120)
    }

    @Test func anAnswerPassesWithoutTouchingTheCommandCounters() throws {
        let before = AIPlannerDiagnostics.snapshot()
        var calls = 0
        let client = CloudVisionClient { request in
            calls += 1
            #expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
            return try Self.reply(request, body: #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"candidate_id\":null}"}}]}"#)
        }
        #expect(ReadinessVisionProbe.probe(settings: try Self.settings(), client: client).ok)
        #expect(calls == 1)
        let after = AIPlannerDiagnostics.snapshot()
        #expect(after.requestCount == before.requestCount && after.captureCount == before.captureCount && after.successCount == before.successCount)
    }

    @Test func failuresAreCategorised() throws {
        let rejected = CloudVisionClient { request in try Self.reply(request, status: 401, body: "{}") }
        #expect(ReadinessVisionProbe.probe(settings: try Self.settings(), client: rejected).category == "http")
        let garbled = CloudVisionClient { request in try Self.reply(request, body: "not json") }
        #expect(ReadinessVisionProbe.probe(settings: try Self.settings(), client: garbled).category == "response")
    }

    @Test func noKeyMeansNoRequest() {
        var calls = 0
        let client = CloudVisionClient { request in calls += 1; return try Self.reply(request, body: "{}") }
        #expect(ReadinessVisionProbe.probe(settings: CloudVisionSettings(), client: client).category == "config")
        #expect(calls == 0)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter ReadinessVisionProbeTests`
Expected: 编译失败，`cannot find 'ReadinessVisionProbe' in scope`。

- [ ] **Step 3: 写实现**（注意：本文件任何地方都不得出现截屏相关标记）

```swift
// Sources/WeComAdapter/ReadinessVisionProbe.swift
import ControlCore
import CoreGraphics
import Foundation
import ImageIO

/// B52 readiness (user decision 2026-10-10): one B16 request with a picture drawn here — two grey squares
/// on white, no text, nothing from the screen or the client — to prove the configured provider, model and
/// key answer. Uses `CloudVisionClient` unchanged (fixed prompt, fixed endpoint, no redirects, 8 s), which
/// does not touch the explicit-command vision counters. The model's answer is discarded; only a category returns.
public enum ReadinessVisionProbe {
    static let width = 320
    static let height = 120
    static let candidates = [
        CloudVisionCandidate(id: "A", normalizedRect: CGRect(x: 0.1, y: 0.25, width: 0.3, height: 0.5)),
        CloudVisionCandidate(id: "B", normalizedRect: CGRect(x: 0.6, y: 0.25, width: 0.3, height: 0.5)),
    ]

    public static func syntheticJPEG() -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1))
        for candidate in candidates {
            let r = candidate.normalizedRect
            // normalizedRect has a top-left origin; the bitmap context a bottom-left one.
            context.fill(CGRect(x: r.minX * CGFloat(width), y: (1 - r.maxY) * CGFloat(height),
                                width: r.width * CGFloat(width), height: r.height * CGFloat(height)))
        }
        guard let image = context.makeImage(), let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    public static func probe(settings: CloudVisionSettings, client: CloudVisionClient = CloudVisionClient()) -> ReadinessProbeResult {
        let started = Date()
        guard let key = settings.apiKey(for: settings.provider) else { return .failure("config", latencyMs: 0) }
        guard let image = syntheticJPEG() else { return .failure("internal", latencyMs: 0) }
        do {
            _ = try client.selectCandidate(imageJPEG: image, candidates: candidates, target: .addMembersButton,
                                           provider: settings.provider, model: settings.model, apiKey: key)
            return .success(latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        } catch let error as CloudVisionError {
            let latency = ReadinessProbeResult.elapsedMs(since: started)
            switch error {
            case .invalidChoice: return .success(latencyMs: latency)   // the model answered; it only named no listed square
            case .timeout: return .failure("timeout", latencyMs: latency)
            case .requestFailed: return .failure("network", latencyMs: latency)
            case .invalidHTTPStatus: return .failure("http", latencyMs: latency)
            case .responseTooLarge, .invalidResponse: return .failure("response", latencyMs: latency)
            case .missingAPIKey, .unsupportedModel: return .failure("config", latencyMs: latency)
            default: return .failure("internal", latencyMs: latency)
            }
        } catch {
            return .failure("network", latencyMs: ReadinessProbeResult.elapsedMs(since: started))
        }
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "ReadinessVisionProbeTests|CloudVisionClientTests|ForbiddenAPITests"`
Expected: 全部通过（`ForbiddenAPITests` 不因新文件变红；客户端对解析不了的应答抛 `invalidResponse`，对不在候选里的 ID 抛 `invalidChoice`）。

- [ ] **Step 5: 提交**

```bash
git add Sources/WeComAdapter/ReadinessVisionProbe.swift Tests/WeComAdapterTests/ReadinessVisionProbeTests.swift
git commit -m "feat(vision): readiness call with a drawn synthetic picture through the B16 client" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: 守护进程装配 `DaemonReadiness`（imctld）

**Files:**
- Create: `Sources/imctld/DaemonReadiness.swift`
- Modify: `Sources/imctld/main.swift`（`:145` `let daemon = DaemonRuntime(log: log)` 之后装配；`:163-170` MQTT 块里补 MQTT 探测；`:172-174` watcher 构造传 `health:`）
- Test: `Tests/imctldTests/DaemonReadinessTests.swift`

**Interfaces:**
- Consumes: Task 1–3、5–10 的全部产出。
- Produces: `final class DaemonReadiness: ReadinessProviding`（`struct Sources`、`struct Probes`、`var probes`、`var runner`、`func facts(nowMs:)`、`static func selected(_:facts:)`、`static func policyFacts(_:readable:)`、`static func visionFacts(url:)`、`static func mqttFacts(url:link:)`、`static func configFacts(url:load:)`、`static func clientVersion(bundleID:)`）。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/imctldTests/DaemonReadinessTests.swift
import ControlCore
import Foundation
import MQTTTransport
import OSSClient
import Testing
import WeComAPI
import WeComAdapter
@testable import imctld

@Suite("Daemon readiness", .serialized)
struct DaemonReadinessTests {
    static func sources(vision: ReadinessFacts.Vision = .init()) -> DaemonReadiness.Sources {
        DaemonReadiness.Sources(
            permissions: { ["accessibility": "trusted", "screenRecording": "granted", "wecomData": "granted",
                            "fullDiskAccess": "yes", "clientRunning": "true", "launchAgent": "true"] },
            watch: { _ in .init(lastPollAgeMs: 500, lastPollOK: true, clientAvailable: true, conversationCount: 3, railRead: true) },
            pauseReasons: { [] }, policy: { .init() }, clientVersion: { "5.0.11" }, vision: { vision },
            mqtt: { .init() }, oss: { .init() }, wecomApi: { .init() }, agents: { .init() })
    }

    static let visionOn = ReadinessFacts.Vision(config: .init(present: true, valid: true), cloudEnabled: true, keyPresent: true,
                                                provider: "qwen", model: "qwen3.7-plus")

    func waitUntilDone(_ readiness: DaemonReadiness) -> ReadinessReport? {
        for _ in 0..<40 {
            let r = readiness.readiness(online: true, refresh: false)
            if r.online.state == "done" { return r }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    @Test func offlineNeverRunsAProbe() {
        var calls = 0
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { calls += 1; return .success(latencyMs: 1) }))
        let report = readiness.readiness(online: false, refresh: false)
        #expect(report.online.state == "skipped" && report.ready && calls == 0)
    }

    @Test func answersImmediatelyWhileTheLiveTestsRun() throws {
        let gate = DispatchSemaphore(value: 0)
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { gate.wait(); return .success(latencyMs: 7) }))
        let started = Date()
        let first = readiness.readiness(online: true, refresh: false)
        #expect(first.online.state == "running" && Date().timeIntervalSince(started) < 0.5)
        gate.signal()
        let done = try #require(waitUntilDone(readiness))
        #expect(done.capabilities.first { $0.id == "vision" }?.checks.last?.tested == true)
    }

    @Test func concurrentCallersStartOneRound() throws {
        let lock = NSLock()
        var calls = 0
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { lock.lock(); calls += 1; lock.unlock(); Thread.sleep(forTimeInterval: 0.2); return .success(latencyMs: 200) }))
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = readiness.readiness(online: true, refresh: true) }
        _ = try #require(waitUntilDone(readiness))
        #expect(calls == 1)
    }

    @Test func aStuckProbeEndsTheRoundAtTheDeadline() throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let readiness = DaemonReadiness(sources: Self.sources(vision: Self.visionOn),
                                        probes: .init(vision: { gate.wait(); return .success(latencyMs: 1) }))
        readiness.runner = { ReadinessProbeRunner.run($0, deadline: 0.2) }
        let done = try #require(waitUntilDone(readiness))
        let vision = try #require(done.capabilities.first { $0.id == "vision" })
        #expect(vision.status == .fail && vision.checks.last?.detail.contains("超时") == true)
    }

    @Test func onlyConfiguredModulesAreProbed() {
        let probes = DaemonReadiness.Probes(vision: { .success(latencyMs: 1) }, mqtt: { .success(latencyMs: 1) },
                                            oss: { .success(latencyMs: 1) }, agents: { .success(latencyMs: 1) },
                                            wecomApi: { .success(latencyMs: 1) })
        var f = ReadinessFacts(version: "v")
        #expect(DaemonReadiness.selected(probes, facts: f).isEmpty)
        f.vision = Self.visionOn
        f.mqtt = .init(config: .init(present: true, valid: true), daemonMode: true, connected: true)
        f.oss = .init(present: true, valid: true)
        f.agents = .init(claude: .init(registered: true, commandMatches: true, skill: .current), cliPresent: true)
        f.wecomApi = .init(present: true, valid: true)
        #expect(Set(DaemonReadiness.selected(probes, facts: f).keys) == Set(ReadinessProbeKind.allCases))
        f.mqtt.connected = false
        #expect(DaemonReadiness.selected(probes, facts: f)[.mqtt] == nil)
    }

    @Test func reportCarriesNoSecretsFromRealConfigFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-ready-\(UUID().uuidString)", isDirectory: true)
        let visionDir = dir.appendingPathComponent("vision", isDirectory: true)
        try FileManager.default.createDirectory(at: visionDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var vision = CloudVisionSettings()
        try vision.setAPIKey("sk-B52-SECRET-VISION", for: .qwen)
        try vision.enable()
        try vision.save(to: visionDir.appendingPathComponent("cloud-vision.json"))
        try OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "secret-bucket-b52", baseDir: "imctl",
                        accessKeyId: "LTAIB52SECRETID", accessKeySecret: "B52-OSS-SECRET").save(to: dir.appendingPathComponent("oss.json"))
        try MQTTSettings(host: "broker-b52.example.invalid", controllerID: "mac-secret-b52", username: "b52-user", password: "B52-MQTT-SECRET")
            .save(to: dir.appendingPathComponent("mqtt.json"))
        try WeComProxySettings(baseURL: "https://proxy-b52.example.invalid", token: "B52-PROXY-TOKEN", corpId: "wwB52SECRETCORP")
            .save(to: dir.appendingPathComponent("wecom-proxy.json"))
        var policy = SendPolicy()
        policy.allowedTitles = ["真实客户群B52"]
        policy.contactAdd.allowedPhones = ["13800000000"]

        var sources = Self.sources()
        sources.vision = { DaemonReadiness.visionFacts(url: visionDir.appendingPathComponent("cloud-vision.json")) }
        sources.oss = { DaemonReadiness.configFacts(url: dir.appendingPathComponent("oss.json")) { try OSSSettings.load(from: $0) } }
        sources.mqtt = { DaemonReadiness.mqttFacts(url: dir.appendingPathComponent("mqtt.json"), link: nil) }
        sources.wecomApi = { DaemonReadiness.configFacts(url: dir.appendingPathComponent("wecom-proxy.json")) { try WeComProxySettings.load(from: $0) } }
        sources.policy = { DaemonReadiness.policyFacts(policy, readable: true) }
        let report = DaemonReadiness(sources: sources).readiness(online: false, refresh: false)
        #expect(report.capabilities.first { $0.id == "vision" }?.status == .ok)
        #expect(report.capabilities.first { $0.id == "mqtt" }?.status == .fail)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for secret in ["sk-B52-SECRET-VISION", "secret-bucket-b52", "LTAIB52SECRETID", "B52-OSS-SECRET", "broker-b52.example.invalid",
                       "mac-secret-b52", "b52-user", "B52-MQTT-SECRET", "proxy-b52", "B52-PROXY-TOKEN", "wwB52SECRETCORP",
                       "真实客户群B52", "13800000000"] {
            #expect(!text.contains(secret), "leaked \(secret)")
        }
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter DaemonReadinessTests`
Expected: 编译失败，`cannot find 'DaemonReadiness' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/imctld/DaemonReadiness.swift
import AXKit
import ControlCore
import Foundation
import MQTTTransport
import WeComAdapter

/// `controller.readiness` for this daemon (B52): facts from the daemon's own state, the evaluator's verdict,
/// and at most one background round of live tests at a time. Called on the socket / MQTT queue: everything
/// here returns quickly — no AX tree reads, no dialogs, no network on the caller's thread.
final class DaemonReadiness: ReadinessProviding, @unchecked Sendable {
    struct Sources {
        var permissions: () -> [String: String]
        var watch: (Int64) -> ReadinessFacts.Watch
        var pauseReasons: () -> [String]
        var policy: () -> ReadinessFacts.Policy
        var clientVersion: () -> String?
        var vision: () -> ReadinessFacts.Vision
        var mqtt: () -> ReadinessFacts.MQTT
        var oss: () -> ReadinessFacts.Config
        var wecomApi: () -> ReadinessFacts.Config
        var agents: () -> ReadinessFacts.Agents
    }

    struct Probes {
        var vision: (() -> ReadinessProbeResult)?
        var mqtt: (() -> ReadinessProbeResult)?
        var oss: (() -> ReadinessProbeResult)?
        var agents: (() -> ReadinessProbeResult)?
        var wecomApi: (() -> ReadinessProbeResult)?
        init(vision: (() -> ReadinessProbeResult)? = nil, mqtt: (() -> ReadinessProbeResult)? = nil,
             oss: (() -> ReadinessProbeResult)? = nil, agents: (() -> ReadinessProbeResult)? = nil,
             wecomApi: (() -> ReadinessProbeResult)? = nil) {
            self.vision = vision; self.mqtt = mqtt; self.oss = oss; self.agents = agents; self.wecomApi = wecomApi
        }
    }

    private let sources: Sources
    private let now: () -> Int64
    private let lock = NSLock()
    private var probesValue: Probes
    private var state = ReadinessOnlineState()
    private let queue = DispatchQueue(label: "com.sunkailun.imctl.readiness")
    /// Tests shorten the deadline.
    var runner: ([ReadinessProbeKind: () -> ReadinessProbeResult]) -> [ReadinessProbeKind: ReadinessProbeResult] = { ReadinessProbeRunner.run($0) }

    init(sources: Sources, probes: Probes = Probes(), now: @escaping () -> Int64 = Clock.nowMs) {
        self.sources = sources; self.probesValue = probes; self.now = now
    }

    /// main.swift adds the MQTT probe once the link exists.
    var probes: Probes {
        get { lock.lock(); defer { lock.unlock() }; return probesValue }
        set { lock.lock(); probesValue = newValue; lock.unlock() }
    }

    func facts(nowMs: Int64) -> ReadinessFacts {
        let p = sources.permissions()
        return ReadinessFacts(
            version: IMCTLVersion.string,
            launchedByLaunchd: p["launchAgent"] == "true",
            pauseReasons: sources.pauseReasons(),
            accessibilityTrusted: p["accessibility"] == "trusted",
            screenRecordingGranted: p["screenRecording"] == "granted",
            wecomData: p["wecomData"] ?? "unknown",
            fullDiskAccess: p["fullDiskAccess"] == "yes",
            clientRunning: p["clientRunning"] == "true",
            clientVersion: sources.clientVersion(),
            watch: sources.watch(nowMs),
            policy: sources.policy(),
            vision: sources.vision(),
            mqtt: sources.mqtt(),
            oss: sources.oss(),
            agents: sources.agents(),
            wecomApi: sources.wecomApi())
    }

    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        let nowMs = now()
        let current = self.facts(nowMs: nowMs)
        lock.lock()
        let decision = state.request(online: online, refresh: refresh, nowMs: nowMs)
        let selected = decision == .start ? Self.selected(probesValue, facts: current) : [:]
        let run = runner
        lock.unlock()
        if decision == .start {
            queue.async { [self] in
                let results = run(selected)
                lock.lock(); state.finish(results, nowMs: now()); lock.unlock()
            }
        }
        lock.lock()
        let info = state.info(online: online, nowMs: nowMs)
        let results = state.results ?? [:]
        lock.unlock()
        return ReadinessEvaluator.evaluate(current, online: results, info: info, nowMs: nowMs)
    }

    /// Only modules that are configured and reachable get a live test.
    static func selected(_ probes: Probes, facts f: ReadinessFacts) -> [ReadinessProbeKind: () -> ReadinessProbeResult] {
        var out: [ReadinessProbeKind: () -> ReadinessProbeResult] = [:]
        if f.vision.config.valid, f.vision.cloudEnabled, f.vision.keyPresent, let p = probes.vision { out[.vision] = p }
        if f.mqtt.daemonMode, f.mqtt.connected, let p = probes.mqtt { out[.mqtt] = p }
        if f.oss.present, f.oss.valid, let p = probes.oss { out[.oss] = p }
        if f.agents.claude.registered || f.agents.codex.registered, f.agents.cliPresent, let p = probes.agents { out[.agents] = p }
        if f.wecomApi.present, f.wecomApi.valid, let p = probes.wecomApi { out[.wecomApi] = p }
        return out
    }

    // MARK: Live facts (counts and states only)

    static func policyFacts(_ p: SendPolicy, readable: Bool) -> ReadinessFacts.Policy {
        ReadinessFacts.Policy(readable: readable, titleCount: p.allowedTitles.count, typesEnabled: !p.allowedTypes.enabledNames.isEmpty,
                              chatIdCount: p.allowedChatIds.count, externalUserIdCount: p.allowedExternalUserIds.count,
                              allowAll: p.allowAll, phoneCount: p.contactAdd.allowedPhones.count,
                              maxAddsPerHour: p.contactAdd.maxAddsPerHour, autoAccept: p.contactRequests.autoAccept.rawValue)
    }

    static func clientVersion(bundleID: String) -> String? {
        AXApp.runningApplication(bundleID: bundleID)?.bundleURL.flatMap(Bundle.init(url:))?
            .infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func visionFacts(url: URL) -> ReadinessFacts.Vision {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReadinessFacts.Vision() }
        guard let s = try? CloudVisionSettings.load(from: url) else { return ReadinessFacts.Vision(config: .init(present: true, valid: false)) }
        return ReadinessFacts.Vision(config: .init(present: true, valid: true), cloudEnabled: s.cloudEnabled, keyPresent: s.keyPresent,
                                     provider: s.provider.rawValue, model: s.model, fullWindowEnabled: s.fullWindowEnabled)
    }

    static func mqttFacts(url: URL, link: MQTTNIOLink?) -> ReadinessFacts.MQTT {
        let present = FileManager.default.fileExists(atPath: url.path)
        return ReadinessFacts.MQTT(config: .init(present: present, valid: present && (try? MQTTSettings.load(from: url)) != nil),
                                   daemonMode: link != nil, connected: link?.isConnected ?? false)
    }

    static func configFacts(url: URL, load: (URL) throws -> Any) -> ReadinessFacts.Config {
        let present = FileManager.default.fileExists(atPath: url.path)
        return ReadinessFacts.Config(present: present, valid: present && (try? load(url)) != nil)
    }
}
```

`main.swift` 改动（文件头补 `import OSSClient`、`import WeComAPI` 如尚未导入）：

1. `let daemon = DaemonRuntime(log: log)` 之后插入：

```swift
        // B52: controller.readiness — facts from this daemon's own state, live tests in the background.
        let watchHealth = WatchHealth()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cli = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("imctl")
        let bundledSkill = Bundle.main.resourceURL.map { $0.appendingPathComponent(AgentPaths.skillRelativePath) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let mqttURL = URL(fileURLWithPath: mqttConfig)
        let ossURL = URL(fileURLWithPath: ossConfig)
        let wecomURL = URL(fileURLWithPath: wecomConfig)
        let readiness = DaemonReadiness(sources: DaemonReadiness.Sources(
            permissions: { (try? handler.permissions(prompt: false, probe: false)) ?? [:] },
            watch: { watchHealth.facts(nowMs: $0) },
            pauseReasons: { (try? store.pauseReasons().map(\.rawValue)) ?? [] },
            policy: { DaemonReadiness.policyFacts(policyProvider.current(), readable: policyProvider.lastError == nil) },
            clientVersion: { DaemonReadiness.clientVersion(bundleID: bundleID) },
            vision: { DaemonReadiness.visionFacts(url: CloudVisionSettings.defaultURL) },
            mqtt: { DaemonReadiness.mqttFacts(url: mqttURL, link: daemon.mqttLink) },
            oss: { DaemonReadiness.configFacts(url: ossURL) { try OSSSettings.load(from: $0) } },
            wecomApi: { DaemonReadiness.configFacts(url: wecomURL) { try WeComProxySettings.load(from: $0) } },
            agents: { AgentRegistrationInspector(home: home, cliPath: cli.path, bundledSkill: bundledSkill).inspect() }))
        readiness.probes = DaemonReadiness.Probes(
            vision: { (try? CloudVisionSettings.loadOrDefault()).map { ReadinessVisionProbe.probe(settings: $0) } ?? .failure("config", latencyMs: 0) },
            oss: { OSSRoundTrip.probe(settingsURL: ossURL) },
            agents: { MCPHandshakeProbe.run(executable: cli) },
            wecomApi: { WeComProxyHealth.probe(settingsURL: wecomURL) })
        dispatcher.readiness = readiness
```

2. MQTT 块里 `daemon.mqttLink = link` 之后加 `readiness.probes.mqtt = { link.probePublish() }`。
3. `DaemonWatcher(...)` 构造调用末尾加参数 `, health: watchHealth`。

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "DaemonReadinessTests|WatchHealthTests" && swift build`
Expected: 全部通过；整包可编译。

- [ ] **Step 5: 提交**

```bash
git add Sources/imctld/DaemonReadiness.swift Sources/imctld/main.swift Tests/imctldTests/DaemonReadinessTests.swift
git commit -m "feat(imctld): controller.readiness from the daemon's own state with background live tests" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `imctl doctor` 与兜底报告（CLI）

**Files:**
- Create: `Sources/imctl/Host/Doctor.swift`
- Create: `Sources/imctl/Commands/DoctorCommand.swift`
- Modify: `Sources/imctl/IMCTL.swift:10`（`subcommands` 末尾加 `DoctorCommand.self`）
- Modify: `Sources/imctl/Commands/SetupCommand.swift`（`run()` 两处收尾各加一行提示）
- Modify: `Tests/imctlTests/CommandParsingTests.swift:9`（子命令清单末尾加 `"doctor"`）
- Test: `Tests/imctlTests/DoctorTests.swift`

**Interfaces:**
- Consumes: Task 1 `ReadinessReport`、`ReadinessCommandText`；Task 4 `RPCDispatcher.readinessMethod`；`UnixSocketClient`、`JSONValue`、`AgentIntegration.executable()`、`Launchctl`、`LaunchctlStatus`、`LaunchAgentSpec`、`HostProbe.client(bundleID:)`。
- Produces: `Doctor.fetch(call:sleep:online:refresh:wait:)`、`Doctor.decode(_:)`、`Doctor.render(_:cli:)`、`Doctor.cliPath(environment:me:resolve:)`、`Doctor.Fallback`、`Doctor.fallbackReason(for:) -> String?`、`Doctor.renderFallback(_:cli:)`、`Doctor.collectFallback(reason:)`、`Doctor.json(_:)`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/imctlTests/DoctorTests.swift
import ControlCore
import Foundation
import MCPTransport
import Testing
@testable import imctl

@Suite("imctl doctor")
struct DoctorTests {
    static func report(_ state: String, ready: Bool = true, next: ReadinessFix? = nil) -> ReadinessReport {
        ReadinessReport(ready: ready, nextStep: next, nextStepCapability: next == nil ? nil : "read",
                        capabilities: [
                            ReadinessCapability(id: "read", title: "读取会话与历史", required: true, status: ready ? .ok : .fail,
                                                checks: [ReadinessCheck(id: "accessibility", status: ready ? .ok : .fail, detail: "d")],
                                                fix: next),
                            ReadinessCapability(id: "vision", title: "视觉兜底", required: false, status: .disabled,
                                                checks: [ReadinessCheck(id: "config", status: .disabled, detail: "未配置")],
                                                fix: ReadinessFix(text: "enable", command: "pbpaste | imctl vision set --provider qwen --secret-stdin")),
                        ],
                        online: ReadinessOnlineInfo(state: state), version: "v", generatedMs: 1)
    }

    static func json(_ r: ReadinessReport) throws -> JSONValue {
        try JSONValue.parse(String(decoding: try JSONEncoder().encode(r), as: UTF8.self))
    }

    @Test func fetchPollsWhileRunningAndOnlyTheFirstCallRefreshes() throws {
        var answers = [Self.report("running"), Self.report("running"), Self.report("done")]
        var params: [[String: JSONValue]] = []
        var slept = 0
        let r = try Doctor.fetch(call: { method, p in
            #expect(method == "controller.readiness")
            params.append(p)
            return try Self.json(answers.removeFirst())
        }, sleep: { _ in slept += 1 }, online: true, refresh: true, wait: 45)
        #expect(r.online.state == "done" && slept == 2)
        #expect(params[0]["refresh"]?.boolValue == true && params[1]["refresh"]?.boolValue == false)
    }

    @Test func fetchGivesUpAfterTheWait() throws {
        var calls = 0
        let r = try Doctor.fetch(call: { _, _ in calls += 1; return try Self.json(Self.report("running")) },
                                 sleep: { _ in }, online: true, refresh: false, wait: 3)
        #expect(r.online.state == "running" && calls == 4)
    }

    @Test func renderLeadsWithTheVerdictAndTheNextStep() {
        let cli = "/Apps/imctl.app/Contents/MacOS/imctl"
        let ready = Doctor.render(Self.report("done"), cli: cli)
        #expect(ready.hasPrefix("✔ 就绪"))
        #expect(ready.contains("○ 视觉兜底（可选）") && ready.contains("$ pbpaste | \(cli) vision set"))
        let broken = Doctor.render(Self.report("done", ready: false, next: ReadinessFix(text: "授权辅助功能", command: "imctl setup")), cli: cli)
        #expect(broken.hasPrefix("✘ 未就绪。下一步：授权辅助功能") && broken.contains("$ \(cli) setup"))
        let unsure = Doctor.render(Self.report("done", ready: false), cli: "imctl")
        #expect(unsure.hasPrefix("? "))
        #expect(Doctor.render(Self.report("skipped"), cli: "imctl").contains("只做了本机检查"))
    }

    @Test func cliPathIsImctlOnlyWhenPathRunsThisBinary() {
        let me = "/Apps/imctl.app/Contents/MacOS/imctl"
        #expect(Doctor.cliPath(environment: ["PATH": "/usr/bin:/usr/local/bin"], me: me, resolve: { $0 == "/usr/local/bin/imctl" ? me : nil }) == "imctl")
        #expect(Doctor.cliPath(environment: ["PATH": "/usr/bin"], me: me, resolve: { _ in nil }) == me)
        #expect(Doctor.cliPath(environment: ["PATH": "/opt/bin"], me: me, resolve: { $0 == "/opt/bin/imctl" ? "/old/imctl" : nil }) == me)
    }

    @Test func anOldDaemonIsReportedAsTooOld() {
        #expect(Doctor.fallbackReason(for: UnixSocketClient.RPCError(code: -32601, message: "method not found", data: nil)) == "tooOld")
        #expect(Doctor.fallbackReason(for: UnixSocketClient.TransportError.timeout) == "unreachable")
        #expect(Doctor.fallbackReason(for: UnixSocketClient.RPCError(code: -32000, message: "x", data: nil)) == nil)
        let text = Doctor.renderFallback(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: 42,
                                               clientRunning: true, clientVersion: "5.0.11", reason: "tooOld"), cli: "imctl")
        #expect(text.contains("版本早于 B52") && text.contains("$ imctl setup"))
    }

    @Test func fallbackNextStepFollowsWhatIsMissing() {
        func next(_ f: Doctor.Fallback) -> String { Doctor.renderFallback(f, cli: "imctl") }
        #expect(next(.init(appPresent: true, plistPresent: false, loaded: false, daemonPid: nil, clientRunning: false, clientVersion: nil, reason: "unreachable")).contains("$ imctl setup"))
        #expect(next(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: nil, clientRunning: true, clientVersion: nil, reason: "unreachable")).contains("imctld.log"))
        #expect(next(.init(appPresent: true, plistPresent: true, loaded: true, daemonPid: 7, clientRunning: true, clientVersion: nil, reason: "unreachable")).contains("kickstart"))
    }

    @Test func defaultsAreOnlineWithAFortyFiveSecondWait() throws {
        let cmd = try DoctorCommand.parse([])
        #expect(!cmd.json && !cmd.offline && !cmd.refresh && cmd.wait == 45)
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter DoctorTests`
Expected: 编译失败，`cannot find 'Doctor' in scope`。

- [ ] **Step 3: 写实现**

```swift
// Sources/imctl/Host/Doctor.swift
import ControlCore
import Foundation
import MCPTransport

/// `imctl doctor` (B52): fetch `controller.readiness`, poll while the live tests run, render in Chinese;
/// when the daemon cannot answer, say what this Mac shows directly and the one next step.
enum Doctor {
    static func fetch(call: (String, [String: JSONValue]) throws -> JSONValue, sleep: (TimeInterval) -> Void,
                      online: Bool, refresh: Bool, wait: TimeInterval) throws -> ReadinessReport {
        var params: [String: JSONValue] = ["online": .bool(online), "refresh": .bool(refresh)]
        var waited: TimeInterval = 0
        while true {
            let report = try decode(try call(RPCDispatcher.readinessMethod, params))
            guard report.online.state == "running", waited < wait else { return report }
            params["refresh"] = .bool(false)
            sleep(1)
            waited += 1
        }
    }

    static func decode(_ value: JSONValue) throws -> ReadinessReport {
        try JSONDecoder().decode(ReadinessReport.self, from: Data(try value.serialized().utf8))
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func symbol(_ status: ReadinessStatus) -> String {
        switch status { case .ok: "✔"; case .fail: "✘"; case .disabled: "○"; case .unknown: "?" }
    }

    static func render(_ report: ReadinessReport, cli: String) -> String {
        var lines: [String] = []
        if report.ready {
            lines.append("✔ 就绪：必需项都可用" + (report.online.state == "done" ? "" : "（联网实测未完成）"))
        } else if let next = report.nextStep {
            lines.append("✘ 未就绪。下一步：\(next.text)")
            if let command = next.command { lines.append("    $ \(ReadinessCommandText.substitute(command, cli: cli))") }
        } else {
            lines.append("? 还有项目暂时无法判断（例如守护进程刚启动），几秒后再运行一次")
        }
        switch report.online.state {
        case "running": lines.append("联网实测在等待时间内没有完成，实测项标为「未实测」；稍后再运行一次")
        case "skipped": lines.append("只做了本机检查（--offline）")
        default: break
        }
        lines.append("")
        for capability in report.capabilities {
            lines.append("\(symbol(capability.status)) \(capability.title)\(capability.required ? "" : "（可选）")")
            for check in capability.checks {
                lines.append("    \(symbol(check.status)) \(check.detail)\(check.tested == false ? "（未实测）" : "")")
            }
            for warning in capability.warnings { lines.append("    ! \(warning)") }
            if let fix = capability.fix, capability.status == .fail || capability.status == .disabled {
                lines.append("    → \(fix.text)")
                if let command = fix.command { lines.append("      $ \(ReadinessCommandText.substitute(command, cli: cli))") }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "imctl" when the first `imctl` on the user's PATH is this binary; this binary's absolute path otherwise.
    static func cliPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                        me: String = AgentIntegration.executable(),
                        resolve: (String) -> String? = { path in
                            FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : nil
                        }) -> String {
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            if let found = resolve(String(dir) + "/imctl") { return found == me ? "imctl" : me }
        }
        return me
    }

    // MARK: Fallback

    struct Fallback: Codable, Equatable {
        var appPresent: Bool
        var plistPresent: Bool
        var loaded: Bool
        var daemonPid: Int?
        var clientRunning: Bool
        var clientVersion: String?
        /// `unreachable` | `tooOld`
        var reason: String
    }

    /// Which failures get the fallback report: an old daemon (`method not found`) or no answer at all.
    static func fallbackReason(for error: Error) -> String? {
        if let rpc = error as? UnixSocketClient.RPCError { return rpc.code == -32601 ? "tooOld" : nil }
        if error is UnixSocketClient.TransportError { return "unreachable" }
        return nil
    }

    static func collectFallback(reason: String) -> Fallback {
        let fm = FileManager.default
        let appPresent = fm.fileExists(atPath: NSHomeDirectory() + "/Applications/imctl.app") || fm.fileExists(atPath: "/Applications/imctl.app")
        let plistPresent = fm.fileExists(atPath: LaunchAgentSpec.defaultPlistPath().path)
        let status = (try? Launchctl.run(["print", Launchctl.serviceTarget(LaunchAgentSpec.defaultLabel)])).map { LaunchctlStatus.parse($0.output) }
        let client = HostProbe.client(bundleID: "com.tencent.WeWorkMac")
        return Fallback(appPresent: appPresent, plistPresent: plistPresent, loaded: status?.loaded ?? false, daemonPid: status?.pid,
                        clientRunning: client != nil, clientVersion: client?.version, reason: reason)
    }

    static func renderFallback(_ f: Fallback, cli: String) -> String {
        var lines = [f.reason == "tooOld"
                     ? "✘ 正在运行的守护进程版本早于 B52（没有 controller.readiness）。本机能直接看到的情况："
                     : "✘ 连不上守护进程。本机能直接看到的情况："]
        lines.append("    \(f.appPresent ? "✔" : "✘") imctl.app \(f.appPresent ? "已安装" : "没找到")")
        lines.append("    \(f.plistPresent ? "✔" : "✘") 后台常驻 \(f.plistPresent ? (f.loaded ? "已加载" : "文件在但没加载") : "没安装")")
        lines.append("    \(f.daemonPid != nil ? "✔" : "✘") imctld \(f.daemonPid.map { "在运行（pid \($0)）" } ?? "没在运行")")
        lines.append("    \(f.clientRunning ? "✔" : "✘") 企业微信 \(f.clientRunning ? "在运行" + (f.clientVersion.map { "（\($0)）" } ?? "") : "没有运行")")
        let next: (text: String, command: String)
        if f.reason == "tooOld" {
            next = ("装好新版 imctl.app 后重装后台常驻", "\(cli) setup")
        } else if !f.plistPresent || !f.loaded {
            next = ("安装后台常驻并请求系统授权", "\(cli) setup")
        } else if f.daemonPid == nil {
            next = ("守护进程起不来：看最近的日志", "tail -n 50 ~/Library/Logs/imctl/imctld.log")
        } else {
            next = ("守护进程在运行但连不上 socket：重启它", "launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl")
        }
        lines.append("")
        lines.append("下一步：\(next.text)")
        lines.append("    $ \(next.command)")
        return lines.joined(separator: "\n")
    }
}
```

```swift
// Sources/imctl/Commands/DoctorCommand.swift
import ArgumentParser
import ControlCore
import Foundation
import MCPTransport

/// B52: which features work on this Mac, why the others do not, and the command that fixes each.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Readiness report: which features work on this Mac, why the others do not, and the command that fixes each. Read-only; the live tests run in the daemon."
    )

    @Flag(help: "Print the readiness JSON.") var json = false
    @Flag(help: "Local checks only: no live tests.") var offline = false
    @Flag(help: "Retest instead of reusing the last round (at most once per 60 s).") var refresh = false
    @Option(help: "Seconds to wait for the live tests.") var wait: Double = 45
    @Option(help: "Unix socket served by imctld.") var socket: String = IMCTLPaths.socket.path

    func run() throws {
        let cli = Doctor.cliPath()
        let client = UnixSocketClient(path: socket, timeout: 15)
        do {
            let report = try Doctor.fetch(call: { try client.call($0, params: $1) }, sleep: { Thread.sleep(forTimeInterval: $0) },
                                          online: !offline, refresh: refresh, wait: wait)
            print(try json ? Doctor.json(report) : Doctor.render(report, cli: cli))
            if !report.ready { throw ExitCode(2) }
        } catch let error where Doctor.fallbackReason(for: error) != nil {
            let fallback = Doctor.collectFallback(reason: Doctor.fallbackReason(for: error) ?? "unreachable")
            print(try json ? Doctor.json(fallback) : Doctor.renderFallback(fallback, cli: cli))
            throw ExitCode(3)
        }
    }
}
```

`IMCTL.swift:10` 的 `subcommands` 数组末尾（`SetupCommand.self` 之后）加 `DoctorCommand.self`；`CommandParsingTests.swift:9` 的清单末尾加 `"doctor"`。

`SetupCommand.run()`：在 `print("完成。控制台 › 状态 › 检查授权 可随时复查。")` 之后、以及 `print("仍缺：…")` 之后各加一行：

```swift
            print("完整体检：imctl doctor（每项功能能不能用、怎么修）")
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "DoctorTests|CommandParsingTests"`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add Sources/imctl/Host/Doctor.swift Sources/imctl/Commands/DoctorCommand.swift Sources/imctl/IMCTL.swift Sources/imctl/Commands/SetupCommand.swift Tests/imctlTests/DoctorTests.swift Tests/imctlTests/CommandParsingTests.swift
git commit -m "feat(cli): imctl doctor readiness report with a fallback when the daemon cannot answer" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: 控制台「体检」区

**Files:**
- Create: `Sources/imctl-console/Model/ReadinessText.swift`
- Modify: `Sources/imctl-console/Views/ResultPane.swift`（抽出 `CopyButton`，原复制按钮改用它）
- Modify: `Sources/imctl-console/Model/ConsoleModel.swift`（`checkPermissions` 附近加体检状态与方法）
- Modify: `Sources/imctl-console/Views/StatusView.swift`（「授权与本机」之后加「体检」）
- Test: `Tests/imctl-consoleTests/ConsoleReadinessTests.swift`

**Interfaces:**
- Consumes: Task 1 类型与 `ReadinessCommandText`；Task 4 `RPCDispatcher.readinessMethod`、`dispatcher.readiness`。
- Produces: `ReadinessText.symbol(_:)`、`ReadinessText.headline(_:)`；`ConsoleModel.readiness`、`readinessRunning`、`runReadiness(localOnly:refresh:maxPolls:pollNanoseconds:)`、`cliCommand(_:)`；`CopyButton(text:)`。

- [ ] **Step 1: 写失败的测试**

```swift
// Tests/imctl-consoleTests/ConsoleReadinessTests.swift
import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport
@testable import imctl_console

final class ScriptedReadiness: ReadinessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String]
    private(set) var calls: [(online: Bool, refresh: Bool)] = []
    init(states: [String]) { self.states = states }
    func readiness(online: Bool, refresh: Bool) -> ReadinessReport {
        lock.lock(); defer { lock.unlock() }
        calls.append((online, refresh))
        let state = states.count > 1 ? states.removeFirst() : (states.first ?? "done")
        return ReadinessReport(ready: state == "done", nextStep: nil, nextStepCapability: nil, capabilities: [],
                               online: ReadinessOnlineInfo(state: state), version: "t", generatedMs: 1)
    }
}

@Suite("Console readiness panel", .serialized)
@MainActor
struct ConsoleReadinessTests {
    func daemon(_ readiness: ReadinessProviding) throws -> (UnixSocketServer, String) {
        let path = "/tmp/imctl-ui-\(UUID().uuidString.prefix(8))/s.sock"
        let store = try ControlStore(path: ":memory:")
        let dispatcher = RPCDispatcher(executor: CommandExecutor(store: store, handler: SwitchingFakeHandler()))
        dispatcher.readiness = readiness
        let server = UnixSocketServer(dispatcher: dispatcher, path: path)
        server.log = { _ in }
        try server.start()
        return (server, path)
    }

    @Test func pollsWhileTheLiveTestsRun() async throws {
        let scripted = ScriptedReadiness(states: ["running", "running", "done"])
        let (server, path) = try daemon(scripted)
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.runReadiness(refresh: true, pollNanoseconds: 10_000_000)
        #expect(model.readiness?.online.state == "done" && !model.readinessRunning)
        #expect(scripted.calls.count == 3 && scripted.calls[0].refresh && !scripted.calls[1].refresh)
    }

    @Test func localOnlyAsksForNoLiveTests() async throws {
        let scripted = ScriptedReadiness(states: ["skipped"])
        let (server, path) = try daemon(scripted)
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.runReadiness(localOnly: true, pollNanoseconds: 10_000_000)
        #expect(scripted.calls.count == 1 && !scripted.calls[0].online)
    }

    @Test func periodicRefreshNeverRunsReadiness() async throws {
        let scripted = ScriptedReadiness(states: ["done"])
        let (server, path) = try daemon(scripted)
        defer { server.stop() }
        let model = ConsoleModel()
        model.socketPathOverride = path
        await model.refresh()
        #expect(scripted.calls.isEmpty && model.readiness == nil)
    }

    @Test func headlinesAndSymbols() {
        let ready = ReadinessReport(ready: true, nextStep: nil, nextStepCapability: nil, capabilities: [],
                                    online: ReadinessOnlineInfo(state: "done"), version: "v", generatedMs: 1)
        #expect(ReadinessText.headline(ready) == "✔ 就绪")
        var broken = ready; broken.ready = false; broken.nextStep = ReadinessFix(text: "打开企业微信并登录")
        #expect(ReadinessText.headline(broken) == "✘ 未就绪 · 下一步：打开企业微信并登录")
        #expect(ReadinessText.symbol(.disabled) == "○")
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter ConsoleReadinessTests`
Expected: 编译失败，`value of type 'ConsoleModel' has no member 'runReadiness'`。

- [ ] **Step 3: 写实现**

```swift
// Sources/imctl-console/Model/ReadinessText.swift
import ControlCore
import Foundation

/// Words for the 体检 panel (B52), kept out of the view so they are testable.
enum ReadinessText {
    static func symbol(_ status: ReadinessStatus) -> String {
        switch status { case .ok: "✔"; case .fail: "✘"; case .disabled: "○"; case .unknown: "?" }
    }

    static func headline(_ report: ReadinessReport) -> String {
        if report.ready { return report.online.state == "done" ? "✔ 就绪" : "✔ 就绪（联网实测未完成）" }
        if let next = report.nextStep { return "✘ 未就绪 · 下一步：\(next.text)" }
        return "? 还有项目暂时无法判断，几秒后再体检一次"
    }
}
```

`ResultPane.swift`：在文件末尾加

```swift
/// One-click copy for short text. The pasteboard stays in this file (ForbiddenAPITests' allowlist).
struct CopyButton: View {
    let text: String
    var body: some View {
        Button {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        } label: { Label("复制", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless).disabled(text.isEmpty)
    }
}
```

并把原来 `:25-28` 的内联复制按钮整段换成 `CopyButton(text: text)`。

`ConsoleModel.swift`：在 `checkPermissions` 之后加（文件头确认已 `import ControlCore` 与 `import MCPTransport`）：

```swift
    /// B52: the last readiness report, in memory only; the console never fetches it on its own (it can cost a paid vision call).
    var readiness: ReadinessReport?
    var readinessRunning = false

    /// Polls while the live tests run, once per `pollNanoseconds`, at most `maxPolls` extra times.
    func runReadiness(localOnly: Bool = false, refresh: Bool = false, maxPolls: Int = 45, pollNanoseconds: UInt64 = 1_000_000_000) async {
        readinessRunning = true
        defer { readinessRunning = false }
        var params: [String: JSONValue] = ["online": .bool(!localOnly), "refresh": .bool(refresh)]
        for _ in 0...maxPolls {
            guard let value = await rpc(RPCDispatcher.readinessMethod, params, log: false),
                  let text = try? value.serialized(),
                  let report = try? JSONDecoder().decode(ReadinessReport.self, from: Data(text.utf8)) else { return }
            readiness = report
            guard report.online.state == "running" else { return }
            params["refresh"] = .bool(false)
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    /// Fix commands with this bundle's CLI (GUI users rarely have `imctl` on PATH).
    func cliCommand(_ command: String) -> String { ReadinessCommandText.substitute(command, cli: cli.executable.path) }
```

`StatusView.swift`：在 `struct StatusView` 的状态属性处加 `@State private var readinessLocalOnly = false`；在 `DisclosureGroup("授权与本机") { … }` 之后插入：

```swift
                DisclosureGroup("体检") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button(model.readinessRunning ? "体检中…" : "运行体检") {
                                Task { await model.runReadiness(localOnly: readinessLocalOnly) }
                            }
                            .disabled(model.readinessRunning)
                            Button("重新实测") { Task { await model.runReadiness(refresh: true) } }
                                .disabled(model.readinessRunning || readinessLocalOnly)
                            Toggle("只做本机检查", isOn: $readinessLocalOnly)
                        }
                        if let report = model.readiness {
                            Text(ReadinessText.headline(report)).font(.headline)
                            if let tested = report.online.testedMs {
                                Text("联网实测时间：\(Date(timeIntervalSince1970: Double(tested) / 1000).formatted(date: .omitted, time: .standard))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(report.capabilities, id: \.id) { capability in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(ReadinessText.symbol(capability.status)) \(capability.title)\(capability.required ? "" : "（可选）")")
                                    ForEach(capability.warnings, id: \.self) { Text("! \($0)").font(.caption).foregroundStyle(.orange) }
                                    if let fix = capability.fix, capability.status == .fail || capability.status == .disabled {
                                        Text(fix.text).font(.caption).foregroundStyle(.secondary)
                                        if let command = fix.command {
                                            HStack {
                                                Text(model.cliCommand(command)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                                CopyButton(text: model.cliCommand(command))
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("还没有体检结果。点「运行体检」开始；不会自动运行。").foregroundStyle(.secondary)
                        }
                    }
                }
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter "ConsoleReadinessTests|ConsoleModelTests|ForbiddenAPITests" && swift build`
Expected: 全部通过；控制台可编译（需要完整 Xcode，本机已装）。

- [ ] **Step 5: 提交**

```bash
git add Sources/imctl-console Tests/imctl-consoleTests/ConsoleReadinessTests.swift
git commit -m "feat(console): on-demand readiness panel with copyable fix commands" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: 安全边界、目录规范、运维文档与版本

**Files:**
- Modify: `AGENTS.md`（项目边界「权限面」条目末尾）
- Modify: `docs/ai-coding/SECURITY_CODING_SPEC.md:64`
- Modify: `docs/ai-coding/AI_DIRECTORY_STRUCTURE_GUIDE.md:56`、`:66`
- Modify: `docs/ops/installer.md`（「给别的 Mac 安装」第 4 步与其后）、`docs/ops/permissions.md:32-36`、`docs/ops/portability.md:12-17`
- Modify: `packaging/pkg/companion/README-另一台Mac.txt:5`、`:25`；`packaging/pkg/companion/install-on-another-mac.command`（「3/3 检查」段）
- Modify: `README.md:63` 段落
- Modify: `Sources/ControlCore/IMCTLVersion.swift`

**Interfaces:** 无代码接口；版本字符串变为 `1.0.15-dev`。

- [ ] **Step 1: 改规则文档**

`AGENTS.md`「权限面限于辅助功能与屏幕录制」条目末尾（「…不能将授权当作已上线证据。」之后）加：

```markdown
B52 用户 2026-10-10 允许：显式 `controller.readiness`（`imctl doctor`、控制台「体检」）在云端视觉已开启且有密钥时，用程序在内存里画的合成图（两个灰色方块，不截屏、不含本机或企微内容）走一次 B16 请求，证明提供商、模型与密钥可用；后台路径与控制台定时刷新不得触发，结果只留错误类别。
```

`SECURITY_CODING_SPEC.md:64` 把「B16 路径只由 `group.addMembers` 显式动作触发；」改为「B16 路径只由 `group.addMembers` 显式动作触发（例外：B52 显式 `controller.readiness` 用程序绘制的合成图走同一请求形状做连通实测，不截屏、不含本机或企微内容，用户 2026-10-10 决定）；」。

`AI_DIRECTORY_STRUCTURE_GUIDE.md`：`:56` 之后加一行

```markdown
| `Sources/ControlCore/Readiness/` | B52 就绪体检的纯逻辑：事实（`ReadinessFacts`）、判定规则（`ReadinessEvaluator`）、联网实测的缓存与并发执行（`ReadinessOnlineState`、`ReadinessProbeRunner`）、修复命令的路径替换 |
```

`:66` 改为「| `Sources/imctld/` | `main.swift`（参数与装配）、运行时、观察者驱动、路径、就绪体检装配（`DaemonReadiness`、`WatchHealth`） |」。

- [ ] **Step 2: 改运维文档（含更正「其它版本自动只读」）**

`docs/ops/installer.md` 第 4 步整行改为：

```markdown
4. 企微已校准的版本是 5.0.11；其它版本不会被拦下，`imctl doctor` 会提示「未在此版本校准」，能否使用以它的可读性检查为准；几何见 `docs/ops/portability.md`。
```

第 5 步之后加：

```markdown
6. `imctl doctor`：逐项列出能不能用、卡在哪、怎么修（默认做联网实测，含一次合成图视觉调用；`--offline` 只看本机），见 `docs/protocol/im-control-protocol.md` §6.45。
```

`docs/ops/permissions.md` 的「## 检查」代码块之后加一句：「授权之外各功能能不能用（企微可读性、策略、视觉、MQTT、OSS、智能体接入）用 `imctl doctor` 看。」

`docs/ops/portability.md` 的「换机 / 换屏后先看什么」代码块第一行之前加：

```bash
imctl doctor                       # 逐项就绪：能不能用、卡在哪、怎么修（先看这个）
```

`README-另一台Mac.txt:5` 改为「- 第二台 Mac 上先装好并登录企业微信（已校准 5.0.11；其它版本 imctl doctor 会提示「未在此版本校准」）。」；`:25` 改为「- 换机后先体检：/Applications/imctl.app/Contents/MacOS/imctl doctor（几何细节：imctl call controller.diagnose）」。

`install-on-another-mac.command` 的「3/3 检查」段，在 `controller.diagnose` 那一行之前加：

```bash
/Applications/imctl.app/Contents/MacOS/imctl doctor || true
```

`README.md:63` 段落末尾加：「装好后用 `imctl doctor` 看每项功能是否可用与修复命令。」

- [ ] **Step 3: 改版本**

`IMCTLVersion.swift`：在 `1.0.14-dev` 那行注释之后加 `/// 1.0.15-dev (2026-10-11): B52 — controller.readiness / imctl doctor: per-capability readiness with background live tests.`，并把 `string` 改为 `"1.0.15-dev"`。

- [ ] **Step 4: 全量验证**

Run: `swift build && swift test 2>&1 | tail -5 && bash scripts/check-secrets.sh && git diff --check`
Expected: 全部测试通过（总数 = 961 + 本批新增），`check-secrets` 仍是原有 11 条提醒，无新增。

- [ ] **Step 5: 提交**

```bash
git add AGENTS.md docs/ai-coding docs/ops packaging/pkg/companion README.md Sources/ControlCore/IMCTLVersion.swift
git commit -m "docs: readiness rules, doctor in the install path, correct the version-gate claim; 1.0.15-dev" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: 变异验证、独立审查、安装与活体门报告

**Files:**
- Create: `docs/gates/<日期>-b52-readiness-doctor.md`

**Interfaces:** 无。

- [ ] **Step 1: 变异验证**

在临时副本里逐条删掉下列保证，各跑对应测试，确认每一处都变红；记录到门报告：

| 删去的保证 | 应变红的测试 |
|---|---|
| `ReadinessOnlineState.request` 的 `running` 判断 | `oneRunAtATimeThenCachedForFiveMinutes`、`concurrentCallersStartOneRound` |
| `refreshFloorMs` 判断 | `refreshWaitsSixtySecondsFromTheLastStart` |
| `ReadinessProbeRunner` 的期限补 `timeout` | `aProbeThatNeverFinishesTimesOutWithoutHidingTheOthers`、`aStuckProbeEndsTheRoundAtTheDeadline` |
| `request` 的 `guard online` | `offlineNeverStarts`、`offlineNeverRunsAProbe` |
| `RPCDispatcher` 查询分支改走 `invoke`（建命令记录） | `directCallReturnsTheReportAndPassesTheFlags`、`answersWhileTheExecutorIsBusy` |
| `OSSRoundTrip.category` 改为返回 `control.message` | `categoryNeverCarriesTheMessage` |
| `policyFacts` 改为带出标题或号码 | `reportCarriesNoSecretsFromRealConfigFiles` |
| `WeComProxyHealth` 加上 Authorization 头 | `okNeedsHTTP200AndStatusOK` |
| `ReadinessVisionProbe` 改用别的客户端计数路径 | `anAnswerPassesWithoutTouchingTheCommandCounters` |
| `Doctor.fallbackReason` 不认 `-32601` | `anOldDaemonIsReportedAsTooOld` |
| `ReadinessEvaluator.mediaCapability` 不看 `wecomData` | `withoutFullDiskAccessMediaPointsAtThatPane` |
| 在 `ConsoleModel.refresh()` 里调 `runReadiness()` | `periodicRefreshNeverRunsReadiness` |

- [ ] **Step 2: 独立审查**

派一个审查代理只读审查本分支相对 `main` 的全部改动，重点：不碰企微界面、不弹框、无密钥与身份信息外泄、查询不进执行器、实测有界、`ForbiddenAPITests` 未放宽、文档与代码一致。直到无严重与重要问题；修复后重跑 Step 1 中受影响的变异。

- [ ] **Step 3: 构建、打包、安装**

```bash
IMCTL_SIGN_TEAM=<证书名括号里的 ID> IMCTL_SIGN_TEAM_ID=<证书的团队 ID> IMCTL_OUT_DIR=out/b52-build$(git rev-list --count HEAD) scripts/build-pkg.sh release
```

（`build-pkg.sh` 自己会调用 `build-app.sh`，两个脚本共用 `IMCTL_OUT_DIR`。证书名括号里的 ID 见 `security find-identity -v -p codesigning`，团队 ID 见 `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject` 的 `OU`；两者都不写进仓库。）展开 pkg 核载荷哈希与严格验签，然后 `installer -pkg <pkg> -target CurrentUserHomeDirectory`，`~/Applications/imctl.app/Contents/MacOS/imctl setup`。新签名身份不同于 build 233：由用户在系统设置里重新允许辅助功能、屏幕录制与完全磁盘访问权限，再 `launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl` 并 `imctl setup --check` 六项读回。

- [ ] **Step 4: 活体验收**

1. 现状：`imctl doctor` → 期望必需项全 ✔、`agents` ✔（握手实测）、其余可选 ○、退出码 0；`imctl doctor --json` 留档（脱敏）。
2. 用户配好千问密钥（以及 MQTT，如果提供 broker）后：`imctl doctor` → `vision` ✔（模型实测），`controller.describe` 的三个 `vision*Count` 前后不变；60 秒内 `imctl doctor --refresh` 返回上一轮结果（`testedMs` 不变），60 秒后才重测。
3. 故障演练：退出企业微信后 `imctl doctor` → `wecom` ✘ 且下一步是打开企业微信、`read` 等为 `?`、退出码 2；重新打开企业微信。`launchctl bootout gui/$(id -u)/com.sunkailun.imctl` 后 `imctl doctor` → 兜底报告、退出码 3；再 `imctl setup` 恢复。
4. 控制台：状态页「体检」→「运行体检」显示同样结果，复制按钮可用；打开页面不自动体检。

- [ ] **Step 5: 写门报告并提交**

按 `docs/ai-coding/TESTING_SPEC.md` 模板写 `docs/gates/<日期>-b52-readiness-doctor.md`：条件、实现、单测数（与 961 对比）、变异表、审查轮次、制品哈希、活体逐项结果（只写状态与类别）、未闭环项（本机角标布局、B 期向导、C 期源码构建、Developer ID）。然后：

```bash
git add docs/gates
git commit -m "docs(gates): B52 readiness doctor on build <N>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

合入 `main` 与推送前先 `git fetch`；远端有新提交就先 rebase 并重跑全量测试。合入与推送等用户确认。门报告提交后，提议用户把本批（含 2026-10-10 的用户决定与证据）归档到 Wiki，以「已提交推送 <hash>」回执为准。

### Task 16（追加，用户 2026-10-12 决定）：controller id 默认取本机名

规格见「追加：controller id 默认取本机名」。本任务在 Task 15 的活体验收中途插入；完成后回到 Task 15，重新构建安装，并补做活体验收。

**Files:**
- Modify: `Sources/MQTTTransport/MQTTSettings.swift`（`isValidControllerID`、`defaultControllerID(localHostName:)`、`currentLocalHostName()`、`resolveControllerID(explicit:existing:hostDefault:)`）
- Modify: `Sources/imctl/Commands/EnrollCommand.swift`（`--controller-id` 可省，取值顺序与校验）
- Modify: `Sources/imctl-console/Model/ConsoleModel.swift`（`formControllerID(stored:hostDefault:)`、`saveMQTT` 校验）、`Sources/imctl-console/Views/SettingsView.swift`（预填、提示、说明）
- Modify: `Sources/ControlCore/Readiness/ReadinessEvaluator.swift`（MQTT 未配置的修复命令与文字）
- Test: `Tests/MQTTTransportTests/ControllerIDTests.swift`（新）、`Tests/imctlTests/EnrollCommandTests.swift`（新）、`Tests/imctl-consoleTests/` 与 `Tests/ControlCoreTests/ReadinessEvaluatorTests.swift`（加测）
- Docs: `README.md`、`docs/protocol/im-control-protocol.md` §2.1、`docs/ops/emqx-auth-acl.md`、`docs/ops/portability.md`

- [ ] **Step 1：失败测试**
  - 清洗：`Example-Mac-Studio` → `example-mac-studio`；`My Mac (2)` → `my-mac-2`；`--Mac--` → `mac`；空串、nil、全中文 → nil；80 个字符截到 64 个，末尾不留 `-`。
  - 校验：`mac-01`、`Mac_01.a` 通过；空串、`a/b`、`a+b`、`a#`、`a b`、65 个字符、中文都拒绝。
  - 取值顺序：显式 > 已登记 > 本机名；显式空串视同未填。
  - `imctl enroll`：已有 `mqtt.json` 且不带 `--controller-id` 时保留原 id；`--controller-id a/b` 报错且不写文件；什么都没有时用本机名默认值。
  - 控制台：没有已存配置时表单预填默认值，有已存 id 时用已存 id；`saveMQTT` 遇到非法 id 不写文件、记一条错误。
  - 体检：MQTT 未配置的修复命令是 `imctl enroll --broker <主机[:端口]>`。
- [ ] **Step 2：实现到全绿**，同步文档。
- [ ] **Step 3：变异**：去掉小写化、去掉「保留已登记 id」、允许 `/`、表单预填盖过已存 id，各自应有测试变红。
- [ ] **Step 4：独立审查**本任务的差异（新的审查代理），严重 / 重要问题修复后全量测试。
- [ ] **Step 5：回到 Task 15**：重新构建打包（同一证书，授权应保留，用 `setup --check` 核对）、安装；控制台 MQTT 表单显示预填 id，用户只填 broker 保存；在「状态」›「守护进程维护」点「安装 / 更新」以 MQTT 模式重装，然后 `imctl doctor` 实测 MQTT 发布。
