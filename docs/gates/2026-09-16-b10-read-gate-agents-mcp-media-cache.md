# 门报告：B10 读会话默认不经白名单、白名单可见可配、改群名入口、Claude Code / Codex 接入、图片缓存路线（2026-09-16 09:2x–10:5x CST）— 通过（图片：一张真实图片经 `message.media` 取回）

规格 `docs/superpowers/specs/2026-09-16-b10-read-gate-agents-mcp-media-cache-design.md`。用户 09:25 对 B9 答复四条（已过目新控件；图片按缓存文件路线；「打开选中会话」的白名单没看到配置、默认不要限制；插件要能给 Codex / Claude Code 自动控制的能力），09:28 补充「没看到改群名的地方」（截图：活动会话是测试群，右栏无改群名控件）。

## 条件

- 企业微信 5.0.11；守护进程 = `~/Applications/imctl.app` 内 release 包 build 59（工作树版本，提交后重建重装）；控制台每次装包后 kill 旧进程再 `open -a`。
- 发送：**0 条**。唯一一次 `message.send` 是对非白名单目标（本人微信测试号）的**拒绝性探针**（`TARGET_NOT_ALLOWED`，选会话之前就被拒，无副作用）。读会话对本人测试号一次（只读），随后回到文件传输助手。
- `controller.mediaCache` 让守护进程第一次触碰企微容器，系统弹出「“imctl.app”想访问其他App的数据。」——等用户点「允许」；清单未回来之前不做图片第二部分。
- Claude Code / Codex 的配置**未写入**（只跑 `--dry-run`）：写入是用户一条命令的事。

## 根因

| 现象 | 根因 |
|---|---|
| 「打开选中会话」只有第一行有效、白名单没处配 | `conversation.read` 经 `ActionPolicy.authorize(.selectConversation)`，目标必须在编译白名单或 `policy.json`；控制台策略页只有一个手输标题的「放宽 / 收回」块，没有把它和「打开会话」联系起来 |
| 改群名控件不见（截图） | `activeIsGroup` 按列表里 `selected = true` 的行判断，而列表是导航前读的（粗体行还是 测试联系人A），活动会话已换到测试群 |
| 智能体没法用 | `imctld run --stdio` 是整个守护进程，不能和 LaunchAgent 里的守护进程并存；没有桥 |
| 图片 | B9：AX 树里没有；企微是沙盒应用，数据在受保护的容器里 |

## 实现

- **读会话默认不经白名单**：`ActionKind.isReadOnly`（`selectConversation`、`scrollHistory`）在 `SendPolicy.gateReads = false`（默认）时跳过目标白名单；`message.send` 在选会话前已 `authorize(.submit)`，发送门不变。`imctl policy reads --gate | --open`，`policy list` 显示 `reads: open|gated`；`policy.set{gateReads?}`（仍受 `remoteEdits`）；`policy.get` 带 `gateReads`。协议 §5 / §6.4 / §6.34 / §6.35 / §12。
- **策略页「发送白名单」块**：生效标题列表（内置项标「内置」，其余可「收回」）、从会话列表下拉勾选「允许发送」、手动输入保留、`gateReads` 开关、`remoteEdits` 开关，说明白名单管发送 / 改群名。数据来自 `policy.get` + `controller.describe.allowlist`。
- **改群名入口**：`activeIsGroup` 按活动标题匹配行（回退选中行）；改群名行**始终显示**，不是群时禁用并写明原因。
- **Claude Code / Codex**：`imctl mcp serve`（stdio MCP → 守护进程套接字桥 `MCPProxy`：`initialize` / `tools/list` / `tools/call` / 直接方法，工具清单与守护进程共用；守护进程不在 → `DAEMON_UNREACHABLE`）、`imctl mcp config`（打印 `claude mcp add …` 与 Codex `config.toml` 块，路径按当前二进制解析）、`imctl mcp install --claude-code --codex --skills [--dry-run]`（Codex 文件保留原 mode）；技能 `docs/agents/skills/imctl/SKILL.md` 随包（`Resources/agents/skills/imctl/`）；文档 `docs/protocol/agents-mcp.md` 随包进对接文档页。
- **图片第一步**：`controller.mediaCache{limit?, refresh?}`（`WeComMediaCacheScanner`：容器 + 两个 group container 只读清点，扩展名 + 文件头识别，深度 / 节点 / 文件头读取上限，跳过 WebKit 等目录；自己的线程，未完成回 `pending`，不占命令队列）。`RPCMethod` 37、`tools/list` 38。

## 单测

`swift test`：第一部分 305 / 80；第二部分后 **312 个用例、82 个套件全部通过**（+7：时间标签解析、索引持久化、缓存定位 / 时间段 / 原图 / 缩放、`message.media` 三条路径与错误、查询路径不建记录、控制台解码；`ControlError` 加 case 后又要 `swift package clean`，否则测试进程在描述错误值时段错误）（293 → +12：只读动作默认放行 / `gateReads` / 写动作仍拒、策略解码、`policy.set{gateReads}` 与 `controller.mediaCache` 路由、`MCPProxy` 经真实套接字握手 / 工具清单 / 调用 / 缺键 / 直接方法 / 守护进程不在、`imctl mcp` 子命令与 Codex 配置合并幂等 / 技能定位、扫描器分类与目录聚合 / 不阻塞与缓存 / 文件头、控制台 `activeIsGroup` 与策略状态）。三处旧断言按新默认改写（打开非白名单目标 → `TARGET_NOT_FOUND` / `TARGET_MISMATCH`，`gateReads` 时仍 `TARGET_NOT_ALLOWED`）。插入 `RPCMethod` case 后又一次 `swift package clean` 才能让 `WeComAPIHandler` 用例不错位。

## 活体（build 59，09:5x–10:0x）

| 步骤 | 结果 |
|---|---|
| `imctl policy list` | `reads: open (default…) remoteEdits=false`，生效标题 = 测试群 + 文件传输助手 |
| `conversation.read 测试联系人A`（非白名单） | `succeeded`，`active = 测试联系人A`；`message.history` 1 行；`conversation.read 文件传输助手` 回到助手 |
| `message.send 测试联系人A`（探针） | `failed` `TARGET_NOT_ALLOWED`（选会话前即拒） |
| `imctl mcp serve` 握手（Python 驱动 stdio） | `initialize` → `serverInfo imctl / 0.1.0-dev`；`tools/list` 38；`tools/call account.status` → `succeeded`（`windowReachable true`、15 个会话）；`message.send` 缺键 → `isError` `INVALID_PARAMS: message.send requires idempotencyKey`；`message.history` 2 行；stdin 关闭后退出 0 |
| `imctl mcp config` / `install --dry-run` | 打印 `claude mcp add --scope user imctl -- <包内 imctl> mcp serve`、Codex 块、两处技能目标路径 |
| `controller.mediaCache` | 第一次 `pending`（`scan started`）；随后系统提示「“imctl.app”想访问其他App的数据。」出现在屏幕上，扫描线程阻塞等待用户点选；命令队列不受影响（同时的 `conversation.read` 等正常） |

## 图片第二部分（10:1x–10:4x，用户点「允许」后）

**清单（`controller.mediaCache`，975 s 后就绪 = 用户点选的时间；18564 个节点）**：图片文件集中在头像 / 表情 / 文档缩略图 / SDImageCache；聊天图片不在 `WXWork/Data/<uid>/`（那里是加密的 SQLite：`message.db` 等文件头不是 `SQLite format 3`），而在 **`Documents/Profiles/<profile>/Caches/Images/<yyyy-MM>/<id>/<id>`**（本例一张 128 KB 的 JPEG，mtime = 2026-09-15 09:36:12），原图在 `<id>_HD/<id>_HD`（打开过才有），表情 `Caches/Emotions`，视频封面 `Caches/Video_Thumbnail`；当前 profile 由 `Documents/Profiles/setting.json` 指出。`controller.mediaCache{dir}` 列目录（只在根内、只看名字 / 大小 / 前 16 字节）用于这次取证。文件头识别改为「非文本类扩展名都看前几个字节」（客户端的图片文件没有扩展名）。

**对应关系与 `message.media`（协议 §6.39）**：查询（不建命令记录，字节不进数据库）。① `MediaIndex`（`media-index.json`，0600）里已有的对应；② 守护进程观察到 `message.observed{kind: media}` 时记下时刻（`DaemonWatcher` → `MediaIndex.observe`），取观察前 120 s 到后 30 s 内出现、未被占用的缓存文件里最近的一个（`observed`）；③ 当前打开会话里，用该行上方最近的时间标签（`MessageTimeLabel`：`21:37` / `昨天 21:37` / `星期一 21:37` / `9月15日 21:37` / `2025年9月15日 21:37`，含上下午）到下一个标签（无则 +6 h）框住一段，段内文件按顺序对应段内 media 行（`window`）。都不成立 → `MEDIA_NOT_FOUND`（消息写明原因）。返回 base64，超过 `maxBytes` / `maxPixels` 时缩放为 JPEG；`hd:true` 取原图。`message.history` 的 media 行带 `media: assigned|observed|unmatched`；控制台会话页对 media 行调 `message.media` 显示缩略图（失败显示原因 + 重试）。

**活体（build 60）**：`conversation.read` 直接打开含图会话（读已不经白名单）；`message.history` 2 行 = `0 message inbound 昨天 9:32` + `3 media unmatched`；`message.media{messageKey, maxPixels: 800}` → `matchedBy: window`、`path = …/Caches/Images/2026-09/42c2…/42c2…`、`size 127988`、`368×800 scaled`、31992 字节 JPEG——解码后正是对方发来的那张手机截图（内容含真实姓名，只留在会话暂存目录并已删除，不入库）；再读 `message.history` 该行 `media: assigned`；`media-index.json` 0600、1 条对应。

**边界**：本轮没有新图片到达，`observed` 路径只有单测覆盖；`window` 路径在多图 / 多会话下的歧义按顺序解决，需要更多样本复核。

**补记（10:5x，`2b26a50`，build 62）**：重装 build 61 后第一次 `message.media` 又弹了一次「访问其他App的数据」提示，而此前 59 → 60 两次重装都没弹；提示期间那次查询在套接字线程上阻塞，`imctl call` 30 s 超时（套接字按连接串行，会拖住其它客户端）。修正：`message.media` 与 `controller.mediaCache{dir}` 的文件访问放到自己的线程，8 s 内没回来就返回可重试的 `MEDIA_NOT_FOUND`（消息写明「等待系统授权提示；允许 imctl.app 或加入完全磁盘访问权限」），线程留在后台跑完。用户点允许后 build 61 与重装后的 build 62 都直接取回图片（build 62 未再弹）。若以后每次更新都弹，一次性办法是 系统设置 › 隐私与安全性 › 完全磁盘访问权限 加 `imctl.app`。单测 313 / 82。

## 未闭环

- `observed` 路径待一张新图片到达时复核（测试手机往测试群发一张图，守护进程运行中）；多图会话的 `window` 顺序对应待样本。
- MQTT：10:1x 起 broker 连接超时（最后一次成功 08:47），与本轮改动无关，守护进程按退避重连。
- 用户跑 `imctl mcp install --claude-code --codex --skills` 后在 Claude Code / Codex 里各调一次工具。
- 控制台策略页「发送白名单」块与会话页改群名行待过目。
