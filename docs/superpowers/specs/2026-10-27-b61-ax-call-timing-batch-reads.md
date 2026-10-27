# B61：AX 逐次计时与批次读取

守护进程的企微读取偶尔要 7–46 秒（B13、B21/B22/B25 门报告），但现在只有命令首尾时间，没有每次 AX 调用的耗时与错误码，无法判断是企微主线程繁忙、多次消息超时累加，还是单纯调用次数太多。维护者 2026-10-27 决定先做同类项目研究报告的 P0 第 1、2 项：加上 AX 逐次计时与批次读取；离线测试通过后，再另行取得安装与只读实测的授权。本批不调整任何超时数值，收紧超时等量测结果出来后另批决定。

## 事实与假设边界

- `LiveAXBackend` 只在 `applicationElement(pid:)` 新建的应用元素上调用 `AXUIElementSetMessagingTimeout`（默认 2 秒）。依 macOS SDK 头文件，这个设置只作用于被设置的元素；从属性读出的窗口、表格、行等子元素沿用系统默认超时。「慢读来自子元素沿用默认超时并多次累加」是待量测的假设，不是结论。
- 守护进程每次轮询（约每秒一次，另有 AX 通知触发）都完整解析会话列表：每一行约 20 次单属性读取（role、frame 或 position/size、children、子元素的 role/value/frame/title、selected）。每次构造 `WeComReader` 都会走一遍 `WeComLayout.locate` 的广度优先定位，每个元素至少读一次 role，候选元素再读 frame（`AXFrame` 不存在时还要读 position 与 size）。
- AX 调用同步跨进程，每次往返都占用企微主线程；同一份属性分多次读，次数就是延迟与超时风险的乘数。`AXUIElementCopyMultipleAttributeValues` 可以一次读回一个元素的多个属性。

## 目标

1. 守护进程内每一次 AX 原语调用都计时，记录操作、属性或动作名、耗时、结果类别与错误码、调用线程；汇总后本机可读。记录不含任何标题、正文、名字、号码或屏幕内容。
2. `AXBackend` 新增批次读原语；会话行、消息行、版面定位与树导出这四条热点读取路径改用批次读，解析结果与原逐个读取完全等价。
3. 新增只读 CLI 探针 `imctl probe ax-timing`：在真实客户端上交替以批次读与逐个读解析会话列表与消息表，输出两种方式的耗时、调用次数，以及两种方式解析结果是否一致（只给布尔值与不一致行数，不输出内容），供下一步只读实测使用。

## 非目标与反目标

- 不改 `AXUIElementSetMessagingTimeout` 的数值，不加按命令期限推导的逐元素超时，不给 system-wide 元素设全局超时：这些要等量测数据，另批决定。
- 不改 `descendants` 等遍历的上限，也不加「读取不完整」标记（调用方语义会变，留给后续批次）。
- 不改协议：方法、参数、结果、事件字段、错误码、MCP 工具数量（45）都不变。不改策略、白名单、按键清单、权限面、视觉上传、checkpoint、幂等与 `unknown` 语义。
- 不新增 SwiftPM 依赖，不新增 macOS 权限。
- 反目标：为了更快而让解析结果与原逐个读取有任何差异；计时日志带出任何聊天内容或身份信息；计时本身明显拖慢轮询（日志不得每次调用都写）。

## 设计

### 1. 逐次计时

- **`AXCallTimings`（AXKit）**：加锁的聚合器，进程内一份。按「操作 + 属性名」累计次数、总耗时、最大值、分桶直方图（毫秒上界 1/2/5/10/20/50/100/200/500/1000/2000/5000/10000/30000/∞）与结果类别计数；按线程标签累计；另有「范围」统计（守护进程用来记每次轮询的总耗时与成败）；保留最近 64 次超过慢阈值（默认 500 ms）的样本（发生时间、操作、属性名、毫秒、结果、线程）。`report()` 生成可编码的报告（p50/p95/p99 取所在分桶上界，落在 ∞ 桶时取最大值），`reset()` 清零。
- **`MeasuredAXBackend`（AXKit）**：包装任意 `AXBackend` 的装饰器。对 `attribute`、`attributes`（批次）、`attributeNames`、`isAttributeSettable`、`setAttribute`、`actionNames`、`performAction`、`pid` 计时并记录；`isProcessTrusted`、`applicationElement`、`makeObserver` 不经企微跨进程往返，直接转发不计时。`name` 返回被包装后端的名字（保持既有 `backend.name == "live"` 判断不变）；错误原样抛出，句柄原样传递。时钟（单调纳秒）、墙钟毫秒与线程标签均可注入，测试不 sleep。`batchReads: false` 时不批次，每个属性在被访问时才逐个读取并计时，即 B61 之前的读法，供探针做 A/B；批次调用返回空结果时记为 `fallback`。
- **结果类别**：`ok`、`noValue`、`unsupported`、`notSettable`、`actionUnsupported`、`cannotComplete`、`invalidElement`、`notImplemented`、`notTrusted`、`valueNotConvertible`，其余 `AXKitError.apiFailure` 记为 `error:<code>`（如 `error:-25201`）。批次调用成功时另计每一项的非 `ok` 结果（`item:<类别>`），用来观察 WeCom 的 -25201 暂态。
- **线程标签**：主线程记 `main`，其余取当前 dispatch 队列标签（如 `com.sunkailun.imctl.executor`），取不到记 `other`。轮询（主线程）与命令（执行器队列）因此可以分开看。
- **守护进程装配**：`imctld` 以 `MeasuredAXBackend(base: LiveAXBackend(), …)` 取代原后端，命令处理器与观察者共用同一个实例。`DaemonWatcher` 把每次 `engine.poll` 的耗时记为 `watch.poll` 范围。
- **本机输出**（只含操作、属性名、毫秒、结果类别、线程标签与计数）：
  - `state.json` 增加 `ax` 摘要：调用次数、总毫秒、超时（`cannotComplete`）次数、慢调用次数、轮询次数与 p50/p95/最大毫秒；`imctl status` 原样显示。
  - 新运行数据文件 `~/Library/Application Support/imctl/ax-timings.json`（0600），每 30 秒原子写入完整报告（前 30 个操作、线程、范围、慢样本）。
  - 守护进程日志：单次 ≥ 1 秒的调用写一行 `ax: slow …`，每分钟最多 30 行，超出部分计数后并入下一行摘要；每 5 分钟写一行累计摘要。

### 2. 批次读取

- **原语**：`AXBackend` 新增 `attributes(_ names: [String], of: AXElementHandle) throws -> [String: AXAttributeResult]`，`AXAttributeResult = Result<AXAttributeValue?, AXKitError>`。重复的属性名只读一次。空结果表示没有批次：快照在访问时才逐个读取，读取内容与次序和 B61 之前完全相同。协议扩展的默认实现就返回空结果；`FakeAXBackend` 默认如此（既有测试的 `onRead` 计数与注入失败不变），`batchesReads = true` 时一次读回全部请求的属性，模拟会批次的后端。
- **Live 实现**：`AXUIElementCopyMultipleAttributeValues`（options 为 0，单项错误放进返回数组）。
  - 调用级 `cannotComplete` → 抛 `cannotComplete`；`invalidUIElement` → `invalidElement`；`apiDisabled` → `notTrusted`。这三种对逐个读取同样是第一次读就失败，不会退回逐个读取而把一次超时放大成多次。
  - 调用级其他错误（`notImplemented`、`illegalArgument`、`failure`、不支持等），或返回数组长度与请求不符 → 返回空结果（访问时逐个读，只读真正用到的属性），并计入 `batchFallbacks` 供探针与守护进程报告。
  - 数组项为 `CFNull` → `.success(nil)`；为 AXError 类型的 `AXValue` → `noValue` 记 `.success(nil)`，其余按单读相同的映射记 `.failure`（操作串同为 `get <属性名>`，暂态判断与单读一致）；其余值按单读相同的转换记 `.success`。
- **快照访问器 `AXAttributeSnapshot`**：`AXElement.read(_ names:)` 返回。访问器与 `AXElement` 同名 getter 语义一致，全部是「不支持即 nil」：`attributeIfSupported`、`string`、`bool`、`elements`/`children`、`role`、`subrole`、`title`、`value`/`valueString`、`axDescription`、`identifier`、`isEnabled`、`isSelected`、`isFocused`、`frame`。`role`、`value`、`frame`（含 position/size 退路）沿用「-25201 时只对该属性单读重试一次、第二次失败原样抛出」：批次那一次算第一次读。单项其他失败只在被访问时抛出，与逐个读取「读到才失败」一致；访问未包含在批次里的属性时退回单读。
- **改用批次读的路径**（解析逻辑、判断顺序与错误传播不变）：
  1. `ConversationRowParser.parse`：行、单元格、单元格子元素各一次批次读。
  2. `MessageRowParser.parse`：同上；`readableValue` 的部分行语义不变（AXValue 暂态重试后仍失败才记 `AX_VALUE_UNAVAILABLE`）。
  3. `WeComLayout.locate`：每个遍历到的元素一次批次读 role 与 frame（含 position/size）；子元素仍在出队时单独读取，表格依旧不展开。
  4. `AXTreeDumper.visit`：每个节点一次批次读全部标准属性、额外属性与 children；actions 与可设置性探测仍逐个调用。
- **不改**：所有 set / action 原语、可设置性与动作名读取、其他面板与导航栏角标等解析（量测后按数据再定）。

### 3. 只读探针 `imctl probe ax-timing`

- `imctl probe ax-timing [--repeat N（默认 3，1–20）] [--json] [--bundle …]`。定位企微主窗口后，每一轮依次逐个读、批次读、再逐个读一次（各自新建 `MeasuredAXBackend`），每次都做：定位版面、解析会话列表、有消息表时解析消息表。第二次逐个读不计时，只用来区分「客户端在两次读取之间变了」与「两种读法不一致」：批次结果与前后两次逐个读都不同才算不一致；前后两次逐个读之间的差异另报为「两次逐个读之间的变化」。
- 输出：每种方式每一步的耗时（中位数与最大值）、AX 调用次数、AX 总耗时、超时次数；以及「两种方式解析结果是否一致」：会话行与消息行去掉句柄后逐字段比较，只给 `equal` 与不一致行数。不输出标题、正文、发送者或任何元素文字。
- 不做任何 set / action，不截图、不上传，不经守护进程；与其他 `probe` 一样需要当前进程的辅助功能授权。

## 安全与回滚

- 计时与探针都是只读；记录、文件、日志与探针输出只有操作名、AX 属性名、计数、毫秒、结果类别与线程标签。
- 消息行解析也服务于发送后的外发证据。改用批次读后，先经全部录制夹具的「批次 = 逐个」离线等价测试，再经授权的只读活体 A/B 等价核对；之前不得据此做任何真实写入，真实写入另需用户授权。
- 回滚：重装 1.0.24/build 9（原安装包与签名身份不变，TCC 授权保持），或 revert 本批提交。`ax-timings.json` 可直接删除。

## 离线验收

- `AXCallTimings`：聚合、分桶百分位、结果类别、线程与范围、慢样本保留上限、`reset`、并发记录计数不丢。
- `MeasuredAXBackend`：每个计时原语一条记录且错误原样抛出；不计时的原语不产生记录；`name` 透传；`batchReads` 两种模式的记录形态；慢调用回调只在阈值以上触发。
- 批次读：默认实现与快照访问器对存在值、不支持、无值、注入失败、-25201 暂态重试（次数与单读一致）、未列入批次的属性、重复属性名的行为；`frame` 退路。
- 四条改造路径：全部录制夹具上批次读与逐个读的解析结果相同，且批次读的往返次数至少少 30%（2026-10-27 录制夹具上少 41%–61%）；既有解析与处理器测试（含 2026-09-23 的几何读取防护）全部不改断言通过。
- 守护进程：`watch.poll` 范围记录、`state.json` 的 `ax` 摘要、`ax-timings.json` 原子写入且权限 0600、慢日志限流与 5 分钟摘要的格式不含内容。
- CLI：子命令列表、参数校验、报告格式与「只输出布尔值和计数」。
- `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test` 全部通过并记录数字（基线 1,238 项 / 163 套件 / 10 程序），`bash scripts/check-secrets.sh` 逐条判断，`git diff --check` 通过。

## 活体验收（待授权）

离线全部通过后，向维护者申请：①安装本批构建（沿用稳定签名身份，保留 LaunchAgent 与设置）；②只读实测：守护进程正常运行至少 30 分钟取得计时报告，执行少量只读命令（`conversation.list`、`message.history`、`controller.diagnose`），以及 `imctl probe ax-timing --repeat 5`。门报告记录超时次数与耗时、批次读前后的调用次数与耗时、A/B 等价结果；任何不一致都停在只读，回滚后再查。获准前不安装、不跑活体。

## 用户事项

- 安装与只读实测授权（维护者 2026-10-27 要求离线通过后再问）。
- 超时数值（全局、逐元素与命令期限）待量测后决定。
