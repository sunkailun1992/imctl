# IM Control Protocol — imctl MQTT 对接协议（`im-control/0.1`）

本页是 imctl 对外协议的**唯一权威文档**：任何语言 / 平台（Java、Python、Go、Node、其它 Mac 上的另一个控制器）只要按本页实现，就能向 imctl 下命令并消费它推送的事件。它与代码同一提交维护：`Tests/MCPTransportTests/ProtocolDocTests.swift` 会核对仓库里的每个方法名、事件名、错误码、`tools/list` 名称和 topic 是否都出现在本页，缺一个 `swift test` 失败。`java-consumer.md`（Java 视角）与 `wecom-token-proxy.md`（代理 HTTP 与回调）只做补充，不复制定义。

字段命名：JSON 一律 camelCase（例外见 6.7 `command.get` 的原始记录）；企微接口自身的 JSON（附件、回调 payload）保持企微原名。时间戳一律毫秒 epoch（`tsMs`、`createdMs`…）。

## 1. 角色与原则

| 角色 | 职责 |
|---|---|
| 控制器（imctl / `imctld`，一台 Mac 一个 `controller_id`） | 读桌面企微客户端、按策略发文本、观察并推送事件；经令牌注入代理调企微官方接口 |
| 业务侧（Java / 任意语言） | 只发命令、只做消息业务：回不回、回什么、给谁、何时按会话人工接管；目标用平台 ID |
| 令牌注入代理（云端） | 持企微 secret，注入 `access_token` 转发；接收企微回调，验签解密后发布 MQTT 事件 |

四条原则：**响应是便利、事件是真相**（响应可丢，事件按 `eventId` 单调可重放）；**QoS 1 下有幂等键的状态变更方法同键不重做**（只读方法可能因重复投递再次读取）；**客户端提交并观察到协议规定的后验事实才是 `succeeded`**（不证明平台送达）；**方向 / 来源 / 类型为 `unknown` 的消息不驱动自动回复**。视觉模型可协助固定桌面命令的定位，但模型回答本身不是执行证据。

## 2. 传输（MQTT 5）

### 2.1 连接

- 控制器：MQTT 5，`clientId = imctl-{controller_id}`，`cleanStart = false`，`sessionExpiryInterval = 86400`，keepalive 30 s，QoS 1；用户名 = `controller_id`，密码每机独立（`imctl enroll`；ACL 见 `docs/ops/emqx-auth-acl.md`）。`controller_id` 由 `imctl enroll` 或控制台设置页登记：登记时只接受 1–64 个 `A–Z a–z 0–9 . _ -`（它是 topic 的一段），已有配置读取时不校验；不填时沿用已登记的 id（`mqtt.json` 在却读不了就报错，不猜），没有就由本机「本地主机名」得出（转小写，其它字符换成 `-`，最长 64）；同一 broker 上每台 Mac 的 id 必须不同（B52 追加）。
- 业务侧：MQTT 5，`cleanStart = false`，`sessionExpiryInterval ≥ 86400`，每个实例一个稳定 `clientId`（如 `java-<instance>`），QoS 1。

### 2.2 Topic

| Topic | 方向 | 内容 |
|---|---|---|
| `im/{controller_id}/cmd` | 业务侧 → 控制器 | JSON-RPC 2.0 请求（一条消息一个请求） |
| `im/{controller_id}/rsp` 及其子树 `im/{controller_id}/rsp/{instance}` | 控制器 → 业务侧 | JSON-RPC 2.0 响应；发到请求的 Response Topic；Response Topic **不在** `im/{controller_id}/` 子树内时改发 `im/{controller_id}/rsp` |
| `im/{controller_id}/evt` | 控制器 → 业务侧 | 事件流（第 7 节），QoS 1，不 retain，按 `eventId` 顺序 |
| `im/{controller_id}/state` | 控制器 → 业务侧 | retained 在线状态（2.5） |
| `wecom/{corp_id}/evt` | 代理 → 业务侧 | 企微回调事件（第 9 节，`wecom-token-proxy.md`） |

业务侧多实例用共享订阅 `$share/{group}/im/+/evt`（任一实例收到即落库）；`wecom/+/evt` 同理。

### 2.3 命令消息属性

- 请求：发布到 `im/{controller_id}/cmd`，QoS 1，MQTT 5 属性 `Response Topic = im/{controller_id}/rsp/{instance}`、`Correlation Data = <请求 id 的字节>`。
- 响应：控制器把 `Correlation Data` 原样回显；user property `controller_id`。没有 `id` 的请求是通知，不回响应。

### 2.4 事件消息属性

- user properties：`controller_id`、`event_id`、`kind`。
- 控制器每 250 ms 把新事件按 `eventId` 顺序发布，游标在发布成功后持久化：崩溃可能造成**重复**，不会造成乱序；消费方以 `(controllerId, eventId)` 去重。

### 2.5 状态与遗嘱

`im/{controller_id}/state`（retained，QoS 1）：

```json
{"online": true, "controllerId": "mac-01", "version": "1.0.3", "protocol": "im-control/0.1", "tsMs": 1789300000000, "pid": 10291}
```

正常退出发 `online:false`；连接异常断开由 broker 发布遗嘱 `{"online": false, "reason": "will", …}`。`online` 从 false 变 true 时消费方应做一次 gap 对账（第 8 节）。

### 2.6 其它绑定（同一方法集）

- 本机行分隔 JSON-RPC：`imctld run --stdio` / `--socket <path>`（socket 父目录须 0700）。
- MCP：`initialize`、`tools/list`（每个方法一个工具，另含查询 `event.replay`、`message.media`、`controller.readiness`）、`tools/call{name, arguments}` → `content[0].text` 为下文的命令记录 JSON，`isError` 在 `failed` / `expired` 时为 true。

## 3. 信封（JSON-RPC 2.0）

请求：

```json
{"jsonrpc": "2.0", "id": "6f1c…", "method": "message.send",
 "params": {"target": "chatId:wrABC", "text": "你好", "idempotencyKey": "k-2026-09-14-0001", "ttlMs": 30000, "issuedAtMs": 1789300000000}}
```

成功响应（`result` 是**命令记录视图**，方法结果在 `result.result`）：

```json
{"jsonrpc": "2.0", "id": "6f1c…", "result": {
  "commandId": "BDE07870-…", "method": "message.send", "state": "succeeded",
  "createdMs": 1789300000100, "updatedMs": 1789300000206, "idempotencyKey": "k-2026-09-14-0001",
  "checkpointMs": 1789300000150,
  "result": {"state": "succeeded", "evidence": "row #12 dir=outbound time=23:24", "latencyMs": 106}}}
```

失败通常也是成功响应，只是 `result.state = "failed"` 且带 `result.error = {"code": "TARGET_NOT_ALLOWED", "message": "…"}`；命令记录与 `command.state` 事件同样存在。只有**在建立命令记录之前**就无法受理的请求才用 JSON-RPC 错误：

```json
{"jsonrpc": "2.0", "id": "6f1c…", "error": {"code": -32000, "message": "message.send requires idempotencyKey", "data": {"code": "INVALID_PARAMS"}}}
```

JSON-RPC 错误码：`-32700` 解析错误、`-32600` 无效请求、`-32601` 方法不存在、`-32602` 未知工具（MCP）、`-32000` 受理失败（`data.code` 为第 10 节的错误码）。`event.replay` 是查询：响应的 `result` 直接是查询结果（6.12），不建命令记录。

B54：命令因视觉轮次停下（模型选 stop、轮次用尽未证实）或视觉出错而以 `failed` / `unknown` 结束时，记录视图多一个 `diagnosis`：`{"visual": {"goal", "phase", "round", "outcome"}, "irreversibleSteps"}`。`goal` / `phase` 是命令停在的那个视觉步骤的目标种类（如 `contactSendVerification`、`conversationRow`，不含标题或名字）和阶段；`round` 是该步骤内最后一轮的序号，从 1 起，该步骤还没请求模型就结束时为 0；命令还没进入任何视觉步骤就结束时 `goal` / `phase` 为 `none`。`outcome` 是 `stop`、`unverified` 或视觉错误类别（如 `timeout`、`staleView`）。`irreversibleSteps` 是本命令已写下的 checkpoint 数：每个都在可能不可逆的桌面写入或按键之前写下，写入或按键本身可能已发生，也可能没有。只含固定类别；没有它的记录与旧版一致。

标识分层：`id` 只关联请求与响应；`idempotencyKey` 由业务侧生成、全局唯一、≥24 h 不复用，控制器持久化；`commandId` 与 `eventId` 由控制器生成（`eventId` 单调无空洞）。

固定方法仍是唯一命令入口：MQTT 消息不能携带“替我看屏幕并自行操作”的自由文本任务、模型 API 地址、密钥或任意点击坐标。B17 的**目标设计**是在本机已启用云端视觉及独立整窗许可时让桌面命令由所选模型协助完成有界多轮观察与 AX 控件选择；这不改变 JSON-RPC 信封、method、参数、Response Topic、Correlation Data 或现有方法的结果字段。当前是否已经支持某个方法，必须以 B17 门报告中的实现矩阵和活体证据为准；调用方不能从收到成功的 MQTT 响应推断曾调用模型。

## 4. 命令生命周期

- 状态：`accepted → running → succeeded | failed | unknown | expired`（`cancelled` 保留：`command.cancel` 当前恒为空操作）。每次状态变化产生一条 `command.state` 事件。
- 幂等：同一个 `idempotencyKey` 的第二次请求返回第一次的命令记录，**不重新执行**；`unknown` 也是终态——业务侧须先对账（读 `message.observed` / `message.history`），确认需要真正再发时才换新键。
- B54：`unknown` 的含义不变；因视觉结束的命令另带 `diagnosis`（第 3 节），写明停在哪个视觉步骤的哪一轮、已写下几个 checkpoint；仍须按原键对账，不换键重试。
- 过期：`ttlMs + issuedAtMs < 控制器当前时间` 时直接 `expired`（`EXPIRED`）。
- 暂停 reason set `{api, local_guard, system}`：非空时 `message.send` 与 `conversation.read` 直接 `failed`（`PAUSED`）；`controller.pause` / `controller.resume` 只增删 `api`；`local_guard` 由控制器在人留草稿等情况置位；`system` 由控制器按客户端可达性置位（停在通讯录页——包括有其它企微窗口（如命令打开的「添加客户」面板或「发送验证申请」窗口）挡在它前面时——算可达）。API 路线方法（6.13–6.28）不受暂停影响。
- 速率硬上限：同一会话 ≥ 3 s 间隔（`chatId:` / `externalUserId:` 经身份桥解析，与标题写法共用一个间隔；桥未命中的 id 按原串计）、全局 60 s 内 ≤ 20 次，按尝试计数；超出 `failed` + `RATE_LIMITED`。业务侧只能更严。
- 发送阶段：locate → open → verify_target → precheck_input → compose → **submit（不可逆点，之前落盘 checkpoint）** → confirm（证据 = 匹配的外发气泡）。控制器重启后"有 checkpoint 无证据"的命令一律 `unknown`（`errorCode = UNKNOWN_AFTER_RESTART`），绝不重跑。

### 4.1 固定桌面命令的有界视觉执行（B17 目标契约与 B34–B44 限定步骤；以门报告确认活体范围）

业务侧继续发送本页 §6 已定义的固定命令。B17 的**目标桌面范围**包括 `account.status`、`conversation.list`、`conversation.read`、`message.history`、`message.send`、`message.sendFile`、`client.navigate`、`contact.list`、`contact.request.list`、`contact.request.accept`、`contact.add`、`group.create`、`group.rename`、`group.addMembers`、`broadcast.confirm`；`message.broadcast` 的每个 `message.send` 子命令沿相同控制路径执行。列入目标范围不代表该方法已接入模型；逐方法上线状态和证据见 B17 门报告。`policy.*`、`command.*`、`controller.*`、`event.replay`、其余企微官方 API 方法、后台 `message.observed` watcher 与 B15 媒体方向判断不因本机制上传窗口。`message.media` 的缓存 / OSS 查询也不作为新的视觉命令入口。

按当前源码，`account.status` 和 `conversation.list` 有意保持纯 AX 读取；其它方法也只在下文各自定义的可逆导航、唯一控件选择或被动复核步骤使用模型。`message.broadcast` 子命令可在目标未活动时复用 B34 选会话链，故意跳过 B36 输入框两次被动观察。B42 `contact.add` 的主窗与本命令新搜索窗若因高度重叠而无法唯一对应截图，必须失败关闭，不能猜选窗口。B46 进一步要求接受申请后看到该卡片明确转为 `added`，不能用卡片消失或表暂空代替。**真实千问 + MQTT + 独立 AX 后验**只证明对应 build、对应方法与步骤；源码、fake、旧版纯 AX 写入、只读切会话或单独的 HTTP 200 均不能推定其它方法活体通过。逐方法活体范围、失败与未验项见 `docs/gates/2026-09-26-b17-visual-coverage-audit.md` 和最新批次门报告。

本机屏幕录制授权、云端总开关 `cloudEnabled` 和整窗许可 `fullWindowEnabled` 分别检查；旧设置缺 `fullWindowEnabled` 时按 false，启用方式为本机 `imctl vision full-window --enable`，关闭为 `--disable`，控制台设置与状态也显示它。仅有 B16 `cloudEnabled` 不能上传整窗。默认选择千问，整窗视觉可在本机切换千问 / Gemini；DeepSeek 配置保留但当前不支持整窗规划。对**显式调用的固定桌面命令**，执行器仍先按该方法完成参数、暂停、目标、白名单、阶段、速率与幂等检查。符合各方法视觉触发条件时，在当前命令内核验企微 PID、单个窗口、活动会话和目标，截取该企微窗口单帧并发送至所选官方云端模型；条件不成立时由该方法按可验证的 AX 快路径执行或明确失败。**完整企微窗口可能包含聊天正文、头像、其他会话预览和个人信息**；本机不保存图片，远端的保存与处理由提供商决定。后台 watcher、自动轮询和 B15 方向补证据不能触发这一上传。

B34 对**非活动目标**的 `conversation.read`，以及 `message.send`、`message.sendFile`、`group.rename`、`group.addMembers` 的**选目标前缀**，在整窗辅助可用时主动执行视觉选择，唯一解析出的 AX 标题行也进入此路径。模型仅能从当前企微窗口的可操作 AX 行候选中选择；只读 `conversation.read` 可接受标题尚未由 AX 解析、但在窗口可见的候选行，四个写命令仍要求候选具有与目标严格相同的 AX 标题。选行后必须重新截图调用模型作新鲜的动作后复核，再读 AX 活动标题并与请求目标严格比较；任一步不成立即停止，不能触碰输入框或提交发送。目标已活动时无需上传选目标截图。仅有像素位置、没有可操作 AX 候选的控件不受支持。B35–B44 各自另有下述限定步骤；其它方法不因 B34 自动具备主动多轮视觉规划，逐方法活体覆盖仍以门报告为准。

B35 限于两个显式读取前的可逆导航：普通 `message.history` 确实需要定位最新、消息区只有一个可见可写竖向 AX 滚动条时，主动让模型选 `scroll`，写入固定的底部值后用新鲜截图模型 `verify` 与 AX 值读回证明到达最新；`contact.request.list`（`contact.request.accept` 共用的只读导航）仅在左侧唯一可见、AX 文本精确匹配「新的客户」的行尚未选中时，主动让模型选 `selectRow`，动作后再以新鲜截图模型复核、AX 选中行及申请表就绪证明导航。滚动条已到底或该行已选中且表就绪时不制造请求；整窗视觉关闭时沿原 AX 路径。`contact.request.accept` 的卡片匹配、按钮和提交仍由固定 AX 流程控制，B41 仅在按钮前增加被动模型复核；后台不上传。`message.history` 与 `contact.request.list` 的限定只读分支已有真实千问两轮、MQTT 终态和独立 AX 后验，见 B35 门报告；真实接受申请仍未验收。

B36 限于直接请求的 `message.send` / `message.sendFile`：目标和唯一可写聊天输入框先由 AX 严格确认，模型在原动作暂存固定正文或附件**之前和之后**各观察一帧经核验的企微主窗，仅返回复核 / 重观察 / 停止。暂存由原 AX 写值或已批准的 ⌘V 完成，提交仍经原策略、checkpoint、Return 与新外发消息后验；模型不能改正文、文件来源或发出提交。`message.broadcast` 的逐目标子命令不触发 B36 输入框观察。源码和 fake 测试不能证明真实模型发送成功；B36 的活体验收仍待门报告。这些限定步骤及下述 B37–B44 实现均不等于发送全程的通用视觉代理能力。

B37 限于**显式** `group.rename` 的群标题编辑：固定目标群已选中后，模型在 AX 写入请求的群名之前和之后分别复核同一个唯一可写标题字段；它只可返回复核 / 重观察 / 停止，不能改变群名、确认改名或决定结果。两轮之间冻结企微窗口、PID、原群选中行、字段句柄、策略与视觉设置。原 AXValue 精确读回、checkpoint、一次 `AXConfirm` 与改名后列表行证据仍由命令负责。写值后若准备失败，仅在原群、原字段和值均可证明时恢复旧名；不能证明恢复时记录不确定 checkpoint 并返回 `unknown`，防止草稿在失焦后提交却报 `failed`。`group.create` 附带的命名不进入此分支。源码与 fake 已过，真实千问改名仍待活体；详见 B37 门报告。

模型在可逆选择步骤只可从当轮发现、属于该命令允许集合的 AX 候选中提出下一步；被动复核步骤只可返回 `verify/reobserve/stop`。实际 AX 动作前重新核对候选角色 / 动作 / 位置以及 PID、窗口、会话与目标，动作后再次读取客户端状态。模型不能更改请求的方法、目标、发送内容、文件来源、成员、策略、按键白名单或幂等键，不能要求全局鼠标或任意坐标点击。达到轮次 / 时间上限、无唯一可操作候选、窗口变化、模型错误或缺可靠结果证据时停止；无客户端证据时不把模型的“成功”当成 `succeeded`。不可逆动作前仍落盘 checkpoint；发生后结果不确定则终态 `unknown`，模型和控制器都不自动重发或换键。

当前 MQTT 命令处理与响应是同步的。`imctl mqtt call` 默认等待 **90 秒**；一次多轮模型调用仍可能超过业务侧配置的等待时间；**响应超时不表示命令未执行或失败**。状态变更命令在超时 / 断线后用**原 `idempotencyKey`** 对账，不要换新键：收取并重放 `command.state`，终态后用 `command.get{commandId|idempotencyKey}` 读取原始记录；拿不准不可逆步骤是否提交时保留 `unknown`，由业务侧查消息 / 客户端证据后决定。只读命令没有幂等键，重复投递可能重新截图和读取，应控制请求频率。

B54：每次请求模型，守护进程日志写一行 `vision round <方法> <目标>/<阶段> #<轮次> → <结果> (<毫秒> ms)`，只含固定类别：不记截图、模型原文、候选标签、标题、名字、号码或验证语。`contact.add` 结果行那一轮的行末另带 ` source=wechat|wecom`（本命令所选来源）。

## 5. 目标、策略与会话类型

- `target`（`message.send`、`conversation.read`）三种写法：`chatId:<chat_id>`、`externalUserId:<external_userid>`、纯标题（开发期）。ID 经控制器本地身份桥（`identities` 表，由 `group.get` / `group.list{syncNames}` / `contact.remark.set` 回写，或 `imctl identity set` 手工填）解析成客户端标题；桥未命中 `TARGET_NOT_FOUND`，同名 `TARGET_AMBIGUOUS`，打开后不符 `TARGET_MISMATCH`。生产只用平台 ID，标题不是身份。
- 放行三级（都在 Mac 本地，业务侧无法远程放宽）：编译白名单（`文件传输助手`）→ `policy.json`（标题 / 会话类型 / `chat_id` / `external_userid`，`imctl policy`，改动发 `controller.state{policy}`）→ 速率硬上限；不允许 → `TARGET_NOT_ALLOWED`。**白名单只管会改变对方可见状态的动作**（发送、改群名、输入框菜单）；`conversation.read` 与 `message.history{scrollback}` 只改本机客户端显示哪个会话，**默认不经白名单**（B10，用户 2026-09-16 定），`policy.json.gateReads = true`（`imctl policy reads --gate`）时恢复经白名单。
- `conversationType ∈ {group, customer, internal, unknown}`：只在客户端有证据（群头部成员数 / 发送者标签 / 列表标记）时给出；`unknown` 是合法值且不能被类型规则放行；`internal` 当前不推断。活体 2026-09-15（5.0.11）：微信联系人组成的外部群头部**没有**成员数，其类型来自列表行的「外部」标签（该标签落在 badge 槽，解析时去掉零宽字符）。`allowAll`（§6.34/§6.35）是类型规则唯一的例外——开启后连 `unknown` 也放行；标题 / `chatId` / `externalUserId` 规则则从不检查类型，被放行的标题本就以 `unknown` 通过，不需要 `allowAll`。
- `messageKey`：`会话+发送者+规范化时间+文本+同元组序号` 的 SHA-256 前 16 hex，不含行索引；用于 `message.observed` 与 `message.history` 去重。可解析的企微时间标签先转成该消息的 UTC 分钟，避免同一行从“16:36”变为“昨天 16:36”后换键；无法解析时仍使用原标签。「文本」对没有文本的行取行上的文件名（`text ?? fileName`，即 `file` 行的文件名）；图片与原生视频行两者都没有，只靠会话 + 规范化时间 + 同元组序号区分。升级前按原始时间标签生成的历史键与新键可能不同；消费方应把升级后读取的键视为新的消息标识，不应仅凭键变化重放发送动作。

## 6. 方法

参数省略即用默认；结果指 `result.result`。UI 路线只对当前登录账号的桌面客户端；API 路线（6.13 起）需控制器 `imctl wecom enroll`，否则 `failed` + `UNSUPPORTED`。

### 6.1 `controller.describe`

无参数。结果：`{platform:"wecom", client:"com.tencent.WeWorkMac", submitStrategy:"enter", allowlist:"文件传输助手", policy:"titles=… types=… chatIds=… externalUserIds=…", targetSyntax:"title | chatId:<id> | externalUserId:<id>", phase:"1", version:"1.0.3", protocol:"im-control/0.1", wecomApi:"enabled"|"disabled", oss:"enabled"|"disabled", visionCaptureCount:"0", visionRequestCount:"0", visionHTTP200Count:"0"}`。三个视觉字段是守护进程启动以来的十进制字符串累计值：`visionCaptureCount` 为经窗口核验后的截图次数，`visionRequestCount` 为已发起的视觉模型 HTTP 请求次数，`visionHTTP200Count` 为固定官方端点返回 HTTP 200 的次数（在 JSON / 模型决策解析之前计）。HTTP 200 不代表模型给出有效选择、AX 后验通过或命令成功；返回值不含截图、模型原文或密钥。

### 6.2 `account.status`

无参数。结果（窗口可达）：`{windowReachable:"true", activeTitle, conversationCount, composerPresent:"true"|"false", activeType, activeMemberCount?}`；不可达：`{clientRunning, windowReachable:"false", loginRequired:"unknown"}` 或 `{…, layoutError}` / `{…, axError}`。值均为字符串。

### 6.3 `conversation.list`

无参数。结果：数组，每行 `{index, selected:"true"|"false", conversationType, title?, preview?, timeLabel?, badge?, markers?}`（`markers` 为逗号串，如 `微信`；5.0.11 里「外部」标签可能落在 badge 槽，解析时并入 `markers`，此时 `badge` 省略）。只含客户端当前列表可见的行，不遍历全部会话。

### 6.4 `conversation.read`

参数 `{target}`。切换客户端活动会话（改变客户端状态；默认任何标题都可打开，`gateReads` 为 true 时经白名单）。结果：`{active, messageCount, composerPresent, conversationType, chatId?, externalUserId?}`。切换那一轮的整屏历史**不**作为 `message.observed` 推送；用 `message.history` 取上下文。

### 6.5 `message.send`

参数 `{target, text, idempotencyKey（必填）, ttlMs?, issuedAtMs?}`。只发文本。提交前消息基线必须完整；提交后仅新出现的、正文完全相同且方向为 `outbound` 的消息行可确认成功。确认时活动会话保持目标不变、旧消息保持原顺序前缀；重复同文与旧行不可区分时保留 `unknown`。入站同文、方向未知、旧行索引变化或输入框清空均不能单独证明发送。整窗辅助开启的**直接请求**在唯一输入框已由 AX 证明后增加 B36 暂存前 / 后两次模型观察和独立 AX 复核；模型不写正文、不按 Return，群发子命令不进入这段观察。源码与 fake 测试已有，真实视觉发送待验，见 B36 门报告。结果：`{state:"succeeded"|"failed"|"unknown", evidence?, reason?, latencyMs?}`；提交后缺少可靠证据且输入框已空时为 `unknown`，同键回放结果，不自动重发。成功后事件流出现 `message.observed{origin:"controller", commandId}`。

### 6.6 `message.history`

参数 `{limit?=50, scrollback?=false}`。普通读取（`scrollback:false`）先将当前已打开会话的企微消息区定位底部，再返回最新 `limit` 条**消息行**；定位失败明确返回错误，不把可见的旧页冒充最新。此动作只由显式 `message.history` 执行，守护进程观察轮次不滚动或切换会话。`scrollback:true` 仍主动加载更早历史并尝试恢复位置。结果不含系统通知和时间分隔行：`[{index, kind:"message"|"media"|"file"|"video", direction:"inbound"|"outbound"|"unknown", text?, timeLabel?, sender?, fileName?, fileSize?, fileType?, mediaType?, duration?, messageKey?, media?, readError?}]`。精确匹配「文件传输助手」时所有消息行的 `direction` 为 `outbound`，MQTT `message.observed` 使用同一规则；其余会话不按标题猜方向。单条文本的暂时性 `AXValue -25201` 经一次重读仍不可用时，该行以 `readError:"AX_VALUE_UNAVAILABLE"` 明示不完整，省略不可信文本及从该行起无法保证稳定的 `messageKey`；业务侧不得用此行驱动回复，稍后重新读取。`media` = 没有可读文本的气泡（可能是图片、表情或卡片；活体 2026-09-15：单元格无子元素的 246 px 行），`text` 省略；这类行带 `mediaType:"image"|"unknown"`：仅当选中会话的最新预览**恰为** `[图片]`，且该行就是最新消息行时给 `image`，其余给 `unknown`，不能凭气泡高度猜成图片。方向先按同一行的 AX 图片或头像位置推断；对仍为 `unknown` 且可见的无文本媒体行，守护进程在已有屏幕录制授权时按需截取企微窗口单帧、仅在内存中判断左右；没有授权、截图失败、离开视口或像素证据含糊时仍为 `unknown`。B15 媒体方向判定对每次普通 `message.history` 最多截一帧；B35 为确需回最新或首次向顶加载更早历史的滚动另做动作前后整窗观察，不计入这一个方向判定帧。文本、文件、视频及 AX 已有方向的行不为方向判定截图，像素不保存也不进入 socket / MQTT。`file` = 文件卡片（图标描述 `file <类型> emphasized` + 文件名 + 大小，活体 2026-09-22 高 82 px；`text` 省略，`fileName` / `fileSize` / `fileType` 给出）；其中 `fileType:"pdf"`、`fileType:"word"` 等是客户端文件图标类型，业务侧还应看扩展名，未知类型不伪装为文档。`video` = 原生视频（播放键 + 时长，高 ≥ 300 px；`duration` 给出）。`file` / `video` 不带 `mediaType`。其它会话的无文本媒体行缺少 AX 子元素时可得到上述按需视觉补证据；没有可靠视觉证据仍为 `unknown`。`media` / `file` / `video` 行都带 `media: assigned|observed|unmatched`；居中的短文本区是客户端的系统通知，不作为消息行。`scrollback:true` 且已加载行数不足时先把消息区滚到顶让客户端加载更早历史（`gateReads` 开启时仅对策略放行会话；唯一可写消息滚动条且确需滚动时，首次向顶滚动走有界视觉选择与新帧复核，后续重复滚动及恢复仍由 AX 执行；已够行或视觉未启用时不上传）。

B35 对 `scrollback:false` 的显式读取，在确实尚未到最新且只有一个可见可写消息区竖向滚动条时，为该可逆滚动增加动作前模型选择、动作后新鲜窗口截图模型复核，并以新鲜 AX 滚动条值证明已到底。已到底无需模型请求；视觉未启用走原 AX 定位；后台 watcher 不滚动也不上传。这里的两轮整窗导航与上文 B15 单帧媒体方向判定是不同用途，均不把图片字节放入结果。此回最新分支的真实千问两轮、MQTT 成功与独立 AX 底部值已在 B35 门报告记录；build 211 的一次超时不能算成功，build 215 重测 2/2/2、MQTT 与 `command.get` 成功、AX 滚动条为 1。`scrollback:true` 首次向顶滚动也有动作前后视觉轮次；企微补入更早消息会使滚动条重新归一化，后验还需 AX 证明所选滚动条向顶移动、行数增加且首行变化。build 224 已在本人文件传输助手完成该分支的真实千问 2/2/2、MQTT 与 `command.get` 成功、返回 48 行并恢复 AX 滚动条到 1；仅证明该次布局与目标，见 B45 门报告。

### 6.7 `command.get`

参数 `{commandId?}` 或 `{idempotencyKey?}`。结果是**原始命令记录**（snake_case）：`{id, idempotency_key, method, params_json, state, created_ms, updated_ms, result_json, error_code, error_message, checkpoint_ms, diagnosis_json?}`（`diagnosis_json` 是第 3 节 `diagnosis` 的 JSON 文本，只出现在因视觉结束的命令上）。

### 6.8 `command.cancel`

参数 `{commandId?}` / `{idempotencyKey?}`。执行器同步串行，命令要么已终态要么正在执行：结果 `{commandId, state, cancelled:"false"}`（空操作，保留）。

### 6.9 `controller.pause`

无参数。加 `api` 暂停原因；结果 `{paused:[…]}`；同时发 `controller.state{paused}`。

### 6.10 `controller.resume`

无参数。去掉 `api`；结果与事件同上。

### 6.11 `client.navigate`

参数 `{action, idempotencyKey（必填）}`，`action ∈ {nextConversation, previousConversation, nextUnreadConversation}`。按客户端自己的「窗口」菜单项切换活动会话（`AXPress` 菜单项，不是合成按键；改变客户端状态，经策略 `navigate` 与暂停集合）。这些菜单项只在客户端是前台应用时可用，所以控制器先用 AX 属性 `AXFrontmost` 让客户端短暂成为前台（≤ 1 s），按完再用同一属性把焦点还给之前的前台应用；结果里 `enabled:"false"` 表示等待后菜单项仍不可用（按了也无效）。结果：`{action, before, after, changed:"true"|"false"}`——`before` / `after` 为切换前后的活动会话标题，`nextUnreadConversation` 没有未读时 `changed:"false"` 不算失败。菜单项不存在（非中文本地化、无主窗口）→ `failed` + `UNSUPPORTED`。`account.changed` 事件已定义未使用（见 7.2）。

B40 整窗视觉开启且 AX 侧栏能保守预测一个与当前会话不同的下一目标时，显式 `client.navigate` 在既有菜单操作前后各观察一次经 PID、窗口与当前 AX 选中行核验的企微主窗口；模型只能返回 `verify` / `reobserve` / `stop`，不能选择菜单项、侧栏行、坐标或改变 `action`。每次观察前后重查录屏授权、本机云端及整窗开关、提供商设置、暂停、策略、窗口和命令预算；菜单项本身始终由固定 AX 路径按一次，成功仍需 AX 活动标题与选中行后验。菜单禁用或 AX 无法预测下一行时沿原 AX 路径且无视觉请求。预测后客户端最终未切换时仍回 `changed:"false"`，可能已经产生一帧菜单前观察，但不做菜单后观察；预测与实际目标不符或菜单后视觉验证失败时不回报成功。B40 的 fake 测试不等于云端与 MQTT 活体验收，见同批门报告。

### 6.12 `event.replay`（查询）

参数 `{afterEventId?=0, limit?=200（≤1000）}`。响应 `result` 直接为 `{events:[{eventId, tsMs, kind, payload}], count, lastEventId}`；`lastEventId` 是控制器最新事件号，`count < limit` 或 `events.last.eventId == lastEventId` 即追平。不建命令记录、不发 `command.state`、可频繁调用；事件表 v0.1 不裁剪。

### 6.13 `group.list`

参数 `{cursor?, limit?, statusFilter?, syncNames?}`。结果 `{groups:[{chatId, status?, name?}], nextCursor}`；`syncNames:true` 时逐群取名并回写身份桥。

### 6.14 `group.get`

参数 `{chatId}`。结果 `{chatId, name?, owner?, createTime?, notice?, members:[{userid, type?, name?, joinTime?, groupNickname?, unionid?}], memberCount}`；回写身份桥 `chat_id ↔ name`。

### 6.15 `group.joinway.create`

参数 `{chatIds（≤5）, remark?, autoCreateRoom?, roomBaseName?, roomBaseId?, state?（≤30）}`（scene 固定 2）。结果 `{configId}`；二维码用 6.16 取。

### 6.16 `group.joinway.get`

参数 `{configId}`。结果 `{configId, chatIds, qrCode?, state?, remark?, roomBaseName?, roomBaseId?, autoCreateRoom?, scene?}`；`qrCode` 是企微的二维码图片 URL（长期有效）。

### 6.17 `group.joinway.update`

参数 `{configId, chatIds?, remark?, autoCreateRoom?, roomBaseName?, roomBaseId?, state?}`。结果 `{ok:true, configId}`。

### 6.18 `group.joinway.delete`

参数 `{configId}`。结果 `{ok:true, configId}`。

### 6.19 `contact.way.create`

参数 `{type?=1, scene?=2, remark?, skipVerify?=true, state?, users?, conclusionText?}`。结果 `{configId, qrCode?}`。客户扫码加员工为联系人；企微回调 `add_external_contact`（带 `State`、`WelcomeCode`）到 `wecom/{corp_id}/evt`。

### 6.20 `contact.way.list`

参数 `{cursor?, limit?}`。结果 `{configIds:[…], nextCursor}`。

### 6.21 `contact.way.get`

参数 `{configId}`。结果 `{configId, users, qrCode?, state?, remark?, skipVerify?, scene?, type?, conclusionText?}`。

### 6.22 `contact.way.update`

参数 `{configId, remark?, skipVerify?, state?, users?, conclusionText?}`。结果 `{ok:true, configId}`。

### 6.23 `contact.way.delete`

参数 `{configId}`。结果 `{ok:true, configId}`。

### 6.24 `contact.welcome.send`

参数 `{welcomeCode, text?, attachments?}`；`attachments` 按企微形状原样透传（`[{msgtype:"link", link:{title, picurl, desc, url}}]` 等；image / miniprogram / video / file 需先经代理 `media/upload` 取 `media_id`）。必须在回调后 20 s 内调用。结果 `{ok:true}`。

### 6.25 `contact.remark.set`

参数 `{userid（员工）, externalUserId, remark, description?}`。结果 `{ok:true, externalUserId, title}`；回写身份桥 `external_userid ↔ remark`，约定 `remark = "<原名>·<external_userid 短码 6 位>"` 使桌面标题唯一。

### 6.26 `broadcast.create`

参数 `{chatIds?（群）| externalUserIds?（客户）, sender?, text, attachments?, allowSelect?, idempotencyKey（必填）}`。结果 `{msgid, failList, chatType:"group"|"single"}`。企业群发每客户 / 每群每月上限 = 当月天数；任务需在客户端确认发送（6.27 或人工）。

### 6.27 `broadcast.confirm`

参数 `{msgid, idempotencyKey?}`。旧调用方只传 `msgid` 时，控制器在本机从 `msgid` 稳定派生幂等键；若显式传键，重投必须复用该键。桌面确认仅在所有已识别企微窗口中**全局唯一**的“群发助手” **AXSheet 或独立窗口**同时显示与请求**完全相同的 `msgid` AX 文本**且只有一个可识别、可用的“发送”按钮时执行一次 `AXPress`；泛化助手面板、缺 `msgid`、重复任务面板、多个发送按钮均在按前以 `failed` + `UNSUPPORTED` 停止，不能用模型猜是哪一个任务。checkpoint 前及其后、按键前均重扫任务面板与按钮的同一句柄；按前落盘 checkpoint，再以按钮消失或禁用作客户端后验。结果 `{msgid, button, verified:"true"|"false"}`：可靠后验为 `succeeded`；checkpoint 后 AX 异常或无法确认时为 `unknown`，不得用新键盲重试。该步骤同桌面命令受暂停检查；真实群发助手能否提供上述 AX 证据尚未活体验证，B17 逐方法状态以门报告为准。

B44：显式命令且本机整窗视觉启用时，先满足上述跨窗口全局唯一的 AX 任务证明；窗口列表读取失败也必须停在 checkpoint 前。模型只对同一企微 PID、已锁定的任务窗口、面板和唯一按钮做 `verify/reobserve/stop` 被动观察，不能选择 `msgid`、任务或执行发送。每次截图前后及原 checkpoint 后立即复核策略、暂停、屏幕录制、云端设置和原句柄；通过后仍由原 AX 路径按一次。按后按钮消失或禁用时以 AX 后验为准，不伪造第二次模型观察；若同一面板和按钮仍可用，可取新帧复核，但模型结果不能把 AX 失败变为成功。独立窗口必须是当前企微窗口且可聚焦；真实群发助手结构与视觉链均待活体确认。

### 6.28 `broadcast.get`

参数 `{msgid, userid?, cursor?, limit?}`。无 `userid`：`{msgid, tasks:[{userid, status?, sendTime?}], nextCursor}`；有 `userid`：`{msgid, results:[{chatId?, externalUserId?, userid?, status?, sendTime?}], nextCursor}`。

### 6.29 `contact.list`

参数 `{limit?=200, scope?="customers"}`（`all` = 面板里的每一行，含 `section`：我的客户 / 公司名 等，B9 用于选默认群成员）。经客户端「+ › 发起群聊」面板读「我的客户」：`[{name, source:"wechat"|"wecom", tag?}]`；面板只在读取瞬间打开，之后按「取消」，不改活动会话。官方接口路线（带 `external_userid`）待代理部署。

B38：显式调用在本命令打开的唯一「发起群聊」面板中，若当前可见行不足 `limit` 且其联系人大纲旁有唯一可见、可写的垂直滚动条，整窗视觉已在本机启用时，第一次确需改动 `AXValue` 的位置由模型从这一条 AX 候选中选择；改动后重新观察，请模型复核，再以同一面板、大纲、滚动条及目标值的 AX 读回决定是否继续。后续位置仍由命令固定为 `0 / 0.25 / 0.5 / 0.75 / 1`，只沿同一滚动条做 AX 写和读回，不再上传。当前行已满足数量、无可写滚动条或整窗视觉关闭时沿 AX 路径；多条候选或面板变化时明确失败并仅尝试取消本命令面板。返回字段不变。B38 的模型链仍需真实企微与 MQTT 活体验收，源码及 fake 测试不是上线证据。

### 6.30 `contact.request.list`

无参数。切到「通讯录 › 新的客户」读卡片再回消息视图：`[{name, greeting?, source, status:"pending"|"added"}]`——`pending` = 卡片上是「接受」按钮（可接受），`added` = 「打招呼」（已是联系人）。切换用客户端自己的快捷键（`⌘8` + `⌃Tab`，只投递给企微进程；用户 2026-09-15 批准）与深链 `wxwork://conversationlist`，企微会短暂成为前台。导航期间前台被拿走时每次按键前会把企微重新置前；导航失败的 `VERIFY_FAILED` 信息带逐步记录（前台 / 焦点角色 / 文本计数 / 视图指纹 / 时延，不含内容）。

B35 在显式调用、整窗视觉已启用且「新的客户」尚未选中时，只对左侧唯一可见、AX 文本精确匹配该标题的行执行主动视觉 `selectRow`；动作后重新截图让模型请求复核，再由 AX 选中行与右侧申请表就绪判定。已选中且表就绪，或整窗视觉关闭时沿原 AX 路径，不制造额外模型请求。后台自动申请轮次不上传；限定只读分支的真实千问两轮、MQTT 成功与 AX 后验见 B35 门报告。

### 6.31 `contact.request.accept`

参数 `{name, idempotencyKey（必填）}`。找到唯一同名 `pending` 卡片按「接受」，再按客户端弹出的备注弹窗（设置备注名 / 备注企业名称 / 设置标签）里的「完成」（备注与标签保持默认），等同名卡片的按钮明确变「打招呼」（状态 `added`，服务端往返最长 10 s）：`{name, accepted:"true", status:"added"}`。B46 起卡片消失、申请表暂空、旧句柄失效均不是接受成功证据；已越过不可逆点而无明确 `added` 时按不确定结果处理，同键不重按。0 个 `TARGET_NOT_FOUND`、多个 `TARGET_AMBIGUOUS`、已添加 `LOCAL_GUARD`；每小时接受上限（`policy.json.contactRequests.maxAcceptsPerHour`，默认 20）超出 `RATE_LIMITED`。成功后事件 `contact.request.accepted`。

B41 限于显式调用且本机整窗视觉已启用的 `contact.request.accept`：进入「新的客户」后，AX 须先证明唯一同名待处理卡片及其「接受」按钮。模型在原 checkpoint 和固定 `AXPress` 前对该按钮作一次只读观察；首次按键后，仅当同卡片仍待处理、同一企微主窗内出现本命令新开的唯一备注弹层与「完成」按钮时，在第二个 checkpoint 和固定按键前再观察一次。两轮均只允许 `verify/reobserve/stop`，不能选择卡片、按键、改备注或决定成功。每次不可逆按键前重新核对窗口/PID、卡片/按钮、策略、暂停、屏幕录制和云端视觉配置；首个「接受」已按而后续弹层或模型验证失败时，执行器记录 `unknown` 且同幂等键不再按第二次。只有客户端卡片状态转为 `added` 才返回成功；后台自动接受、整窗视觉关闭时沿原 AX 路径。源码及 fake 测试不等于真实接受活体验收。

B35 仅复用上一节进入「新的客户」时的**只读、可逆选行前缀**；模型不选择申请卡片、接受按钮或提交。前缀无可靠 AX 后验时不得进入接受动作。接受流程的授权、限速、checkpoint 与成功证据仍由原 AX 实现负责，B35 未对真实接受动作做活体验收。

### 6.32 `group.create`

参数 `{members:[name…]（至少 2 个且姓名互异）, name?, idempotencyKey（必填）}`。用客户端自己的 ⌘N 打开「发起群聊」面板（「+」按钮不响应 AXPress），逐个把名字写进搜索框、确认唯一且排第一的结果后对客户端 pid 投递一次回车选中（活体 2026-09-15：结果行不接受 AX 选择 / 按压 / 聚焦）。「完成」前、checkpoint 后及最终 AXPress 前均要求已选表的可读姓名**逐一精确等于请求成员**，同数量但换人也不得提交。客户端异步切群（≤ 10 s）后，仅当原可见会话行保持、列表恰新增一个先前不存在且唯一选中的群行、群头标题与此行一致，并且群头人数恰为请求人数加本人，或无人数的外部群自动标题逐项含请求姓名，才返回 `opened:true`；单凭任何活动标题变化或旧群的人数不能证明新群。证据不足时，已越过 checkpoint 的命令返回 `unknown`，同键不重做。有 `name` 时在已证实的新群上再写头部标题（§6.33）：`{title, memberCount, renamed, opened, requestedName?}`。只给 1 个成员 `LOCAL_GUARD`；成员找不到 `TARGET_NOT_FOUND`，第一条结果是别人 `VERIFY_FAILED`；这些前置错误关闭命令自有面板、不建群。成功后事件 `group.created`。显式命令且本机整窗视觉三门启用时，模型在「完成」前和新群 AX 后验成立后各做有界、只读的 `verify/reobserve/stop` 观察；模型不能选择成员、按「完成」或把证据不足改成成功。本视觉分支仅有 fake 证据，真实千问建群待活体。

自动接受策略（本机 `policy.json.contactRequests`，`imctl policy requests`，热加载）：`autoAccept ∈ {off, all, rules, remote}`（`off` 只上报角标数；`rules` 按 `allowNames` / `greetingContains`；`remote` 只发事件由业务侧逐条 `contact.request.accept`）、`autoGroup ∈ {off, perPerson}`（接受后一人一群，成员 = 客户 + `groupDefaultMembers`，群名 = 客户名 + `groupNameSuffix`；`groupDefaultMembers` 为空时只有客户 1 人、客户端不会建群，守护进程跳过并记日志）、`maxAcceptsPerHour`。触发（角标是客户端的未读计数，人工点开即清零而请求仍待处理；一轮只在角标 > 0 时才开始，无请求可处理时不做可见的切页——用户 2026-09-23 决定。B49 起角标按导航栏的实时 AX 结构归属到「通讯录」：角标按钮与其锚点成对、锚点等距成列、客户端列出的第 2 对且位于第 10 格；任一不符或读取出错即视为「未知」：沿用上次已归属的角标数、不喂给触发器，既不算降为 0、恢复后也不算升高，不启动轮次，原因写入守护进程日志与 `state.json` 的 `newCustomersBadgeProblem`）：角标升到正数（从 0 升起，或在已为正时继续增加）触发一轮；策略从 `off` 切到非 `off`、或守护进程启动，且那一刻角标已 > 0，也各触发一轮（角标为 0 时什么都不做，等下一次角标升高按前一条规则触发）；角标下降或清零永不触发，人工清零后若仍有待处理卡片，只能靠业务侧显式调用 `contact.request.list`；角标 > 0 期间每 30 分钟再扫一轮；失败一轮后只在角标 > 0 时重试，距失败依次 5、10、20、30、30 分钟（逐次翻倍、封顶 30 分钟，其间不另扫），5 次重试都失败后停到角标变化或策略重新打开，成功、角标变化或重新打开都让退避从 5 分钟重新算；两轮至少间隔 60 s，`off` 不进通讯录。自动接受 / 自动建群的幂等键为 `auto-accept-<sha16>` / `auto-group-<sha16>`，上一次失败、过期或取消后换新键重试（成功、unknown、进行中仍回放）。

### 6.33 `group.rename`

参数 `{target, name, idempotencyKey（必填）}`。`target` 是白名单 / 策略允许的群（标题或 `chatId:`）；切到该群后把头部标题文本框写成 `name`，必要时执行客户端自己的 `AXConfirm`（活体 2026-09-15：群标题是可编辑的 `AXTextField`，带 `AXConfirm` 动作；不是合成输入）。结果 `{title, renamed, requestedName}`：`renamed:"true"` = 客户端列表中原群的选中行已经显示新名（服务端往返，最多等 10 s）；仅有标题框提前回显新名不算成功。`group.create` 带 `name` 时在开群后做同一件事，结果与 `group.created` 事件的 `renamed` 随之为 true。整窗视觉已启用的显式 `group.rename` 在固定写值前做 B37 被动观察；尚未证明改名完成时，写值后再观察。模型不能修改 `name` 或触发 `AXConfirm`。

1.0.18-dev：客户端可能在 `AXValue` 写入时就改名，因此显式改名的 checkpoint 提前到第一次写值前。若随后新鲜 AX 证据同时证明原窗口、原编辑字段及原选中会话行未变，字段和唯一原行均已显示请求的新名，且策略、屏幕录制授权和视觉设置仍有效，则直接返回成功，不再确认或失焦；这也可核对由旧标题失效引起的 `staleView`。模型 stop / 非法选择、同名歧义、换行、换窗口、换字段或授权撤销均不得据此报成功。未能证实时保留 `unknown`，同幂等键回放、不自动重试。源码 / fake 测试不代表该视觉分支已经完成真实客户端验收，现场证据见对应门报告。

1.0.19-dev：群名被动观察可识别一个严格匹配的 macOS 视窗分享指示器（`WindowSharingSessionButton`）。它必须与原主窗同 PID，结构和相对几何符合已校准模式，完全位于会话表左侧或上方的主窗左上非命令区，且不遮挡会话表、消息视口或群名字段；其他附窗 / 对话框仍拒绝。该规则只做只读窗口集合核对，不操作分享控件、不改变单帧范围、视觉授权或改名的 checkpoint / 幂等语义。见 [B55 门报告](../gates/2026-10-19-b55-group-name-window-sharing.md)。

1.0.20-dev：仅澄清 `group.rename` 群名准备 / 验证被动轮的视觉提示：候选是只读观察锚点，`writeText` 仅标记本机 AX 能力；正常侧栏、聊天消息与下方输入框不属于替代群名编辑器。活动群冲突、候选越出标题区、竞争群名编辑器或遮挡标题的冲突弹窗仍须停止，不确定时仍可停止。模型只允许 `verify / reobserve / stop`，不得带候选 ID、写值、确认或宣告成功；协议字段、解析、AX、策略、checkpoint、幂等与授权不变。该提示歧义已由代码确认，但尚未证明是此前真实 `stop` 的原因，真实改名仍待验收，见 [B56 门报告](../gates/2026-10-19-b56-group-name-passive-prompt.md)。

1.0.21-dev：若原主窗因位于另一 Space 而明确返回空 `AXWindows`，外部群改名的 B37 路径会在任何群名写入或模型请求前，先核对原主窗、focused window、唯一选中行与精确目标，再用一次 `AXFrontmost=true` 请求恢复可见窗口列表。等待有界，并逐轮核对策略、pause、辅助功能 / 录屏授权、视觉设置、命令预算与原窗口 / 行 / 标题 / 几何；任何变化停止。取得同一主窗后仍须通过完整 B37 / B55，不能把空集合、未知 AX 回覆或额外对话框当成通过证据。动作结束后尝试归还原前景；该准备步骤不改 checkpoint、幂等、模型停止权或抓图范围。尚未完成真实改名验收，见 [B57 门报告](../gates/2026-10-19-b57-group-name-visible-window.md)。

### 6.34 `policy.get`

无参数。返回本机 `policy.json` 的全部内容：`{allowedTitles, allowedTypes{group, customer, internal}, allowedChatIds, allowedExternalUserIds, contactRequests{autoAccept, allowNames, greetingContains, autoGroup, groupDefaultMembers, groupNameSuffix, groupNameTemplate, maxAcceptsPerHour}, remoteEdits, gateReads, contactAdd{maxAddsPerHour, maxSearchesPerHour}, sendFile{allowedHosts, maxBytes}, allowAll}`（B9：控制台「策略」页的读取走同一条路；`sendFile` 是 `message.sendFile` 的 `url` 源域名白名单与单文件字节上限，经 `policy.set{allowHosts, denyHosts}` 或 `imctl policy hosts` 修改；`allowAll` 见 §6.35 与 §5「目标、策略与会话类型」——B14 用户 2026-09-22「全部放开」，默认 false，只经本机 `imctl policy all` / 控制台开关，`policy.set` 不接受）。

### 6.35 `policy.set`

参数 `{allow?: [标题], deny?: [标题], contactRequests?: {…同上}, gateReads?: bool, allowHosts?: [域名], denyHosts?: [域名]}`。B12 的 `allowPhones` / `denyPhones` 自 2026-10-13 起不再有作用（号码不再需要登记）：传了照常成功，不改任何东西。放行 / 收回标题、整块替换 `contactRequests`、设置读会话是否经白名单，写入 `policy.json` 后守护进程热加载并发 `controller.state{policy}`。`allowHosts` / `denyHosts`：sendFile.allowedHosts 的增删（同 remoteEdits 门）。**只有本机 `remoteEdits` 为 true 时才执行**（`imctl policy remote --enable`，或控制台策略页开关），否则 `LOCAL_GUARD`——把白名单交给远端仍是本机人的决定。类型 / `chatId` / `externalUserId` 规则仍只经终端。**`allowAll`（B14，用户 2026-09-22「全部放开」）只经本机 `imctl policy all --enable|--disable` 或控制台的二次确认开关；这个参数没有列在上面，`policy.set` 不接受它，永远不能经远端打开**——开启后 `ActionPolicy.allows` 对任何已解析目标放行（含类型 `unknown`），守护进程 `policy reloaded` 日志与 `controller.describe.policy` 摘要带 `allowAll=true`。

### 6.36 `controller.diagnose`

无参数。只读：`{trusted, windowFrame, conversationTable, messageTable, composerPresent, activeTitle, activeType, conversationCount, rowHeights, messageImages}`（控制台体检页「界面诊断」读到的同一类信息，但经守护进程自身授权）。

### 6.37 `controller.logs`

参数 `{lines?=100}`（≤ 500）。返回守护进程日志尾部 `{lines, count}`（`~/Library/Logs/imctl/imctld.log`；内容含 broker 主机名，不含凭据）。

### 6.38 `controller.mediaCache`

参数 `{limit?=50（≤ 500）, refresh?=false}`。B10 图片路线第一步：图片在客户端的辅助功能树里没有元素（B9 探针），只能从客户端本地缓存取。本方法**只读**清点客户端容器（`~/Library/Containers/com.tencent.WeWorkMac/Data`、`~/Library/Group Containers/88L2Q4487U.com.tencent.WeWorkMac`…）里的图片 / 视频文件：`{status:"ready"|"pending", roots, elapsedMs, scanned, files:[{root, path, size, modifiedMs, kind:"image"|"video"|"audio", signature?}], directories:[{root, path, images, newestMs}], notes}`；不读文件内容（只看扩展名与文件头）。扫描在守护进程自己的线程上跑，未完成时立即返回 `pending`，不占命令队列。macOS 对访问其它 App 的数据会在**第一次**弹系统提示并阻塞到用户点选：提示归 `imctld`，点「允许」一次即可；误点「不允许」时在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 里加 `imctl.app`。消息 ↔ 文件的对应与内容读取（`message.media`）按清单另定。

### 6.39 `message.media`

查询（与 `event.replay` 一样不建命令记录）。参数 `{messageKey, hd?=true}`（1.0 的 `maxBytes` / `maxPixels` 仍接受但忽略）。B13：图片 / 文件 / 视频封面只向已配置的 OSS bucket（`oss.json`）上传一次，返回签名地址而不是字节：`{messageKey, kind:"image"|"file"|"video", matchedBy:"observed"|"window"|"name", fileName, bytes, contentType, ossKey, url, expiresAtMs, width?, height?, duration?, body?:"uploaded"|"absent", bodyOssKey?, bodyUrl?}`。**先定行类型**：优先用守护进程记下的观察类型（`message.observed{kind}`），没有观察记录才看当前打开的会话里那一行，再没有就看已记下的对应落在哪个缓存目录；都没有 → `MEDIA_NOT_FOUND`（先开会话再问），不扫任何缓存；观察类型与行上的类型不一致 → `MEDIA_NOT_FOUND` 并写明这两个类型。**索引答得上来的键（已有对应，或已观察到的 `media` / `video` 行、带 `fileName` 的 `file` 行）不读客户端的消息行**；只有索引答不上来才读一次辅助功能树，且这次读取在 8 s 文件授权框之外（读一次消息表在繁忙客户端上要十几秒，2026-09-23 活体 ~14 s，框内会让每次调用在解析开始前就超时）。**索引答得上来、但观察窗口里一个缓存文件都没有时（客户端把缩略图写晚了，或观察时刻落后于行），再读一次消息行**（同样在授权框之外；一次调用最多读一次），用行上下的时间标签走下面第 ③ 步；客户端读不到、或该键不在当前打开的会话里，就仍回窗口那一条 `MEDIA_NOT_FOUND`。类型不符、`file` 行拿不到文件名这类硬拒绝不触发这次补读。类型决定搜哪些缓存目录，也决定能不能占用某个文件：`media` / `file` / `video` 以外的行（`message` / `system` …）直接 `MEDIA_NOT_FOUND` 并写明它是什么行——视频键或文本行的键不会占用（并永久绑定）属于图片行的缓存文件；已记下的对应与行类型不符时按作废处理（丢弃重新解析）。图片（`media` 行）：`hd:true` 且客户端已下载原图（`<id>_HD`）时给原图；匹配顺序不变——① 之前的对应；② 该行被守护进程观察到（`message.observed{kind:"media"}`）前 120 s 到后 30 s 内出现的缓存文件，取最近的一个；③ 当前打开的会话里，用该行上下相邻的时间标签框住一个时间段，段内的缓存文件按顺序对应段内的同类行。`file` 行：文件名与大小取自行上，或取自守护进程观察该行时记下的 `fileName` / `fileSize`（2026-09-23 起；旧索引没有这两项，就仍须在当前打开的会话里）；两者都没有且没有已记下的对应 → `MEDIA_NOT_FOUND`（先开会话再问）；按 `Caches/Files/<yyyy-MM>/<id>/<name>` 下与行上文件名相同（有大小标签时如 "74K" 再筛一次）的缓存文件解析，`matchedBy:"name"`；同一个文件收到多次时客户端会在同一目录里另存 `<名字> (1).<扩展名>`、`<名字> (2).<扩展名>`…，而每一行仍显示原名（活体 2026-09-23，5.0.11），所以这些副本也是候选：同名的排在前，副本按修改时间新的在前，同样按大小标签筛、同样排除已被别的行占用的文件，于是每一行拿到自己的那一份。`video` 行：封面按图片同样的匹配顺序取，但**只在** `Caches/Video_Thumbnail` 里找；原始视频体只在客户端已下载过（播放过，`Caches/Videos`）且不超过 `maxUploadBytes` 时才一并上传，在该行的时间窗内取离观察时刻最近、且未被别的行占用的那个（对应关系记在 `<messageKey>#body`，同一小时的两条视频不会共用同一个文件），内容类型按文件头判（mp4 → `video/mp4`，mov → `video/quicktime`），认不出就不传体；传了 `body:"uploaded"` 并带 `bodyOssKey` / `bodyUrl`，否则 `body:"absent"` 且不带这两个字段。都不成立 → `MEDIA_NOT_FOUND`（消息里写明原因：不在打开的会话里 / 没有观察记录 / 行类型不对 / 上方没有时间标签 / 段内没有文件 / `Caches/Files` 下没有同名文件）。对象键 `<baseDir>/<yyyy>/<MM>/<dd>/<messageKey>-<name>`（UTC 日期取自缓存文件的修改时间）；上传前先 `HEAD`（`exists`）探一次，命中就跳过 `PUT`，签名地址每次调用都重新签。本机没有 `oss.json` → `OSS_NOT_CONFIGURED`；缓存文件超过 `oss.json.maxUploadBytes` → `MEDIA_TOO_LARGE`；对象存储拒绝或不可达 → `OSS_ERROR`。B10 活体（5.0.11）：图片在 `Documents/Profiles/<profile>/Caches/Images/<yyyy-MM>/<id>/<id>`（原图 `<id>_HD/<id>_HD`），表情 `Caches/Emotions`，视频封面 `Caches/Video_Thumbnail`；消息数据库本身是加密的，文件修改时间就是到达时间。`message.history` 的 media / file / video 行都带 `media: assigned|observed|unmatched`。任何传输都不带字节。 图片行（media）只在 Caches/Images、Emotions、Link_Thumbnail 里找文件，窗口里只有视频封面时回 `MEDIA_NOT_FOUND`，不会把封面当图片返回。

补充（2026-09-23 控制台附件修复）：若 `file` 行的企微缓存已被清理，只有 `message.observed` 明确归因为本控制器一次成功的 `message.sendFile`，且会话、方向、文件名、大小与时间匹配时，守护进程才从该命令保存在本机数据库里的 `url` / `ossKey` 重新获取；文件头和字节数复核后上传到 `<baseDir>/sent/<messageKey>-<name>`，返回 `matchedBy:"sent-source"`。相同条件下，外发 `video` 行若只有封面，可从发送来源补齐正片，`body:"uploaded"`；原来源不可取时保留封面并返回 `body:"source-failed"`。入站文件和无法确证来源的图片不猜测或借用相似缓存，仍回 `MEDIA_NOT_FOUND`。控制台把签名 URL 下载到本机私有目录，验证 OSS 主机、大小和文件头后用系统默认应用打开；真头像像素不在当前 AX / 协议返回值内，界面仅显示身份占位图。

补充（2026-09-24 消息键兼容）：旧版以原始时间标签生成键；升级后即使标签不变，已分配缓存的图片也会换为规范化键，跨天从“HH:mm”显示成“昨天 HH:mm”时还会再改变原始标签。`message.media` 只考虑当前原始标签与明确的“昨天 HH:mm”对应的旧裸时钟标签；当前打开会话中的图片行、唯一旧键、同类行和缓存均能建立唯一对应，且实际文件头和缓存修改日期符合时，才把旧分配及其观察记录迁到规范化键。多个候选、日期或类型不符仍返回 `MEDIA_NOT_FOUND`；不按相近时间借用别的消息附件。

### 6.40 `message.broadcast`

参数 `{targets: [目标]（1–50，互不相同）, text, idempotencyKey（必填）, intervalMs?=3500, stopOnFailure?=false}`。B11 群发：一条命令记录代表整轮，每个目标一条**独立的** `message.send` 子命令（子键 `<key>#<序号>`，各自经白名单、限速、事件），逐个发送并在目标之间暂停 `intervalMs`；限速不放行时**等待**（最多 70 s）而不是消耗尝试次数；子命令一条条经串行队列，**其它客户端的命令可以插在两个目标之间**（30 个目标的群发不会把队列锁两分钟）。结果 `{total, succeeded, failed, items:[{target, commandId, state, errorCode?, errorMessage?, evidence?}]}`；全部成功 `succeeded`；有确定失败且无不确定子命令时为 `failed`，`error.code` 取第一个失败目标的错误码；任何子命令为 `unknown` 或仍 `running` 时父命令为 `unknown`，`error.code=UNKNOWN_CHILD`，调用方按子命令 ID 对账，不能用新键重发整轮。同键重放返回整轮记录；中途重启整轮记 `unknown`（子命令各自可按子键对账）。不在白名单的目标单独失败，其余照发。

### 6.41 `controller.permissions`

参数 `{prompt?=false, probe?=false}`。守护进程**自己的**授权状态（TCC 按进程记）：`{accessibility: trusted|untrusted, screenRecording: granted|denied, wecomData: granted|denied|pending|absent|unknown, fullDiskAccess: yes|no, clientRunning, launchAgent, wecomDataPath, prompted}`。`prompt:true` 一次性触发能触发的系统对话框（辅助功能、屏幕录制、「访问其他 App 的数据」），供安装后初始化（`imctl setup`，控制台体检页与初始化向导的「安装并请求授权」）；屏幕录制由守护进程申请，macOS 已拒绝时到系统设置 › 隐私与安全性 › 屏幕录制允许 `imctl.app`，按系统提示重启后再读回。不传时 `wecomData` 只在已有完全磁盘访问权限时探测（探测本身会弹框）；`probe:true` 只探容器，不触发新的辅助功能或屏幕录制提示（`imctl setup` 等待对话框时轮询用）。完全磁盘访问权限只能在系统设置里手动加 `imctl.app`，加了以后更新版本不再弹「访问其他 App 的数据」。

### 6.42 `contact.add`

参数 `{phone, source?="wechat"（wechat | wecom | any）, greeting?, dryRun?=false, idempotencyKey（必填）}`。B12（用户 2026-09-16 12:09 批准搜索框回车）：通讯录 › 新的客户 › 右上「添加」（客户端须在前台，`AXPress`）→ 「添加客户」面板（客户端的**第二个 AXWindow**）→ 搜索框 `AXValue` = 号码 → **对搜索框投递一次 pid 级回车**（客户端只在按键时搜索）→ 结果表每行 = 来源图标（`AXDescription` "icon outer user card search" = 微信、"appicon 24x24" = 企业微信）+ 名字 + 「添加」→ 按 `source` 选行、`AXPress` 其「添加」→ 若出现验证 / 备注对话框，写入 `greeting`（有的话）并按 发送 / 确定 / 完成 → 关闭面板、回 消息。**门**：号码不限（用户 2026-10-13 决定：对方通不通过由对方决定，发出的申请收不回；此前须登记在 `contactAdd.allowedPhones`，旧文件里的这一项读入后忽略），但只收手机号形式（数字及 `+ - ( )` 与空格，5–20 位数字），否则 `INVALID_PARAMS`；真实添加每小时成功上限 `contactAdd.maxAddsPerHour`（默认 20）与只搜索（`dryRun`）每小时上限 `contactAdd.maxSearchesPerHour`（默认 60）各自计数，超出 `RATE_LIMITED`，设为 0 即关闭该项（`imctl policy phones --max-per-hour / --max-searches-per-hour`）；本机 `policy.json` 无法解析时两者都按 0；经暂停检查。结果 `{status: matched|no-match|pressed|confirm-pressed|requested, matches, match0..n: "<source>/<名字>", chosen?, phone: 掩码, dryRun, panel, keystroke, pressed?, confirmed?, inviteWindow?, inviteDialog?: closed|still open, greeting?, buttonAfter?}`（`inviteWindow: "separate"` 表示邀请出现在独立的「发送验证申请」窗口；`pressed` = 按了结果行「添加」但未出现可对应的邀请，`confirm-pressed` = 按了邀请确认但对话框或窗口仍开着，两者命令状态均为 `unknown`，只能用原幂等键对账）。号码只以掩码形式（`138****00`）出现在结果、日志与错误里；命令记录的参数在本机数据库里。

B42：命令进入「新的客户」后必须先证明当前只有企微主窗，再由本命令按标题栏「添加」并观察**新出现的唯一空白**「添加客户」窗口；已有搜索窗、其它第二窗口或无法证明归属时停止，不接管其输入或邀请。显式命令且本机整窗视觉三门齐备时，在唯一搜索框写入前、手机号搜索后唯一来源结果按「添加」前、唯一邀请确认前分别让千问 / 当前选定模型做有界被动观察：只能返回 `verify` / `reobserve` / `stop`，没有候选按压权。每轮重查当前命令、策略、暂停、PID、主窗 / 搜索窗及 AX 输入或按钮；提交前仍由本地请求、checkpoint 和客户端后验决定。`dryRun` 绝不按结果或邀请按钮。视觉截图可能包含搜索号码，只在内存中经本机整窗授权送所选官方端点，模型原文不写响应、事件或日志。真实第二窗与主窗可能几何重叠，无法唯一识别截图对应的窗口时直接拒绝视觉调用；该分支须单独活体验收。B50（2026-09-28 实测：「添加客户」面板与主窗同帧 `(0, 30, 1920×1170)`）：命令在自己按「添加」前记录企微窗口号，只有快照证实原主窗后，才把按下后新出现的唯一同帧窗口认作面板并按该窗口号截图；证明不了就照旧拒绝。B51（2026-09-29 实测：按企业微信用户结果行的「添加」会另开独立的「发送验证申请」窗口，含预填验证语输入框、「发送」与关闭按钮）：只认实录形状——标准窗口，恰一个可写单行输入框、恰一个确认按钮且标题为「发送」并可按、恰一个关闭按钮，无「添加客户」标题、无多行文本区或列表（聊天窗、只有「确定」的提示框都不算）。归属：按结果行「添加」前最后一刻依次记下企微窗口号与 AX 窗口，此后若有任何窗口提供确认或窗口集合变化即停止；按下后只把不在快照中、形状相符且在窗口列表中的那一个窗口认作本命令的邀请窗口，后续每次复核只放过这一个窗口，另有多出的窗口即停止。`greeting` 写入该窗口自己的输入框，「发送」前另有 checkpoint；按下后该窗口从窗口列表消失才算 `requested`，仍开着为 `confirm-pressed`。视觉观察只按快照证实为新出现的该窗口号截取它，证实不了即拒绝截图、不按「发送」。

B54：邀请在本命令证实的独立「发送验证申请」窗口里时，邀请轮用目标 `contactSendVerification`，提示写明截图里只有该窗口、看不到结果列表；面板内或主窗弹层的邀请仍用 `contactInvite`，提示不变。结果行一轮的提示写明本命令所选来源。按下「发送」之后没有视觉步骤，所以带 `diagnosis` 时「发送」一定没按。`irreversibleSteps` 为 1：「添加」前的 checkpoint 已写；`visual.goal` 是邀请轮（`contactInvite` / `contactSendVerification`）时「添加」已按下，是 `contactMatch` 时可能还没按。为 2：「发送」前的 checkpoint 也已写，「添加」已按下，「发送」没按。

### 6.43 `message.sendFile`

参数 `{target, url? | ossKey?, fileName?, idempotencyKey（必填）, ttlMs?, issuedAtMs?}`，`url` 与 `ossKey` 二选一：`url` 必须 `https` 且域名在 `policy.json.sendFile.allowedHosts`（精确或 `.后缀`；空名单 = 全拒；重定向逐跳复查）；`ossKey` 是已配置 bucket（`oss.json`）里的对象键，守护进程自己签名下载。类型白名单 `png jpg jpeg gif webp mp4 mov pdf doc docx xls xlsx ppt pptx zip txt` 且文件头一致；单文件 ≤ `sendFile.maxBytes`（默认 100 MB）。执行：下载到 outbox → 取得完整消息基线 → 聚焦输入框 → 置前 → ⌘V（用户 2026-09-22 批准的唯一新按键）→ ≤ 3 s 内确认输入框出现附件 → checkpoint → 回车 → 取证 = 基线没有的新**外发**消息，且图片须为 `media`、视频须为 `video`、其它文件须为 `file`：`file` 行还必须显示贴进去的那个文件名（与 outbox 文件同名），`video` 行客户端没有文件名时查新消息键、类型与方向，`media`（图片）行客户端没有文件名，仅用新消息键、类型与可靠的 `outbound` 方向取证；确认时活动会话须保持目标不变，旧消息须保持原顺序前缀，候选与旧行不可区分或图片方向未知时保持 `unknown`（图片 15 s、文件 30 s、视频 30 s + 每 10 MB 加 10 s，上限 180 s）→ 交还前台；发完即删 outbox 文件。取证期间某一轮 AX 读失败不算发送失败（回车已经发出去了），跳过这一轮继续等；一直没等到证据时，无论输入框已清空还是仍有附件，均为 `unknown`，保留输入框现状，绝不重发。结果 `{state, evidence?, reason?, latencyMs?, fileName, bytes, contentType, kind:"image"|"video"|"file"}`；限速与 `message.send` 同池；同键回放；崩溃后 `unknown`。活体 2026-09-22（5.0.11 / macOS 27.0）：贴入文件 URL 不弹确认窗，mp4 以原生视频消息发出。

B36 对**直接请求**的 `message.sendFile` 在原来源 / 文件头与唯一输入框检查之后、附件暂存前后各加一次受控整窗视觉观察；原动作仍只执行一次 ⌘V，模型不选择文件、不能按 Return。暂存后必须由 AX 证明单个原生附件对象，提交前重新读取完整消息基线，并沿原 checkpoint、目标复核和新外发消息证据判断终态。客户端对图片 / 视频通常不暴露附件文件名，所以可证明来源文件经过本机校验与暂存类型守卫，不能仅凭模型画面声称发送字节与来源完全一致。B36 真实视觉发送待验，不能用 B33 的纯 AX 附件发送替代。

### 6.44 `group.addMembers`

参数 `{target, members: [名字…]（1–20）, dryRun?=false, idempotencyKey（必填）, ttlMs?, issuedAtMs?}`。`target` 语法同其它方法（标题 / `chatId:` / `externalUserId:`），须过 `ActionPolicy`（`ActionKind.addGroupMembers`，`requiresTarget`，阶段 0 禁止，与 `submit` / `sendFile` 同级不可逆）。切到目标会话后读 `before`（头部或侧栏 `群成员·N`，读不到则为空）；表头无人数且侧栏无 `群成员·` 时判定目标不是群，返回 `NOT_A_GROUP`。执行前已有任何 picker 均拒绝，不复用也不取消；标题按钮后出现不属于本命令的面板也停止并保留。经本命令新打开的「添加群成员」表单（与 B7 发起群聊面板同族的 `AXSheet`）逐个成员搜索并选中：已在群里的行（`checkbox selected disabled`）计入 `skipped{name, reason:"alreadyMember"}`、不按回车；找不到计入 `skipped{reason:"notFound"}`；多个同名计入 `skipped{reason:"ambiguous"}`；其余对搜索框投递一次 pid 级回车选中（与 B7 选人面板同一按键、同一批准）计入 `added`。选人后、checkpoint 前和按「确定」前重查实时策略 / 暂停、窗口与活动群及精确已选成员清单。`added` 为空、或 `dryRun` 为真时按「取消」，结果 `succeeded`，`evidence` 为 `"nothing-to-add"` / `"dry-run"`（`dryRun` 时 `added` 是本会选中但未提交的名字）；否则 checkpoint → 按「确定」→ 取证：侧栏 `群成员·N` 变为 `before + added.count`，或消息区新增一条含「邀请」且含每个 `added` 名字的系统行——有证据 `succeeded`（`evidence` 为 `"count N→M"` 或该行摘要），表单已关但无证据 `unknown`（重启后同规则，不重跑），「确定」不可用或表单未关 `failed`；checkpoint 后的策略 / 状态拒绝也归为 `unknown` 且不重试。结果 `{state, target, before?, after?, added, skipped:[{name, reason}], dryRun, evidence, latencyMs, reason?}`；`reason` 只在 `failed` 时给出（同 `message.sendFile.reason`，也会落在命令记录的 `error.message` 上），`unknown` 不给（没有证据不等于失败）。事件 `group.membersAdded` 只在有客户端证据的 `succeeded` 且 `added` 非空、`dryRun=false` 时发出；`unknown` 只发终态 `command.state` 供按原幂等键核对，不宣称已入群。`failed` 与 `dryRun` 也不发该事件。已在群的成员天然被 `alreadyMember` 跳过；`unknown` 后仍须先核对，不能自动换键重试。

### 6.45 `controller.readiness`

**查询**（与 `event.replay` 一样：不建命令记录、不产生 `command.state` 事件、不排进执行器队列）。参数 `{online?=true, refresh?=false}`。返回本机逐项就绪情况：`{ready, nextStep?{text, command?}, nextStepCapability?, capabilities: [{id, title, required, status: ok|fail|disabled|unknown, checks: [{id, status, detail, tested?, latencyMs?}], fix?{text, command?}, warnings}], online: {state: skipped|running|done, testedMs?, nextRefreshAllowedMs?}, version, generatedMs}`。能力依次为 `daemon`、`wecom`、`read`、`send`、`media`（必需）与 `contactAdd`、`autoAccept`、`vision`、`mqtt`、`oss`、`agents`、`wecomApi`（可选，未配置为 `disabled`）。`ready` = 必需项全 `ok` 且已启用的可选项 `ok`；`nextStep` 是按上述顺序第一个 `fail` 的修复指引；`command` 以 `imctl ` 开头时由调用方换成本机可执行路径。

本机检查只用守护进程已有状态（自己的授权读回、watcher 最近一次轮询、暂停原因、策略、各配置文件、MQTT 连接、Claude Code / Codex 的注册文件），不读 AX 树、不弹框，约 1 秒内返回。本机 socket 上每个连接各自排队，其他客户端的长命令不会挡住体检；经 MQTT 调用时与其它 MQTT 命令共用一条命令队列，会排在先到的命令之后。`online:true` 时若没有 300 秒内的实测结果，就在后台起一轮（同一时间最多一轮，总期限 40 秒）：已开启云端视觉且有密钥时用程序画的合成图走一次 B16 请求；MQTT 模式下 QoS 1 发布到 `im/{controller_id}/readiness` 并等 broker 确认；有 `oss.json` 时做 1 KB 往返；已注册时启动包内 `imctl mcp serve` 握手；有 `wecom-proxy.json` 时 `GET <baseURL>/healthz`。本次返回 `online.state: running`，调用方隔一秒再调，直到 `done`。`refresh:true` 忽略上次结果，但距上一轮开始不足 60 秒时仍返回上次结果（不分调用方）。上次结果只对测它时的配置有效：视觉、MQTT、OSS、企微代理的配置文件或智能体注册一有变化，下一次 `online:true` 调用就另起一轮，不受 300 秒与 60 秒限制（MQTT 连上或断开不算配置变化）。`oss.json`、`wecom-proxy.json` 只在守护进程启动时读入：启动后才写入或改过的，`oss` / `wecomApi` 报 `fail`（检查项 `loaded`，重启守护进程后生效），不做实测。检查项只含状态、计数、错误类别与耗时，不含密钥、号码、会话名、broker 地址、桶名或 corpId。命令行 `imctl doctor`、控制台「体检」页与初始化向导都调它。

B53：`fix` 可带 `action: {kind, target?}`，是给人点的快捷操作类型（`openSystemSettings`（`accessibility` / `screenRecording` / `fullDiskAccess`）、`openWeCom`、`setup`、`reinstallDaemon`、`restartDaemon`、`resumeDaemon`、`registerAgents`、`installSkills`、`retest`、`openSettings`（`mqtt` / `oss` / `proxy` / `vision`）、`openPolicy`（`phones` / `autoAccept` / `allowlist`）、`openLogs`）。客户端只执行认识的类型，从不执行 `command` 的文字；不认识的 `kind` 只显示文字。报告另带 `build`（守护进程启动时的 `CFBundleVersion`，开发构建为空）与 `runningCommands`（本次启动以来受理、仍为已接受或执行中的命令数；更早进程遗留的不算）；`setup` / `reinstallDaemon` / `restartDaemon` 在点按钮与确认时各查一次，`runningCommands > 0` 或守护进程在运行却没有应答时由客户端拒绝，连不上（没在运行）或早于 B53 的守护进程按 0 处理。新增可选能力 `health`（运行健康：最近一小时失败、结果未知的命令数与读取企业微信出错次数），只出提醒，不影响 `ready`；`daemon` 增加 build 一致性检查（运行的与已安装的不一致为 `fail`，动作 `restartDaemon`），`mqtt` 增加最近一次收到命令的时间。智能体可以读 `action`，但只报告，不执行。

**仍只在本机的功能**：MQTT 与代理设置（改连接自身、含 secret）、LaunchAgent 安装 / 重启 / 卸载、对接文档页。其余控制台页面的动作都有对应方法：会话 = `conversation.list` / `conversation.read` / `client.navigate` / `message.history`，发送 = `message.send`，通讯录 = `contact.*` / `group.create` / `group.rename` / `group.addMembers`，事件 = `event.replay`，策略 = `policy.*`，体检 = `controller.readiness`（页内「界面诊断」在控制台进程里只读，不经守护进程），日志 = `controller.logs`。

## 7. 事件

MQTT 载荷：`{"eventId": N, "tsMs": …, "kind": "<kind>", "controllerId": "…", "payload": {…}}`。`payload` 的值除标注外均为字符串；缺省字段省略而不是填假值。

### 7.1 `controller.state`

三种触发：暂停变化 `{paused:[…]}`；客户端可达性变化 `{paused:[…], clientAvailable:true|false（布尔）, reason?}`；策略文件热加载 `{policy:"titles=… types=… chatIds=… externalUserIds=…", policyFile}`。（B7 起可含 `newCustomersBadge`：通讯录导航栏角标数，即客户端的「新的客户」计数——接受后不一定减少，不等于待处理数；待处理请以 `contact.request.list` 的 `status` 为准。B49 起导航栏布局无法按 AX 结构识别时沿用上次已归属的值（守护进程启动后尚无则为 0），不因无法识别而跳变，也不代表确认无申请）

### 7.2 `account.changed`

保留（登录 / 账号切换），v0.1 不发。

### 7.3 `conversation.activity`

会话表某行变化：`{title, fields:"preview,badge,timeLabel,selected,type,title 的逗号子集", preview, timeLabel, badge, conversationType, chatId?, externalUserId?}`；活动会话切换：`{activeFrom, activeTo, conversationType, chatId?, externalUserId?}`。`badge` / `preview` 变化是"有新消息"的低保真信号；完整入站事件不存在。

### 7.4 `message.observed`

新出现的可见无文本媒体行若 AX 方向未知，守护进程在事件落库和 MQTT 发布前最多截取企微窗口一帧补证据；守护进程常规轮询不反复截图，首次观察到的历史页和切换会话时的历史基线不因截图制造新事件。屏幕录制未授权或证据不够时仍发布 `direction:"unknown"`、`origin:"unknown"`，业务侧不据此自动回复。

当前活动会话新增一条消息行：`{conversation, kind:"message"|"media"|"file"|"video", direction, timeLabel, text, origin, commandId?, sender?, fileName?, fileSize?, fileType?, mediaType?, duration?, messageKey, conversationType, chatId?, externalUserId?}`（`media` / `file` / `video` 见 §6.6，`text` 为空串；`mediaType` 只在 `media` 行给 `image` 或 `unknown`，与 `message.history` 同一判据）（`sender` 只在客户端显示发送者标签时出现；`conversationType` 在客户端无证据时按身份桥的类型补，同 §5）。`origin`：`controller`（我们发的，带 `commandId`）、`other`（**接管信号**：同账号的人从手机 / 桌面发出）、`peer`（对方）、`unknown`。切换会话那一轮、历史前插、系统通知与时间分隔行都不产生本事件。

### 7.5 `command.state`

`{commandId, state, method, idempotencyKey?, errorCode?, queuedMs?, irreversibleSteps?, visualGoal?, visualPhase?, visualRound?, visualOutcome?}`，每次状态迁移一条。`queuedMs` 只出现在 `accepted` 且排队等待 > 0 ms 时：执行器串行执行，一条慢命令（发送 10 s 超时、通讯录导航）会让后面的命令等待，等待超过 1 s 还会写进守护进程日志（2026-09-15 现场的“7 秒不接 socket”就是这个等待）。 B54：记录带 `diagnosis` 时多这五个字符串字段，取值同第 3 节。

### 7.6 `contact.request.observed`

守护进程每轮对新出现的待接受卡片各发一次：`{name, greeting?, source, status}`（按 `name+greeting` 去重）。

### 7.7 `contact.request.accepted`

`{name, accepted:"true", status:"added", by:"policy"|"remote", commandId}`——`policy` 为守护进程按本机策略接受，`remote` 为业务侧命令。

### 7.8 `group.created`

`{title, memberCount, renamed, opened, members, requestedName?, commandId}`。`opened` = 客户端已切到新群（头部带成员数）；建群是异步的（活体 2026-09-15：约 4 s），`opened:"false"` 表示 10 s 内未见成员数，群可能稍后才出现，业务侧勿据此重建。

### 7.9 `group.membersAdded`

`{commandId, target, added, before?, after?}`。只在 `group.addMembers` 获得客户端入群证据且命令结果为 `succeeded`、`added` 非空、`dryRun=false` 时发出。`unknown` 只发终态 `command.state`，消费者须按命令记录核对，不得推断成员已入群；`dryRun`、`nothing-to-add` 和 `failed` 也不发本事件。

## 8. 重放与 gap 对账

事件 `eventId` 严格单调、无空洞（控制器本地日志是真相，broker 缓冲只是快路径）。消费方每个 `controllerId` 维护 `lastEventId`：收到 `e.eventId <= lastEventId` 丢弃；`== lastEventId + 1` 落库前进；`> lastEventId + 1` 先落库再循环 `event.replay{afterEventId: lastEventId, limit: 500}` 补齐到 `count < limit` 或 `events.last.eventId == lastEventId`。触发对账的时机：出现空洞、自身重连、`state` 从 `online:false` 变 `online:true`。

## 9. 企微回调事件（`wecom/{corp_id}/evt`）

由代理发布：`{"eventId": N, "tsMs": …, "kind": "wecom.callback", "corpId": "…", "payload": {"Event": "change_external_contact", "ChangeType": "add_external_contact", "UserID": "…", "ExternalUserID": "…", "State": "…", "WelcomeCode": "…", …}}`（字段名保持企微 PascalCase，`eventId` 由代理单调分配）。典型：`change_external_contact/add_external_contact`（联系我扫码 → 20 s 内 `contact.welcome.send`）、`change_external_chat/create|update|dismiss`（群活码建群 / 变更）。回调不含聊天内容。

## 10. 错误码

| 码 | 含义 | 出现位置 |
|---|---|---|
| `TARGET_NOT_FOUND` | 标题不存在，或 `chatId:` / `externalUserId:` 在身份桥未命中 | `result.error` |
| `TARGET_AMBIGUOUS` | 多个同名会话 | `result.error` |
| `TARGET_MISMATCH` | 打开后活动会话不是目标 | `result.error` |
| `TARGET_NOT_ALLOWED` | 不在编译白名单也未被 `policy.json` 放行 | `result.error` |
| `PAUSED` | 暂停 reason set 非空（`api` / `local_guard` / `system`） | `result.error` |
| `EXPIRED` | `ttlMs + issuedAtMs` 已过 | `result.error` |
| `LOCAL_GUARD` | 输入框非空（人正在打字）等本地互锁 | `result.error` |
| `INVALID_PARAMS` | 参数缺失或无法解码（缺 `idempotencyKey` 时为 JSON-RPC 错误） | 两者 |
| `CLIENT_UNAVAILABLE` | 客户端未运行、窗口不可达、AX 失败、区域缺失 | `result.error` |
| `INTERNAL` | 控制器内部错误 | 两者 |
| `RATE_LIMITED` | 超出速率硬上限 | `result.error` |
| `UNSUPPORTED` | 本控制器不能做：未 enroll 代理、群发助手探针无目标、AX 动作不可用 | `result.error` |
| `MEDIA_NOT_FOUND` | `message.media`：无法确认哪个本地缓存文件对应这个 `messageKey`（未被观察到、不在打开的会话里、文件已被客户端清理或候选有歧义）；不代表本机一定没有该文件 | JSON-RPC error `data.code` |
| `WECOM_API` | 企微 `errcode ≠ 0`（message 含 errcode 与 errmsg） | `result.error` |
| `PROXY_ERROR` | 代理不可达 / 拒绝 token / 非 2xx / 响应不可解码 | `result.error` |
| `UNKNOWN_AFTER_RESTART` | 重启后有 checkpoint 无证据，状态 `unknown` | `command.state.errorCode` |
| `SOURCE_NOT_ALLOWED` | `message.sendFile`：非 https、域名不在 `sendFile.allowedHosts`、重定向出名单 | `result.error` |
| `SOURCE_UNSUPPORTED` | 扩展名不在白名单，或文件头与扩展名不符 | `result.error` |
| `SOURCE_TOO_LARGE` | 超过 `sendFile.maxBytes` | `result.error` |
| `SOURCE_UNREACHABLE` | 下载失败 / 超时 / 对象不存在 | `result.error` |
| `PASTE_FAILED` | 附件没有出现在输入框里；未按回车，输入框已清空 | `result.error` |
| `OSS_NOT_CONFIGURED` | 用了 `ossKey` 或 `message.media`，但本机没有 `oss.json`（`imctl oss set`） | 两者 |
| `MEDIA_TOO_LARGE` | `message.media`：缓存文件超过 `oss.json.maxUploadBytes` | JSON-RPC error `data.code` |
| `OSS_ERROR` | 对象存储拒绝或不可达（HTTP 状态 + Code / Message；不含地址与密钥） | 两者 |
| `NOT_A_GROUP` | `group.addMembers`：目标没有成员列表（不是群：表头无人数且侧栏无 `群成员·`） | `result.error` |

## 11. 典型流程

- **AI 回复回路**：`conversation.activity{badge/preview}` → `conversation.read{target:"chatId:…"}` → `message.history{limit:20}` → AI → `message.send{target, text, idempotencyKey}` → `command.state=succeeded` + `message.observed{origin:"controller"}`。看到 `origin:"other"` 就按会话静默（业务侧策略）。一次只有一个活动会话，业务侧负责排队。
- **扫码建群**：`group.joinway.create{chatIds:[种子群], autoCreateRoom:true, roomBaseName, roomBaseId, state}` → `group.joinway.get` 取 `qrCode` → 客户扫码进群 → 回调 `change_external_chat`（`wecom/{corp_id}/evt`）→ `group.get` 回写身份桥 → 群内消息经 `message.observed{conversationType:"group", chatId}`。
- **扫码加人 + 欢迎语**：`contact.way.create{state}` → `qrCode` → 客户扫码 → 回调 `add_external_contact{State, WelcomeCode}` → 业务侧按渠道开关 20 s 内 `contact.welcome.send{welcomeCode, text, attachments:[群活码链接]}` → `contact.remark.set` 让桌面标题唯一。
- **群发**：`broadcast.create{chatIds, text, idempotencyKey}` → `msgid` → `broadcast.confirm{msgid}`（`UNSUPPORTED` 则逐群 `message.send`）→ `broadcast.get`。
- **人工接管**：任何 `message.observed{origin:"other"}` 表示同账号的人在发消息；业务侧对该会话静默，恢复由业务侧决定。

## 12. 版本与变更

`protocol` 字段 `im-control/0.1`（草案，未冻结；不兼容变更升 `0.2` 并写迁移）。

| 日期 | 变更 |
|---|---|
| 2026-09-12 | B1：命令记录、`command.state`、幂等键、checkpoint / `unknown`、stdio / socket 绑定 |
| 2026-09-13 | B2：MQTT 5 绑定（cmd / rsp / evt / state、Response Topic、Correlation Data、retained + 遗嘱）；B3：`message.observed.origin`、`message.history.scrollback`、`event.replay`、Response Topic 限子树 |
| 2026-09-14 | B4：`target` 语法 `chatId:` / `externalUserId:`、`policy.json` 与 `controller.state{policy}`、`RATE_LIMITED`、事件字段 `sender` / `messageKey` / `conversationType` / `chatId` / `externalUserId`、`conversation.list` 行 `conversationType` / `markers`；B5：`group.*` / `contact.*` / `broadcast.*` 16 个方法、`UNSUPPORTED` / `WECOM_API` / `PROXY_ERROR`、`describe.wecomApi`、`wecom/{corp_id}/evt`；`controller.state.paused` 统一为数组 |
| 2026-09-15 | B7：`contact.list`、`contact.request.list` / `accept`、`group.create`；事件 `contact.request.observed` / `accepted`、`group.created`；`controller.state` 增 `newCustomersBadge`；`policy.json.contactRequests`；接受经备注弹窗「完成」；建群用客户端 ⌘N + 搜索框一次 pid 级回车，单人不建群（`LOCAL_GUARD`） |
| 2026-09-15 | B6：`client.navigate`（窗口菜单导航，需 `idempotencyKey`）；`state.json` 增 `trusted` / `socket`；控制台与安装包不改 wire 协议。B4 活体校准：速率上限按会话（id 经桥解析）计；`message.observed.sender` 缺失即省略；`conversationType` 无客户端证据时按桥补；`origin` 归因对 `chatId:` 目标经桥比对 |
| 2026-09-15 | B8：`message.history` / `message.observed` 增 `kind`（`media` 行）；`conversation.list` 的「外部」标签可来自 badge 槽；`group.create` 增 `opened` 与真正的 `renamed`；新增 `group.rename`（头部标题文本框 + `AXConfirm`）；群内发送者标签「名字@微信」按钮 → `sender` 去掉 `@微信` |
| 2026-09-16 | B9：`policy.get` / `policy.set`（本机 `remoteEdits` 开关）、`controller.diagnose`、`controller.logs`；`contact.list.scope`；`contactRequests.groupNameTemplate`（默认 `{客户名}群聊`）；`command.state{accepted}` 增 `queuedMs`；发送前把客户端置前（未激活时回车被丢弃） |
| 2026-09-16 | B12：`contact.add`（按手机号添加客户：添加客户面板 + 一次搜索框回车 + 「添加」；号码白名单 `contactAdd.allowedPhones`，`policy.set{allowPhones, denyPhones}`）；脱敏规则不再保留 ≥ 7 位连续数字 |
| 2026-09-16 | B11：`message.broadcast`（群发 = 逐目标的子 `message.send`，等限速、可插队）；`controller.permissions{prompt}` + `imctl setup`（一次性授权与检查）；图片行带自己的时间标签也识别为 media（388 px 行）；`message.media` 的界面读取进串行队列 |
| 2026-09-16 | B10：`conversation.read` / 回滚默认不经白名单（`policy.json.gateReads`，`imctl policy reads`，`policy.set{gateReads}`）；`controller.mediaCache`（图片路线第一步：客户端缓存只读清单，`{dir}` 列目录）；智能体接入 `imctl mcp serve`（stdio MCP → 守护进程套接字桥，见 `agents-mcp.md`）；`message.media`（图片从客户端缓存取回，`MEDIA_NOT_FOUND`），`message.history` media 行带 `media` |
| 2026-09-22 | B13：`message.sendFile`（https / ossKey → outbox → ⌘V → 回车）；行 `file` / `video`；`message.media` 改为 OSS 签名地址；`policy.json.sendFile`；`oss.json` |
| 2026-09-23 | B14：`group.addMembers`（已建群二次添加成员，经「添加群成员」表单；已在群成员 `alreadyMember` 跳过，天然幂等；`dryRun` 只选中即取消）；事件 `group.membersAdded`；错误码 `NOT_A_GROUP`；`ActionKind.addGroupMembers`（阶段 0 禁止，同 `submit` / `sendFile`）；MCP `tools/list` 43 → 44 |
| 2026-09-24 | `messageKey` 对可解析时间标签使用 UTC 分钟，跨日相对标签不再换键；`message.media` 对经唯一性、日期和文件头验证的旧图片缓存分配做一次性迁移；`MEDIA_NOT_FOUND` 的文案明确区分“无法确认对应”与“本机无文件”。方法、字段、错误码集合不变。 |
| 2026-09-24 | 用户允许按需单帧窗口截图识别 AX 无方向锚点的可见 `media` 行左右，`controller.permissions` 增 `screenRecording`；`message.history` 与 MQTT `message.observed` 共用方向结果，证据不足仍为 `unknown`。无图片字节进入协议。 |
| 2026-09-24 | B17 目标契约：显式固定桌面命令计划在本机云端开关开启后用经核验的企微窗口单帧做有界多轮 AX 定位；method / 参数 / 响应信封 / topic 不变，后台观察不上传。逐方法实现与活体状态以门报告为准，见 §4.1。 |
| 2026-09-28 | B49：`controller.state.newCustomersBadge` 与自动接受轮次触发改按导航栏实时 AX 结构归属「通讯录」，无法归属时沿用上次值、不启动轮次；`group.create` 新群消息视口未出现时不写群名（`renamed:false`）；无新方法、字段或错误码 |
| 2026-09-29 | B50/B51：`contact.add` 面板按本命令证实的窗口号截图；企业微信用户的邀请走独立「发送验证申请」窗口（只认实录形状、按前快照定归属、窗口消失才算 `requested`、截图须证实窗口号），结果增 `inviteWindow`，列出既有的 `inviteDialog` / `greeting` 与 `confirm-pressed` 状态；其它企微窗口挡在通讯录页前不再累计为客户端不可达；结果行视觉复核按「所选来源唯一」，同号的微信 / 企业微信两行不再令模型停止 |
| 2026-10-11 | B52：新增查询 `controller.readiness`（逐项就绪、修复指引、后台联网实测；不建命令记录、不发事件）；MCP `tools/list` 44 → 45；MQTT 探测主题 `im/{controller_id}/readiness` 只由控制器发布 |
| 2026-10-12 | B53：`controller.readiness` 的 `fix.action`、报告 `build` / `runningCommands`、可选能力 `health`；`daemon` 增加 build 一致性检查，`mqtt` 增加最近一次收到命令的时间。方法、错误码集合不变。 |
| 2026-10-13 | B54：命令记录视图与 `command.state` 事件的 `diagnosis`（`command.get` 的 `diagnosis_json`）；守护进程视觉轮次日志；`contact.add` 独立「发送验证申请」窗口的邀请轮目标 `contactSendVerification`，结果行提示写明所选来源；`contact.add` 不再要求号码白名单（用户决定），只收手机号形式，只搜索另有每小时上限 `maxSearchesPerHour`，`policy.set` 的 `allowPhones` / `denyPhones` 不再生效。方法、错误码集合不变。 |
