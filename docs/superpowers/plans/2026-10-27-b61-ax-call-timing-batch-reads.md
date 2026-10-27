# B61 AX 逐次计时与批次读取 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 守护进程内每次 AX 调用可计时、可汇总；热点读取路径改用一次往返读多个属性，解析结果与逐个读取完全等价；提供只读 A/B 探针供下一步实测。

**Architecture:** AXKit 新增 `AXCallTimings`（聚合器）与 `MeasuredAXBackend`（装饰任意 `AXBackend` 的计时层），`AXBackend` 增加批次读原语（协议默认逐个读，Live 用 `AXUIElementCopyMultipleAttributeValues`）与 `AXAttributeSnapshot` 访问器。四条读取路径改用快照。`imctld` 用计时层包住 `LiveAXBackend`，由 `AXTimingReporter` 写 `state.json` 摘要、`ax-timings.json` 与限流日志；CLI 新增 `imctl probe ax-timing`。

**Tech Stack:** Swift 6.4 工具链 / Swift 5 语言模式，SwiftPM，swift-testing，ApplicationServices（只在 `LiveAXBackend.swift`）。

**Spec:** `docs/superpowers/specs/2026-10-27-b61-ax-call-timing-batch-reads.md`

## Global Constraints

- 不改超时数值：`LiveAXBackend(messagingTimeoutSeconds: 2)` 与只设在应用元素上的现状保持不变。
- 不改协议：方法、参数、结果、事件字段、错误码不变；MCP `tools/list` 仍为 45；`ProtocolDocTests` 不需要改。
- 不改策略、白名单、`KeystrokeInjector` 按键清单、权限面、视觉上传、checkpoint、幂等与 `unknown` 语义；不新增 SwiftPM 依赖、不新增 macOS 权限。
- AX 符号只出现在 `Sources/AXKit/LiveAXBackend.swift`；`ForbiddenAPITests` 必须通过。
- 计时记录、`ax-timings.json`、日志与探针输出只含操作名、AX 属性/动作名、计数、毫秒、结果类别与线程标签；不含标题、正文、名字、号码、句柄描述或屏幕内容。
- 慢样本阈值 500 ms、保留 64 条；慢调用日志阈值 1000 ms、每分钟最多 30 行；报告文件每 30 秒写一次、权限 0600；摘要日志每 300 秒一行；分桶上界（毫秒）1/2/5/10/20/50/100/200/500/1000/2000/5000/10000/30000/∞。
- 测试不 sleep：时钟、墙钟、线程标签全部注入。
- 代码注释用英文，仓库文档用简体中文；提交信息英文 Conventional Commits，结尾署名 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 最终验证：`swift build`、`IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`（基线 1,238 项 / 163 套件 / 10 程序）、`bash scripts/check-secrets.sh` 逐条判断、`git diff --check`。

## Review Focus

- Live 批次读把「不支持」回成 `CFNull`，而单读抛 `attributeUnsupported`：快照的「不支持即 nil」访问器必须对两者给出同一结果（Task 3 `unsupportedAndNullReadTheSame`）。
- 执行器队列与主线程同时记录：计数不得丢失（Task 1 `concurrentRecordsAreAllCounted`）。
- 企微卡死时慢调用连续出现：日志不得刷屏，超出部分进入下一行摘要（Task 5 `slowLinesAreRateLimited`）。
- 报告文件写不进去（目录缺失、磁盘满）：守护进程不得抛错或退出，只记一次警告（Task 5 `unwritableReportDoesNotThrow`）。
- 批次调用整体超时：不得退回逐个读而把一次超时放大成多次（Task 3 `callLevelTimeoutDoesNotFallBack`，以纯函数测试 Live 的处置表）。

---

### Task 1: AX 调用计时聚合器

**Files:**
- Create: `Sources/AXKit/AXCallTimings.swift`
- Test: `Tests/AXKitTests/AXCallTimingsTests.swift`

**Interfaces:**
- Produces:
  - `public enum AXCallOperation: String, Codable { case get, getMany, attributeNames, isSettable, set, actionNames, perform, pid }`
  - `public struct AXCallSample: Equatable, Codable { var atMs: Int64; var operation: AXCallOperation; var name: String; var nanos: UInt64; var outcome: String; var thread: String; var itemOutcomes: [String: Int] }`（`itemOutcomes` 默认 `[:]`）
  - `public final class AXCallTimings { init(slowThresholdMs: Double = 500, keepSlowSamples: Int = 64, wallMs: @escaping () -> Int64 = …); func record(_ sample: AXCallSample); func recordScope(_ name: String, nanos: UInt64, ok: Bool); func report(topOperations: Int = 30) -> AXCallTimingReport; func reset(); static func outcomeLabel(for error: Error) -> String; static let bucketUpperBoundsMs: [Double] }`
  - `public struct AXCallTimingReport: Equatable, Codable`，字段 `sinceMs, generatedMs, calls, totalMs, timeouts, slowCalls, slowThresholdMs, operations: [Operation], threads: [Thread], scopes: [Scope], slowSamples: [AXCallSample]`；`Operation { operation, name, count, totalMs, maxMs, p50Ms, p95Ms, p99Ms, outcomes }`；`Thread { thread, count, totalMs, maxMs }`；`Scope { name, count, failures, totalMs, maxMs, p50Ms, p95Ms, p99Ms }`

- [ ] **Step 1: 写失败测试**
  - `aggregatesByOperationAndName`：记 3 次 `get AXRole`（1、3、40 ms）与 1 次 `get AXChildren`（6000 ms, `cannotComplete`）→ `calls == 4`、`timeouts == 1`、AXRole 项 `count == 3`、`maxMs == 40`、`p50Ms == 5`（分桶上界）、`operations.first?.name == "AXChildren"`（按总耗时降序）。
  - `percentileInOverflowBucketUsesMax`：一次 45,000 ms → `p99Ms == 45000`。
  - `outcomeLabelsCoverEveryError`：`outcomeLabel` 对 `.cannotComplete` → `"cannotComplete"`、`.attributeUnsupported` → `"unsupported"`、`.apiFailure(code: -25201, …)` → `"error:-25201"`，其余各 case 一一断言。
  - `slowSamplesKeepTheNewestUpToTheLimit`：`keepSlowSamples: 2`、阈值 500，记 499/500/700/900 ms → `slowCalls == 3`、`slowSamples.map(\.nanos)` 为 700 与 900 ms。
  - `threadsAndScopesAreSeparate`：两个线程标签各自累计；`recordScope("watch.poll", …, ok: false)` → `scopes[0].failures == 1`，不计入 `calls`。
  - `resetClearsEverythingAndMovesSince`：`reset()` 后 `calls == 0`，`sinceMs` 取注入墙钟的新值。
  - `concurrentRecordsAreAllCounted`：`DispatchQueue.concurrentPerform(iterations: 1000)` 各记一次 → `calls == 1000`。

- [ ] **Step 2: 运行，确认失败**
  Run: `swift test --filter AXCallTimingsTests`
  Expected: 编译失败，`AXCallTimings` 未定义。

- [ ] **Step 3: 实现 `Sources/AXKit/AXCallTimings.swift`**
  `NSLock` 保护的字典；直方图 15 个桶（14 个上界 + 溢出桶）；百分位取累计数首次 ≥ ⌈q·count⌉ 的桶上界，溢出桶取 `maxMs`；毫秒保留一位小数。

- [ ] **Step 4: 运行，确认通过**
  Run: `swift test --filter AXCallTimingsTests` → PASS

- [ ] **Step 5: 提交** `feat(axkit): aggregate per-call AX timings`

### Task 2: 计时装饰后端

**Files:**
- Create: `Sources/AXKit/MeasuredAXBackend.swift`
- Test: `Tests/AXKitTests/MeasuredAXBackendTests.swift`

**Interfaces:**
- Consumes: Task 1 全部类型；Task 3 的 `attributes(_:of:)` 与 `attributesBySingleReads(_:of:)`（两个任务同一提交前完成；先写 Task 3 的协议声明再写本任务实现亦可）。
- Produces: `public final class MeasuredAXBackend: AXBackend { init(base: AXBackend, timings: AXCallTimings, batchReads: Bool = true, now: @escaping () -> UInt64 = …, wallMs: @escaping () -> Int64 = …, threadLabel: @escaping () -> String = MeasuredAXBackend.currentThreadLabel); let base; let timings; let batchReads; var slowCallThresholdMs: Double = 1000; var onSlowCall: ((AXCallSample) -> Void)?; static func currentThreadLabel() -> String }`

- [ ] **Step 1: 写失败测试**（底层用 `FakeAXBackend(root: SampleTree.make())`，`now` 每次调用递增 2 ms）
  - `everyTimedPrimitiveRecordsOneSample`：依次调用 `attribute`、`attributeNames`、`isAttributeSettable`、`setAttribute`（可设属性）、`actionNames`、`performAction`、`pid` → 7 条记录，操作与名字一一对应，每条 2 ms。
  - `errorsAreRethrownUnchangedAndClassified`：注入 `get:AXTitle = .cannotComplete("x")` → 抛出原错误，记录 `outcome == "cannotComplete"`；无值属性记 `noValue`。
  - `untimedPrimitivesRecordNothing`：`isProcessTrusted`、`applicationElement`、`makeObserver` 后 `calls == 0`。
  - `nameIsForwarded`：`MeasuredAXBackend(base: fake…).name == "fake"`。
  - `batchModeRecordsOneRoundTrip` / `singleModeRecordsEachRead`：`attributes([AXRole, AXTitle, AXFrame])` 在 `batchReads: true` 记 1 条 `getMany`（名字 `"AXRole,AXTitle,AXFrame"`），`false` 记 3 条 `get`；两种结果字典相同。
  - `slowCallbackOnlyAboveThreshold`：阈值 1000，耗时 999 不触发、1000 触发一次。

- [ ] **Step 2: 运行，确认失败** `swift test --filter MeasuredAXBackendTests` → 编译失败。

- [ ] **Step 3: 实现** 每个计时原语：取 `now()`、调用、算纳秒、分类（成功的 `get` 返回 nil 记 `noValue`）、`timings.record`、超阈值调 `onSlowCall`、原样返回或抛出。批次成功时 `itemOutcomes` 统计非成功项（`item:<类别>`，`.success(nil)` 记 `item:noValue`）。`currentThreadLabel()`：主线程 `"main"`，否则 `__dispatch_queue_get_label(nil)` 的字符串，空则 `"other"`。

- [ ] **Step 4: 运行，确认通过** → PASS

- [ ] **Step 5: 提交** `feat(axkit): time every AX primitive through a decorator backend`（可与 Task 3 合并提交）

### Task 3: 批次读原语与快照访问器

**Files:**
- Modify: `Sources/AXKit/AXBackend.swift`（协议加要求 + 默认实现）
- Modify: `Sources/AXKit/LiveAXBackend.swift`（Live 批次实现与两个纯处置函数）
- Create: `Sources/AXKit/AXAttributeSnapshot.swift`
- Test: `Tests/AXKitTests/AXAttributeSnapshotTests.swift`、`Tests/AXKitTests/LiveAXBatchDispositionTests.swift`、`Tests/AXKitTests/LiveAXBackendTests.swift`（live-only 用例）

**Interfaces:**
- Produces:
  - `public typealias AXAttributeResult = Result<AXAttributeValue?, AXKitError>`
  - 协议要求 `func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult]`
  - 扩展 `func attributesBySingleReads(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult]`（单项 `AXKitError` 记 `.failure`，其他错误抛出；`attributes` 的默认实现调用它）
  - `public struct AXAttributeSnapshot { init(element: AXElement, results: [String: AXAttributeResult]); let element: AXElement; func attributeIfSupported(_:) throws -> AXAttributeValue?; func string(_:); func bool(_:); func elements(_:) throws -> [AXElement]; func role(); func subrole(); func title(); func value(); func valueString(); func axDescription(); func identifier(); func isEnabled(); func isSelected(); func isFocused(); func children(); func frame() throws -> CGRect? }`
  - `public extension AXElement { func read(_ names: [String]) throws -> AXAttributeSnapshot }`
  - `LiveAXBackend`：`enum BatchCallDisposition: Equatable { case proceed, fallBack, fail(AXKitError) }`；`static func batchCallDisposition(_ err: AXError) -> BatchCallDisposition`；`static func itemResult(code: AXError, name: String) -> AXAttributeResult`

- [ ] **Step 1: 写失败测试**
  - `defaultBatchMatchesSingleReads`：`SampleTree` 每个节点，`read(全部标准属性)` 的各访问器结果等于 `AXElement` 同名 getter。
  - `unsupportedAndNullReadTheSame`：结果为 `.failure(.attributeUnsupported("AXTitle"))` 与 `.success(nil)` 的两个快照，`title()` 都是 nil。
  - `itemFailureThrowsOnlyWhenAccessed`：注入 `get:AXTitle = .invalidElement` → `read([AXRole, AXTitle])` 不抛；`role()` 正常；`title()` 抛 `invalidElement`。
  - `transientRetryMatchesSingleGetter`（参数化 AXRole / AXValue / AXFrame / AXPosition / AXSize）：首读 -25201 → 访问器成功且该属性总读次数 2；连续两次 -25201 → 抛第二次错误、读次数 2；-25204 → 不重试、读次数 1（对照 `AXElementTransientReadTests`）。
  - `frameFallsBackToPositionAndSize`：去掉 AXFrame 后 `frame()` 取 position + size，且三者都在同一批次时不再单读。
  - `missingAttributeFallsBackToSingleRead`：快照未含 AXTitle 时 `title()` 单读一次。
  - `duplicateNamesAreReadOnce`：`read([AXRole, AXRole])` 只读一次 AXRole。
  - `callLevelTimeoutDoesNotFallBack`：`batchCallDisposition(.cannotComplete) == .fail(.cannotComplete("get multiple attributes"))`，`.invalidUIElement` → `.fail(.invalidElement)`，`.apiDisabled` → `.fail(.notTrusted)`；`.notImplemented`、`.illegalArgument`、`.failure`、`.attributeUnsupported` → `.fallBack`；`.success` → `.proceed`。
  - `itemErrorsMapLikeSingleReads`：`itemResult(code: .noValue, …) == .success(nil)`；`.attributeUnsupported` → `.failure(.attributeUnsupported(name))`；`.illegalArgument` → `.failure(.apiFailure(code: -25201, operation: "get AXValue"))`（名字为 AXValue 时）。
  - live-only `batchEqualsSingleOnTheTestApp`：`IMCTL_LIVE=1` 时对测试应用（默认 Finder）比较批次与逐个读取的 role/title/frame/children 数量相同。

- [ ] **Step 2: 运行，确认失败** `swift test --filter "AXAttributeSnapshotTests|LiveAXBatchDispositionTests"` → 编译失败。

- [ ] **Step 3: 实现**
  - 协议默认实现：去重保序后逐个 `attribute(_:of:)`。
  - Live：`AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)`；按 `batchCallDisposition` 处置；数组长度不符退回单读；`CFNull` → `.success(nil)`；`AXValue` 且类型为 `.axError` → `itemResult`；其余 `convert`。`itemResult` 复用既有 `check` 映射，操作串为 `get <name>`。
  - 快照：`role`、`value`、`frame`（含 position/size）遇 `.apiFailure(-25201, "get <name>")` 用 `element.attributeIfSupported(name)` 单读重试一次；`attributeUnsupported` 视为 nil；未含的属性走 `element` 的同名 getter。

- [ ] **Step 4: 运行，确认通过** → PASS；`swift test --filter "AXElementTransientReadTests|FakeAXBackendTests|AXTreeDumperTests"` 仍 PASS。

- [ ] **Step 5: 提交** `feat(axkit): read several attributes in one AX round trip`

### Task 4: 四条读取路径改用批次读

**Files:**
- Modify: `Sources/AXKit/AXTreeDumper.swift`（`visit`）
- Modify: `Sources/WeComAdapter/ConversationRow.swift`（`parse`）
- Modify: `Sources/WeComAdapter/MessageRow.swift`（`parse`、`readableValue`）
- Modify: `Sources/WeComAdapter/WeComLayout.swift`（`locate` 的遍历）
- Test: `Tests/WeComAdapterTests/BatchReadEquivalenceTests.swift`、`Tests/AXKitTests/AXTreeDumperTests.swift`

**Interfaces:**
- Consumes: Task 2 `MeasuredAXBackend`、Task 3 `AXElement.read` / `AXAttributeSnapshot`。
- Produces: `MessageRowParser.readableValue(_ snapshot: AXAttributeSnapshot, readError: inout String?) throws -> String?`（替换原 `AXElement` 版本，语义不变）。
- 读取集合（写成各文件内的 `static let`）：
  - 会话行：行 `[AXRole, AXFrame, AXPosition, AXSize, AXChildren, AXSelected]`，行子元素同上（找到第一个 cell 即停），cell 子元素 `[AXRole, AXValue, AXFrame, AXPosition, AXSize, AXTitle]`。
  - 消息行：行与行子元素 `[AXRole, AXFrame, AXPosition, AXSize, AXChildren]`，cell 子元素 `[AXRole, AXValue, AXFrame, AXPosition, AXSize, AXTitle, AXDescription]`。
  - 版面定位：遍历到的每个元素 `[AXRole, AXFrame, AXPosition, AXSize]`；`children()` 仍在出队时单读，表格不展开。
  - 树导出：12 个标准属性 + `AXFrame, AXPosition, AXSize, AXChildren` + `extraAttributes`；标准属性用 `attributeIfSupported`（导出原本不做暂态重试），frame 用快照 `frame()`；整个批次抛错记 1 次错误、各字段为 nil，actions 与可设置性探测照旧。

- [ ] **Step 1: 写失败测试**
  - `everyFixtureParsesTheSameBothWays`：遍历 `Tests/Fixtures/ax-trees/*.json`（跳过 `.raw.json`），各自 `FakeAXBackend`；分别以 `MeasuredAXBackend(base: fake, timings: …, batchReads: true/false)` 定位主窗口、`WeComLayout.locate`、`ConversationRowParser.parse`、有消息表时 `MessageRowParser.parse`；两种方式结果相等（同一 fake，句柄可直接比较），定位失败时两种方式抛相同错误。
  - `batchUsesFewerRoundTrips`：`wecom-5.0.11-main-window.json` 上批次方式的 `report().calls` 小于逐个方式的一半。
  - `dumperUsesOneBatchPerNode`：`SampleTree` 导出时 `getMany` 记录数等于节点数（7）。
  - 既有 `AXTreeDumperTests` 三项不改断言仍通过。

- [ ] **Step 2: 运行，确认失败** `swift test --filter "BatchReadEquivalenceTests|AXTreeDumperTests"` → `batchUsesFewerRoundTrips` 与 `dumperUsesOneBatchPerNode` 失败。

- [ ] **Step 3: 改造四个函数** 判断顺序、`continue` / `guard` 与 `try` / `try?` 位置保持原样，只把属性读取换成快照访问器。

- [ ] **Step 4: 运行，确认通过**
  Run: `swift test --filter "BatchReadEquivalenceTests|AXTreeDumperTests|ConversationRow|MessageRow|WeComLayout|WatchEngine|AXValueRecovery"` → PASS

- [ ] **Step 5: 提交** `perf(adapter): parse rows and locate layout with batched AX reads`

### Task 5: 守护进程计时输出

**Files:**
- Create: `Sources/imctld/AXTimingReporter.swift`
- Modify: `Sources/imctld/DaemonPaths.swift`（`static var axTimings: URL { root.appendingPathComponent("ax-timings.json") }`）
- Modify: `Sources/imctld/DaemonWatcher.swift`（`var axReporter: AXTimingReporter?`；`poll` 记 `watch.poll` 范围；`writeState` 加 `ax` 摘要并调 `tick()`）
- Modify: `Sources/imctld/main.swift`（装配）
- Test: `Tests/imctldTests/AXTimingReporterTests.swift`

**Interfaces:**
- Consumes: Task 1、Task 2。
- Produces: `final class AXTimingReporter { init(timings: AXCallTimings, reportURL: URL, log: @escaping (String) -> Void, nowMs: @escaping () -> Int64 = Clock.nowMs); let timings; func noteSlowCall(_ sample: AXCallSample); func stateSummary() -> [String: Any]; func tick(); func writeReport() throws; static func slowLine(_ sample: AXCallSample) -> String; static func summaryLine(_ report: AXCallTimingReport, suppressedSlowLines: Int) -> String }`
  - `stateSummary` 键：`calls`、`totalMs`、`timeouts`、`slowCalls`、`polls`、`pollP50Ms`、`pollP95Ms`、`pollMaxMs`。
  - `slowLine` 形如 `ax: slow get AXChildren 6012 ms cannotComplete on main`；`summaryLine` 以 `ax: summary` 开头，含 `calls=`、`ms=`、`timeouts=`、`slow=`、`suppressed=`、`poll p50/p95/max`，以及按总耗时前 5 项 `op name n= p95= max=`。

- [ ] **Step 1: 写失败测试**
  - `slowLinesAreRateLimited`：同一分钟内 `noteSlowCall` 35 次 → 日志 30 行 `ax: slow`；下一次摘要含 `suppressed=5`；跨入下一分钟后又可写。
  - `tickWritesTheReportEvery30sAndTheSummaryEvery300s`：规则为「距上次写报告 ≥ 30 秒才写」「距上次摘要（初始为创建时刻）≥ 300 秒才写」。注入时钟依次在 0、29、30、299、300 秒各 `tick()` → 报告写 3 次（0、30、299 秒），摘要 1 行（300 秒）。
  - `reportFileIsOwnerOnlyAndDecodes`：`writeReport()` 后权限 `0600`，内容可解码为 `AXCallTimingReport`。
  - `unwritableReportDoesNotThrow`：报告路径的父目录是一个普通文件 → `tick()` 不抛，只写一行 `ax: report not written` 警告且同一原因不重复。
  - `outputsCarryNoContent`：样本名字只用 AX 属性名，`slowLine`、`summaryLine` 与报告 JSON 不含测试里放进 fake 树的标题文字。
  - `stateSummaryHasPollPercentiles`：`recordScope("watch.poll", …)` 三次后 `stateSummary()["polls"] as? Int == 3`。

- [ ] **Step 2: 运行，确认失败** `swift test --filter AXTimingReporterTests` → 编译失败。

- [ ] **Step 3: 实现与装配**
  - `main.swift`：`let axTimings = AXCallTimings()`；`let axReporter = AXTimingReporter(timings: axTimings, reportURL: DaemonPaths.axTimings, log: log.info)`；`let measured = MeasuredAXBackend(base: LiveAXBackend(), timings: axTimings)`；`measured.onSlowCall = axReporter.noteSlowCall`；原 `backend` 全部改用 `measured`；创建 `DaemonWatcher` 后 `watcher.axReporter = axReporter`。
  - `DaemonWatcher.poll`：在 `engine.poll` 前后取 `DispatchTime.now().uptimeNanoseconds`，成功与失败分支各调一次 `axReporter?.timings.recordScope("watch.poll", nanos:, ok:)`。
  - `writeState`：`if let axReporter { state["ax"] = axReporter.stateSummary(); axReporter.tick() }`。
  - 报告写入：`JSONEncoder`（sortedKeys）→ 同目录临时文件 → `setAttributes([.posixPermissions: 0o600])` → `replaceItemAt` / 原子 `write(to:options:.atomic)` 后再设权限。

- [ ] **Step 4: 运行，确认通过** `swift test --filter "AXTimingReporterTests|DaemonWatcherAvailabilityTests|WatchHealthTests|DaemonReadinessTests"` → PASS

- [ ] **Step 5: 提交** `feat(imctld): record AX call timings and report them locally`

### Task 6: 只读探针 `imctl probe ax-timing`

**Files:**
- Create: `Sources/imctl/Probe/AXTimingProbe.swift`
- Create: `Sources/imctl/Commands/ProbeAXTimingCommand.swift`
- Modify: `Sources/imctl/Commands/ProbeCommand.swift`（`subcommands` 加 `ProbeAXTimingCommand.self`）
- Modify: `README.md`（命令清单加一行）
- Test: `Tests/imctlTests/ProbeAXTimingTests.swift`；如有子命令清单断言则同步更新

**Interfaces:**
- Consumes: Task 2、Task 3、Task 4。
- Produces:
  - `struct AXTimingProbe { struct ModeResult: Equatable, Codable { var mode: String; var locateMs: [Double]; var conversationsMs: [Double]; var messagesMs: [Double]; var calls: Int; var axMs: Double; var timeouts: Int }; struct Result: Equatable, Codable { var rounds: Int; var messageTable: Bool; var single: ModeResult; var batch: ModeResult; var conversationsEqual: Bool; var conversationDiffs: Int; var messagesEqual: Bool; var messageDiffs: Int }; static func run(rounds: Int, base: AXBackend, root: (AXBackend) throws -> AXElement, now: () -> UInt64 = …) throws -> Result; static func render(_ result: Result) -> String }`
  - `ProbeAXTimingCommand`：`commandName: "ax-timing"`；`@OptionGroup var options: ProbeOptions`；`@Option var repeat: Int = 3`（校验 1–20）。

- [ ] **Step 1: 写失败测试**
  - `fixtureRunReportsBothModesAndEquality`：用 `wecom-5.0.11-main-window.json` 跑 2 轮 → `single.conversationsMs.count == 2`、`batch.calls < single.calls`、`conversationsEqual && messagesEqual`、两组差异数为 0。
  - `renderedReportHasNoText`：渲染结果（文本与 JSON）不含 fixture 里任何 `AXTitle` / `AXValue` 文字（遍历 fixture 收集），只含数字与固定标签。
  - `repeatOutsideRangeIsRejected`：`ProbeAXTimingCommand.parse(["--repeat", "0"])` 与 `"21"` 抛参数校验错误；默认值 3。
  - `diffCountsIgnoreHandles`：两组行只差句柄时 `conversationsEqual == true`（比较投影去掉 `handle`）。

- [ ] **Step 2: 运行，确认失败** `swift test --filter ProbeAXTimingTests` → 编译失败。

- [ ] **Step 3: 实现** 每轮先逐个后批次，各新建 `AXCallTimings` 与 `MeasuredAXBackend`；`root` 闭包：live 用 `AXApp.byBundleID(bundle, backend: measured)`，fixture 用 `AXElement(handle: fake.rootHandle, backend: measured)`；`WeComWindowLocator.mainWindow(from:)` 之后计时三步；行比较用不含 `handle` 的投影。命令先检查辅助功能授权（与 `ProbeSession.root` 相同的 `IMCTLError.notTrusted`），`--json` 输出 `ProbeSession.encode(result)`。

- [ ] **Step 4: 运行，确认通过** → PASS；`swift test --filter "imctlTests"` 全部 PASS。

- [ ] **Step 5: 提交** `feat(cli): add a read-only AX timing A/B probe`

### Task 7: 版本、运行数据文档、全量验证与门报告草稿

**Files:**
- Modify: `Sources/ControlCore/IMCTLVersion.swift`（`1.0.25-dev`，注释行 `/// 1.0.25-dev (2026-10-27): B61 — per-call AX timings (state.json, ax-timings.json, rate-limited log) and batched attribute reads on row parsing, layout location and tree dumps; read-only AX timing probe.`）
- Modify: `docs/ai-coding/AI_CODING_GUIDE.md` §6 表格（加 `ax-timings.json | AX 逐次计时报告（只有操作、属性名、毫秒、结果类别、线程） | 0600 | imctld，每 30 秒覆写`；`state.json` 内容补「AX 计时摘要」）
- Create: `docs/gates/2026-10-27-b61-ax-call-timing-batch-reads.md`（状态「待活体」：条件、实现、单测数字、活体表留空并写明待授权、未闭环与用户事项）
- Test: 版本相关断言（如有）

- [ ] **Step 1: 改版本与文档**；若有测试断言版本字符串则同步。
- [ ] **Step 2: 全量验证**
  Run: `swift build && IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`
  Expected: 全部通过；测试数 = 1,238 + 本批新增，套件数相应增加。
  Run: `bash scripts/check-secrets.sh`（逐条判断新增告警）、`git diff --check`、`git status --short`（无 `.raw.json`、临时文件、本机路径）。
- [ ] **Step 3: 写门报告草稿**（测试数、各任务改动、往返次数对比、待授权的活体步骤）。
- [ ] **Step 4: 提交** `docs(gates): record B61 offline results pending live timing`
