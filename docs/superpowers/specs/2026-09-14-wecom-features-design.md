# 企业微信功能设计（v0.2 草案）

用户 2026-09-14 00:56 决定：个人微信暂缓，先完成企业微信全部功能；拉群后必须让后期业务程序拿到用户聊天内容、方便交给 AI 分析并由 AI 自动回复。09:17 批准本设计（"全部完成吧"）。设计口径来自 wiki topic 页，本文只写企微功能的增量；官方接口事实按 2026-09-14 查阅的企业微信开发者文档（`add_join_way` 92229、`add_contact_way` 92228、`add_msg_template` 92135、`groupchat/list` 92120、`groupchat/get` 92707、回调 94670）。

## 1. 需求与能力对照

| 需求 | 路线 | 官方事实 |
|---|---|---|
| 自动创建客户群 | 群活码 `groupchat/add_join_way`：`scene=2`、`chat_id_list ≤ 5`、`auto_create_room=1` 群满自动建、`room_base_name`+`room_base_id` 命名、`state ≤ 30` 区分渠道 | 没有"建群"API；不用 JS-SDK `openEnterpriseChat`（需客户端选人，含微信客户时 ≤ 40 人） |
| 扫企微码自动建微信群 | 同上，客户扫群活码进群；群变更由回调 `change_external_chat`（create/update/dismiss）通知 | 长期有效（区别于 7 天的群二维码名片） |
| 扫个人码拉群 + 开关 | 联系我 `add_contact_way`（`scene=2`、`state` 渠道、`skip_verify`）→ 回调 `change_external_contact/add_external_contact`（带 `State`、`WelcomeCode`）→ Java 按渠道开关决定 → `send_welcome_msg`（**20 s 内**）附群活码链接 → 客户点链接进群 | 联系我没有"自动进群"选项；没有把外部客户拉进群的 API；真拉人只能桌面 UI（本期不做） |
| 群发 + 控制哪些群 | 企业群发 `add_msg_template{chat_type:"group", chat_id_list ≤ 2000, sender}`，`chat_id_list` 由 Java 白名单给出；创建后**成员需在客户端确认**，由 imctl 用 AX 在桌面客户端"群发助手"里点击确认；结果 `get_groupmsg_send_result` | 每客户/每群每月上限 = 当月天数（≈ 每天 1 条）；文本 ≤ 4000 字节，附件 ≤ 9 |
| 用户聊天内容获取（供 AI） | 桌面 UI 观察：群会话解析（发送者标签、文本、时间、去重键），`conversation.activity` 触发 `conversation.read` + `message.history`；身份桥把 `chat_id`/`external_userid` 对到会话 | 会话存档（付费、Linux/Windows SDK、需客户同意）留作后期补全 |
| AI 自动回复 | Java 侧：事件 → AI → `message.send{target: chatId|externalUserId}`；imctl 解析目标、UI 发送、`origin` 归因 | 大模型只在回复内容/异常处理/维护三处进入（既定） |

## 2. 组件与职责

| 组件 | 位置 | 职责 | 不做 |
|---|---|---|---|
| `WeComAdapter`（扩展） | imctl / Mac | 群会话解析（发送者标签、系统消息过滤、去重键）、会话类型识别（外部群 / 外部客户 / 内部）、目标解析（`chatId:`/`externalUserId:`/标题） | 不猜方向未知的消息 |
| `WeComAPI`（新，Swift） | imctl / Mac | 经代理调企微接口：群列表/详情、群活码、联系我、欢迎语、群发、备注；身份桥缓存（`identities` 表）；API 路线命令的执行器 | 不持 secret，不直连企微 |
| `wecom-token-proxy`（新，Java 17 / Spring Boot 4） | 云端固定 IP 主机 | 持 corp secret、刷 access_token、`POST /wecom/**` 透传注入 token（路径白名单）；接收企微回调（签名校验 + AES 解密）→ MQTT `wecom/{corpId}/evt`（QoS 1）；对 imctl 用 Bearer token 鉴权 | 无业务、无企微语义、不落库正文 |
| Java 消费方（参考实现，`examples/java-consumer`） | 用户 Java fleet | 订阅 `$share/<group>/im/+/evt` 与 `wecom/+/evt`，落库去重，`event.replay` 对账；渠道开关、群白名单、AI 回复策略（可插拔，默认 OpenAI 兼容接口）；发命令 | 不碰企微 API、不感知客户端 |

## 3. 协议扩展（草案）

- **方法（API 路线，经 `WeComAPI`）**：`group.list`、`group.get{chatId}`、`group.joinway.create{chatIds, remark, autoCreateRoom, roomBaseName, roomBaseId, state}` / `group.joinway.get|update|delete{configId}`、`contact.way.create{type, scene, remark, skipVerify, state, users, conclusions}` / `contact.way.list|get|update|delete`、`contact.welcome.send{welcomeCode, text, attachments}`、`contact.remark.set{externalUserId, remark}`、`broadcast.create{chatIds | externalUserIds, text, attachments, sender, idempotencyKey}`、`broadcast.confirm{msgid}`（UI 步骤）、`broadcast.get{msgid}`。`broadcast.create` 需幂等键（会产生群发任务）。
- **事件（imctl `…/evt`）**：`message.observed` 增加 `sender`（群内发送者标签，私聊为空）、`messageKey`（会话+索引+文本+时间的稳定散列）、`conversationType`（`group` / `customer` / `internal` / `unknown`）、`chatId?` / `externalUserId?`（身份桥命中时）；`conversation.activity` 增加 `conversationType`、`chatId?` / `externalUserId?`。
- **事件（代理 `wecom/{corpId}/evt`）**：`{eventId, tsMs, kind:"wecom.callback", payload:{Event, ChangeType, UserID, ExternalUserID, ChatId, State, WelcomeCode, …}}`，`eventId` 由代理单调分配并持久化，Java 同样以 `(source, eventId)` 去重。
- **目标语法**：`message.send.target` 与 `conversation.read.target` 接受 `chatId:<id>`、`externalUserId:<id>` 或纯标题（开发期）；控制器解析失败 `TARGET_NOT_FOUND`，多个 `TARGET_AMBIGUOUS`。

## 4. 身份桥

- 群：`group.list` + `group.get` 得到 `chat_id → name`，写 `identities(kind='group', id, title, updated_ms)`；自动建的群名 = `room_base_name + 序号`，天然唯一；种子群必须由人设唯一群名（本期测试群由用户命名）。
- 客户：`contact.remark.set` 把备注写成 `<原名>·<external_userid 短码 6 位>`，控制器据此在会话表按标题定位；备注只在客户加好友事件后由 Java 下令写入。
- 桥未命中时事件只带标题，不带 id；Java 不得凭标题下发送命令（开发期除外）。

## 5. 策略与白名单

- 编译默认仍是 `["文件传输助手"]`；新增本地策略文件 `~/Library/Application Support/imctl/policy.json`（0600）：`allowedTitles`、`allowedTypes{group, customer, internal}`、`allowedChatIds`、`allowedExternalUserIds`，由 `imctl policy allow|deny|list` 维护，改动写日志事件 `controller.state{policy}`。上线放开外部群/外部客户是用户决定。
- 速率硬上限（imctl）：每会话 ≥ 3 s 间隔，全局 ≤ 20 条/分钟；超出 `RATE_LIMITED`。Java 的策略上限只能更严。

## 6. AI 回复回路（数据流）

客户在群里发言 → 客户端会话表出现未读 → imctl `conversation.activity{chatId, badge}` → Java `conversation.read{target:"chatId:…"}` → imctl 切换并回 `messageCount`，随后 `message.observed{sender, text, messageKey, chatId}`（切换那一轮的整屏历史不推，Java 用 `message.history{limit}` 取上下文）→ Java 调 AI → `message.send{target:"chatId:…", text, idempotencyKey}` → imctl UI 发送 → `command.state=succeeded` + `message.observed{origin:"controller"}`。看到 `origin:"other"` 即按会话静默（Java 策略）。一次只有一个活动会话，Java 负责排队。

## 7. 群发流程

Java 决定群列表 → `broadcast.create` → imctl 经代理调 `add_msg_template` 得 `msgid` → 客户端出现"群发助手"待发送任务 → imctl `broadcast.confirm{msgid}`：AX 定位客户端里的群发任务与"发送"按钮并 `AXPress`（探针先验证可达；不可达则回 `UNSUPPORTED`，Java 改用逐群 `message.send`）→ `broadcast.get` 查结果。

## 8. 代理与回调

- 部署：用户指定的固定公网 IP 主机（可信 IP 即它的出口 IP），HTTPS 域名，企微后台"接收事件服务器"填 `https://<host>/wecom/callback`，Token/EncodingAESKey 只在代理环境变量。
- 代理对 imctl：`Authorization: Bearer <proxy-token>`；路径白名单只放本设计用到的接口；限流与审计日志（不含正文）。
- 回调：GET 验签回显 echostr；POST 验签 + 解密 → 发布 MQTT（持久会话，QoS 1）；企微要求 5 s 内回 `success`，代理先发 MQTT 再应答。

## 9. 边界与风险

- 欢迎语 20 s 窗口：Java 必须秒级响应；Mac 离线则本次跳过，事件仍在。
- 群发每群每天 1 条；AI 回复不走群发。
- 风控：控制器硬上限 + Java 策略；客户消息送云端模型的合规由业务侧决定。
- 开发期只对用户自己的测试群（只有本人）与本人微信作为测试客户发消息；任何真实客户/客户群的发送等用户放开策略。
- 个人微信暂缓（4.1.13 无 AX 树）。

## 10. 验收

| 组件 | 单元 | 活体 |
|---|---|---|
| 群解析 / 身份桥 / 策略文件 | 夹具（脱敏的群会话树）测试 | 测试群：发送者标签、去重、`conversationType`、`chatId:` 目标发送 |
| `WeComAPI` | 伪代理（`URLProtocol`）测试每个方法的请求/响应映射 | 需自建应用 + 代理上线后：群活码建群、联系我、欢迎语、群发 + AX 确认 |
| `wecom-token-proxy` | token 缓存、路径白名单、回调验签/解密、MQTT 发布的单元测试 | 部署后用企微后台"测试回调"与真实扫码 |
| Java 消费方 | 事件落库去重、对账、渠道开关、AI 策略的单元测试 | 与 imctld + 代理联调一次完整回路 |

## 11. 需要用户提供

自建应用（corpid、agentid、secret、可信 IP、回调 Token/EncodingAESKey，只进代理环境变量）；代理主机与域名；测试群名（把"未设置群名"改成唯一名）；本人微信加为测试客户；共享订阅组名（暂用 `imctl-consumers`）；上线时放开策略的决定。
