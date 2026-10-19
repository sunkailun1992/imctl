# B54 独立验证窗口的邀请提示与视觉轮次记录 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `contact.add` 在企业微信用户的独立「发送验证申请」窗口里有一套与截图相符的邀请提示；同时记下每一轮视觉的结果，命令因视觉结束时在命令记录里留下诊断。

**Architecture:**
- 视觉执行器与选择器在调用模型处统一生成「轮次记录」（只含固定类别），处理器写进守护进程日志，并记住本命令最后一轮。
- 处理器在每个视觉停止 / 出错的出口把结束方式记到执行器上下文；执行器按命令 ID 数越过的不可逆点，命令失败或不确定时把两者合成 `diagnosis` 写进新列，并带到记录视图与事件。
- 邀请在本命令证实的独立窗口里时，处理器换用新目标 `contactSendVerification` 与它自己的提示；结果行一轮把所选来源带进提示。

**Tech Stack:** Swift 6.3（Swift 5 语言模式），SwiftPM，swift-testing，GRDB，系统 SQLite3（只在测试里用）。

**Spec:** `docs/superpowers/specs/2026-10-13-b54-verification-invite.md`

## Global Constraints

- 版本 `IMCTLVersion.string` 为 `1.0.17-dev`。
- 日志与 `diagnosis` 只有固定类别：不记截图、模型原文、候选标签、目标会话、号码、验证语、提示词。
- 越过 checkpoint 后仍记 `unknown`，含义不变：抛错路径的错误码仍为 `UNKNOWN_AFTER_CHECKPOINT`；`desktopMutation` 路径的结果仍是原来的不确定结果。只多一个 `diagnosis`。
- 处理器各结束点抛出的错误（类型、错误码、文字）一律不变，只是在抛出前记下结束方式。
- `contactInvite` 的提示与本批之前一字不差；模型权限不变：passive 轮只能 verify / reobserve / stop，「发送」只由代码在第二个 checkpoint 之后按。
- 不新增系统权限与网络端点；`ForbiddenAPITests` 不放宽。
- 号码白名单与每小时上限照旧；真实添加每次都要用户当次授权；号码不进对话、代码与 Wiki，读命令记录时不打印 `params_json`。
- 构建与测试一律 `swift test --scratch-path <会话 scratchpad>/b54-build`，命令里写作 `$BUILD`。打包签名环境变量与 B53 相同。

## Review Focus

1. 带会话标题、联系人名或成员名的目标（`conversationRow`、`contactRow`、`requestCard`、`groupMember`）：日志行与诊断里只出现目标种类，绝不出现标题或名字。由 Task 3 的 `everyModelRequestIsReportedWithoutTitles` 覆盖。
2. 群发里一个子发送在越过 checkpoint 后因视觉结束：这个子命令的记录带自己的诊断（`irreversibleSteps` 为 1），父命令不带，下一条命令也不继承。由 Task 1 的 `aBroadcastChildKeepsItsOwnDiagnosis` 覆盖。
3. 一条命令在任何一轮模型请求之前就因视觉结束（例如开关在门检查时被关）：诊断写 `none` / 第 0 轮和错误类别，绝不用上一条命令的轮次。由 Task 4 的 `aVisualEndBeforeAnyRoundNamesNoRound` 覆盖。
4. 1.0.16 留下的数据库（没有 `diagnosis_json` 列）：守护进程照常打开并迁移，旧记录读出没有诊断，之后能写入诊断。由 Task 1 的 `aDatabaseFromBeforeB54GainsTheColumn` 覆盖。
5. 视觉结束后用同一幂等键再次请求：返回原记录和它的诊断，不重跑。由 Task 1 的 `aReplayAfterAVisualEndReturnsTheSameDiagnosis` 覆盖。

## 文件结构

| 文件 | 职责 |
|---|---|
| `Sources/ControlCore/Protocol/CommandDiagnosis.swift`（新） | 诊断结构、事件平铺字段 |
| `Sources/ControlCore/Protocol/CommandRecord.swift` | `diagnosisJSON` 列 |
| `Sources/ControlCore/Store/ControlStore.swift` | 迁移 `v4-diagnosis`、`updateCommand(diagnosisJSON:)` |
| `Sources/ControlCore/Executor/CommandHandler.swift` | `desktopCommandVisualEnd` 上下文 |
| `Sources/ControlCore/Executor/CommandExecutor.swift` | 数不可逆点、写诊断、事件字段 |
| `Sources/MCPTransport/RPCDispatcher.swift` | 记录视图带 `diagnosis` |
| `Sources/WeComAdapter/AIPlanner/AIPlannerRoundRecord.swift`（新） | 轮次记录、目标与错误的固定名字、统一上报 |
| `Sources/WeComAdapter/AIPlanner/AIPlannerReversibleRunner.swift`、`AIPlannerRoundSelector.swift` | 经统一出口请求模型；独立窗口目标；来源进上下文 |
| `Sources/WeComAdapter/AIPlanner/AIPlannerVisionClient.swift`、`AIPlannerStepDecision.swift` | 新目标、来源枚举、新提示与来源句 |
| `Sources/WeComAdapter/Handler/WeComCommandHandler.swift` | 记录轮次、标记视觉结束、选目标与来源 |
| `Sources/WeComAdapter/Contacts/AddCustomerPanel.swift`、`Actions/AddContact.swift` | 面板带所选来源 |
| `Sources/imctld/main.swift` | 日志与选择器接线 |
| `docs/protocol/im-control-protocol.md`、`AGENTS.md`、`docs/agents/skills/imctl/SKILL.md`、`Sources/ControlCore/IMCTLVersion.swift` | 文档与版本 |

---

### Task 1: 命令记录上的诊断（ControlCore）

**Files:**
- Create: `Sources/ControlCore/Protocol/CommandDiagnosis.swift`
- Modify: `Sources/ControlCore/Protocol/CommandRecord.swift`
- Modify: `Sources/ControlCore/Store/ControlStore.swift`
- Modify: `Sources/ControlCore/Executor/CommandHandler.swift`
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift`
- Test: `Tests/ControlCoreTests/CommandExecutorTests.swift`、`Tests/ControlCoreTests/ControlStoreTests.swift`

**Interfaces:**
- Produces:
  - `public struct CommandDiagnosis: Codable, Equatable, Sendable { var visual: Visual?; var irreversibleSteps: Int; var eventFields: [String: String] }`，`CommandDiagnosis.Visual(goal: String, phase: String, round: Int, outcome: String)`；
  - `CommandRecord.diagnosisJSON: String?`（列 `diagnosis_json`）；
  - `ControlStore.updateCommand(…, diagnosisJSON: String? = nil)`；
  - 协议 `DesktopCommandOriginAware` 新增 `var desktopCommandVisualEnd: CommandDiagnosis.Visual? { get set }`（扩展给出空实现）。

- [ ] **Step 1：写失败的测试**

`Tests/ControlCoreTests/ControlStoreTests.swift` 顶部 `import Foundation` 之后加 `import SQLite3`，结构体里加：

```swift
    /// B54: the diagnosis column round-trips; a record without one reads back nil.
    @Test func aDiagnosisRoundTripsAndPlainRecordsHaveNone() throws {
        let store = try ControlStore(path: ":memory:")
        let plain = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "p", nowMs: 1)
        let ended = CommandRecord(method: .contactAdd, paramsJSON: "{}", idempotencyKey: "e", nowMs: 1)
        _ = try store.insertCommand(plain)
        _ = try store.insertCommand(ended)
        try store.updateCommand(id: ended.id, state: .unknown, nowMs: 2, diagnosisJSON: #"{"irreversibleSteps":1}"#)
        #expect(try store.command(id: plain.id)?.diagnosisJSON == nil)
        #expect(try store.command(id: ended.id)?.diagnosisJSON == #"{"irreversibleSteps":1}"#)
    }

    /// Review Focus 4: a database from 1.0.16 has no diagnosis column; opening it adds the column, old records
    /// read back without a diagnosis, and new diagnoses can be written.
    @Test func aDatabaseFromBeforeB54GainsTheColumn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-b54-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "old", nowMs: 1)
        do {
            let store = try ControlStore(path: path)
            _ = try store.insertCommand(old)
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE commands DROP COLUMN diagnosis_json; DELETE FROM grdb_migrations WHERE identifier = 'v4-diagnosis';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try ControlStore(path: path)
        #expect(try store.command(id: old.id)?.diagnosisJSON == nil)
        try store.updateCommand(id: old.id, state: .unknown, nowMs: 2, diagnosisJSON: #"{"irreversibleSteps":1}"#)
        #expect(try store.command(id: old.id)?.diagnosisJSON == #"{"irreversibleSteps":1}"#)
    }
```

`Tests/ControlCoreTests/CommandExecutorTests.swift`：
- `FakeHandler` 在 `var desktopCommandIsBroadcastChild = false` 之后加：

```swift
    var desktopCommandVisualEnd: CommandDiagnosis.Visual?
    /// B54: the send ends visually — this end is set, then `sendErrorAfterCheckpoint` is thrown
    /// (or, with `visualEndBeforeCheckpoint`, a guard error before the checkpoint).
    var visualEndOnSend: CommandDiagnosis.Visual?
    var visualEndBeforeCheckpoint = false
    /// B54: contact.add crosses this many checkpoints, then ends visually.
    var contactAddVisualEnd: (checkpoints: Int, visual: CommandDiagnosis.Visual)?
```

- `FakeHandler.messageSend` 里从 `if failingTargets.contains(target) { … }` 到 `if let sendErrorAfterCheckpoint { … }` 的四行改为（其后 `failReason` 与 `return sendResult` 不变）：

```swift
        if failingTargets.contains(target) { throw ControlError.targetNotAllowed(target) }
        if let visual = visualEndOnSend, visualEndBeforeCheckpoint {
            desktopCommandVisualEnd = visual
            throw ControlError.localGuard("composer visual round stopped")
        }
        try checkpoint()
        try afterSubmit()
        if let sendErrorAfterCheckpoint {
            if let visual = visualEndOnSend { desktopCommandVisualEnd = visual }
            throw sendErrorAfterCheckpoint
        }
```

- 带 checkpoint 的 `FakeHandler.contactAdd` 改为：

```swift
    func contactAdd(phone: String, source: String, greeting: String?, dryRun: Bool,
                    checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> [String: String] {
        guard phone.hasSuffix("0000") else { throw ControlError.targetNotAllowed("phone \(ContactAddPolicy.mask(phone))") }
        if let end = contactAddVisualEnd, !dryRun {
            for _ in 0..<end.checkpoints { try checkpoint() }
            desktopCommandVisualEnd = end.visual
            throw ControlError.localGuard("contact add visual round stopped")
        }
        if !dryRun { try checkpoint(); try afterSubmit() }
        return try contactAdd(phone: phone, source: source, greeting: greeting, dryRun: dryRun)
    }
```

- 测试结构体里加：

```swift
    static func diagnosis(_ record: CommandRecord) -> CommandDiagnosis? {
        record.diagnosisJSON.flatMap { try? JSONDecoder().decode(CommandDiagnosis.self, from: Data($0.utf8)) }
    }
    static let stop = CommandDiagnosis.Visual(goal: "sendButton", phase: "commit", round: 2, outcome: "stop")

    /// B54: a visual end after the checkpoint stays `unknown` and keeps where it ended, with one irreversible point.
    @Test func aVisualEndAfterTheCheckpointIsUnknownWithItsDiagnosis() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("composer visual round stopped")
        handler.visualEndOnSend = Self.stop
        let record = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(record.state == .unknown && record.errorCode == "UNKNOWN_AFTER_CHECKPOINT")
        #expect(Self.diagnosis(record) == CommandDiagnosis(visual: Self.stop, irreversibleSteps: 1))
        let last = try #require(try store.events(after: 0, limit: 100).last { $0.kind == .commandState })
        #expect(last.payloadJSON.contains(#""visualOutcome":"stop""#) && last.payloadJSON.contains(#""irreversibleSteps":"1""#)
                && last.payloadJSON.contains(#""visualGoal":"sendButton""#))
    }

    /// A visual end before any checkpoint fails with the same diagnosis and zero irreversible points.
    @Test func aVisualEndBeforeAnyCheckpointFailsWithZeroSteps() throws {
        let (exec, handler, _) = try make(limiter: nil)
        handler.visualEndOnSend = Self.stop
        handler.visualEndBeforeCheckpoint = true
        let record = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(record.state == .failed && record.checkpointMs == nil)
        #expect(Self.diagnosis(record) == CommandDiagnosis(visual: Self.stop, irreversibleSteps: 0))
    }

    /// Ends that are not visual carry no diagnosis; successes neither; an end left on the handler from outside
    /// the executor is cleared before the next command.
    @Test func nonVisualEndsAndSuccessesCarryNoDiagnosis() throws {
        let (exec, handler, _) = try make(limiter: nil)
        let ok = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(ok.state == .succeeded && ok.diagnosisJSON == nil)
        handler.sendErrorAfterCheckpoint = .localGuard("bubble missing")
        handler.desktopCommandVisualEnd = Self.stop
        let lost = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k2"}"#, idempotencyKey: "k2")
        #expect(lost.state == .unknown && lost.diagnosisJSON == nil)
    }

    /// contact.add goes through the desktop-mutation path (no throw reaches the executor): the diagnosis counts
    /// the irreversible points crossed — 1 after the chosen result's 添加, 2 after 发送 too.
    @Test func contactAddCountsBothIrreversiblePoints() throws {
        let (exec, handler, _) = try make(limiter: nil)
        let invite = CommandDiagnosis.Visual(goal: "contactSendVerification", phase: "commit", round: 1, outcome: "stop")
        handler.contactAddVisualEnd = (1, invite)
        let one = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"wecom","idempotencyKey":"a1"}"#,
                                  idempotencyKey: "a1")
        #expect(one.state == .unknown && Self.diagnosis(one) == CommandDiagnosis(visual: invite, irreversibleSteps: 1))
        handler.contactAddVisualEnd = (2, invite)
        let two = try exec.submit(method: .contactAdd, paramsJSON: #"{"phone":"13800000000","source":"wecom","idempotencyKey":"a2"}"#,
                                  idempotencyKey: "a2")
        #expect(two.state == .unknown && Self.diagnosis(two) == CommandDiagnosis(visual: invite, irreversibleSteps: 2))
    }

    /// Review Focus 2: a broadcast child that ends visually after its checkpoint keeps its own diagnosis; the
    /// parent carries none, and the next command does not inherit the end.
    @Test func aBroadcastChildKeepsItsOwnDiagnosis() throws {
        let (exec, handler, store) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("composer visual round stopped")
        handler.visualEndOnSend = Self.stop
        let params = #"{"targets":["文件传输助手"],"text":"test","idempotencyKey":"bc","intervalMs":0}"#
        let parent = try exec.submit(method: .messageBroadcast, paramsJSON: params, idempotencyKey: "bc")
        #expect(parent.state == .unknown && parent.diagnosisJSON == nil)
        let child = try #require(try store.command(idempotencyKey: "bc#0"))
        #expect(Self.diagnosis(child) == CommandDiagnosis(visual: Self.stop, irreversibleSteps: 1))
        handler.visualEndOnSend = nil
        let next = try exec.submit(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"hi","idempotencyKey":"k9"}"#, idempotencyKey: "k9")
        #expect(next.state == .unknown && next.diagnosisJSON == nil)
    }

    /// Review Focus 5: the same key after a visual end returns the original record and its diagnosis, not a re-run.
    @Test func aReplayAfterAVisualEndReturnsTheSameDiagnosis() throws {
        let (exec, handler, _) = try make(limiter: nil)
        handler.sendErrorAfterCheckpoint = .localGuard("composer visual round stopped")
        handler.visualEndOnSend = Self.stop
        let first = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        handler.sendErrorAfterCheckpoint = nil
        handler.visualEndOnSend = nil
        let replay = try exec.submit(method: .messageSend, paramsJSON: send, idempotencyKey: "k1")
        #expect(replay.id == first.id && replay.diagnosisJSON == first.diagnosisJSON && first.diagnosisJSON != nil
                && handler.sendCalls == 1)
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter "ControlStoreTests|CommandExecutorTests"`
Expected: 编译失败（`CommandDiagnosis`、`diagnosisJSON`、`desktopCommandVisualEnd` 不存在）。

- [ ] **Step 3：实现**

`Sources/ControlCore/Protocol/CommandDiagnosis.swift`：

```swift
import Foundation

/// B54: why a command ended without success, as fixed categories only — never a title, name, phone number,
/// greeting, prompt or model text. Recorded only when a visual round ended the command.
public struct CommandDiagnosis: Codable, Equatable, Sendable {
    /// The last model round of this command and how its visual part ended. `goal` / `phase` are `none` and
    /// `round` is 0 when the command ended before its first model round.
    public struct Visual: Codable, Equatable, Sendable {
        /// A fixed goal kind such as `contactSendVerification` or `conversationRow`.
        public var goal: String
        /// prepare | locate | verify | commit …, or `none`.
        public var phase: String
        /// 1-based within its visual step; 0 when there was no round yet.
        public var round: Int
        /// `stop`, `unverified`, or a fixed vision error name such as `timeout` or `staleView`.
        public var outcome: String

        public init(goal: String, phase: String, round: Int, outcome: String) {
            self.goal = goal; self.phase = phase; self.round = round; self.outcome = outcome
        }
    }

    public var visual: Visual?
    /// Irreversible points this command crossed, each after its checkpoint was written. `contact.add`:
    /// 1 = the chosen result's 添加 was pressed, 2 = 发送 was pressed too.
    public var irreversibleSteps: Int

    public init(visual: Visual?, irreversibleSteps: Int) {
        self.visual = visual; self.irreversibleSteps = irreversibleSteps
    }

    /// Flat string fields for the `command.state` event payload.
    public var eventFields: [String: String] {
        var fields = ["irreversibleSteps": String(irreversibleSteps)]
        if let visual {
            fields["visualGoal"] = visual.goal
            fields["visualPhase"] = visual.phase
            fields["visualRound"] = String(visual.round)
            fields["visualOutcome"] = visual.outcome
        }
        return fields
    }
}
```

`CommandRecord.swift`：在 `checkpointMs` 之后加属性，并在 `CodingKeys` 末尾加 `case diagnosisJSON = "diagnosis_json"`：

```swift
    /// B54: `CommandDiagnosis` JSON when a visual round ended this command without success.
    public var diagnosisJSON: String?
```

`ControlStore.swift`：在 `v3-identities` 迁移之后、`try migrator.migrate(dbQueue)` 之前注册：

```swift
        migrator.registerMigration("v4-diagnosis") { db in
            try db.alter(table: "commands") { t in t.add(column: "diagnosis_json", .text) }
        }
```

`updateCommand` 参数表末尾（`checkpointMs: Int64? = nil` 之后）加 `, diagnosisJSON: String? = nil`，函数体在 `if let checkpointMs { … }` 之后加 `if let diagnosisJSON { record.diagnosisJSON = diagnosisJSON }`。

`CommandHandler.swift`：协议 `DesktopCommandOriginAware` 末尾加需求，并在协议之后加默认实现：

```swift
    /// B54: set by the handler when a visual round ends the running command (fixed categories only). The
    /// executor clears it before each command and records it on a failed or unknown record.
    var desktopCommandVisualEnd: CommandDiagnosis.Visual? { get set }
}

public extension DesktopCommandOriginAware {
    /// Handlers without visual rounds never end a command visually.
    var desktopCommandVisualEnd: CommandDiagnosis.Visual? {
        get { nil }
        set {}
    }
}
```

`CommandExecutor.swift`：
1. 文件末尾加计数类：

```swift
/// B54: irreversible points each running command crossed; a broadcast's children are counted apart.
final class IrreversibleCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ id: String) { lock.lock(); counts[id, default: 0] += 1; lock.unlock() }
    func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id] ?? 0 }
    func remove(_ id: String) { lock.lock(); counts[id] = nil; lock.unlock() }
}
```

2. 类里（`contactAddsPerHour` 附近）加属性与两个私有方法：

```swift
    /// B54: irreversible points crossed per running command.
    private let irreversible = IrreversibleCounts()

    /// One more irreversible point of this command: its checkpoint goes to disk first, then it is counted.
    private func crossCheckpoint(_ id: String) throws {
        try store.updateCommand(id: id, state: .running, nowMs: now(), checkpointMs: now())
        irreversible.add(id)
    }

    /// B54: the record's diagnosis when a visual round ended the command; nil otherwise.
    private func diagnosisJSON(_ id: String, _ visual: CommandDiagnosis.Visual?) -> String? {
        guard let visual else { return nil }
        return try? encode(CommandDiagnosis(visual: visual, irreversibleSteps: irreversible.count(id)))
    }
```

3. 下列 5 处 `try self.store.updateCommand(id: record.id, state: .running, nowMs: self.now(), checkpointMs: self.now())` 换成 `try self.crossCheckpoint(record.id)`（`broadcast()` 里父命令那处 `try store.updateCommand(id: record.id, …)` 不是桌面不可逆点，保持不变）：
   - `broadcastConfirm` 的 `checkpoint` 闭包（其后 `crossed = true` 保留）；
   - `groupAddMembers`、`messageSend`、`messageSendFile` 三处 `checkpoint: { … }`；
   - `desktopMutation` 的 `checkpoint` 闭包（其后 `crossed = true` 保留）。
4. `run(...)` 里从 `record = try transition(record.id, to: .running)` 到函数结尾的 `do / catch` 改为：

```swift
        record = try transition(record.id, to: .running)
        defer { irreversible.remove(record.id) }
        // B54: where a visual round ended this command — read inside the defer below, before the context is
        // restored (the catch blocks run after it).
        var visualEnd: CommandDiagnosis.Visual?
        do {
            let aware = handler as? any DesktopCommandOriginAware
            let previousOrigin = aware?.desktopCommandOrigin
            let previousMethod = aware?.desktopCommandMethod
            let previousBroadcastChild = aware?.desktopCommandIsBroadcastChild
            let previousVisualEnd = aware?.desktopCommandVisualEnd
            aware?.desktopCommandOrigin = origin
            aware?.desktopCommandMethod = method
            aware?.desktopCommandIsBroadcastChild = isBroadcastChild
            aware?.desktopCommandVisualEnd = nil
            defer {
                visualEnd = aware?.desktopCommandVisualEnd
                if let previousOrigin { aware?.desktopCommandOrigin = previousOrigin }
                aware?.desktopCommandMethod = previousMethod
                if let previousBroadcastChild { aware?.desktopCommandIsBroadcastChild = previousBroadcastChild }
                aware?.desktopCommandVisualEnd = previousVisualEnd
            }
            let (state, resultJSON) = try execute(method: method, record: record, paramsJSON: paramsJSON)
            // A handler-reported failure (a send without its bubble) carries its reason in the result; surface it on the record too.
            return try transition(record.id, to: state, resultJSON: resultJSON,
                                  errorMessage: state == .failed ? Self.failureReason(in: resultJSON) : nil,
                                  diagnosisJSON: state == .failed || state == .unknown
                                    ? diagnosisJSON(record.id, aware?.desktopCommandVisualEnd) : nil)
        } catch let error as ControlError {
            let diagnosis = diagnosisJSON(record.id, visualEnd)
            if try store.command(id: record.id)?.checkpointMs != nil {
                return try transition(record.id, to: .unknown, errorCode: "UNKNOWN_AFTER_CHECKPOINT",
                                      errorMessage: "desktop action may have completed but could not be verified",
                                      diagnosisJSON: diagnosis)
            }
            return try transition(record.id, to: .failed, errorCode: error.code, errorMessage: error.message,
                                  diagnosisJSON: diagnosis)
        } catch let error as CrashInjected {
            throw error
        } catch {
            let diagnosis = diagnosisJSON(record.id, visualEnd)
            if try store.command(id: record.id)?.checkpointMs != nil {
                return try transition(record.id, to: .unknown, errorCode: "UNKNOWN_AFTER_CHECKPOINT",
                                      errorMessage: "desktop action may have completed but could not be verified",
                                      diagnosisJSON: diagnosis)
            }
            return try transition(record.id, to: .failed, errorCode: "INTERNAL", errorMessage: String(describing: error),
                                  diagnosisJSON: diagnosis)
        }
```

5. `transition` 与 `emitState`（保留 `@discardableResult`）：

```swift
    @discardableResult
    private func transition(_ id: String, to state: CommandStateV1, resultJSON: String? = nil, errorCode: String? = nil,
                            errorMessage: String? = nil, diagnosisJSON: String? = nil) throws -> CommandRecord {
        try store.updateCommand(id: id, state: state, nowMs: now(), resultJSON: resultJSON, errorCode: errorCode,
                                errorMessage: errorMessage, diagnosisJSON: diagnosisJSON)
        guard let record = try store.command(id: id) else { throw ControlError.internalError("command vanished") }
        try emitState(record)
        return record
    }

    private func emitState(_ record: CommandRecord, extra: [String: String] = [:]) throws {
        var payload: [String: String] = ["commandId": record.id, "state": record.state.rawValue, "method": record.method]
        payload.merge(extra) { current, _ in current }
        if let k = record.idempotencyKey { payload["idempotencyKey"] = k }
        if let c = record.errorCode { payload["errorCode"] = c }
        if let d = record.diagnosisJSON,
           let diagnosis = try? JSONDecoder().decode(CommandDiagnosis.self, from: Data(d.utf8)) {
            payload.merge(diagnosis.eventFields) { current, _ in current }
        }
        try store.appendEvent(kind: .commandState, payloadJSON: try encode(payload), nowMs: now())
    }
```

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "ControlStoreTests|CommandExecutorTests"`
Expected: 全部 PASS（新加 8 条）。

- [ ] **Step 5：提交**

```bash
git add Sources/ControlCore Tests/ControlCoreTests
git commit -m "feat(executor): a visual end and the irreversible points crossed go on the command record as its diagnosis" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: 记录视图带 `diagnosis`（MCPTransport）

**Files:**
- Modify: `Sources/MCPTransport/RPCDispatcher.swift`（`recordJSON`）
- Test: `Tests/MCPTransportTests/DispatcherTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `CommandRecord.diagnosisJSON`。
- Produces: 记录视图（`message.send` 等的 `result`、MCP 文本、MQTT 回复）在有诊断时带 `"diagnosis": {…}`。

- [ ] **Step 1：写失败的测试**（加在 `DispatcherTests` 结构体里）

```swift
    /// B54: the record view carries the diagnosis as an object, and nothing when there is none.
    @Test func theRecordViewCarriesTheDiagnosis() throws {
        var record = CommandRecord(method: .contactAdd, paramsJSON: "{}", idempotencyKey: "a", nowMs: 1)
        #expect(RPCDispatcher.recordJSON(record).objectValue?["diagnosis"] == nil)
        record.diagnosisJSON = #"{"visual":{"goal":"contactSendVerification","phase":"commit","round":1,"outcome":"stop"},"irreversibleSteps":1}"#
        let diagnosis = try #require(RPCDispatcher.recordJSON(record).objectValue?["diagnosis"]?.objectValue)
        #expect(diagnosis["irreversibleSteps"] == .number(1))
        #expect(diagnosis["visual"]?.objectValue?["outcome"] == .string("stop"))
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter DispatcherTests`
Expected: FAIL（`diagnosis` 为 nil）。

- [ ] **Step 3：实现**（`recordJSON` 里 `checkpointMs` 那行之后加）

```swift
        if let d = r.diagnosisJSON, let v = try? JSONValue.parse(d) { o["diagnosis"] = v }
```

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter DispatcherTests`
Expected: PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/MCPTransport/RPCDispatcher.swift Tests/MCPTransportTests/DispatcherTests.swift
git commit -m "feat(rpc): the command record view carries its diagnosis" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: 每一轮的记录（视觉执行器与选择器）

**Files:**
- Create: `Sources/WeComAdapter/AIPlanner/AIPlannerRoundRecord.swift`
- Modify: `Sources/WeComAdapter/AIPlanner/AIPlannerReversibleRunner.swift`
- Modify: `Sources/WeComAdapter/AIPlanner/AIPlannerRoundSelector.swift`
- Test: `Tests/WeComAdapterTests/AIPlannerReversibleRunnerTests.swift`、`Tests/WeComAdapterTests/AIPlannerRoundSelectorTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `CommandDiagnosis.Visual`。
- Produces:
  - `public struct AIPlannerRoundRecord: Equatable`（`method`、`goal: String`、`phase`、`round: Int`、`outcome: String`、`latencyMs: Int`、`line`、`ended(_:) -> CommandDiagnosis.Visual`）；
  - `AIPlannerGoal.logName`、`AIPlannerVisionError.logName`、`AIPlannerReversibleOutcome.logName`；
  - `AIPlannerReversibleRunner.roundSink` 与 `AIPlannerRoundSelector.roundSink`：`((AIPlannerRoundRecord) -> Void)?`。

- [ ] **Step 1：写失败的测试**

`AIPlannerReversibleRunnerTests` 里加（复用文件里的 `fixture()`、`round(window:table:)`、`capture()`）：

```swift
    /// Review Focus 1 / B54: every model request is reported once, numbered, with the goal's kind only —
    /// the conversation title never reaches a record or its log line.
    @Test func everyModelRequestIsReportedWithoutTitles() throws {
        let (fake, window, table, status) = try Self.fixture()
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(status.handle, attribute: AXAttribute.value, to: .string("测试会话"))
        }
        var calls = 0
        var records: [AIPlannerRoundRecord] = []
        var runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in
                calls += 1
                return calls == 1 ? AIPlannerStepDecision(step: .reobserve, candidateID: nil)
                                  : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
            })
        runner.roundSink = { records.append($0) }
        _ = try runner.run(method: .conversationRead, gate: {},
                           observe: { try Self.round(window: window, table: table) },
                           apply: { _, row in try table.setAttribute(AXAttribute.selectedRows, to: .elements([row.handle])) },
                           verify: { try status.valueString() == "测试会话" })
        #expect(records.map(\.round) == [1, 2] && records.map(\.outcome) == ["reobserve", "selectRow"])
        #expect(records.allSatisfy { $0.goal == "conversationRow" && $0.phase == .locate && $0.method == .conversationRead && $0.latencyMs >= 0 })
        #expect(records.allSatisfy { !$0.line.contains("测试会话") })
        #expect(records[0].line == "vision round conversation.read conversationRow/locate #1 → reobserve (\(records[0].latencyMs) ms)")
    }

    /// A failed model request is reported by its fixed error name and still thrown.
    @Test func aFailedModelRequestIsReportedByItsErrorName() throws {
        let (_, window, table, status) = try Self.fixture()
        var records: [AIPlannerRoundRecord] = []
        var runner = AIPlannerReversibleRunner(
            beforeRound: {},
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: Self.capture(),
            decide: { _, _, _ in throw AIPlannerVisionError.timeout })
        runner.roundSink = { records.append($0) }
        #expect(throws: AIPlannerVisionError.timeout) {
            _ = try runner.run(method: .conversationRead, gate: {},
                               observe: { try Self.round(window: window, table: table) },
                               apply: { _, _ in }, verify: { try status.valueString() == "测试会话" })
        }
        #expect(records.map(\.outcome) == ["timeout"] && records.first?.round == 1)
    }

    @Test func fixedNamesForGoalsErrorsAndOutcomes() {
        #expect(AIPlannerGoal.conversationRow(title: "13800000000").logName == "conversationRow")
        #expect(AIPlannerGoal.groupMember(name: "张三").logName == "groupMember")
        #expect(AIPlannerGoal.control(.contactMatch).logName == "contactMatch")
        #expect(AIPlannerVisionError.staleView.logName == "staleView")
        #expect(AIPlannerReversibleOutcome.stopped.logName == "stop")
        #expect(AIPlannerReversibleOutcome.unverified.logName == "unverified")
        let record = AIPlannerRoundRecord(method: .contactAdd, goal: "contactMatch", phase: .verify, round: 2, outcome: "stop", latencyMs: 9)
        #expect(record.ended("stop") == CommandDiagnosis.Visual(goal: "contactMatch", phase: "verify", round: 2, outcome: "stop"))
    }
```

`AIPlannerRoundSelectorTests` 里加：

```swift
    /// B54: the selector reports its model request like the runner does.
    @Test func aSelectorRoundIsReported() throws {
        let (_, window, button) = try Self.fixture()
        var records: [AIPlannerRoundRecord] = []
        var selector = AIPlannerRoundSelector(
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            observe: { window, pid, title, kinds, handles in
                try AIPlannerObservation.capture(window: window, expectedPID: pid,
                                                 expectedTitle: title, allowedKinds: kinds,
                                                 eligibleHandles: handles,
                                                 capture: { _, _ in AIPlannerObservationTests.shot() })
            },
            decide: { _, _, _ in AIPlannerStepDecision(step: .stop, candidateID: nil) }
        )
        selector.roundSink = { records.append($0) }
        #expect(try Self.select(selector, window: window, eligible: button) == nil)
        #expect(records.count == 1 && records[0].outcome == "stop" && records[0].round == 1
                && records[0].goal == "sendButton" && records[0].method == .messageSend)
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter "AIPlannerReversibleRunnerTests|AIPlannerRoundSelectorTests"`
Expected: 编译失败（`AIPlannerRoundRecord`、`roundSink`、`logName` 不存在）。

- [ ] **Step 3：实现**

`Sources/WeComAdapter/AIPlanner/AIPlannerRoundRecord.swift`：

```swift
import ControlCore
import Foundation

/// B54: one model request inside an explicit visual command, as fixed categories only. No image, prompt,
/// model text, candidate label, title, name, phone number or greeting is kept.
public struct AIPlannerRoundRecord: Equatable {
    public let method: RPCMethod
    /// `AIPlannerGoal.logName`: the goal's kind, never its title or name.
    public let goal: String
    public let phase: AIPlannerPhase
    /// 1-based within one visual step (one runner or selector).
    public let round: Int
    /// The model's step (`verify`, `reobserve`, `stop`, `selectRow`, …) or a fixed error name.
    public let outcome: String
    public let latencyMs: Int

    public init(method: RPCMethod, goal: String, phase: AIPlannerPhase, round: Int, outcome: String, latencyMs: Int) {
        self.method = method; self.goal = goal; self.phase = phase
        self.round = round; self.outcome = outcome; self.latencyMs = latencyMs
    }

    /// The daemon log line.
    public var line: String {
        "vision round \(method.rawValue) \(goal)/\(phase.rawValue) #\(round) → \(outcome) (\(latencyMs) ms)"
    }

    /// This round as the command record's view of how the visual part ended.
    public func ended(_ outcome: String) -> CommandDiagnosis.Visual {
        CommandDiagnosis.Visual(goal: goal, phase: phase.rawValue, round: round, outcome: outcome)
    }
}

extension AIPlannerGoal {
    /// The goal's kind for logs and diagnoses: titles and names are never included.
    public var logName: String {
        switch self {
        case .conversationRow: "conversationRow"
        case .contactRow: "contactRow"
        case .requestCard: "requestCard"
        case .groupMember: "groupMember"
        case .historyScrollBar: "historyScrollBar"
        case .pickerContactsScrollBar: "pickerContactsScrollBar"
        case .control(let purpose): purpose.rawValue
        }
    }
}

extension AIPlannerVisionError {
    /// The case name (`timeout`, `staleView`, …): no case carries a value, so it is fixed and content-free.
    public var logName: String { String(describing: self) }
}

extension AIPlannerReversibleOutcome {
    public var logName: String {
        switch self {
        case .verified: "verify"
        case .stopped: "stop"
        case .unverified: "unverified"
        }
    }
}

/// B54: model requests of one runner or selector, numbered from 1.
final class AIPlannerRoundCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// B54: runs one model request and reports it to `sink` as a fixed-category record; never retries.
func recordedDecision(_ context: AIPlannerStepContext, round: Int, now: () -> TimeInterval,
                      sink: ((AIPlannerRoundRecord) -> Void)?,
                      _ decide: () throws -> AIPlannerStepDecision) throws -> AIPlannerStepDecision {
    let started = now()
    func report(_ outcome: String) {
        let elapsed = now() - started
        let ms = elapsed.isFinite ? max(0, Int((elapsed * 1000).rounded())) : 0
        sink?(AIPlannerRoundRecord(method: context.method, goal: context.goal.logName, phase: context.phase,
                                   round: round, outcome: outcome, latencyMs: ms))
    }
    do {
        let decision = try decide()
        report(decision.step.rawValue)
        return decision
    } catch let error as AIPlannerVisionError {
        report(error.logName)
        throw error
    } catch {
        report("error")
        throw error
    }
}
```

`AIPlannerReversibleRunner`：
1. 属性区（`private let now` 之后）加：

```swift
    /// B54: one fixed-category record per model request; the handler logs it and keeps the last.
    public var roundSink: ((AIPlannerRoundRecord) -> Void)?
    private let rounds = AIPlannerRoundCounter()
```

2. 文件里 7 处 `let decision = try decide(observation, context, settings)` 全部换成：

```swift
            let decision = try recordedDecision(context, round: rounds.next(), now: now, sink: roundSink) {
                try decide(observation, context, settings)
            }
```

`AIPlannerRoundSelector` 同样在 `private let now` 之后加这两个属性，并把唯一一处 `let decision = try decide(observation, context, settings)` 换成同样的写法。

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter "AIPlannerReversibleRunnerTests|AIPlannerRoundSelectorTests"`
Expected: 全部 PASS。

- [ ] **Step 5：提交**

```bash
git add Sources/WeComAdapter/AIPlanner Tests/WeComAdapterTests/AIPlannerReversibleRunnerTests.swift Tests/WeComAdapterTests/AIPlannerRoundSelectorTests.swift
git commit -m "feat(vision): every model request becomes a fixed-category round record" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: 处理器接线——日志、视觉结束点、守护进程

**Files:**
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`
- Modify: `Sources/imctld/main.swift`
- Test: `Tests/WeComAdapterTests/AIPlannerHandlerSafetyTests.swift`、`Tests/WeComAdapterTests/AIPlannerAddCustomerHeaderIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `desktopCommandVisualEnd`、`CommandDiagnosis.Visual`；Task 3 的 `AIPlannerRoundRecord`、`roundSink`、`logName`。
- Produces（Task 5 与守护进程使用）：
  - `public var desktopCommandVisualEnd: CommandDiagnosis.Visual?`、`public var visualRoundLog: ((String) -> Void)?`、`public func noteVisualRound(_:)`；
  - `func recording(_:) -> AIPlannerReversibleRunner`、`func markVisualEnd(_ outcome: String)`、`func visualEnded(_ message: String, outcome: String) -> ActionError`。
- 结束点的现状（共 17 处结果判断 + 22 处视觉错误捕获 + 13 处执行器调用）：
  - 7 处 `guard result.outcome == .verified else {`：5 处随后抛 `ActionError.actionUnavailable("… visual round stopped")`；2 处（群发确认、联系人接受）随后抛 `AIPlannerVisionError.invalidChoice`，再被外层捕获转成 `actionUnavailable("…: invalidChoice")`；
  - 6 处 `case .stopped…`：2 处同行抛出、2 处下一行抛出、2 处是 `case .stopped, .unverified:`；
  - 4 处 `case .unverified…`：抛 `targetMismatch` 或 `verifyFailed`，其中 1 处同行；
  - 22 处 `catch let error as AIPlannerVisionError {`，下一行都是 `throw ActionError.actionUnavailable("…: \(error)")`；
  - 13 处 `try runner.`；
  - 选择器的停止与出错不经过这些出口：`WeComActions.visualChoice` 把它们一律转成 `actionUnavailable(purpose)`，所以在处理器的 `a.visualSelect` 包装里记；漏到 `mapErrors` 的视觉错误（如入口守卫抛的 `disabled`）在那里兜底。

  闭包里调用处理器方法须写 `self.`，所以改写一律用 `self.`。

- [ ] **Step 1：写失败的测试**

`AIPlannerHandlerSafetyTests` 里加源码扫描测试：

```swift
    /// B54: every visual stop or vision error that ends a handler command notes where it ended, and every
    /// runner reports its rounds. The counts pin today's sites: a new site must take the same path.
    @Test func everyVisualEndInTheHandlerIsRecorded() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/WeComAdapter/Handler/WeComCommandHandler.swift")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        // The line itself and the next non-blank line.
        func site(_ i: Int) -> String {
            lines[i] + "\n" + (lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "")
        }
        var catches = 0, outcomes = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.contains(" as AIPlannerVisionError {") {
                catches += 1
                #expect(site(i).contains("visualEnded(") || site(i).contains("markVisualEnd("), "line \(i + 1)")
            } else if trimmed.hasPrefix("case .stopped") || trimmed.hasPrefix("case .unverified")
                        || line.contains("outcome == .verified else {") {
                outcomes += 1
                #expect(site(i).contains("visualEnded(") || site(i).contains("markVisualEnd("), "line \(i + 1)")
            }
        }
        // 22 rethrows + the selector wrapper + mapErrors; 7 guards + 6 stopped + 4 unverified.
        #expect(catches == 24 && outcomes == 17)
        #expect(!lines.contains { $0.contains("try runner.") })
        #expect(lines.filter { $0.contains("try self.recording(runner).") }.count == 13)
    }
```

`AIPlannerAddCustomerHeaderIntegrationTests` 里加三条：

```swift
    /// B54: a model stop at the invite records where it stopped, and each round reaches the log as fixed
    /// categories only — no phone number.
    @Test func aStopAtTheInviteRecordsWhereItStopped() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  let panel = box.panelHandle,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            _ = box.fake.appendChild(to: panel, node: AXNode(
                role: AXRole.button, title: "发送添加邀请",
                frame: CGRect(x: 884, y: 702, width: 222, height: 40),
                actions: [AXAction.press]))
        }
        var lines: [String] = []
        box.handler.visualRoundLog = { lines.append($0) }
        Self.installRunner(box, passive: { context in
            if case .control(.contactInvite) = context.goal { return .init(step: .stop, candidateID: nil) }
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "contactInvite", phase: "commit", round: 1, outcome: "stop"))
        #expect(lines.count == 3 && lines.last?.contains("contact.add contactInvite/commit #1 → stop") == true)
        #expect(!lines.contains { $0.contains(Self.phone) })
    }

    /// Review Focus 3: a command whose visual part ends before any model round names no round — never one left
    /// over from an earlier command.
    @Test func aVisualEndBeforeAnyRoundNamesNoRound() throws {
        let box = try Box(ambiguous: false)
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactAdd, goal: "contactMatch", phase: .verify,
                                                         round: 1, outcome: "verify", latencyMs: 5))
        box.handler.desktopCommandVisualEnd = nil  // what the executor does before each command
        box.handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { throw AIPlannerVisionError.disabled },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: { _, frame in Self.shot(frame) },
                decide: { _, _, _ in Issue.record("no model request expected"); return .init(step: .stop, candidateID: nil) })
        }
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: true,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "none", phase: "none", round: 0, outcome: "disabled"))
    }

    /// A stop the handler then rethrows as a vision error keeps the stop; a new round lets the next end replace it.
    @Test func theFirstEndAfterARoundStands() throws {
        let box = try Box(ambiguous: false)
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactRequestAccept, goal: "requestAcceptButton",
                                                         phase: .commit, round: 1, outcome: "stop", latencyMs: 5))
        box.handler.markVisualEnd("stop")
        box.handler.markVisualEnd("invalidChoice")
        #expect(box.handler.desktopCommandVisualEnd?.outcome == "stop")
        box.handler.noteVisualRound(AIPlannerRoundRecord(method: .contactRequestAccept, goal: "requestAcceptButton",
                                                         phase: .commit, round: 2, outcome: "verify", latencyMs: 5))
        box.handler.markVisualEnd("timeout")
        #expect(box.handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "requestAcceptButton", phase: "commit", round: 2, outcome: "timeout"))
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter "AIPlannerHandlerSafetyTests|AIPlannerAddCustomerHeaderIntegrationTests"`
Expected: 编译失败（`visualRoundLog`、`noteVisualRound`、`markVisualEnd` 不存在）。

- [ ] **Step 3：实现**

1. 处理器在 `public var desktopCommandIsBroadcastChild = false` 之后加：

```swift
    /// B54: where a visual round ended the running command. The executor clears it before each command, and
    /// the rounds go with it: a new command never reports an earlier command's round.
    public var desktopCommandVisualEnd: CommandDiagnosis.Visual? {
        didSet {
            if desktopCommandVisualEnd == nil { lastVisualRound = nil; visualEndNoted = false }
        }
    }
    /// B54: one fixed-category line per model request; the daemon passes its log.
    public var visualRoundLog: ((String) -> Void)?
    /// B54: the last model round of the running command.
    private var lastVisualRound: AIPlannerRoundRecord?
    /// B54: an end was noted after the last round — a stop the handler then rethrows as a vision error keeps
    /// the stop.
    private var visualEndNoted = false

    /// B54: the rounds of every runner and of the selector come here.
    public func noteVisualRound(_ record: AIPlannerRoundRecord) {
        lastVisualRound = record
        visualEndNoted = false
        visualRoundLog?(record.line)
    }

    /// B54: this runner reports its rounds to the handler.
    func recording(_ runner: AIPlannerReversibleRunner) -> AIPlannerReversibleRunner {
        var runner = runner
        runner.roundSink = { [weak self] in self?.noteVisualRound($0) }
        return runner
    }

    /// B54: the visual part of this command ended with `outcome` after its last round (or before any round).
    /// The first end after a round stands.
    func markVisualEnd(_ outcome: String) {
        guard !visualEndNoted else { return }
        desktopCommandVisualEnd = lastVisualRound?.ended(outcome)
            ?? CommandDiagnosis.Visual(goal: "none", phase: "none", round: 0, outcome: outcome)
        visualEndNoted = true
    }

    /// B54: a visual round ended this command: note where, then fail exactly as before.
    func visualEnded(_ message: String, outcome: String) -> ActionError {
        markVisualEnd(outcome)
        return ActionError.actionUnavailable(message)
    }
```

2. 在仓库根运行改写脚本（先于下一步的手工改动，否则选择器包装里的新 `catch` 也会被脚本匹配）：

```bash
python3 - <<'EOF'
p = 'Sources/WeComAdapter/Handler/WeComCommandHandler.swift'
lines = open(p, encoding='utf-8').read().split('\n')

def nxt(i):
    j = i + 1
    while not lines[j].strip():
        j += 1
    return j

def ind(s):
    return s[:len(s) - len(s.lstrip())]

def ended(line, outcome):
    # throw ActionError.actionUnavailable("…") → throw self.visualEnded("…", outcome: …)
    assert 'throw ActionError.actionUnavailable(' in line and line.rstrip().endswith(')'), line
    line = line.replace('throw ActionError.actionUnavailable(', 'throw self.visualEnded(', 1).rstrip()
    return line[:-1] + ', outcome: ' + outcome + ')'

counts = {}
def hit(rule):
    counts[rule] = counts.get(rule, 0) + 1

edits = []
for i, line in enumerate(lines):
    t = line.strip()
    if t == 'catch let error as AIPlannerVisionError {':
        j = nxt(i); edits.append((j, [ended(lines[j], 'error.logName')])); hit('catch')
    elif t == 'guard result.outcome == .verified else {':
        j = nxt(i)
        if lines[j].strip() == 'throw AIPlannerVisionError.invalidChoice':
            edits.append((j, [ind(lines[j]) + 'self.markVisualEnd(result.outcome.logName)', lines[j]])); hit('guard-mark')
        else:
            edits.append((j, [ended(lines[j], 'result.outcome.logName')])); hit('guard-throw')
    elif t.startswith('case .stopped: throw '):
        edits.append((i, [ended(line, '"stop"')])); hit('stopped-inline')
    elif t == 'case .stopped:':
        j = nxt(i); edits.append((j, [ended(lines[j], '"stop"')])); hit('stopped')
    elif t == 'case .unverified:':
        j = nxt(i); edits.append((j, [ind(lines[j]) + 'self.markVisualEnd("unverified")', lines[j]])); hit('unverified')
    elif t.startswith('case .unverified: throw '):
        body = ind(line) + '    '
        edits.append((i, [ind(line) + 'case .unverified:', body + 'self.markVisualEnd("unverified")',
                          body + t[len('case .unverified: '):]])); hit('unverified-inline')
    elif t == 'case .stopped, .unverified:':
        j = nxt(i); edits.append((j, [ended(lines[j], 'outcome.logName')])); hit('either')
for i, line in enumerate(lines):
    if 'try runner.' in line:
        edits.append((i, [line.replace('try runner.', 'try self.recording(runner).')])); hit('runner')
assert len({i for i, _ in edits}) == len(edits), 'two rules touched one line'
for i, new in sorted(edits, reverse=True):
    lines[i:i + 1] = new
open(p, 'w', encoding='utf-8').write('\n'.join(lines))
print(sorted(counts.items()))
EOF
```

Expected 输出：`[('catch', 22), ('either', 2), ('guard-mark', 2), ('guard-throw', 5), ('runner', 13), ('stopped', 2), ('stopped-inline', 2), ('unverified', 3), ('unverified-inline', 1)]`。数目不符就停下逐处核对，不改脚本凑数。

3. 手工改两处：
   - `a.visualSelect = { [weak self] … }`（选择器包装）改为：

```swift
            a.visualSelect = { [weak self] window, goal, kinds, expectedTitle, eligible, gate in
                guard let self, self.desktopCommandMethod == owningMethod else { throw AIPlannerVisionError.disabled }
                // B54: the action turns a stop or a vision error here into its own error; note where it ended.
                do {
                    let chosen = try select(window, goal, kinds, expectedTitle, eligible, gate)
                    if chosen == nil { self.markVisualEnd("stop") }
                    return chosen
                } catch let error as AIPlannerVisionError {
                    self.markVisualEnd(error.logName)
                    throw error
                }
            }
```

   - `mapErrors` 在 `catch let e as ControlError { throw e }` 之后加一支（映射与原先的兜底 `catch` 相同）：

```swift
        catch let e as AIPlannerVisionError {
            // B54: a vision error that reaches here ended the command visually; it maps as before.
            markVisualEnd(e.logName)
            throw ControlError.internalError(String(describing: e))
        }
```

4. `Sources/imctld/main.swift`：
   - `handler.visualSelect = { [weak handler] … }` 之前加 `handler.visualRoundLog = log.info`；
   - 闭包里 `let selector = AIPlannerRoundSelector(` 改为 `var selector = AIPlannerRoundSelector(`，构造之后、`return try selector.select(` 之前加 `selector.roundSink = { handler.noteVisualRound($0) }`。

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter WeComAdapterTests`
Expected: 全部 PASS（原有视觉集成测试的错误码与文字不变）。再跑 `swift build --scratch-path $BUILD` 确认 `imctld` 编译通过。

- [ ] **Step 5：提交**

```bash
git add Sources/WeComAdapter/Handler/WeComCommandHandler.swift Sources/imctld/main.swift Tests/WeComAdapterTests
git commit -m "feat(handler): log every visual round and note where a visual round ended the command" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: 独立窗口的目标与提示、结果行写明来源

**Files:**
- Modify: `Sources/WeComAdapter/AIPlanner/AIPlannerVisionClient.swift`（新目标、来源枚举）
- Modify: `Sources/WeComAdapter/AIPlanner/AIPlannerReversibleRunner.swift`（`AIPlannerReversibleRound.contactSource`、`observeContactAdd`）
- Modify: `Sources/WeComAdapter/AIPlanner/AIPlannerStepDecision.swift`（`AIPlannerStepContext.contactSource`、新提示、来源句）
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift`（选目标、带来源）
- Modify: `Sources/WeComAdapter/Contacts/AddCustomerPanel.swift`、`Sources/WeComAdapter/Actions/AddContact.swift`
- Test: `Tests/WeComAdapterTests/AIPlannerStepDecisionTests.swift`、`Tests/WeComAdapterTests/AIPlannerAddCustomerHeaderIntegrationTests.swift`

**Interfaces:**
- Consumes: Task 4 的处理器（`recording`、`visualEnded` 已就位）。
- Produces:
  - `AIPlannerControlPurpose.contactSendVerification`；
  - `public enum AIPlannerContactSource: String { case wechat, wecom }`（`promptName`）；
  - `AIPlannerReversibleRound(…, contactSource: AIPlannerContactSource? = nil)`；
  - `AIPlannerStepContext(…, contactSource: AIPlannerContactSource? = nil)`（只允许配 `contactMatch` 目标）；
  - `AddCustomerPanel.chosenSource: String?` 与 `choosing(_:)`。

- [ ] **Step 1：写失败的测试**

`AIPlannerStepDecisionTests` 里加：

```swift
    static func prompt(goal: AIPlannerGoal, phase: AIPlannerPhase, evidence: AIPlannerEvidence,
                       source: AIPlannerContactSource? = nil) throws -> String {
        let (_, _, observation) = try Self.fixture()
        let context = try AIPlannerStepContext(method: .contactAdd, allowedSteps: [.verify, .reobserve, .stop],
                                               phase: phase, lastEvidence: evidence, goal: goal, contactSource: source)
        var prompt = ""
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            prompt = try #require(parts.first?["text"] as? String)
            return (Self.body("{\"step\":\"verify\"}"), Self.http(request))
        }
        _ = try client.decide(observation: observation, context: context, settings: AIPlannerVisionClientTests.settings())
        return prompt
    }

    /// B54: the standalone 发送验证申请 window has a prompt that matches what its image shows.
    @Test func theSendVerificationPromptMatchesItsStandaloneWindow() throws {
        let prompt = try Self.prompt(goal: .control(.contactSendVerification), phase: .commit, evidence: .pendingConfirmation)
        #expect(prompt.contains("standalone Send Verification Request window"))
        #expect(prompt.contains("This image shows only that window") && prompt.contains("are not needed"))
        #expect(prompt.contains("already a customer") && prompt.contains("cannot press it"))
        #expect(!prompt.contains("another dialog") && !prompt.contains("title match"))
    }

    /// The in-panel invite keeps its prompt word for word.
    @Test func theInPanelInvitePromptIsUnchanged() throws {
        let prompt = try Self.prompt(goal: .control(.contactInvite), phase: .commit, evidence: .pendingConfirmation)
        #expect(prompt.contains("A single offered candidate by itself is not proof of a title match. If its AX title has not been confirmed, use the image to distinguish the fixed target; stop if it remains ambiguous."))
        #expect(prompt.contains("The caller has independently proved one invitation confirmation tied to this command's chosen result and checked its fixed greeting. The offered button is an image anchor only. Choose verify if the image is consistent with that one invitation; you cannot press it, edit text, or claim that an invitation was sent. Stop if another dialog or multiple plausible confirmations appear."))
    }

    /// The result-row prompt names the chosen source when the caller gives one.
    @Test func theMatchPromptNamesTheChosenSource() throws {
        let wecom = try Self.prompt(goal: .control(.contactMatch), phase: .verify, evidence: .postconditionPresent, source: .wecom)
        #expect(wecom.contains("chosen result is the WeCom (企业微信) result"))
        let plain = try Self.prompt(goal: .control(.contactMatch), phase: .verify, evidence: .postconditionPresent)
        #expect(!plain.contains("chosen result is the"))
    }

    @Test func aContactSourceGoesOnlyWithTheMatchGoal() {
        #expect(throws: AIPlannerVisionError.invalidGoal) {
            try AIPlannerStepContext(method: .contactAdd, allowedSteps: [.verify, .reobserve, .stop], phase: .commit,
                                     lastEvidence: .pendingConfirmation, goal: .control(.contactInvite), contactSource: .wechat)
        }
    }
```

`AIPlannerAddCustomerHeaderIntegrationTests` 里加：

```swift
    /// B54: the standalone window's round uses its own goal; the result round carries the chosen source.
    @Test func theStandaloneWindowRoundUsesItsOwnGoalAndTheMatchCarriesTheSource() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        var verification: AXElementHandle?
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }) else { return }
            let title = (try? AXElement(handle: last, backend: box.fake).title()) ?? nil
            if title == "添加", box.panelHandle != nil, verification == nil {
                verification = box.fake.appendChild(to: box.fake.rootHandle, node: AddContactTests.verificationWindow())
            } else if title == "发送", let window = verification {
                box.fake.mutate(window, attribute: AXAttribute.role, to: .string(AXRole.group))
            }
        }
        var purposes: [AIPlannerControlPurpose] = []
        var sources: [AIPlannerContactSource?] = []
        Self.installRunner(box, passive: { context in
            if case .control(let purpose) = context.goal { purposes.append(purpose) }
            sources.append(context.contactSource)
            return .init(step: .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        let result = try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                                checkpoint: {}, afterSubmit: {})
        #expect(result["status"] == "requested" && result["inviteWindow"] == "separate")
        #expect(purposes == [.contactSearch, .contactMatch, .contactSendVerification])
        #expect(sources == [nil, .wechat, nil])
    }

    /// An invite inside the Add Customer panel keeps the original goal.
    @Test func anInPanelInviteKeepsTheInviteGoal() throws {
        let box = try Box(ambiguous: false)
        let original = box.fake.reactions["action:\(AXAction.press)"]
        box.fake.reactions["action:\(AXAction.press)"] = {
            original?()
            guard let last = box.fake.recordedActions.last?.handle,
                  !box.headerButtons.contains(where: { $0.handle == last }),
                  let panel = box.panelHandle,
                  (try? AXElement(handle: last, backend: box.fake).title()) == "添加" else { return }
            _ = box.fake.appendChild(to: panel, node: AXNode(
                role: AXRole.button, title: "发送添加邀请",
                frame: CGRect(x: 884, y: 702, width: 222, height: 40),
                actions: [AXAction.press]))
        }
        var purposes: [AIPlannerControlPurpose] = []
        Self.installRunner(box, passive: { context in
            guard case .control(let purpose) = context.goal else { return .init(step: .stop, candidateID: nil) }
            purposes.append(purpose)
            return .init(step: purpose == .contactInvite ? .stop : .verify, candidateID: nil)
        }, decide: { _, _ in Issue.record("unique header offered to model"); return .init(step: .stop, candidateID: nil) })
        #expect(throws: ControlError.self) {
            try box.handler.contactAdd(phone: Self.phone, source: "wechat", greeting: nil, dryRun: false,
                                       checkpoint: {}, afterSubmit: {})
        }
        #expect(purposes == [.contactSearch, .contactMatch, .contactInvite])
    }
```

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter "AIPlannerStepDecisionTests|AIPlannerAddCustomerHeaderIntegrationTests"`
Expected: 编译失败（`contactSendVerification`、`AIPlannerContactSource`、`contactSource` 不存在）。

- [ ] **Step 3：实现**

1. `AIPlannerVisionClient.swift`：
   - `AIPlannerControlPurpose` 在 `case contactInvite` 之后加 `case contactSendVerification`；`description` 的 switch 在 `.contactInvite` 之后加 `case .contactSendVerification: "the Send button of this command's own Send Verification Request window"`；
   - 文件里（`AIPlannerControlPurpose` 之后）加：

```swift
/// B54: the source of the result `contact.add` chose; named in the result-row prompt.
public enum AIPlannerContactSource: String {
    case wechat, wecom

    var promptName: String {
        switch self {
        case .wechat: "WeChat (微信)"
        case .wecom: "WeCom (企业微信)"
        }
    }
}
```

2. `AIPlannerReversibleRound`：加属性 `public let contactSource: AIPlannerContactSource?`，`init` 末尾加参数 `contactSource: AIPlannerContactSource? = nil` 并赋值 `self.contactSource = contactSource`。

3. `AIPlannerStepContext`：加属性 `public let contactSource: AIPlannerContactSource?`；`init` 改为：

```swift
    public init(method: RPCMethod, allowedSteps: Set<AIPlannerStep>, phase: AIPlannerPhase,
                lastEvidence: AIPlannerEvidence, goal: AIPlannerGoal,
                contactSource: AIPlannerContactSource? = nil) throws {
        let sourceFits: Bool
        if case .control(.contactMatch) = goal { sourceFits = true } else { sourceFits = contactSource == nil }
        guard let ceiling = Self.methodCeiling(method), !allowedSteps.isEmpty,
              allowedSteps.isSubset(of: ceiling), goal.description != nil, sourceFits else {
            throw AIPlannerVisionError.invalidGoal
        }
        self.method = method
        self.allowedSteps = allowedSteps
        self.phase = phase
        self.lastEvidence = lastEvidence
        self.goal = goal
        self.contactSource = contactSource
    }
```

4. `AIPlannerStepDecision.swift` 的提示：
   - `selectionHint` 链里，在 `.control(.contactSearch)` 一支之后插入：

```swift
        } else if case .control(.contactSendVerification) = context.goal,
                  context.phase == .commit, context.lastEvidence == .pendingConfirmation {
            selectionHint = "The caller pressed Add on this command's chosen result and has independently proved from AX that this standalone Send Verification Request window opened in response; its window number is proved. This image shows only that window and is a read-only veto before the caller's second checkpoint and its own fixed press of Send. The boxed Send button is an image anchor only: you cannot press it, edit text, or claim that a request was sent."
```

   - `verificationHint` 链里，`contactMatch` 一支改为在原句后接上来源句（原句一字不改）：

```swift
        } else if case .control(.contactMatch) = context.goal,
                  context.phase == .verify, context.lastEvidence == .postconditionPresent {
            let source = context.contactSource.map {
                " This command's chosen result is the \($0.promptName) result; when the phone lists one result per source, judge that one."
            } ?? ""
            verificationHint = "The caller has independently read back its fixed search and proved from AX the one result with the requested source; the offered Add button is that result's own image anchor. A phone search can list one result per source, such as a WeChat result and a WeCom result for the same person, each with its own Add. Choose verify if the image shows this command's search results with the boxed Add inside one result row; you cannot press, change the source, or choose another result. Reobserve while the results are still loading. Stop if a different search or window appears, or if the boxed Add is not inside a result row." + source
```

   - 在 `contactInvite` 一支之前插入：

```swift
        } else if case .control(.contactSendVerification) = context.goal,
                  context.phase == .commit, context.lastEvidence == .pendingConfirmation {
            verificationHint = "AX shows that the window holds exactly one single-line field, whose fixed greeting the caller checked, one Send button and one close button. The search results are not in this image and are not needed. Choose verify if the image shows one such window with the boxed Send button inside it. Reobserve while the window is still loading. Stop if the image shows a different window such as a chat or a notice, if the window shows an error or limit message such as already a customer, too frequent, or no such user, or if the boxed control is not Send."
```

5. `AIPlannerReversibleRunner.observeContactAdd`：
   - 守卫里 `purpose == descriptor.0,` 改为 `purpose == descriptor.0 || (stage == .inviteConfirm && purpose == .contactSendVerification),`；
   - `AIPlannerStepContext(method: .contactAdd, …, goal: round.goal)` 末尾加 `, contactSource: stage == .sourceMatch ? round.contactSource : nil`。

6. `AddCustomerPanel`：在 `inviteWindowID` 之后加：

```swift
    /// B54: the source (wechat | wecom) of the result this command chose; set for its result-row round.
    public var chosenSource: String? = nil

    /// This panel with the chosen result's source.
    public func choosing(_ source: String) -> AddCustomerPanel {
        var panel = self
        panel.chosenSource = source
        return panel
    }
```

7. `AddContact.swift` 两处结果行视觉轮次：
   - dryRun 一支 `try visualObserveContactAdd?(app, window, panel, .sourceMatch, button, {` 改为 `try visualObserveContactAdd?(app, window, panel.choosing(candidate.source), .sourceMatch, button, {`；
   - 真实添加一支 `try visualObserveContactAdd?(app, window, panel, .sourceMatch, chosenButton, {` 改为 `try visualObserveContactAdd?(app, window, panel.choosing(chosen.source), .sourceMatch, chosenButton, {`。

8. 处理器的 `actions.visualObserveContactAdd` 闭包：
   - `let purpose: AIPlannerControlPurpose` 改为 `let basePurpose: AIPlannerControlPurpose`，三个 `case` 里的 `purpose = ` 改为 `basePurpose = `；
   - 在确定 `captureWindow` 的 `if / else if / else` 之后加：

```swift
            // B54: an invite in this command's own 发送验证申请 window gets that window's goal and prompt.
            let purpose = stage == .inviteConfirm && captureWindow.handle == observedPanel.inviteWindow
                ? AIPlannerControlPurpose.contactSendVerification : basePurpose
```

   - observe 闭包里 `AIPlannerReversibleRound(window: window, goal: .control(purpose), …, evidence: evidence)` 末尾加 `, contactSource: stage == .sourceMatch ? observedPanel.chosenSource.flatMap(AIPlannerContactSource.init(rawValue:)) : nil`。

- [ ] **Step 4：运行，确认通过**

Run: `swift test --scratch-path $BUILD --filter WeComAdapterTests`
Expected: 全部 PASS（B51 的独立窗口与面板内邀请测试照旧通过）。

- [ ] **Step 5：提交**

```bash
git add Sources/WeComAdapter Tests/WeComAdapterTests
git commit -m "feat(contact.add): the standalone verification window gets its own goal and prompt; the result round names its source" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: 文档与版本

**Files:**
- Modify: `Sources/ControlCore/IMCTLVersion.swift`、`Tests/ControlCoreTests/IMCTLVersionTests.swift`
- Modify: `docs/protocol/im-control-protocol.md`
- Modify: `AGENTS.md`、`docs/agents/skills/imctl/SKILL.md`

- [ ] **Step 1：写失败的测试**

`IMCTLVersionTests` 的断言改为 `#expect(IMCTLVersion.string == "1.0.17-dev")`。

- [ ] **Step 2：运行，确认失败**

Run: `swift test --scratch-path $BUILD --filter IMCTLVersionTests`
Expected: FAIL（实际是 `1.0.16-dev`）。

- [ ] **Step 3：改版本与文档**

- `IMCTLVersion.swift`：在 1.0.16-dev 注释之后加一行 `/// 1.0.17-dev (2026-10-13): B54 — the standalone verification window's invite prompt; visual rounds logged; command records carry a diagnosis when a visual round ended them.`，`string` 改为 `"1.0.17-dev"`。
- 协议文档：
  - §3 在「失败通常也是成功响应…」一段之后加一段：「B54：命令因视觉轮次停下（模型选 stop、轮次用尽未证实）或视觉出错而以 `failed` / `unknown` 结束时，记录视图多一个 `diagnosis`：`{"visual": {"goal", "phase", "round", "outcome"}, "irreversibleSteps"}`。`goal` 是目标种类（如 `contactSendVerification`、`conversationRow`，不含标题或名字）；`phase` 是阶段；`round` 是该视觉步骤内的轮次，从 1 起，结束在任何一轮之前时 `goal` / `phase` 为 `none`、`round` 为 0；`outcome` 是 `stop`、`unverified` 或视觉错误类别（如 `timeout`、`staleView`）；`irreversibleSteps` 是本命令越过的不可逆点数。只含固定类别；没有它的记录与旧版一致。」
  - §4 在「幂等」一条之后加一条：「- B54：`unknown` 的含义不变；因视觉结束的命令另带 `diagnosis`（第 3 节），写明停在哪一轮、越过了几个不可逆点；仍须按原键对账，不换键重试。」
  - §4.1 末尾加一段：「B54：每次请求模型，守护进程日志写一行 `vision round <方法> <目标>/<阶段> #<轮次> → <结果> (<毫秒> ms)`，只含固定类别：不记截图、模型原文、候选标签、标题、名字、号码或验证语。」
  - §6.7 `command.get` 的字段表末尾加 `diagnosis_json?`，并补一句「（`diagnosis_json` 是第 3 节 `diagnosis` 的 JSON 文本，只出现在因视觉结束的命令上）」。
  - §6.42 `contact.add` 末尾加一段：「B54：邀请在本命令证实的独立「发送验证申请」窗口里时，邀请轮用目标 `contactSendVerification`，提示写明截图里只有该窗口、看不到结果列表；面板内或主窗弹层的邀请仍用 `contactInvite`，提示不变。结果行一轮的提示写明本命令所选来源。`diagnosis.irreversibleSteps` 为 1 表示已按所选结果的「添加」、未按「发送」；为 2 表示「发送」也已按下。」
  - §7.5 `command.state` 的字段表末尾加 `irreversibleSteps?, visualGoal?, visualPhase?, visualRound?, visualOutcome?`，并补一句「B54：记录带 `diagnosis` 时多这五个字符串字段，取值同第 3 节。」
  - §12 表格末尾加一行：`| 2026-10-13 | B54：命令记录视图与 command.state 事件的 diagnosis（command.get 的 diagnosis_json）；守护进程视觉轮次日志；contact.add 独立「发送验证申请」窗口的邀请轮目标 contactSendVerification，结果行提示写明所选来源。方法、错误码集合不变。 |`
- `AGENTS.md`：「模型只在固定协议命令的桌面执行步骤内协助规划和定位」一条末尾加一句：「B54：每次请求模型在守护进程日志写一行固定类别（方法、目标种类、阶段、轮次、结果、耗时）；命令因视觉结束时在记录上写 `diagnosis`；两者都不含截图、模型原文、标题、名字、号码或验证语。」
- `SKILL.md`：
  - 第 4 步「Confirm」末尾加：「A failed or unknown record may carry `diagnosis` (where a visual round ended and how many irreversible points were crossed); it never changes what `unknown` means.」
  - `contact.add` 一行末尾加：「; `unknown` with `diagnosis.irreversibleSteps: 1` means 发送 was not pressed — reconcile with the same key and report to a person, never retry with a new key」。

- [ ] **Step 4：运行全量**

Run: `swift test --scratch-path $BUILD`
Expected: 全部 PASS（`ProtocolDocTests`、`ForbiddenAPITests` 照旧通过）。另跑 `bash scripts/check-secrets.sh`（只读提醒，与 B53 时的条目对比，不新增）与 `git diff --check`。

- [ ] **Step 5：提交**

```bash
git add Sources/ControlCore/IMCTLVersion.swift Tests/ControlCoreTests/IMCTLVersionTests.swift docs/protocol/im-control-protocol.md AGENTS.md docs/agents/skills/imctl/SKILL.md
git commit -m "docs: B54 diagnosis, visual round log and the standalone invite goal; 1.0.17-dev" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: 变异验证、独立审查、安装与活体门报告

**Files:**
- Create: `docs/gates/<日期>-b54-verification-invite.md`

- [ ] **Step 1：变异验证**

在临时副本里逐条删掉下列保证，各跑对应测试，都应变红；跑完恢复原样：

| 删去的保证 | 应变红的测试 |
|---|---|
| `AIPlannerGoal.logName` 对 `conversationRow` 返回带标题的描述 | `everyModelRequestIsReportedWithoutTitles`、`fixedNamesForGoalsErrorsAndOutcomes` |
| `recordedDecision` 出错时不上报 | `aFailedModelRequestIsReportedByItsErrorName` |
| 抛错路径不写诊断（catch 里 `diagnosisJSON: nil`） | `aVisualEndAfterTheCheckpointIsUnknownWithItsDiagnosis`、`aVisualEndBeforeAnyCheckpointFailsWithZeroSteps` |
| `desktopMutation` 路径不写诊断 | `contactAddCountsBothIrreversiblePoints` |
| `crossCheckpoint` 不计数 | `contactAddCountsBothIrreversiblePoints` |
| 执行器每条命令前不清空 `desktopCommandVisualEnd` | `nonVisualEndsAndSuccessesCarryNoDiagnosis` |
| 执行器既不清空也不恢复 | `aBroadcastChildKeepsItsOwnDiagnosis` |
| 清空时不忘掉最后一轮 | `aVisualEndBeforeAnyRoundNamesNoRound` |
| `markVisualEnd` 覆盖本轮之后已记的结束 | `theFirstEndAfterARoundStands` |
| 某个处理器结束点仍直接抛 `ActionError.actionUnavailable` | `everyVisualEndInTheHandlerIsRecorded` |
| 独立窗口也用 `contactInvite` | `theStandaloneWindowRoundUsesItsOwnGoalAndTheMatchCarriesTheSource` |
| 面板内邀请也用新目标 | `anInPanelInviteKeepsTheInviteGoal` |
| 新提示含 `another dialog` | `theSendVerificationPromptMatchesItsStandaloneWindow` |
| `contactInvite` 提示被改动 | `theInPanelInvitePromptIsUnchanged` |
| 结果行不带来源 | `theMatchPromptNamesTheChosenSource`、`theStandaloneWindowRoundUsesItsOwnGoalAndTheMatchCarriesTheSource` |
| 迁移 `v4-diagnosis` 缺失 | `aDatabaseFromBeforeB54GainsTheColumn` |

- [ ] **Step 2：独立审查**

派一个新的审查代理（最强模型），只读审查本分支相对 `main` 的全部改动，带上规格、计划、本计划的 Review Focus 与台账里的 Ruling。重点：
- 日志与诊断不含内容；
- `unknown` 含义与错误码不变；处理器各结束点抛出的错误不变；
- 旧提示一字不改；模型权限不变；
- 每个视觉结束点都记录，且不把上一条命令的轮次带进来；
- 文档与代码一致。

严重与重要问题在一轮修复里改完，每项 RED→GREEN，然后跑全量测试。

- [ ] **Step 3：构建、打包、安装**

```bash
IMCTL_SIGN_TEAM=<证书名括号里的 ID> IMCTL_SIGN_TEAM_ID=<团队 ID> IMCTL_OUT_DIR=out/b54-build$(git rev-list --count HEAD) scripts/build-pkg.sh release
```

展开 pkg 核对载荷、严格验签 → `installer -pkg <pkg> -target CurrentUserHomeDirectory` → 体检页按钮或 `imctl doctor --fix` 重启守护进程；`imctl doctor --offline` 与 `setup --check` 核对。

- [ ] **Step 4：活体（这台 Mac，企业微信 5.0.12）**

号码由用户在控制台里填写，不进对话；读命令记录只取 `state`、`error_code`、`result_json` 里的 `status` / `inviteWindow` / `inviteDialog` 与 `diagnosis_json`，不打印 `params_json`。

1. 用户把自有测试号加进本机号码白名单：须是企业微信用户，当前不是客户。
2. 用户在控制台通讯录页对该号做一次 dryRun（来源企业微信）。核对：
   - 守护进程日志里每一轮一行 `vision round contact.add …`，不含号码；
   - 结果行一轮的记录在。
3. 用户点头后，在控制台用新键真实添加一次。期望：
   - `requested`，`inviteWindow` 为 `separate`，`inviteDialog` 为 `closed`；
   - 日志里有 `contactSendVerification/commit #… → verify`；
   - 如果停下，命令记录的 `diagnosis` 写明停在哪、`irreversibleSteps` 是几。
4. 如果 5.0.12 的窗口形状与 5.0.11 不同而在按「添加」前停止，记下差异，补不补校准由用户决定。

- [ ] **Step 5：写门报告并提交**

按 `docs/ai-coding/TESTING_SPEC.md` 与 B53 门报告的格式写 `docs/gates/<日期>-b54-verification-invite.md`。包括：
- 条件、实现；
- 单测数（与 B53 的 1144 对比）、变异表、审查结论；
- 制品哈希；
- 活体逐项结果，不含号码与联系人；
- 未闭环项。

```bash
git add docs/gates
git commit -m "docs(gates): B54 verification window invite on build <N>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

合入 `main` 与推送前先 `git fetch`，等用户确认。合入后从 main 重建安装，并提议用户归档到 Wiki。
