# 门报告：B11 串行确认、群发、一次性授权与检查、应用图标与安装包、换机换屏与智能体手册、接受 / 建群复验（2026-09-16 11:0x–11:5x CST）— 通过（图片授权待用户点选）

用户 11:02 七项：① 并发（MQTT / Codex / Claude 同时来）要排队一个个处理；② 换 Mac / 换屏兼容性写进项目记忆与 LLM-Wiki；③ Codex / Claude 的用法也写进项目记忆与 wiki；④ 生成应用图标、打 Mac 安装包给别的 Mac 用；⑤ 群发；⑥ 权限在初始化时一次性授权、不要一次次弹窗，并加检查授权；⑦ 删了企微上的测试客户可重新接受，企微挪到了另一块屏。另：用户往文件传输助手发了一张图，MQTT 恢复。

## 条件

- 企业微信 5.0.11，**窗口在第二块屏**（`windowFrame (1920, 0, 1920×1080)`，消息表 `(2330, -1046, 1511×1942)`）；守护进程 = 包内 release 包（工作树版本 build 63 做活体，提交后 build 64 重装）；控制台每次装包后 kill 旧进程再 `open -a`。
- 发送：群发 1 轮 = 文件传输助手 1 条 + 测试群 1 条（用户此前授权的测试群，成员全是用户自己的账号）+ 对本人微信测试号 1 次拒绝性探针（`TARGET_NOT_ALLOWED`，无副作用）；接受 1 次（用户的测试号 2）、建群 1 次（测试号 2 + 测试联系人A）、改群名 2 次（旧测试群 → `imctl测试群`，新群 → 模板名）；策略：旧群标题收回、新群标题放行、自动化开了一轮后关回 `off/off`。
- 图片：用户 11:01 发到文件传输助手的图片，行已识别；取回被「访问其他 App 的数据」提示挡住（重装后再弹），等用户点选或加完全磁盘访问权限。

## 答复与根因

| 用户项 | 结论 |
|---|---|
| ① 并发 | 守护进程本来就只有一条串行队列（`CommandExecutor.queue.sync`），MQTT / 套接字 / MCP 的命令按到达顺序一个个执行，`command.state{accepted}.queuedMs` 是排队时长。活体：8 个套接字调用 + 2 个 MQTT 调用同时发出，事件日志里 11 条命令 **0 次交叠**，最长等待 8.5 s，`queuedMs` 611 / 776 / 1236 ms。本轮补上唯一的例外：`message.media` 的界面读取（相邻时间标签）也进同一队列（`CommandExecutor.serialized`）。群发在目标之间让路（见 ⑤） |
| ⑦ 换屏 | 企微在第二块屏上：会话读取、通讯录导航（⌘8 / ⌃Tab 两步）、`conversation.read`、图片行识别、接受、建群全部正常，**未改一处几何代码**（B9 的相对化生效） |
| 图片行 | 用户新发的图片是一个 388 px 的行，唯一子元素是时间标签「11:01」——之前被当成时间分隔行。规则改为：无文本、高 ≥ 100 px 的行一律 media（自带时间标签） |
| ⑦ 接受 / 建群 | 自动化（`rules`，名单里有测试号 2）11:26 接受成功；随后的自动建群失败：`group picker sheet did not open`——客户端主窗口上挂着一个「添加失败」模态（取消 / 确定），⌘N 被它挡住；模态消失后手动 `group.create` 第一次 `no conversation for target`（面板刚开时搜索结果陈旧），第二次成功（约 3 s 开群）。修正：面板搜索一次重试。新群按模板改名成功，放行、旧群收回 |
| `policy.json` | 11:24 发现 `allowNames` 空、`maxAcceptsPerHour = 100`（不是 09:5x 的名单 + 20），是控制台策略页保存的结果（用户过目时）；本轮只把测试号 2 加回名单，上限保留 100 |

## 实现

- **群发** `message.broadcast{targets(1–50), text, idempotencyKey, intervalMs?=3500, stopOnFailure?}`（协议 §6.40）：整轮一条记录，每个目标一条独立 `message.send` 子命令（键 `<key>#<序号>`，各自经白名单 / 限速 / 事件），目标之间暂停；限速不放行时等待（≤ 70 s）而不是消耗尝试；子命令一条条进串行队列，其它客户端的命令可插在中间；结果 `{total, succeeded, failed, items[]}`，有失败即 `failed` + 第一个失败码；同键重放；中途重启记 `unknown`。控制台发送页勾选目标 + 间隔 + 「群发」。
- **一次性授权与检查**：`controller.permissions{prompt?, probe?}`（§6.41：辅助功能 / 企微数据 / 完全磁盘访问权限 / 客户端 / launchd，守护进程自己的视角）；`imctl setup`（装或重启 LaunchAgent → 一次触发辅助功能与「访问其他 App 的数据」对话框 → 打开完全磁盘访问权限设置页 → 轮询结果）、`imctl setup --check`；控制台状态页「检查授权 / 一次性初始化授权 / 打开完全磁盘访问权限设置」；`docs/ops/permissions.md`；安装包 readme / conclusion 改为三步。
- **图标与安装包**：`packaging/console/icon/draw-icon.swift`（CoreGraphics 画：蓝青渐变圆角方 + 白色气泡 + `>_`）、`make-icns.sh` 生成 `AppIcon.icns`，`Info.plist` `CFBundleIconFile`，`build-app.sh` 复制进 Resources；`out/imctl-0.1.0.pkg`（20 MB，build 64，未签名开发包）已复制到桌面；`docs/ops/installer.md` 增「给别的 Mac 安装」五步。
- **手册（项目记忆）**：`docs/ops/portability.md`（换 Mac / 换屏：相对几何原则、先看什么、何时重录夹具、未验证项）、`docs/ops/permissions.md`、`docs/protocol/agents-mcp.md` + `SKILL.md`（并发说明、群发）；`AGENTS.md` 阅读顺序加第 11 条指向它们。
- 其它：`MessageRowParser` 自带时间标签的图片行；`GroupPicker` 搜索重试 + 内容无关的结果形状 trace；`CommandExecutor.serialized`。`RPCMethod` 39、`tools/list` 41。

## 单测

`swift test`：**315 个用例、82 个套件全部通过**（313 → +2 … 合计：群发子命令 / 每目标结果 / 重放 / 参数校验 / 等限速、`controller.permissions` 路由、自带时间标签的图片行、`imctl setup` 注册）。插入 `RPCMethod` case 后 `swift package clean`。

## 活体（build 63 / 64）

| 步骤 | 结果 |
|---|---|
| 并发 | 见上表：11 条命令 0 交叠 |
| `message.history` 文件传输助手 | 第 20 行 `media`、`timeLabel 11:01`、`media: unmatched`（用户 11:01 发的图） |
| `message.media` 该行 | 重装后系统再次弹「访问其他 App 的数据」→ 8 s 内返回可重试的 `MEDIA_NOT_FOUND`（套接字不被拖住）；`imctl setup` 已把对话框和完全磁盘访问权限设置页拉到前台，等用户 |
| `message.broadcast`（文件传输助手、测试群、测试联系人A；3 s 间隔） | 12.2 s；助手 `row #21`、测试群 `row #4` 成功，测试联系人A `TARGET_NOT_ALLOWED`；整轮 `failed`「1 of 3 target(s) failed」 |
| 自动化 `rules` 一轮 | 11:26:20 `contact.request.accept` 成功（通讯录在第二屏两步到达）；`group.create` 失败 = 客户端「添加失败」模态挡住 ⌘N |
| 手动 `group.create` ×2 | 第一次 `no conversation for target`（面板搜索陈旧），第二次成功（`opened`，3049 ms）；`group.rename` → 模板名成功（白名单先放行） |
| `imctl setup --check` | 辅助功能 trusted、企微数据 unknown / pending、完全磁盘访问权限 no、客户端 true、launchd true |
| 图标 | `Info.plist CFBundleIconFile = AppIcon`，`Resources/AppIcon.icns` 842 KB |

## 补记（11:37 用户追加：按手机号添加客户）

用户截图：通讯录 › 新的客户 › 右上「添加」→「添加客户」面板，输入手机号后列出匹配（微信 / 企业微信各一条，各带「添加」）。只读探针 `imctl probe addcustomer --phone … --frontmost`（新增，按不了「添加」）：

| 步骤 | 结果 |
|---|---|
| 页面右上「添加」`AXPress` | 客户端**不在前台**时无反应；置前后打开一个**第二个 AXWindow**（全屏大小的透明层，`[0,30 1920×1200]`），内含 `AXTextField`（352×42）、1 个关闭按钮、2 个静态文本 |
| 搜索框 `AXValue` = 手机号 + `AXFocused` + `AXConfirm`（字段动作有 `AXShowMenu`、`AXConfirm`） | 值落进去了（长度 11），等 5 s **没有任何结果行**进入 AX 树（面板仍只有 4 个元素） |
| 关闭 | `AXCloseButton` 有效，随后回 消息 |

结论：面板能开、能写值，但客户端只在**按键输入**时才搜索（与选人面板一样：那里也是写值后要一次搜索框回车才生效）。下一步需要用户批准：对这个搜索框投递一次 pid 级回车（`KeystrokeInjector` 已有的机制，新的使用点），批准后再看结果行是否进 AX 树、「添加」按钮能否 `AXPress`、之后是否还有验证消息 / 备注弹窗。手机号属个人数据：只作策略白名单（计划 `policy.json.contactAdd.allowedPhones`）、不入日志 / 事件 / 仓库。

### B12（12:09 用户批准搜索框回车 → 12:3x 落地）

- **回车后**：结果表进 AX 树（`AXTable`，每行 26 px 来源图标 `AXDescription` "icon outer user card search" = 微信 / "appicon 24x24" = 企业微信，42 px 头像，名字（企业微信用户多一行「添加后可查看完整信息」），「添加」按钮）。
- **`contact.add{phone, source?=wechat|wecom|any, greeting?, dryRun?, idempotencyKey}`**（协议 §6.42）：`withContactsView` → 页面「添加」（客户端置前后 `AXPress`）→ 面板 = 第二个 AXWindow → 搜索框 `AXFocused` + `AXValue` → `withFront` 一次 pid 级回车 → 等结果（≤ 6 s）→ 按 `source` 选行 `AXPress`「添加」→ **发送添加邀请** 步（用户 12:29 截图：默认打招呼语文本框 + 「发送添加邀请」按钮；判定 = 标题含 发送 / 邀请 或 确定 / 完成）：写入 `greeting`（有的话）、按下、等按钮消失 → 关面板 → 回 消息。上一次中断留下的邀请对话框会在下一次调用开头直接补完（`resumed`）。
- **门**：`policy.json.contactAdd.allowedPhones`（`imctl policy phones --allow / --deny / --max-per-hour`、`policy.set{allowPhones, denyPhones}`、控制台通讯录页「放行此号码 / 收回」），不在名单 → `TARGET_NOT_ALLOWED`（错误里号码掩码 `137******28`）；每小时成功上限 `maxAddsPerHour`（默认 20，dry run 不计）；经暂停检查。号码只以掩码进结果 / 日志 / 错误；脱敏规则改为 ≥ 7 位连续数字一律哈希（之前时间标签的数字规则会放过手机号）。
- **活体**（build 66，用户本人号 + 12:32 新增的两个测试号，号码只进本机 policy.json）：未放行 → `TARGET_NOT_ALLOWED`；放行后 dry run → `matched`，2 个匹配（wechat / wecom）；第一次真加（微信匹配）按下「添加」后邀请对话框出现在我的 3 s 等待之外、按钮标题是「发送添加邀请」而不是「发送」→ 当时判成 `pressed`、对话框留在屏幕上（用户看到「有一个发送邀请」）；修正后对新测试号：`matched` 1 个（微信）→ 真加 → `greeting: set`、`confirmed: 发送添加邀请`、`inviteDialog: closed`、`status: requested`，面板关闭、回到消息。中途一次失败「contacts view did not appear（texts=1）」是用户当时在客户端上操作（新建了「测试」群、窗口在另一 Space），等窗口回来后重试即成功。
- 夹具 `wecom-5.0.11-add-customer.json`（脱敏；菜单栏整段去掉，因为「最近使用的项目」菜单项标题会带真实姓名）。单测 321 / 83。

## 未闭环

- 13:58 用户加了完全磁盘访问权限：`imctl setup --check` 五项全 ✔（企微数据 granted），`message.media` 取回 11:01 那张图（`window` 路径，62 KB JPEG 缩到 276×600，内容是一张手机截图），`message.history` 该行 `assigned`；`observed` 路径仍待守护进程运行中的新图片。
- 给别的 Mac：包未签名（没有 Developer ID），双击会被 Gatekeeper 挡，用 `sudo installer -pkg … -target /`；目标机上跑 `imctl setup`。
- 14:10 用户跑 `imctl mcp install`：`claude mcp add` 子进程挂了 10 分钟——`Process` 先 `waitUntilExit` 再读管道，claude CLI 的大量 `[mcp-sdk]` 警告把管道写满（且 stdin 继承终端）；修正为先读完管道再等退出、stdin 接 null（`45ff888` 后的 build 69）。重跑：Claude Code 用户级 `imctl` 已注册（`claude mcp get imctl` → Connected），Codex `config.toml` 追加 `[mcp_servers.imctl]`（0600 保留），技能装到两处。
- `contact.add`：第一次真加留在屏幕上的「发送添加邀请」是否被用户手动发出未知；企业微信用户（`wecom`）匹配的添加流程未活体（只验证了微信匹配）。
- 自动建群在客户端弹模态时会失败并在下一轮换键重试（5 min）；模态本身来自客户端（本例「添加失败」出现在自动化之前，来源未知）。
