# 批次 B1：ControlCore 核心 + 执行器 + MCP/本地传输 + imctld 骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户要求"把功能都实现了一口气测试"。本批把 v0.1 中不依赖外部输入（MQTT broker、企微 API 应用）的部分全部做完：协议类型、命令状态机与幂等/过期/暂停、SQLite 持久化、串行执行器（含 `message.send` 全链路与崩溃注入）、stdio JSON-RPC 2.0（兼容 MCP `tools/*`）与本地 Unix socket 传输、`imctld` 守护进程骨架、`imctl status`。最后对文件传输助手做一次端到端测试（经 MCP 调 `message.send`）。

**Architecture:**
- `ControlCore/Protocol/`：`RPCMethod`（枚举 + 参数/结果 Codable 类型）、`ControlEvent`、`CommandRecord`（状态机）、`PauseReason`。
- `ControlCore/Store/`：`ControlStore`（GRDB，表 `commands`/`events`/`pause_reasons`/`checkpoints`），`event_id` 自增游标，`idempotency_key` 唯一。
- `ControlCore/Executor/`：`CommandExecutor`（串行队列；受理 → 幂等查重 → 过期判定 → 暂停判定 → `CommandHandler` 执行 → 状态与事件落库）；`CommandHandler` 协议由 `WeComAdapter` 实现（`WeComCommandHandler`），测试用 fake。
- `MCPTransport/`：`JSONRPCServer`（行分隔 JSON-RPC 2.0；`initialize`/`tools/list`/`tools/call` 映射到我们的方法；也接受直接 `method: "message.send"`）、`StdioTransport`、`UnixSocketTransport`。
- `imctld`：`run`（watcher 事件 → 事件表；执行器；传输；状态文件）；`imctl status` 读状态文件。
- 崩溃注入：`IMCTL_CRASH_AFTER=submit` → keystroke 之后、confirm 之前 `exit(70)`；重启时 `running` 且有 checkpoint 的命令 → `unknown`，事件 `command.state`。

**Tech Stack:** GRDB 7.11.1（`.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")`），Foundation `FileHandle`/`DispatchIO`，Unix domain socket 用 `Network.framework`（`NWListener` with `NWEndpoint.unix`）。

## Global Constraints

- `message.send` 只对白名单目标（编译进 `WeComClient`），阶段 1 策略固定 `enter`；每键只发一次；`unknown` 终态不重试。
- 传输层不含企微语义；执行器不感知传输。
- 生产默认关闭 MCP/socket（`imctld run` 需显式 `--stdio` / `--socket`）。
- 事件是真相：每个状态变化都写 `events`；响应只是便利。

---

### Task 1: 协议类型（ControlCore/Protocol）

**Files:** `Sources/ControlCore/Protocol/RPCTypes.swift`、`Sources/ControlCore/Protocol/CommandRecord.swift`、`Sources/ControlCore/Protocol/ControlEvent.swift`；Test `Tests/ControlCoreTests/ProtocolTests.swift`

```swift
public enum RPCMethod: String, Codable, CaseIterable {
    case controllerDescribe = "controller.describe", accountStatus = "account.status"
    case conversationList = "conversation.list", conversationRead = "conversation.read"
    case messageSend = "message.send", messageHistory = "message.history"
    case commandGet = "command.get", commandCancel = "command.cancel"
    case controllerPause = "controller.pause", controllerResume = "controller.resume"
}
public struct SendParams: Codable, Equatable { public var target: String; public var text: String; public var idempotencyKey: String; public var ttlMs: Int?; public var issuedAtMs: Int? }
public struct ReadParams: Codable, Equatable { public var target: String }
public struct HistoryParams: Codable, Equatable { public var limit: Int? }
public enum CommandStateV1: String, Codable { case accepted, running, succeeded, failed, unknown, cancelled, expired }
public struct CommandRecord: Codable, Equatable { id, idempotencyKey, method, paramsJSON, state, createdMs, updatedMs, resultJSON?, errorCode?, errorMessage?, checkpointMs? ; isTerminal }
public enum PauseReason: String, Codable, CaseIterable { case api, localGuard = "local_guard", system }
public enum ControlEventKind: String, Codable { case controllerState = "controller.state", accountChanged = "account.changed", conversationActivity = "conversation.activity", messageObserved = "message.observed", commandState = "command.state" }
public struct ControlEvent: Codable, Equatable { eventId: Int64, tsMs, kind, payloadJSON }
public enum ControlError: Error, Equatable { targetNotFound, targetAmbiguous, targetMismatch, paused([PauseReason]), expired, localGuard(String), invalidParams(String), notAllowed(String), internal(String) } + code strings
```

- [ ] 测试：`RPCMethod` 往返；`CommandRecord.isTerminal`；`ControlError.code` 字符串（`TARGET_NOT_FOUND` 等）。

### Task 2: `ControlStore`（GRDB）

**Files:** `Package.swift`（GRDB 依赖，ControlCore 依赖 GRDB）、`Sources/ControlCore/Store/ControlStore.swift`；Test `Tests/ControlCoreTests/ControlStoreTests.swift`

```swift
public final class ControlStore {
    public init(path: String) throws            // ":memory:" 或文件；建表/迁移
    public func insertCommand(_ r: CommandRecord) throws -> Bool   // false = idempotencyKey 已存在
    public func command(idempotencyKey:) throws -> CommandRecord?
    public func command(id:) throws -> CommandRecord?
    public func updateCommand(id:, state:, resultJSON:?, errorCode:?, errorMessage:?, checkpointMs:?) throws
    public func runningWithCheckpoint() throws -> [CommandRecord]
    public func appendEvent(kind:, payloadJSON:) throws -> ControlEvent
    public func events(after eventId: Int64, limit: Int) throws -> [ControlEvent]
    public func setPause(_ reason: PauseReason, on: Bool) throws
    public func pauseReasons() throws -> [PauseReason]
}
```

- [ ] 测试：幂等唯一；状态更新；事件单调递增与游标；暂停集合；`runningWithCheckpoint`。

### Task 3: `CommandExecutor` + `CommandHandler`

**Files:** `Sources/ControlCore/Executor/CommandHandler.swift`、`Sources/ControlCore/Executor/CommandExecutor.swift`；Test `Tests/ControlCoreTests/CommandExecutorTests.swift`（`FakeHandler`）

```swift
public protocol CommandHandler {
    func describe() throws -> [String: String]
    func accountStatus() throws -> [String: String]
    func conversationList() throws -> [[String: String]]
    func conversationRead(target: String) throws -> [String: String]
    func messageHistory(limit: Int) throws -> [[String: String]]
    /// 执行到 submit 之后调用 `afterSubmit()`（崩溃注入点），再取证。
    func messageSend(target: String, text: String, checkpoint: () throws -> Void, afterSubmit: () -> Void) throws -> SendResult
}
public struct SendResult: Codable, Equatable { state: CommandStateV1 (succeeded/failed/unknown), evidence: String?, reason: String?, latencyMs: Int? }
public final class CommandExecutor {
    public init(store: ControlStore, handler: CommandHandler, now: () -> Int64 = …, crashAfterSubmit: Bool = false)
    public func submit(method: RPCMethod, params: Data, idempotencyKey: String?) throws -> CommandRecord   // 受理并同步执行（串行队列）
    public func recoverAfterRestart() throws -> [CommandRecord]    // running+checkpoint → unknown
}
```

规则：`message.send` 必须带 `idempotencyKey`；重复键 → 返回已有记录（不执行）；`issuedAtMs + ttlMs < now` → `expired`；暂停集合非空 → `failed PAUSED`（`command.state` 事件）；执行中先 `running` 事件；handler 抛 `ControlError` → `failed` + code；`SendResult.state` 映射终态；每次状态变化 `appendEvent(.commandState)`。

- [ ] 测试：幂等重复不执行；过期；暂停；成功链路事件序列 `accepted→running→succeeded`；`crashAfterSubmit` 用注入 `exitHook` 代替真 exit 后 `recoverAfterRestart` 把它标 `unknown` 且 handler 只被调一次。

### Task 4: `WeComCommandHandler`（WeComAdapter）

**Files:** `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`；Test `Tests/WeComAdapterTests/WeComCommandHandlerTests.swift`（fake）

- `conversationList` → `WeComReader.conversations()` 映射（title/preview/timeLabel/badge/selected）。
- `conversationRead(target)` → `WeComActions.selectConversation`（白名单策略）→ 活动标题 + 可见消息。
- `messageHistory(limit)` → 可见消息行（阶段 1 不滚动）。
- `messageSend` → select（若活动不是目标）→ compose → checkpoint 回调 → submit(`enter`) → `afterSubmit()` → confirm；映射 `SubmitOutcome` → `SendResult`。
- `accountStatus` → 窗口是否存在、活动标题、会话数（登录态粗判：无主窗口或无会话表 = `login_required` 疑似）。

### Task 5: `MCPTransport`

**Files:** `Sources/MCPTransport/JSONRPC.swift`（消息类型）、`Sources/MCPTransport/RPCDispatcher.swift`（method → executor）、`Sources/MCPTransport/StdioServer.swift`、`Sources/MCPTransport/UnixSocketServer.swift`；Test `Tests/MCPTransportTests/DispatcherTests.swift`

- 行分隔 JSON-RPC 2.0；支持 `initialize`（返回 MCP 风格 capabilities）、`tools/list`（每个 `RPCMethod` 一个 tool，带 inputSchema）、`tools/call`（`name` + `arguments`）、以及直接 `method: "message.send"`。
- 错误码：`-32601` 未知方法、`-32602` 参数、`-32000` + `data.code` 为 `ControlError.code`。
- `Package.swift` 新 target `MCPTransport`（依赖 ControlCore）。

- [ ] 测试：`tools/list` 含 10 个方法；`tools/call message.send` 走 executor（fake handler）返回 command 记录；直接方法调用等价；未知方法 `-32601`。

### Task 6: `imctld` + `imctl status`

**Files:** `Sources/imctld/main.swift`（argument-parser：`run --stdio --socket <path> --db <path> --state <path> [--watch-interval]`）、`Sources/imctl/Commands/StatusCommand.swift`；`Package.swift` 新 executable `imctld`。

- 启动：`ControlStore` → `recoverAfterRestart` → `WeComCommandHandler(live)` → executor → watcher（复用 `WatchRunner` 的 diff，事件写 `conversation.activity` / `message.observed`）→ 传输。状态文件每 5 s 写 `{pid, startedMs, lastPollMs, paused:[...], lastEventId, client:{active,title}}`。
- `imctl status`：读状态文件与 DB 概况（命令计数、最近事件）。

### Task 7: 一口气测试

1. `swift test` 全绿。
2. `imctld run --stdio`：用 `printf` 喂 `initialize`、`tools/list`、`conversation.list`、`message.send`（目标文件传输助手，文本 `imctl-b1-e2e`，幂等键 UUID），再喂同一幂等键一次 → 第二次返回同一命令且不再发送。
3. `IMCTL_CRASH_AFTER=submit imctld run --stdio` + `message.send` → 进程退出；重启 → 该命令 `unknown`，消息表只有一条。
4. 结果写 `docs/gates/2026-09-12-b1-e2e.md`。

## 执行结果（2026-09-12 01:2x）

- Task 1–7 完成：113 个测试通过；E2E 1（stdio、10 工具、send 88 ms、幂等回放）与 E2E 2（崩溃注入 → unknown、不重跑、客户端恰好一条）均通过，见 `docs/gates/2026-09-12-b1-e2e.md`。
- 偏离：watcher 只并入轮询路径；`command.get` 的幂等键误用已修。
