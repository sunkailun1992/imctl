# 批次 B4：群会话解析、策略文件、平台 ID 目标语法、事件字段扩展、速率硬上限（2026-09-14 15:1x–19:3x CST）— 单测通过、只读探针通过、活体待用户事项

条件：企微 5.0.11（pid 76115，非前台、未隐藏）；终端进程辅助功能 trusted（继承自桌面应用）；launchd 下的 `imctld`（稳定副本，旧二进制 `5f8e8c9` 之前的构建）仍 **未勾选辅助功能**，`state.json` 为 `paused ["system"]`、`errors` 持续增长；本批**没有选行、没有设值、没有发送**，只做只读探针；探针输出默认脱敏（标题 → `«hash»`）。计划：`docs/superpowers/plans/2026-09-14-b4-group-parsing-policy-targets-ratelimit.md`。规格：`docs/superpowers/specs/2026-09-14-wecom-features-design.md` §2–§5。

## 实现

- `ControlCore`：`ConversationType{group,customer,internal,unknown}`；`TargetRef.parse`（`chatId:` / `externalUserId:` / 标题；空 ID 不匹配任何东西）；`MessageKey`（会话+发送者+时间标签+文本+同元组序号的 SHA-256 前 16 hex，**不含行索引**——B3 实测历史前插会移位索引）；`ControlError.rateLimited`（`RATE_LIMITED`）；`targetNotFound` 文案改为对目标（可含 `chatId:`）。
- 策略：`SendPolicy`（`policy.json`，0600，`allowedTitles` / `allowedTypes{group,customer,internal}` / `allowedChatIds` / `allowedExternalUserIds`；缺文件 = 空策略，坏文件抛错不视为放行）；`ResolvedTarget`；`ActionPolicy.authorize(_:resolved:)`：标题规则 → ID 规则 → 类型规则，`unknown` 类型永远不被类型规则放行；编译白名单未改。`PolicyProvider` 按 mtime+size 热加载，坏文件保留上一份好策略并记 `lastError`。
- `RateLimiter`：每目标 ≥ 3000 ms、全局 60 s 滑动窗口 ≤ 20 次，按**尝试**计数；`CommandExecutor` 在幂等 / 过期 / 暂停检查之后、`running` 之前 `admit`，拒绝即 `failed` + `RATE_LIMITED`（一条 `command.state`）。
- 身份桥：`ControlStore` 迁移 `v3-identities`（`identities(kind,id,title,updated_ms)`，PK `(kind,id)`，`title` 索引）；`Identity` / `IdentityKind` / `IdentityLookup`（`ControlStore` 实现；`NoIdentities` 供测试与 CLI 探针）。
- `WeComAdapter`：`MessageRow.kind ∈ {message, system, timeSeparator, empty}`（无 `AXTextArea` 且唯一静态文本水平居中 = 系统通知；只有时间标签 = 分隔行）；`ConversationRow.markers`（列表标记 `微信` / `外部` / `外部群` 不再混进标题或预览）；`ConversationHeader.parse`（"群名(12)" → 标题 + 成员数，`activeConversationTitle()` 返回归一化标题）；`ConversationTypeInference`（头部成员数或发送者标签 → `group`；`微信` 标记或 "名字@公司" → `customer`；`外部` 标记 → `group`；否则 `unknown`；`internal` 不推断）；`WeComReader.chatMessages()`（只含 `.message` 行并赋 `messageKey`）；`TargetResolver`（桥 + 行 + 头部 / 消息证据 → `ResolvedTarget`，客户端证据优先于桥的类型）；`WeComActions.resolvedTarget` 让 select / compose / submit / scroll / menu 的内部授权与命令级授权一致；`WeComCommandHandler` 接 `IdentityLookup` 与 `sendPolicyProvider`，`describe` 带 `policy` 摘要与 `targetSyntax`，`account.status` 带 `activeType` / `activeMemberCount`，`conversation.list` 行带 `conversationType` / `markers`，`conversation.read` 返回 `conversationType` / `chatId` / `externalUserId` 并对已激活会话同样过策略，`message.history` 只返回消息行且带 `messageKey`。
- 观察：`WatchSnapshot` 只保留消息行并带 `sender` / `messageKey` / `activeType` / 行级 `type`；`message.observed` += `sender`、`messageKey`、`conversationType`、`chatId?`、`externalUserId?`；`conversation.activity` += `conversationType`、`chatId?`、`externalUserId?`（`WatchEngine.identityLookup` 反查身份桥）；系统消息与时间分隔行不产生观察事件。
- 守护进程：`imctld run --policy <path>`；处理器接 `store` 作身份桥与 `PolicyProvider`；watcher 在定时轮询路径检查策略文件变化，变化即 `controller.state{policy, policyFile}` 并写日志；`state.json` 增加 `policy` 摘要。
- CLI：`imctl policy list|allow|deny`（`--title` / `--chat-id` / `--external-user-id` / `--type`，可重复；写 0600）；`imctl identity list|set|remove`（直接写 imctld 的 SQLite）；`probe conversations` 行带 `type` / `markers`，`probe messages` 行带 `kind` / `key`。`tools/list` 的 `target` 描述改为含 `chatId:` / `externalUserId:`。
- 文档：`docs/protocol/java-consumer.md`（目标语法、新事件字段与语义、`RATE_LIMITED`、策略是本地决定）、`README.md`；AI 编程规范整套（`AGENTS.md`、`docs/ai-coding/`、`scripts/check-secrets.sh`）同日提交。
- 群夹具用测试代码合成（`Tests/WeComAdapterTests/GroupFixture.swift`，几何取自 5.0.11 实录），不录真实客户群。

## 单测

- `swift test`：**182 个测试 / 52 个套件通过**（B3 为 155 / 43），含 `ForbiddenAPITests`。
- 新增套件：TargetRef、MessageKey、SendPolicy、RateLimiter、PolicyProvider、TargetResolver、Group conversation parsing、imctl policy、imctl identity；追加：Protocol types、ActionPolicy、CommandExecutor（速率）、ControlStore（身份桥）、WeComCommandHandler（`chatId:` 目标、类型规则、未命中桥、已激活会话读取过策略、历史带键）、WatchEngine（群事件字段）、Command parsing、probe commands。
- `bash scripts/check-secrets.sh`：仅 1 条既有历史命中（`docs/superpowers/plans/2026-09-11-s1-repo-scaffold.md` 里 2026-09-11 的 Desktop 路径，属历史证据，不改写）。

## 只读探针（真实客户端，脱敏）

| 步骤 | 结果 |
|---|---|
| `imctl env` | `accessibility_trusted: true`（终端进程），客户端 5.0.11 非前台，未锁屏 |
| `imctl probe conversations` | 最左表格当前是 **32 px 行的列表**（无预览、无时间、无标记，行 #0/#8 为 8 px 分隔行），`type=unknown`——即交接里提到的"非消息视图"；标题定位前先核视图这一提醒成立，B4 解析在该视图下不误判类型 |
| `imctl probe messages` | 活动会话 `«695c102c»`（非白名单，未选行未操作），7 行全部 `kind=system`：无 `AXTextArea`、静态文本 x 960–1370 居中于表格 410–1921、7 行文本同一散列（同一标题的通知卡片），时间标签 `8月28日 17:41` … `11:00` 被 `TimeLabel` 识别；`key=-`（系统行不赋键）；composer 0 字符。说明：居中判据把通知类会话整体判为系统行，这类会话不会产生观察事件，符合"不猜"的取向；真实群消息行的形态（发送者标签在气泡上方）仍待测试群校准 |
| `imctl policy list` | 文件缺席（`~/Library/Application Support/imctl/policy.json`），编译白名单 `文件传输助手`，有效标题只有它 |
| `state.json`（只读文件） | 旧稳定副本仍运行，`paused ["system"]`，`observer false`，`errors` 持续增长（辅助功能未勾选）；本批未重启、未更新稳定副本、未打开其 SQLite（新迁移 `v3-identities` 会在下一次由新版 `imctl status` / `imctl identity` / 新版 `imctld` 打开时应用；旧二进制对未知迁移安全：GRDB 7.11 `DatabaseMigrator.runMigrations` 只执行已注册且未应用的迁移，越界 `fatalError` 只比较已注册标识，所以旧 `imctld` 在被新版 CLI 迁到 v3 的库上照常启动） |

## 结论与未闭环

- **通过（单测 + 只读探针）**：协议类型、策略文件与 CLI、目标语法与身份桥表、事件字段、速率硬上限、群解析在合成夹具上的行为；真实客户端上的只读解析对非消息视图与通知类会话不误判。
- **待活体（阻塞于用户事项）**：(1) 系统设置 › 隐私与安全性 › 辅助功能勾选 `imctld`，然后 `scripts/install-daemon.sh` 更新稳定副本（新二进制含 `v3-identities` 迁移、`--policy` 与身份桥）；(2) 测试群名（把"未设置群名"改成唯一名并告知）→ `imctl policy allow --title <群名>`（或 `--type group` 只在确认列表标记 / 头部成员数可靠后）→ 在测试群上校准：发送者标签位置、系统通知居中判据、列表 `微信` / `外部` 标记、头部 "群名(N)"；(3) `imctl identity set --kind group --id <占位 chat_id> --title <群名>` 后经 `chatId:` 发送一条 `imctl-b4-…`，验证 `message.observed{origin:controller, sender:"", messageKey, conversationType:group, chatId}` 闭环与 `RATE_LIMITED`（3 s 内第二条）；(4) `controller.state{policy}` 热加载事件。
- **已知边界**：`internal` 不推断（只能靠标题规则）；`customerMarkers` / `groupMarkers` / "名字@公司" 规则来自客户端常识，未在本机取证；速率按原始目标串计数（`chatId:X` 与其标题算两个键，全局上限兜底）；`messageKey` 的同元组序号在更早的同文本消息被前插时会移位（头对齐，追加常见路径稳定）；`RateLimiter` 为内存态，重启清零。
- **未做**：B5（`WeComAPI`）、P1（代理）、J1（Java 消费方）；`command.cancel` 仍空操作；EMQX 凭据 / ACL、Developer ID、B2 计划文件 git 历史里的 broker 地址是否改写仍等用户决定。
