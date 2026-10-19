# 通讯录能力设计：新客户请求（自动接受）、好友列表、接受后自动拉群（v0.2 追加，草案待批准）

日期：2026-09-15。来源：用户 09:33 / 10:10 / 10:15 三条要求与截图。本页只定"做什么、怎么做、边界"，代码级任务在批准后按 writing-plans 另写。

## 1. 用户要求（原话要点）

- 企微有"新的客户"（别人加我）。发现有人添加要能**自动接受**；自动接受可开可关；也可以**让软件（Java 侧）控制接受哪些微信好友**。
- 给 **MQTT 命令**：通讯录功能，获取新客户数据——**有「打招呼」按钮的其实已经加了；有「接受」按钮的表示可以接受好友**。
- 加一个功能：**接受后是否自动拉一个群，并把那些好友加进群**（可开可关）。
- 需要**获取好友列表**功能。
- 客户端「+」→「我的客户」里有对应客户好友信息（用户指出的读取入口）。
- 设置页要显示现有 MQTT 配置与密钥位（已做：`7e187a9`，留空保留原值）。

## 2. 活体事实（2026-09-15 探针，企业微信 5.0.11）

| 事实 | 依据 |
|---|---|
| 「通讯录 › 新的客户」是一张 `AXTable`，每张卡片一行（122 px）：来源标签（微信）、昵称、头像、打招呼语、一个按钮 **`接受`**（待接受）或 **`打招呼`**（已添加）；按钮是真 AppKit 按钮，`enabled=true`，可 `AXPress`；页头有 `添加` 按钮 | `Tests/Fixtures`（待入库的脱敏夹具 `wecom-5.0.11-new-customers.json`） |
| 「通讯录」的待处理数在**消息视图里就能读到**：导航栏切片按钮的标题（如 `"2"`，y≈385） | 两次 dump 一致 |
| 「+」（消息视图搜索框右侧，(361,15)）打开 **`AXSheet`「发起群聊」**：左侧搜索框（`AXValue` 可写）、`AXOutline`（`AXSelectedRows` 可写）分组「我的客户 › 微信联系人」（每行：昵称、`@微信` 标签、头像）与「示例公司」（内部成员）；右侧已选列表；`取消` / `完成`（未选外部成员时 `完成` 禁用） | 10:1x dump；`取消` 已实测可按 |
| **回到消息视图**：`open "wxwork://conversationlist"` 立即生效（OS 级 URL 打开，不是合成输入） | 实测 |
| **进入通讯录没有 AX / 深链路径**：导航栏按钮是 2×4 px 禁用切片，置前后按也无效；`AXEnhancedUserInterface` 无效；`wxwork://action?type=1/2/3`、`jump?target=new_customer|newcustomer|contact|contacts|addressbook|customer`、`wxwork://contacts|newcustomer` 全部无效；二进制里只有内部方法 `p_jumpNewCustomer:` | 实测 |
| `conversationlist` 之外可用的深链：`jump?target=conv|openchat|user_profile|input_conv_name&conv_id=…` 等 | `strings` |
| **官方快捷键**（用户 11:12 给的帮助页 `open.work.weixin.qq.com/help2/pc/20575`，Mac 列）：切换左侧 Tab `⌘1`–`⌘8`；下一个左侧 Tab `⌃Tab`、上一个 `⇧⌃Tab`；创建群聊 `⌘N`；激活搜索框 `⌘F`；下一个 / 上一个聊天 `↓` / `↑`；下一个未读 `⌥⌘↓`；标为已读 / 未读 `⌘U`。本机导航栏 12 项（消息、邮件、文档、日程、待办、会议、智能文档、智能总结、工作台、通讯录、微盘、高级功能），通讯录第 10 项没有数字键；顺序可被用户自定义 | 帮助页图片；`⌘2`–`⌘8` 实测各切到对应 Tab（邮件 / 文档 / 日程 / 待办 / 会议 / 智能文档 / 智能总结），`⌘9` / `⌘0` 无效 |

结论：**好友列表与拉群可以全走 AX（「+」面板）**；**读取 / 接受「新的客户」必须先进入通讯录**，办法是对企微进程投递官方快捷键（`⌘8` 后 `⌃Tab` 逐步，或从消息 `⌃Tab` 逐步）并用「新的客户」文字校验到站——pid 级按键，用户 10:34 已批准（第二个合成输入例外，键为 `⌘数字` 与 `⌃Tab`）。

## 3. 协议新增（`im-control/0.1` 内追加，语言中立，文档同一提交更新）

| 方法 | 参数 | 结果 | 副作用 / 策略 |
|---|---|---|---|
| `contact.list` | `{via?: "ui"\|"api", limit?}` | `[{name, source:"wechat"\|"wecom", tag?, externalUserId?}]` | `ui`：打开「+」面板读「我的客户 › 微信联系人」（滚动读全）后 `取消`；瞬时面板，不改会话。`api`：`externalcontact/list` + `get`（经代理，未 enroll 回 `UNSUPPORTED`），带 `external_userid` 并回写身份桥 |
| `contact.request.list` | 无 | `[{name, greeting, source, status:"pending"\|"added"}]` | 进入通讯录（⌘2）→ 读卡片 → `conversationlist` 回消息视图；`pending` = 有 `接受` 按钮，`added` = 有 `打招呼` 按钮 |
| `contact.request.accept` | `{name, idempotencyKey}` | `{name, accepted:true, status:"added"}` | 进入通讯录 → 找到唯一同名待接受卡片（0 个 `TARGET_NOT_FOUND`，多个 `TARGET_AMBIGUOUS`）→ `AXPress 接受` → 复核按钮变 `打招呼` → 回消息视图；策略动作 `acceptRequest` |
| `group.create` | `{members:[name…], name?, idempotencyKey}` | `{title, memberCount, renamed:"true"\|"false"}` | 「+」→ 逐个搜索并选中成员（复核右侧已选列表）→ `完成` → 复核新活动会话头部 `群名(N)` → 有 `name` 则改群名（群聊页群名编辑；不可达时 `renamed:"false"`）；策略动作 `createGroup` |

事件（`…/evt`）：`contact.request.observed{name, greeting, source, status}`（每张新卡片一次，按 `name+greeting` 去重）、`contact.request.accepted{name, by:"policy"\|"remote", commandId?}`、`group.created{title, members}`。`controller.state` 增 `newCustomersBadge`（角标数）。

## 4. 自动化（守护进程）

1. **检测**：每次轮询顺带读通讯录角标（消息视图内、零开销）；`newCustomersBadge` 变大 → 触发一轮处理（最多每 60 s 一轮）。
2. **处理一轮**：⌘2 → 读卡片 → 发 `contact.request.observed` → 按策略接受 → `conversationlist` 回消息视图 → 若开启自动拉群，对本轮接受的人 `group.create`（一人一群或本轮一群，由策略定）。
3. **策略文件 `policy.json`** 追加：
   ```json
   "contactRequests": {
     "autoAccept": "off" | "all" | "rules" | "remote",
     "allowNames": ["…"], "greetingContains": ["…"],
     "autoGroup": "off" | "perPerson",
     "groupDefaultMembers": ["…"],
     "groupNameSuffix": "群聊",
     "maxAcceptsPerHour": 20
   }
   ```
   `off`：只按角标上报 `newCustomersBadge`，不进通讯录；`all`：全接受；`rules`：昵称在名单或打招呼语含关键词才接受；`remote`：进通讯录读卡片、只发事件，由 Java 调 `contact.request.accept`（不超时）。热加载与现有策略一致，控制台「策略」页给开关与名单。
4. **接受后拉群**（用户 2026-09-15 10:45 定）：默认**一人一群**；建群时把 `groupDefaultMembers`（内部同事等）一并勾选；**群名 = 客户名 + `groupNameSuffix`**（例：`测试联系人A群聊`）。改名走群聊页的群名编辑（AX 路径待活体取证；若客户端不暴露则先保留自动名并记事件）。失败不重试（记事件），不影响接受结果。

## 5. 控制台

- 新页「通讯录」：待接受列表（读取 / 接受按钮）、好友列表（读取）、拉群（勾选成员 → 创建）。
- 「策略」页：`autoAccept` / `autoGroup` 开关与名单编辑（写 `policy.json`）。
- 「事件」页自然显示新事件。

## 6. 安全边界

- 接受好友与建群都影响真实客户：**默认全关**；开启是用户在本机 `policy.json` 的决定，Java 远程只能在 `remote` 模式下逐条接受，不能改开关。
- 每次接受 / 建群都是命令记录 + 事件，可审计；`maxAcceptsPerHour` 硬上限。
- 合成输入：除已批准的 pid 级回车外，新增 **pid 级 `⌘1`–`⌘8` 与 `⌃Tab`（切换左侧 Tab 到通讯录）**——用户 2026-09-15 10:34 批准；只投递给企微进程，只在 `KeystrokeInjector`，`ForbiddenAPITests` 仍限制在该文件；每次按键后用 AX 校验到站，最多 12 步；回消息视图用深链 `wxwork://conversationlist`，不用按键。
- 读取面板与卡片只在命令执行的瞬间打开，之后恢复消息视图；真实姓名只进本机日志与事件流，不进仓库 / wiki。

## 7. 实施分解（批准后各写计划）

| 批 | 内容 | 前置 |
|---|---|---|
| B7a | `contact.list(ui)`、`group.create`、「+」面板夹具与解析、控制台通讯录页（好友 / 拉群） | 无（纯 AX） |
| B7b | `contact.request.list` / `accept`、新的客户夹具、⌘2 注入、角标读取 | 用户批准 ⌘2 |
| B7c | 自动化循环、`policy.json.contactRequests`、事件、控制台开关、`maxAcceptsPerHour` | B7a + B7b |
| 后续 | `contact.list(api)` 经代理、群改名（`input_conv_name` 需 conv_id）、用户自建应用参数 | 代理部署 |

## 8. 需要用户决定

1. **是否允许第二个合成输入例外：对企微进程投递 ⌘2 进入通讯录**（不允许则 B7b/B7c 只能做"检测 + 提醒"，接受由人点）。
2. 「测试联系人A」（打招呼语"我是 测试联系人A"）是否是你本人的微信测试号——是则作为接受动作的活体对象。
3. ~~自动拉群的默认粒度~~ 已定（10:45）：一人一群，可配默认进群成员，群名 = 客户名 + "群聊"。
4. ~~`remote` 超时~~ 已定：不超时，只发事件。
5. （新）`contact.request.list` / `accept` 的进入通讯录路径：⌘2 已获批准（10:34），但实测投递 ⌘2 客户端不切换视图（置前与否都一样），需确认企微 Mac 的真实快捷键或另找入口。

## 7. 活体修正（2026-09-15 下午，5.0.11）

设计阶段的假设与真实客户端的差异，实现以此为准（门报告 `docs/gates/2026-09-15-b7-contacts-requests-groups.md`）：

- **接受有弹窗**：「接受」后客户端弹出备注弹窗（设置备注名 / 备注企业名称 / 设置标签 / 完成），请求只经其「完成」才真正接受；备注与标签保持默认。卡片变「打招呼」是服务端往返，复核窗口放宽到 10 s（`acceptTimeout`）。
- **⌘8 首次会丢**：`AXFrontmost` 写入后要等激活落地再投递快捷键；聚焦在文本框时 ⌃Tab 被吃掉，先把焦点移到表格 / 大纲（AX 属性写，不是事件）。
- **前台会在步与步之间被拿走**（16:0x 定位，门报告 `docs/gates/2026-09-15-b7-contacts-navigation-refront.md`）：客户端只在自己是活动应用时响应投递到 pid 的快捷键；用户在导航期间点回自己的 IDE / 终端后，其余 ⌃Tab 全部被丢弃——「守护进程重启后首次调用失败」是巧合（两次都发生在用户刚敲完命令的几秒内），重启本身不触发。实现：每次投递前检查 NSWorkspace 前台 pid 与客户端自己的 `AXFrontmost`，任一说失去前台就先 `bringToFront`（等两侧都落地）再投递；逐步 trace（角色 / 计数 / 视图指纹 / 时延，不含内容）进守护进程日志与失败信息。
- **「+」不响应 AXPress**：发起群聊改用客户端自己的 ⌘N；面板里「我的客户」与其下「微信联系人」组默认折叠（`AXDisclosing` 可写）；结果行不接受 AX 选择 / 按压 / 聚焦，唯一可达的选中方式是把名字写进搜索框、确认唯一且排第一后对企微 pid 投递一次回车。⌘N 与这次回车超出用户 2026-09-15 10:34 批准的 ⌘1–⌘8 / ⌃Tab 范围，用户 16:3x 批准。与通讯录导航一样，每次投递前先确认客户端仍是活动应用（`lostFront` → `bringToFront`）。
- **接受后原地刷新**（16:39 活体，测试号 2）：「完成」后客户端在 3 s 内重建整张卡片表，按下之前读到的表元素随即失效（`invalid or stale AX element`），而请求已被接受、卡片变「打招呼」。`contactRequestAccept` 的校验每次重新定位表，表暂时缺失 / 失效 / 为空都算「尚未落定」，非空列表里卡片消失才算已接受。
- **建群是异步的**（16:43 活体，成员 = 测试号 2 + 测试联系人A）：「完成」后约 4 s 客户端才创建外部群并切到它，群标题由客户端生成（成员名以顿号相连，含本人），`requestedName` 不生效（改名未实现）；「完成」后立刻读头部仍是原会话。`group.create` 等头部出现成员数（≤ 10 s，`groupOpenTimeout`），结果与 `group.created` 事件带 `opened`。
- **自动化幂等键**：执行器对同一幂等键一律回放既有记录（失败也回放），自动化的 `auto-accept-<sha16>` / `auto-group-<sha16>` 在上一次失败 / 过期 / 取消后换新键 `…-r<ms>` 重试；成功、`unknown`、进行中仍回放。
- **单人不建群**：只勾 1 个成员按「完成」，客户端打开的是单聊（活体：标题为对方名字、无成员数）。`group.create` 少于 2 人直接 `LOCAL_GUARD`；一人一群要靠 `groupDefaultMembers`（为空时守护进程跳过建群并记日志）。
- **角标不是待处理数，也不可靠**：通讯录角标是客户端「新的客户」未读计数——两张卡都接受后仍为 2；用户 16:0x 指出并活体证实：人工点开通讯录角标就清零而卡片仍是「接受」（`newCustomersBadge` 读到 0 时 `contact.request.list` 仍有 `pending`），守护进程自己读一次后角标又回到 1。状态与事件字段名 `newCustomersBadge`；待处理以 `contact.request.list` 的 `status` 为准。自动化触发改为 `RequestRoundTrigger`（纯逻辑、有单测）：角标**任何变化**（清零后等 30 s 再进，人多半还在那页）、策略从 `off` 切到非 `off`、守护进程启动且策略非 `off` 各触发一轮，角标 > 0 期间每 30 分钟扫一轮，失败一轮 5 分钟后重试；两轮至少间隔 60 s，`off` 不进通讯录。

