# 批次 B62：B61 审查延后的次要问题（2026-10-28 CST）— 通过（离线）；已随 B63 安装

条件：只做离线验证。本批未安装、未连接真实企业微信、未发送、未写入、未调用视觉提供商；版本 `1.0.26-dev`，基于 `main@0282ba5`（B61）。范围是 [B61 门报告](2026-10-27-b61-ax-call-timing-batch-reads.md) 列出的 7 项延后问题，维护者 2026-10-27 全部勾选，包括修改 CI。

## 实现

1. **计时输出改用单调时钟**（`Sources/imctld/AXTimingReporter.swift`）：报告每 30 秒、摘要每 5 分钟、慢调用每分钟限流三个时间窗改用开机以来的单调毫秒，墙钟只留给报告时间戳；注入的时钟若仍倒退，各时间窗立即到期，不再停住报告或一直压掉慢调用行。
2. **线程标签**（`Sources/AXKit/MeasuredAXBackend.swift`）：GCD 全局队列与普通线程报告的 `com.apple.root.*` 记为 `other`；主线程标签改在 `MainActor` 上实测，原来那条不在主线程执行的断言已替换。
3. **批次停用开关**（`Sources/AXKit/LiveAXBackend.swift`）：`BatchLatch` 在连续 50 次批次回退且从未成功时，为本进程停用批次 API，之后每个属性在访问时逐个读；只要成功过一次就不停用。守护进程记一行 `ax: batched reads switched off …`，`state.json` 的 `ax.batchingDisabled` 与摘要行的 `batching=off` 同步显示。
4. **CI 覆盖批次路径**：`IMCTL_FAKE_BATCH=1` 让 `FakeAXBackend` 默认像真实客户端一样回应批次读；`.github/workflows/ci.yml` 在原有一轮之后再跑一轮带此变量的 `swift test --no-parallel`。专门断言逐个读行为的 5 个测试（含 2026-09-23 的两项几何读取防护）显式设 `batchesReads = false`。`TESTING_SPEC.md` 与 `AGENTS.md` 的验证命令已同步。
5. **批次数组映射可离线测试**：`LiveAXBackend.mapBatchItems` 把 `CFNull`、AXError 项、转换值与长度不符的处理从实时调用里抽出来，测试用 `kCFNull` 与 `AXValueCreate(.axError, …)` 构造；无状态的转换函数改为 `static`。
6. **测试文件改名**：纯函数套件 `LiveAXBatchDispositionTests.swift` 改为 `AXBatchDispositionTests.swift`，`Live` 前缀按目录规范只留给需要 `IMCTL_LIVE` 的测试。
7. **整批超时写出属性名**：调用级 `cannotComplete` 现在报 `cannot complete get AXRole,AXValue…`（属性名都是代码常量），`clientUnavailable`、diagnose 与日志能看出是哪批属性超时。

不变：协议（方法、字段、错误码、MCP 工具数 45）、策略与白名单、按键清单、权限面、视觉上传、checkpoint / 幂等 / `unknown`、超时数值。

## 单测

- `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`：**1,306 项 / 171 套件 / 10 程序全部通过**（B61 为 1,296）。
- 同上再加 `IMCTL_FAKE_BATCH=1`：**1,306 项 / 171 套件 / 10 程序全部通过**。未固定 `batchesReads` 之前，这一轮恰好是审查指出的 5 个测试失败。
- 每项修改都先写出会失败的测试：`aClockGoingBackwardsDoesNotStall`（三个时间窗都停住）、`globalQueuesAndPlainThreadsReadOther`、`batchingStopsAfterRepeatedFallbacksWithoutASuccess`、`batchingOffIsReportedWhenKnown`、`batchItemsMapLikeSingleReads`、`wholeBatchTimeoutNamesItsAttributes`。
- `ForbiddenAPITests` 通过；`bash scripts/check-secrets.sh` 为既有 11 条示例 / 模板告警，无新增；`git diff --check` 通过。

## 活体

本批合并时不安装、不做活体。10-28 09:55 随 B63 装为 1.0.26 / build 13（构建、签章与回滚包见 [B63 门报告](2026-10-28-b63-mqtt-reconnect.md)），之后只读核对：

- `ax-timings.json` 约每 30 s 更新（0600），首个 `ax: summary` 在启动后 5 分钟整写出：调用 34,764 次、超时 0、慢调用 0、批次回退 0，轮询 301 次失败 0，p50 20 ms、p95 36.7 ms。30 s 报告与 5 分钟摘要两个时间窗在单调时钟下按时到期；慢调用每分钟限流的窗口要等出现慢调用才看得到。
- `state.json` 的 `ax.batchingDisabled` 为 false，没有 `ax: batched reads switched off` 日志行；B61 活体期间批次回退也为 0，正常情况下停用开关不会触发。
- 线程标签 `other` 与整批超时写出的属性名，要等出现非主线程调用或整批超时时才看得到；至此只有 `main` 一个线程。

## 结论与未闭环

- 离线通过；10-28 09:55 随 B63 安装，安装后只读核对正常。
- 停用阈值 50 是经验值：每秒约 115 次 AX 调用时，完全不能批次的客户端约在半秒内被识别。
