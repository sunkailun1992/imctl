# 阶段 1 任务 P1-1：提交路径验证（`probe submit`）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 回答"没有发送按钮时，纯 AX 动作能否把输入框内容发出去"。实现 `imctl probe submit --allow-submit <text> --strategy ax-confirm|newline`，走完整的 precheck_input → compose → **checkpoint 落盘 → submit** → confirm（外发气泡取证）链路，只对文件传输助手。

**Architecture:** `ActionPolicy` 进入 `phase1`，`submit` 需 `--allow-submit` 且目标在白名单。`ControlCore` 新增 `SubmitCheckpoint` + `FileCheckpointStore`（submit 前写 `pending`，取证后写 `succeeded/failed/unknown`；启动时发现残留 `pending` 一律标 `unknown`，绝不重跑）。`WeComAdapter.WeComActions.submit` 按策略执行不可逆动作：`axConfirm` = 对输入框 `performAction("AXConfirm")`；`newline` = 输入框 `AXValue` 设为 `text + "\n"`。取证：超时前消息表出现正文等于 `text` 的新行 → `succeeded`；超时且输入框仍是原文 → `failed`（并清空）；超时且输入框已空但无气泡 → `unknown`（不清、不重试）。`FakeAXBackend` 加 `reactions`（动作/设值后的脚本化树变化）以便在 fake 上测通取证。

**Tech Stack:** 同前；checkpoint 目录默认 `~/Library/Application Support/imctl/checkpoints/`，测试用临时目录。

## Global Constraints

- 只对 `WeComClient.fileTransferAssistantTitle`；`--allow-submit` 缺失即拒绝；阶段仍由代码写死为 `phase1` 仅在 `probe submit` 内启用。
- 零合成事件：策略只允许 `performAction` 与 `setAttribute`。
- 每次 `probe submit` 只尝试一种策略、只发一条；不自动重试。
- 输入框非空（人留草稿）→ `LOCAL_GUARD` 中止。
- 活体测试前向用户确认一次。

---

### Task 1: `SubmitCheckpoint` / `FileCheckpointStore`（ControlCore）

**Files:** `Sources/ControlCore/Checkpoint/SubmitCheckpoint.swift`、`Sources/ControlCore/Checkpoint/FileCheckpointStore.swift`；Test `Tests/ControlCoreTests/SubmitCheckpointTests.swift`

**Interfaces:**

```swift
public enum CommandState: String, Codable { case pending, succeeded, failed, unknown }
public struct SubmitCheckpoint: Codable, Equatable {
    public var id: String            // UUID
    public var target: String
    public var text: String
    public var strategy: String
    public var createdAt: Date
    public var state: CommandState
    public var evidence: String?
    public var reason: String?
}
public protocol CheckpointStore {
    func write(_ c: SubmitCheckpoint) throws          // 原子写 <id>.json
    func load(id: String) throws -> SubmitCheckpoint?
    func pending() throws -> [SubmitCheckpoint]
}
public final class FileCheckpointStore: CheckpointStore { public init(directory: URL) throws }
```

- [ ] 测试：写→读相等；`pending()` 只返回 `pending`；更新为 `succeeded` 后 `pending()` 为空；目录不存在自动创建。
- [ ] 实现 → PASS → 提交 `feat(core): add submit checkpoint store`

### Task 2: fake 的 `reactions`（AXKit）

- `FakeAXBackend.reactions: [String: () -> Void]`，键同 `injectedFailures`（`action:AXConfirm`、`set:AXValue`），在成功记录之后调用。
- [ ] 测试：注册 `action:AXPress` 反应把某文本改掉，`perform` 后读到新值。
- [ ] 实现 → PASS → 提交 `feat(axkit): scripted reactions on FakeAXBackend`

### Task 3: `WeComActions.submit`（WeComAdapter）

**Files:** `Sources/WeComAdapter/Actions/Submit.swift`；Test `Tests/WeComAdapterTests/SubmitTests.swift`

**Interfaces:**

```swift
public enum SubmitStrategy: String, Codable, CaseIterable { case axConfirm = "ax-confirm", newline }
public struct SubmitOutcome: Codable, Equatable {
    public var state: CommandState; public var strategy: String; public var target: String?
    public var checkpointID: String; public var reason: String?; public var evidence: String?
    public var latencyMs: Int?; public var composerAfter: Int   // 结束时输入框字符数
}
extension WeComActions {
    public func submit(text: String, strategy: SubmitStrategy, reader: WeComReader,
                       checkpoints: CheckpointStore, timeout: TimeInterval = 10) throws -> SubmitOutcome
}
```

流程：authorize(.submit, active) → precheck（composer 存在且为空；基线 = messages() 的 (index,text) 集合）→ compose(text) 复核 → checkpoint pending → 执行策略（`axConfirm` 若 `actionUnsupported` → failed "AXConfirm unsupported"，清空输入框）→ 轮询取证（每 200 ms `messages()`，找 text 相等且不在基线中的行）→ 结果分类 → 写 checkpoint → 返回。

- [ ] 测试（fake，fixture 输入框动作只有 AXShowMenu）：
  1. `axConfirm` → `failed`，reason 含 "unsupported"，recordedSets = [text, ""]，checkpoint failed。
  2. 给输入框加 `AXConfirm` 动作 + reaction（追加一条正文 = text 的右贴边消息行并清空输入框）→ `succeeded`，evidence 含行号，checkpoint succeeded，latencyMs ≥ 0。
  3. 同上但 reaction 只清空输入框不加行 → `unknown`，输入框不再被动。
  4. `newline` 策略且无 reaction → 超时后输入框仍含文本 → `failed` 并清空。
  5. 输入框非空 → `LOCAL_GUARD`，不写 checkpoint。
  6. phase0 策略 → `PolicyError.phaseForbids`。
- [ ] 实现 → PASS → 提交 `feat(adapter): policy-gated submit with checkpoint and bubble evidence`

### Task 4: `imctl probe submit`

- `ProbeSubmitCommand`：`--allow-submit <text>`、`--strategy ax-confirm|newline`（默认 ax-confirm）、`--timeout 10`、`--checkpoint-dir`（默认 App Support）、`--from-fixture`。启动先处理残留 pending → 标 unknown 并打印；然后执行；打印 outcome（含前后 `ClientState`）。
- [ ] 测试：fixture 上 `--strategy ax-confirm` → state failed；残留 pending 文件 → 输出含 `unknown` 且该文件状态被改。
- [ ] 实现 → PASS → 提交 `feat(cli): add probe submit (phase 1, allowlisted, one strategy per run)`

### Task 5: 活体验证（需用户确认）

1. `probe submit --allow-submit "imctl-p1-confirm" --strategy ax-confirm`。
2. 若 failed(unsupported) → `--strategy newline`。
3. 结果写 `docs/gates/2026-09-11-p1-submit-path.md`；两者都失败则记录"纯 AX 无提交路径"，下一步由用户决定（`CGEventPostToPid` 救急验证是否允许）。

## 执行结果（2026-09-12 00:0x）

- Task 1–4 完成，83 个测试通过；Task 5 活体：`ax-confirm` → failed（unsupported），`newline` → failed（无气泡，输入框保留文本）。报告 `docs/gates/2026-09-12-p1-submit-path.md`。
- 补充：安全审查指出 compose 与 submit 之间的 TOCTOU，已在不可逆步骤前重新核对活动标题与输入框身份（fake 测试覆盖）。
- 第二轮（2026-09-12 01:08）：新增 `enter`/`ctrl-enter` 策略（`KeystrokeInjector`，pid 级回车，用户决定的唯一例外）与 `--auto`；`enter` 首发成功，115 ms 取证，企微未激活。91 个测试通过。
