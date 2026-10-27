# 批次 B61：AX 逐次计时与批次读取（2026-10-27 CST）— 通过（只读范围）

条件：离线验证（`FakeAXBackend` 与 `Tests/Fixtures/ax-trees/` 录制夹具）之后，维护者 2026-10-27 授权安装本批构建并做只读实测（不发送、不写入）。实测在本机企业微信 5.0.13（本版未校准）、用户 LAN 的 EMQX、守护进程 MQTT + socket 下进行；全程未发送、未写入、未调用视觉提供商；分支 `feat/ax-call-timing-batch-reads`，基于 `main@539fbb9`，版本 `1.0.25-dev`。规格与计划：[spec](../superpowers/specs/2026-10-27-b61-ax-call-timing-batch-reads.md)、[plan](../superpowers/plans/2026-10-27-b61-ax-call-timing-batch-reads.md)。

## 实现

- **计时（AXKit）**：`AXCallTimings` 按「操作 + AX 属性 / 动作名」聚合次数、总耗时、最大值、分桶百分位（上界不超过实测最大值）、结果类别、队列标签与调用方计时的范围，保留最近 64 条 ≥ 500 ms 的慢样本。`MeasuredAXBackend` 包装任意后端，对每次跨进程原语计时；错误、句柄与 `name` 原样透传。
- **批次读（AXKit）**：`AXBackend.attributes(_:of:)`。Live 用 `AXUIElementCopyMultipleAttributeValues`：调用级 `cannotComplete` / 失效元素 / 未授权直接失败，不退回逐个读（避免把一次超时放大）；其他调用级错误或数组形状不符返回空结果，计入 `batchFallbacks`。空结果表示没有批次，`AXAttributeSnapshot` 在访问时才逐个读取，读取内容与次序和本批之前相同；`FakeAXBackend` 默认如此，`batchesReads = true` 时模拟会批次的元素。快照访问器保留 AXRole / AXValue / frame 的 -25201 单次重试。
- **改用批次读的路径（WeComAdapter / AXKit）**：会话行、消息行、版面定位的遍历、树导出。判断顺序与错误传播不变。
- **守护进程**：`imctld` 以 `MeasuredAXBackend` 包住 `LiveAXBackend`，命令处理器与观察者共用；每次观察轮询记 `watch.poll` 范围；`state.json` 增加 `ax` 摘要；`ax-timings.json`（0600）每 30 秒覆写；单次 ≥ 1 秒的调用写一行 `ax: slow …`（每分钟最多 30 行），每 5 分钟一行 `ax: summary …`（含被限流行数与批次回退数）。
- **CLI**：`imctl probe ax-timing [--repeat N] [--json] [--from-fixture …]`，每轮逐个读、批次读、再逐个读一次，输出耗时、AX 往返、超时、回退与两种解析是否一致（只有数字与固定标签）；批次结果与前后两次逐个读都不同才算不一致，两次逐个读之间的差异另报，客户端在量测中途变化不会误报。
- 不变：协议（方法、字段、错误码、MCP 工具数 45）、策略与白名单、按键清单、权限面、视觉上传、checkpoint / 幂等 / `unknown`、`LiveAXBackend` 2 秒消息超时的设置方式与数值。

## 单测

- `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`：**1,296 项 / 171 套件 / 10 程序全部通过**（B60 基线 1,238 / 163）。新增 8 个套件：AXCallTimings、MeasuredAXBackend、AXAttributeSnapshot and batched reads、LiveAXBackend batch dispositions、Batched reads parse like single reads、AX timing reporter、Daemon watcher AX timings、probe ax-timing。
- 14 份录制夹具上，批次读与逐个读得到的版面、会话行与消息行完全相同；2026-09-23 的两项几何读取防护测试未改断言仍通过（逐个读时仍只读用到的节点）。
- 往返次数（同一夹具，逐个读 = 本批之前的读法，含定位、会话列表与消息表）：

| 夹具 | 逐个读 | 批次读 | 减少 |
|---|---|---|---|
| 5.0.10 主窗口 | 321 | 190 | 41% |
| 5.0.11 主窗口 | 281 | 148 | 47% |
| 5.0.11 外部群 | 584 | 303 | 48% |
| 5.0.11 文件 / 视频消息表 | 61 | 24 | 61% |

  定位遍历中的单独几何读取由 53 次降为 3 次（遍历后读消息滚动区自身的 frame）。录制夹具都带 `AXFrame`；真实 Qt 元素若没有 `AXFrame`，逐个读每次取 frame 要 3 次往返，实际节省可能更多，以活体为准。
- `ForbiddenAPITests` 通过（AX 符号只在 `LiveAXBackend.swift`）。`bash scripts/check-secrets.sh` 为既有 11 条示例 / 模板告警，本批无新增；`git diff --check` 通过。

## 活体 / 只读探针

| 步骤 | 结果 |
|---|---|
| 安装（21:12 CST） | build 21，由分支 `854e036` 构建（之后的分支提交只改文档）。三个可执行文件的 designated requirement 与 1.0.24 / build 9 逐字相同（同一 Apple Development 证书），TCC 授权保留（`trusted`）；LaunchAgent 与全部设置未改。SHA-256：imctl `f9297e95…`、imctl-console `530c5028…`、imctld `882f1011…`。回滚包 `out/rollback/imctl-1.0.24-build9-20261027.zip`（不入库，SHA-256 `824fe73f…`），解包后签章与三个可执行文件哈希已核对。 |
| 健康 | `imctl doctor --offline` 就绪：守护进程与安装版同为 build 21、未暂停、MQTT 已连、技能文件为当前版本。企业微信已更新到 5.0.13，本版未校准。 |
| A/B 探针（`imctl probe ax-timing --repeat 5`） | 两种解析一致：会话与消息 0 处不一致、0 处客户端变化。逐个读 1,830 次 AX 往返、AX 合计 103.3 ms；批次读 865 次（−53%）、63.4 ms（−39%）。中位耗时：定位 2.1 / 2.4 ms，会话列表 5.1 / 5.0 ms，消息表 6.2 / 5.4 ms。0 超时、0 回退。 |
| 新旧版本对照 | 1.0.24（逐个读）与 1.0.25（批次读）的 CLI 只读探针，在同一客户端上不脱敏输出逐字段相同（会话 14 行、消息 9 行，两轮）；比较只在本机进行，输出随即删除。 |
| 只读命令 | `conversation.list` 0.06 s（14 行）；`controller.diagnose` 0.07 s。`message.history` 返回 `INVALID_PARAMS`（`scrollHistory` 需要目标）：当前窗格有消息表但没有可读标题与输入框，新旧版本都读不到活动会话标题，在任何 AX 动作之前即被拒绝，未操作客户端，本批未测到它的耗时。 |
| 守护进程连续运行 30 分钟（21:12:31–21:43:01） | 观察轮询成功 1,834 次、失败 2 次；轮询耗时 p50 20 ms、p95 50 ms、最大 1,505 ms。AX 调用 210,884 次（115 次/秒），合计 36.4 s（约占 2.0% 时间）：主线程（观察）210,483 次，执行器 401 次。批次读 145,855 次、单读 64,661 次，批次回退 0。超时 2 次，都是主线程单读 `AXValue`，各 1,505 ms 后 `cannotComplete`（21:33:18、21:38:13），各记一次 degraded，下一次轮询即恢复，未进入 system 暂停；另有一次 `AXRole` 单读 808 ms 成功。消息单元格子元素的批次里有 1,106 项返回 `-25200`，都是解析不读取的属性，轮询与 A/B 解析均不受影响。 |
| 写入与不确定状态 | 安装后只有上面三个只读命令；`unknown` 仍为原有 2 条，0 个 checkpoint，无发送、无写入。 |

活体通过的三项判断都满足：A/B 两种解析一致、批次回退为 0、没有新增 `unknown` 或写入。

量测发现（只描述这 30 分钟）：
- 本窗口没有复现 7–46 秒的慢读；企微平均约 0.17 ms 回应一次 AX 调用。
- 两次超时都在约 1.5 秒结束，而不是 2 秒（应用元素）或假设中子元素的 6 秒默认值；「慢读来自子元素沿用 6 秒默认超时并累加」在这批样本里没有得到支持。超时数值不调，等繁忙时段的更多样本。
- 安装前的旧进程 8 天累计成功轮询 175,950 次、失败 531,004 次；本次 30 分钟只失败 2 次。客户端当时所在窗格不同，不能据此归因于 B61。
- 仍为单读的调用每 30 分钟约 6.5 万次（`AXRole` 3.5 万、`AXChildren` 1.5 万、`AXFrame` 0.66 万，来自尚未改造的窗口定位、导航栏角标与会话头部等路径），可作为后续批次的候选。

## 结论与未闭环

- 离线与只读活体通过。超时数值（全局、逐元素、按命令期限）不在本批；本次只观察到 2 次约 1.5 秒的超时，等更多样本再另批决定。
- 安装的是分支构建 build 21；合并（squash）后 `main` 的提交数变少，下一次从 `main` 构建的 build 号会小于 21，这是 build 号按提交计数的结果，不代表回退。
- 读取不完整标记与遍历期限、导航栏角标与各面板等其他读取路径未改，按量测数据再定。
- 消息行解析也服务发送后的外发证据：只读活体 A/B 确认两种解析一致之前，不据此做任何真实写入；真实写入另需授权。
- 独立审查（全新上下文）：0 个严重、0 个重要、8 个次要。探针在量测中途客户端变化时会误报不一致，按影响升为重要并已修正（先失败的测试 `aClientChangeBetweenPassesIsNoiseNotADiff`，另加 `aRealParseDifferenceIsCounted`）。其余 7 项延后、待维护者决定：报告节奏用墙钟、线程标签取不到 `other`、企微无法批次时没有自动停用（改为活体判断条件）、CI 未在批次模式下跑既有测试、Live 数组项映射只有活体测试、`LiveAXBatchDispositionTests.swift` 命名与目录规范的 Live 前缀不符、整批超时的错误信息不再写属性名。
- 回滚：重装 1.0.24 / build 9（签名身份不变，TCC 授权保持），或 revert 本批提交；`ax-timings.json` 可直接删除。
