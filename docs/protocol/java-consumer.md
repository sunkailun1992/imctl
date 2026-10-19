# Java 最小消费方契约（IM Control Protocol over MQTT 5）

Java 只发命令、只做消息业务；它看到的是 topic、JSON-RPC 2.0 信封和事件流。本页是 Java 侧实现前要遵守的全部约定；共享订阅**组名由用户决定**，下文写作 `<group>`。

## 连接

- MQTT 5，用户 `java`（见 `docs/ops/emqx-auth-acl.md`），`cleanStart = false`，`sessionExpiryInterval` ≥ 86400，QoS 1。
- 每个 Java 实例一个稳定 `clientId`（如 `java-<instance>`），回复 topic 固定为 `im/<controller_id>/rsp/<instance>`。

## 命令（Java → 控制器）

- 发布到 `im/<controller_id>/cmd`，QoS 1，MQTT 5 属性：`Response Topic = im/<controller_id>/rsp/<instance>`，`Correlation Data = <request id>`。
- 载荷 JSON-RPC 2.0：`{"jsonrpc":"2.0","id":"<uuid>","method":"message.send","params":{"target":"…","text":"…","idempotencyKey":"<uuid>","ttlMs":30000,"issuedAtMs":<epoch ms>}}`。
- **目标语法**（B4 起）：`target` 接受 `chatId:<chat_id>`、`externalUserId:<external_userid>` 或纯标题（开发期）。ID 经控制器本地身份桥（`identities` 表：B5 由企微 API 填充，之前用 `imctl identity set` 手工填）解析成客户端标题；桥未命中 `TARGET_NOT_FOUND`，同名 `TARGET_AMBIGUOUS`，打开后不符 `TARGET_MISMATCH`。生产只用平台 ID，标题不是身份。
- **`message.send` 必带 `idempotencyKey`**（Java 生成、全局唯一、≥24 h 不复用）。QoS 1 重复投递与 Java 自身重试都用同一个 key → 控制器返回同一 `commandId`，不重发。**重试是新的业务决定时才换新 key**；`unknown` 对控制器是终态，Java 不得用同 key 期待重跑。
- 响应是便利：可能因断网丢失。真相是 `…/evt` 上的 `command.state` 事件。
- Response Topic 不在 `im/<controller_id>/` 子树内会被忽略，回复落到 `im/<controller_id>/rsp`。
- **速率硬上限**（控制器侧，按尝试计数）：同一目标 ≥ 3 s 间隔，全局 60 s 内 ≤ 20 次；超出 `command.state=failed`、`errorCode=RATE_LIMITED`。Java 的策略只能更严；被限的命令不会自动重试，用新键重发是 Java 的业务决定。
- **白名单与策略**：目标必须在控制器编译白名单（`文件传输助手`）或本地 `policy.json`（按标题 / 会话类型 / `chat_id` / `external_userid` 放行，`imctl policy allow|deny`）内，否则 `TARGET_NOT_ALLOWED`。放开真实客户或群是人在 Mac 上的决定，Java 无法远程放宽；策略变化以 `controller.state{policy}` 事件通知。

方法（完整定义见 `im-control-protocol.md`）：`controller.describe`（含 `policy` 摘要、`targetSyntax`、`wecomApi`）、`controller.readiness`（查询：逐项就绪，联网实测在后台）、`account.status`（含 `activeType`、`activeMemberCount?`）、`conversation.list`（行含 `conversationType`、`markers?`）、`conversation.read{target}`（返回 `conversationType`、`chatId?`、`externalUserId?`）、`message.send`、`message.sendFile{target, url|ossKey, fileName?, idempotencyKey}`、`group.addMembers{target, members, dryRun?, idempotencyKey}`（已建群补人，结果 `added` / `skipped`，`dryRun` 先试）、`message.history{limit, scrollback}`（普通读先将当前会话定位最新；回滚读加载旧历史；行含 `sender?`、`messageKey?`、`readError?`，不含系统消息）、`command.get{commandId|idempotencyKey}`、`command.cancel`、`controller.pause`、`controller.resume`；查询 `event.replay{afterEventId, limit}`（见下）。API 路线（B5，需控制器 `imctl wecom enroll`，否则 `UNSUPPORTED`）：`group.list|get`、`group.joinway.create|get|update|delete`、`contact.way.create|list|get|update|delete`、`contact.welcome.send`、`contact.remark.set`、`broadcast.create`（需 `idempotencyKey`）`|confirm|get`；不受暂停影响；错误 `WECOM_API`（企微 errcode）/ `PROXY_ERROR`；企微回调事件在 `wecom/{corpId}/evt`（`docs/protocol/wecom-token-proxy.md`）。
- **文件与媒体类型**：`message.sendFile` 只给地址（https，域名要在控制器本机的 `policy.json.sendFile.allowedHosts`）或 `ossKey`；`message.media` 对图片 / 文件 / 视频回 OSS **签名地址**（`url`，`expiresAtMs` 过期后再问一次），MQTT 上永远没有文件内容。`message.history` 与 `message.observed` 用 `kind=file` + `fileType` 区分 PDF / Word 等文件，`kind=video` 表示视频，`kind=media` + `mediaType=image|unknown` 表示无文本媒体；`unknown` 可能是图片、表情或卡片，业务侧不得猜测。只有选中会话最新预览明确为 `[图片]` 且最后一条消息行是无文本媒体时才给 `image`。精确匹配「文件传输助手」的自我会话在历史与 MQTT 事件中统一报 `direction=outbound`；其它会话维持证据不足时的 `unknown`。单行 `readError=AX_VALUE_UNAVAILABLE` 表示文本 AX 值重读后仍不可用，该行和后续行可能省略 `messageKey`；业务侧应重新回读，不据不完整行自动回复。

## 事件（控制器 → Java）

- 订阅 `$share/<group>/im/+/evt`，QoS 1。任一实例收到即落库；落库唯一键 `(controllerId, eventId)`，重复投递靠它去重。
- 载荷：`{"eventId":N,"tsMs":…,"kind":"…","controllerId":"…","payload":{…}}`；user property 也带 `event_id`、`kind`、`controller_id`。
- `kind`：`command.state{commandId,state,method,idempotencyKey?,errorCode?}`、`conversation.activity{title,fields,preview,timeLabel,badge,conversationType,chatId?,externalUserId? | activeFrom,activeTo,conversationType,chatId?,externalUserId?}`、`message.observed{conversation,kind,direction,timeLabel,text,origin,commandId?,sender?,fileName?,fileSize?,fileType?,mediaType?,duration?,messageKey,conversationType,chatId?,externalUserId?}`、`controller.state{paused,clientAvailable?,reason? | policy,policyFile}`。
- `sender`：群内发送者标签（客户端在气泡上方显示的名字）；私聊和我们自己的气泡为空串。`messageKey`：`会话+发送者+时间标签+文本+同元组序号` 的 SHA-256 前 16 hex，不含行索引（历史前插不改变它）；「文本」对没有文本的行取行上的文件名（`text ?? fileName`，即 `file` 行的文件名）。Java 用它把 `message.observed` 与 `message.history` 去重。`conversationType ∈ {group, customer, internal, unknown}`：只在客户端有证据（群头部成员数 / 发送者标签 / 列表标记）时给出，`unknown` 是合法值；`internal` 当前不推断。`chatId` / `externalUserId` 只在身份桥命中时出现；未命中的事件只有标题，Java 不得凭标题下发送命令（开发期除外）。系统消息（入群、撤回等居中通知）和时间分隔行不产生 `message.observed`。
- `message.observed.origin`：`controller`（我们发的，带 `commandId`）、`other`（**接管信号**：同一账号从手机或桌面由人发出）、`peer`（对方发来的）、`unknown`（方向不明，不驱动自动回复）。按会话静默是 Java 的策略。
- `im/<controller_id>/state`（retained）：`{"online":true|false,"pid":…}`；遗嘱把它置为 offline。

## 断网 / 重连下的 gap 对账

事件按 `eventId` 严格单调、无空洞（控制器本地日志是真相，broker 缓冲是快路径）。Java 每个 `controllerId` 维护 `lastEventId`：

1. 收到事件 `e`：若 `e.eventId <= lastEventId` 丢弃（重复）；若 `e.eventId == lastEventId + 1` 落库并前进；若 `e.eventId > lastEventId + 1` 先落库这条，再进入补齐。
2. 补齐：循环调 `event.replay{"afterEventId": lastEventId, "limit": 500}`，把返回的 `events` 逐条落库（同样按唯一键去重），`lastEventId` 前进到已连续的最大值；直到 `count < limit` 或 `events.last.eventId == lastEventId`。
3. 触发补齐的三种时机：出现空洞；Java 自己重连成功；`…/state` 从 `online:false` 变 `online:true`（控制器重启，它的 MQTT 游标只在发布成功后前进，通常不丢，但仍对账一次）。
4. `event.replay` 是查询，不产生 `command.state`；可以频繁调用。控制器事件表不裁剪（v0.1）。

## 一条完整回路（建议的最小实现）

`conversation.activity`（`badge`/`preview` 变化）→ `conversation.read{target}` → `message.history{limit:20}` 决定回复 → `message.send{idempotencyKey}` → 等 `command.state = succeeded`（证据 = 外发气泡）→ 随后 `message.observed{origin:"controller", commandId}` 闭环。看到 `origin:"other"` 就按会话静默（Java 策略）。

## 不承诺的事

- 平台送达；完整入站流（只有可见窗口）；方向 `unknown` 的消息。
- 白名单 / 策略外目标：`TARGET_NOT_ALLOWED`；身份桥未命中：`TARGET_NOT_FOUND`；同名会话：`TARGET_AMBIGUOUS`；人留草稿：`LOCAL_GUARD`；暂停：`PAUSED`；超速：`RATE_LIMITED`。
- `conversationType=unknown` 的会话不会被类型规则放行；方向 / 来源 / 类型为 `unknown` 的消息不驱动自动回复。
