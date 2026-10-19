# 批次 B14：已建群二次添加成员（`group.addMembers`）与发送白名单完善（`allowAll` / 类型开关 / 条目编辑）（2026-09-23 04:4x–08:2x CST）— 通过（09:22 真加用户测试号 1 人通过）

条件：macOS 27.0、企业微信 5.0.11、imctl 1.0.3（07:40 装 build 123 = 7d06061；08:17 装 abf6850；门报告提交后再装一次含末次修复的构建）。守护进程 launchd 常驻，`setup --check` 五项 ✔。传输：本机 socket（`imctl call`）。目标只有 `imctl测试群`（策略放行的测试群）与 `文件传输助手`（只用来验证 `NOT_A_GROUP`）；**本轮没有真正邀请任何人进群**（全部 `dryRun`，选中后按取消），没有发送消息。客户端 AX 仍慢（读一次 7–30 s，见 B13 门报告结论 3），但本轮各步都在超时内完成。凌晨侦察时（04:4x）误按了群成员侧栏的「群邮件」按钮，客户端开了一个「新邮件」窗口并弹出保存草稿确认框——那个确认框没有 AX 子元素，助手不用全局按键去关，**留给用户手动点「不保存」**；另一个「…」小菜单窗口也留着（无害）。

## 实现
- 规格 `docs/superpowers/specs/2026-09-23-b14-add-members-allowlist-design.md`，计划 `docs/superpowers/plans/2026-09-23-b14-add-members-allowlist.md`；子智能体逐任务（T1–T9）+ 逐任务审查 + 终审（opus）+ 三波修复；32389ff..HEAD。
- 客户端事实（04:4x 只读采集，原始树只在临时目录）：群聊标题区最右的无标题 30×30 `AXButton`（1920 宽时 x=1879）直接弹「添加群成员」`AXSheet`（搜索框 + 大纲 + 右侧 `添加群成员` 文本 + 已选表 + `确定`（未选时 disabled）/ `取消`）；已在群里的成员行带 `AXImage` 描述 `checkbox selected disabled`；侧栏抬头 `群成员·N`；侧栏抬头的两个小按钮是「群邮件」与「…」菜单，不是添加。
- `group.addMembers{target, members, dryRun?, idempotencyKey}`：`ActionKind.addGroupMembers`（要目标、阶段 0 禁止）→ 策略先于选会话 → 取 `群成员·N`（无则 `NOT_A_GROUP`，什么都不按）→ 关掉任何残留表单 → 按标题区按钮直到出现「添加群成员」表单（≤ 3 s，别的表单按取消再试下一个、且确认关掉后才按下一个）→ `pickMembers(skipDisabled)`（已在群 → `alreadyMember`，找不到 → `notFound`，重名 → `ambiguous`；回车沿用选人面板批准）→ 无可加 / dryRun：取消，`succeeded` → checkpoint → `确定` → 关闭等待 3 s（TO CALIBRATE）→ 取证 ≤ 10 s：`群成员·N` = before + added 或**新出现**的含「邀请」且含每个名字的行 → `succeeded` / 关了无证据 `unknown`（`确定` 抛错也是 `unknown`，`confirm-threw`）/ 没关 `failed`（`sheet-still-open`，`reason` 字段）。事件 `group.membersAdded` 只在 `succeeded` / `unknown` 且 `added` 非空且非 dryRun 时发。执行器：幂等键回放、TTL、暂停、按会话限速、checkpoint、崩溃后 `unknown`。MCP 工具 44。
- `imctl probe addmembers --target <群> [--search <名>] [--dump] [--settle]`：先过 `ActionPolicy(.addGroupMembers)`，再选会话、开表单、可选搜索、按脱敏格式打印行（`#i len= section= source= disabled=`）、`确定 enabled=`、必按取消；不按回车、不按确定。
- `policy.json.allowAll`（缺省 false）：`imctl policy all --enable|--disable`、`policy list` / `policy.get` 显示、守护进程 `policy reloaded … allowAll=true`；`ActionPolicy.allows` 第一行放行任何目标（含类型 `unknown`）——**类型规则永远不放行 `unknown`，`allowAll` 是用户明确开启、只本机、有日志的唯一例外**；`policy.set` 永远不能设它（有回归测试）；AGENTS.md / SECURITY_CODING_SPEC / README / 协议 §5 §6.34 §6.35 同步。
- 控制台策略页：「全部放开」开关（二次确认对话框 + 红字）、群 / 客户 / 内部三开关、标题条目「修改」（先 deny 再 allow，失败会报错）、chatId / externalUserId 列表增删；建群页「添加到现有群」（先试跑默认开）。成员输入按 `,` `，` `、` 拆分。
- 测试 439 → 496（`ForbiddenAPITests` 按键清单不变）；`check-secrets` 只有 11 条既有 warning。

## 单测
- `swift test`：496 tests / 97 suites 全绿（release 7d06061 时 488，两波修复后 496）；`swift build` 无警告。
- 守卫：`ForbiddenAPITests`（合成按键清单未变）、`ProtocolDocTests`（§6.44 / §7.9 / `NOT_A_GROUP` / 工具 44）、`policy.set` 不能设 `allowAll`（执行器 + MCP schema 两处）。

## 活体 / 只读探针
| 时间 | 步骤 | 结果 |
|---|---|---|
| 04:4x | 只读侦察（临时 AX 工具，原始树不入库） | 标题区两按钮、侧栏两小按钮、「添加群成员」表单形状、`checkbox selected disabled`、`群成员·3` 全部采到；误开「新邮件」窗口（见条件） |
| 07:40 | 装 1.0.3 build 123，`setup --check` | 五项 ✔，`imctl --version` = 1.0.3 |
| 07:41 | `imctl policy all --enable` → `policy.get` → 守护进程日志 → `--disable` | `allowAll: true`；日志 `policy reloaded: titles=2 types=- … allowAll=true`；关闭后 `false`；文件 0600 |
| 07:41 | `imctl policy allow --type group` / `policy list` / `deny --type group` | `types: group` → `types: -`；热加载 |
| 07:41 | `imctl probe addmembers --target imctl测试群 --search <已在群成员>` | `policy: allowed`，rows: 1，`#1 len=7 section=0c source=wechat disabled=true`，`确定 enabled=false`，`取消 pressed: closed=true`，3 s |
| 07:56 | `group.addMembers{imctl测试群, [<已在群成员>, <非成员联系人>], dryRun: true}`（`b14-live-dry-1`） | `succeeded`，`before: 3`，`added: [<非成员>]`（选中后取消），`skipped: [{<成员>, alreadyMember}]`，`evidence: dry-run`，粘到取消 1753 ms；事件只有 3 条 `command.state`（无 `group.membersAdded`）；没有表单残留 |
| 08:17 | 装 abf6850（终审修复：表单等标题、残留表单先关、关闭等待 3 s、`reason`、事件不发给 failed） | — |
| 08:18 | `probe addmembers` 复跑 | 同 07:41 |
| 08:18 | `group.addMembers dryRun`（`b14-live-dry-2`） | `succeeded`，1819 ms，`before: 3`，`reason: alreadyMember` 在 skipped 里；同键回放返回同一 `commandId` |
| 08:19 | `group.addMembers{文件传输助手, …, dryRun}` | `failed` `NOT_A_GROUP`（无人数、无侧栏），未按任何按钮 |
| 08:2x | 末次修复（外来表单没关掉就不按下一个按钮）装入后 | 见文末补记 |

## 结论与未闭环
1. 通过：`allowAll` 开关（含日志、`policy.set` 拒绝）、类型开关、探针、`group.addMembers` 的 dryRun 全链路（策略 → 侧栏人数 → 开表单 → 已在群跳过 → 选中非成员 → 取消）、`NOT_A_GROUP`、同键回放。
2. 待用户：**真按一次「确定」**（邀请一个用户指定的测试号进 `imctl测试群`，验证 `群成员·N` 增加 / 「邀请」新行取证、`group.membersAdded` 事件、关闭等待 3 s 是否够——代码里标了 TO CALIBRATE）；控制台策略页 / 添加到现有群 页面人工点检；「新邮件」窗口手动关掉（点「不保存」）；tag `v1.0.3` 是否打；第二台 Mac 装 1.0.3。
3. 机制成立、效果待验：视频 / 图片路径与 B13 相同未变；`memberCount` 依赖右侧「群成员」侧栏打开（侧栏收起的群会回 `NOT_A_GROUP`，待样本）；`groupRename` 仍是先选会话再查策略（与 `addGroupMembers` 修前一样，留作后续）；一个成员「搜索到但不是第一条结果」仍整批中止（安全方向）。
4. 客户端 AX 慢（B13 结论 3）未变，本轮操作都在超时内。

## 08:45 补记：末次修复 b2fb414 装入后 — 通过

- 装入后 `setup --check` 五项 ✔；`probe addmembers --target imctl测试群 --search <已在群成员>` 同前（policy allowed，1 行 disabled=true，确定 disabled，取消关闭）。
- 本报告提交即 build 126（`git rev-list --count HEAD`），随包文件同步为该数；本机 `~/Applications/imctl.app` 为 b2fb414 构建（与 build 126 只差文档提交）。
- 测试 496 / 97 全绿；`check-secrets` 11 条既有。

## 09:22 补记：真按「确定」一次 — 通过；阿里云 OSS 复核 — 正常；客户端 AX 已恢复

- 用户 09:20 指定测试号后：先 dryRun（`b14-live-kellen-dry-1`：`added: [<测试号>]`、`before: 3`、1887 ms）再真加（`b14-live-kellen-real-1`）：`succeeded`，`evidence: row #6 邀请`，`before: 3`，`after: 3`（取证时侧栏计数还没刷新，10 s 内先由新「邀请」行取证），粘到取证 3114 ms，checkpoint 已落盘；事件 39745 `group.membersAdded{target, added, before 3, after 3}`；之后侧栏 `群成员·4`，消息区新行「你邀请来自微信的<测试号>加入了外部群聊」；再跑 `probe addmembers --search <测试号>` → `disabled=true`（已在群）。3 s 关闭等待够用（表单在取证前已关）；侧栏计数滞后于「邀请」行，`after` 可能等于 `before`——消费方以事件 / 新行为准。
- 阿里云：`imctl oss status` 正常（region cn-hangzhou、view 1800 s、maxUpload 50 MB），`imctl oss test` 5/5 ok（约 1 s），`controller.describe.oss=enabled`；`message.media` 的签名地址 GET 200（75,543 B，`%PDF-` 头）、Range GET 206；HEAD 回 403 是预期（预签名只对 GET 签名），不是故障。
- 客户端 AX：09:14 起命令行直读消息表约 150 ms（守护进程停 / 开无差别），守护进程侧 `message.history` 364 ms、`conversation.list` 581 ms；与凌晨误开的「新邮件」窗口及其保存草稿确认框被关闭的时间吻合——判断是那个模态确认框拖慢了整个客户端的 AX 服务，不是守护进程；watcher degraded 记录同时停止。企微现在只剩主窗口。

## 10:3x 补记：通讯录轮次每 5 分钟切一次的问题 — 已修（decfcd0，build 128）

- 现象（用户 09:31 报告）：开着 imctl 时企微经常自己切到通讯录。日志：自 2026-09-22 10:xx UTC 起每 5 分钟 `requests: round (retry, badge 0)` → ⌘8 / ⌃Tab 到通讯录 › 新的客户 → `contact.request.list` 失败 `CLIENT_UNAVAILABLE: could not locate WeCom region contacts.outline` → 5 分钟后重试，无限循环（每小时 12 次），角标一直是 0。
- 根因（只读采集 09:3x）：通讯录左侧大纲的行标签现在是 `AXTextArea`（B7 录制时是静态文本，`texts(in:)` 已兼容），但右侧面板顶部还有一个同名 `AXStaticText`「新的客户」（x=330，在 `leftColumnWidth=400` 的左限内），BFS 先遍历到它，向上 4 层找不到 `AXRow`，于是报出误导性的 `contacts.outline`；`newCustomersTable` 的左限同样会漏掉 x=310 的卡片表。第二个缺陷：`RequestRoundTrigger` 失败后不管角标是否为 0 都每 `retryMs`（5 分钟）重试。
- 修复：`selectNewCustomers` 遍历所有同名文本，只取能向上找到 `AXRow` 且其父为可设 `AXSelectedRows` 大纲的那个，已选中则不再设置；卡片表按大纲中线定位；触发器：角标为 0 时永不重试也不做半小时巡检，失败后 5 → 10 → 20 → 30 → 30 分钟退避，连续失败到上限后等角标变化 / 重新开启；协议文档同步。测试 496 → 505。
- 活体：10:28 装入；`imctl policy requests --auto-accept all` 恢复用户原设置 → 一轮 `switchedOn`（可见切换一次）→ `reached steps=2 table=true` → `2 card(s), 0 new, 0 to accept`；之后 2 分钟内没有新轮次（角标 0）。09:32–10:28 期间自动接受曾临时关闭。
- 未闭环：我在装入后立刻手动调 `contact.request.list` 一次失败（`contacts.newCustomersRow`：视图刚出现、行标签尚未就绪），4 s 后守护进程自己的轮次成功——首次调用的就绪等待待观察；`RailBadges` 读角标的纵向带（B7 录制的 370–400）在现在的窄侧栏上可能对不上位置（角标可能一直读 0），需要一个真实的新客户申请样本才能校准——待用户；守护进程启动时仍会跑一轮（可见切换一次），是否也改成只在角标 > 0 时跑，待用户定。

## 11:1x 补记：轮次只在角标 > 0 时启动（7c2c60e，用户 10:40 决定）— 通过

- 用户：守护进程启动时的那一轮验证切换「很影响使用」。改为任何原因的轮次都要求当前角标 > 0：启动、开关打开、角标清零都不再导航；角标从 0 变正才 `badgeChanged`；巡检 / 重试仍要求角标 > 0；`settleMs` 删除（无外部引用）。测试 505 → 508，协议文档句子同步。
- 活体：装入后 `launchctl kickstart -k` 重启守护进程（角标 0）：75 s 内 `requests: round` 0 条、`contacts:` 0 条，客户端没有切换；策略照常热加载。
- 顺带记录：10:19–10:20 策略文件被控制台逐步改成 `titles=0, types=group+customer+internal, allowAll=true`（用户在新策略页操作），这是用户自己的配置动作，守护进程按新策略运行；若要缩回，`imctl policy all --disable`、`policy allow --title <群>`。
