# B14：已建群二次添加成员（`group.addMembers`）与发送白名单完善（类型规则 / 条目编辑 / 全部放开）— 设计

日期 2026-09-23 05:0x CST。用户 2026-09-22 的两条要求：「功能没有加上再次添加客户的功能，只能拉完就没了，不能二次添加」「你设置了发送、群里的白名单，光设置没有修改功能，还有也没有全部放开能力。要不就不要了，要不就完善」。用户同时指示不介入、由助手决定细节并用子智能体逐任务执行；本文的设计决定标注「助手决定」，用户可在门报告后否决。

## 1. 客户端事实（2026-09-23 04:4x 只读采集，企微 5.0.11 / macOS 27.0，原始树只在临时目录，不入库）

- 群聊打开时，标题区右侧有两个 30×30 无标题无描述的 `AXButton`（窗口 1920 宽时 x=1839 与 x=1879，y=47，与标题 `AXTextField`（x=326，y=50）同一父级 `AXSplitGroup`，是它的兄弟节点）。**按最右一个（x=1879）直接弹出「添加群成员」表单**；x=1839 的那个未按（未知用途）。右侧「群成员」侧栏抬头行的两个 18×18 小按钮分别是「群邮件」（会打开「新邮件」窗口）和「…」菜单（搜索群成员 / 复制群成员账号 / 复制群成员邮箱地址）——都不是添加成员。
- 「添加群成员」是主窗口的 `AXSheet`（640×560，居中），结构与 B7 的发起群聊面板同族：`AXSplitGroup` → 左 `AXGroup`（搜索 `AXTextField` 274×34 + `AXScrollArea` › `AXOutline`：行 = `我的客户`（文件夹图标，可展开）、空行、公司名行、成员行……）/ `AXSplitter` / 右 `AXGroup`（`AXStaticText` 值 **`添加群成员`** + 已选 `AXTable` + `AXButton` **`确定`**（无选择时 disabled）+ `AXButton` **`取消`** + 两个无标题按钮（y=786，用途未知，不碰））。
- 成员行 `AXCell` 里：`AXImage`（头像）、`AXTextArea`（名字）、`AXImage` 描述 **`checkbox selected disabled`**（已在群里的成员，不可再选）、2×2 的 `AXButton`、创建者带 `AXImage` 描述 `icon virtual corp creator`。B7 的发起群聊面板没有这个 checkbox；其余（缩进分节、`@微信` 尾标、我的客户默认折叠）沿用 B7 事实待活体复核。
- 添加成功后消息区出现系统行文本「你邀请来自微信的 A、B 加入了外部群聊」（本群 2026-09-15 的历史行），标题区 `群成员·N` 计数变化；标题 `imctl测试群` 头部无人数后缀，人数在侧栏抬头。

## 2. 范围

做：`group.addMembers`（协议 + 执行器 + 适配器 + MCP 工具 + 控制台入口 + 探针 + 门报告）；`policy.json.allowAll` 与 `imctl policy all`；控制台策略页：类型开关、标题条目修改、chatId / externalUserId 条目增删、全部放开开关（二次确认）；协议与规则文档同步；版本 1.0.3。

不做：踢人、群公告、群管理设置；远程（`policy.set`）改类型 / id / allowAll（仍只经终端与控制台，即本机）；控制台 UI 自动化测试。

## 3. `group.addMembers`

- 参数 `{target, members: [String]（1…20）, dryRun?: false, idempotencyKey, ttlMs?, issuedAtMs?}`。`target` 同其它方法（标题 / `chatId:` / `externalUserId:`），必须过 `ActionPolicy`（`ActionKind.addGroupMembers`，`requiresTarget`，阶段 0 禁止，与 `submit` 同级不可逆）。
- 流程（`WeComActions.addGroupMembers`）：选中会话（同 `groupRename`）→ 读侧栏 / 表头得 `before`（`群成员·N`，读不到则 `before` 为空）→ 定位标题区按钮：`activeTitle` 的兄弟 `AXButton`，高 24…36、`minY` 在标题带 ±12 内，按 `minX` 从右到左依次按（最多 2 个），每按一次等 ≤ 3 s 出现带 `添加群成员` 文本的表单；出现别的表单就按其 `取消` 再试下一个；都不行 → `ACTION_UNAVAILABLE`（消息 `添加群成员`）→ 逐个成员：写搜索框 → 等过滤 → 唯一匹配；行带 `checkbox selected disabled` → 记 `skipped{name, reason: alreadyMember}`，不按回车；否则聚焦搜索框 + 一次 pid 级回车（**与发起群聊面板同一按键、同一批准**，AGENTS.md「选人面板搜索框上的那次」），已选表增长 → `added`；找不到 → `skipped{notFound}`（不中断，继续下一个）；多个同名 → `skipped{ambiguous}` → 若 `added` 为空：按 `取消`，结果 `succeeded`，`evidence: "nothing-to-add"` → `dryRun` 为真：按 `取消`，结果 `succeeded`，`evidence: "dry-run"`，`added` 是「本会选中的」→ 否则 checkpoint → 按 `确定` → 表单关闭 → 取证 ≤ 10 s：侧栏 `群成员·N` = before + added.count，或消息区新增系统行含「邀请」且含每个 added 名字；有证据 `succeeded`，表单关了但无证据 `unknown`（重启后同规则），`确定` 不可用 / 表单没关 `failed`。
- 结果 `{state, target, before?, after?, added, skipped, dryRun, evidence, latencyMs}`；事件 `group.membersAdded{commandId, target, added, before?, after?}`（只在真的按了确定且 added 非空时）；错误码新增 `NOT_A_GROUP`（目标不是群：表头无人数且侧栏无 `群成员·`）。同键回放同结果；重试用新键——已在群里的人会被 `alreadyMember` 跳过，所以重发天然幂等。
- 执行器：与 `message.send` 同一条流水线（幂等键、TTL、暂停、按会话限速池、checkpoint 在按 `确定` 前、崩溃后 `unknown`）。
- 控制台：「通讯录 / 建群」页加「添加到现有群」：目标群（会话列表里类型为群或已放行的标题）+ 成员（逗号分隔）+ 「先试跑」开关（dryRun）+ 按钮，结果面板显示 added / skipped。
- 探针：`imctl probe addmembers --target <群> [--search <名>] [--dump <路径>]`：只读——打开表单、可选输入一个名字、按脱敏规则打印行（名字长度 / 分节 / 来源 / 是否已在群），最后按 `取消`；不按回车、不按确定。
- 夹具：合成 `Tests/Fixtures/ax-trees/wecom-5.0.11-add-members-sheet.json`（中性名字：`李四` / `王五` / `甲公司`），按第 1 节形状；主窗口夹具 `GroupFixture` 加标题区两个按钮（`window(addMemberButtons: true)`）。

## 4. 白名单完善

- `SendPolicy.allowAll: Bool`（JSON `allowAll`，缺省 false，旧文件照常解码）。`ActionPolicy.allows` 第一行：`allowAll` 为真即放行任何目标（含类型 `unknown`）；阶段、启用、目标存在、限速、`gateReads` 都不变。这是用户 2026-09-22 要求的「全部放开」——**唯一**允许 `unknown` 类型放行的途径，只能本机开：`imctl policy all --enable|--disable`（开启时打印告警）与控制台开关（二次确认，开启后策略页顶部红字「全部放开：任何会话都可发送」）；`policy.get` 回 `allowAll`；`policy.set` 不接受它（远程永远不能开）；守护进程 `policy reloaded` 日志与 `controller.describe.policy` 摘要带 `allowAll=true`。
- 控制台策略页：类型三开关（群 / 客户 / 内部 → `imctl policy allow|deny --type`），标题条目行加「修改」（内联编辑：先 `deny` 旧、再 `allow` 新；内置 `文件传输助手` 不可改），新增 chatId / externalUserId 两个列表（增：文本框；删：收回），保留现有「收回」「允许发送」「会话下拉」「gateReads」「remoteEdits」「文件来源域名」。
- CLI：`imctl policy list` 打印 `allowAll`；`imctl policy all`。

## 5. 安全边界

- 合成按键不新增（回车沿用选人面板批准；`ForbiddenAPITests` 清单不变）。所有 AX 动作前先 `ActionPolicy.authorize`。
- 添加成员只对策略放行的群；开发期只对 `imctl测试群`；活体门用 `dryRun` 走到选人后取消，真正按 `确定` 的一次只加用户自己的测试号（用户点头后）。
- `allowAll` 默认关、只本机、日志可见；文档（AGENTS.md、SECURITY_CODING_SPEC、协议 §6.34 / §6.35、README）同步写明它是用户决定的例外。
- 名字、手机号、真实群名不进夹具 / 文档 / 提交信息；探针默认脱敏。

## 6. 版本与验收

- 1.0.3；`swift test` 全绿（含 `ProtocolDocTests`、`ForbiddenAPITests`）、`check-secrets` 无新增；活体门 `docs/gates/2026-09-23-b14-add-members-allowlist.md`：`policy all` 开关来回、类型开关、条目修改；`probe addmembers`；`group.addMembers dryRun` 到 `imctl测试群`（已在群成员 → alreadyMember；非成员 → 选中后取消）；真按确定一次待用户指定测试号；wiki 归档。
