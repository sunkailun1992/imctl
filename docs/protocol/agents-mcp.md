# Claude Code / Codex 接入（`imctl mcp`）

智能体（Claude Code、Codex CLI）和 Java 一样，**只发控制命令、不碰桌面客户端**：它们通过 MCP 拿到的工具就是本协议的方法，全部经同一个守护进程执行——同一条串行队列、同一份 `policy.json`、同一个幂等存储与事件日志。

## 1. 结构

```
Claude Code / Codex  ──stdio (MCP, 换行分隔 JSON-RPC)──▶  imctl mcp serve  ──Unix socket──▶  imctld（LaunchAgent）──AX──▶ 企业微信
```

- `imctl mcp serve`：stdio 上的 MCP 服务端（`initialize` / `tools/list` / `tools/call` / `ping`），每个 `tools/call` 转发到 `~/Library/Application Support/imctl/run/imctl.sock`。它自己不驱动客户端；守护进程没起来时工具回 `DAEMON_UNREACHABLE`。
- 工具名 = 方法名（`conversation.list`、`message.send`…，`tools/list` 与 `docs/protocol/im-control-protocol.md` §6 一一对应）；工具结果 = 命令记录 JSON（`state` / `result` / `error`），`state ∈ {failed, expired}` 时 `isError: true`。
- 直接写 JSON-RPC 行（不走 `tools/call`）也可以，与 `imctl call` 等价。
- B34 在本机云端视觉和独立整窗辅助均已启用时，对**非活动目标**的 `conversation.read` 和 `message.send`、`message.sendFile`、`group.rename`、`group.addMembers` 的选目标前缀主动让模型从可操作 AX 行中选择，即使 AX 已解析出唯一行也一样。AX 选行后必须用新鲜企微主窗截图再调用模型复核，并以 AX 活动标题严格核对目标；写命令仍要求精确 AX 标题候选，模型不决定正文、成员或提交动作。目标已活动时不为选目标上传。除下述 B35 两步外，其它固定桌面方法保留其 AX 或受限视觉后备；这不是任意桌面任务入口，不能以 MQTT/MCP 成功响应推断模型被调用。
- B35 只扩展显式读取前的两个可逆导航步骤：普通 `message.history` 确需回到最新且只有一个可见可写消息区滚动条时，模型先选该 AX 条，滚动后经新鲜截图模型复核及 AX 底部值验证；`contact.request.list`（`contact.request.accept` 共用的只读导航）仅在左侧唯一可见、AX 标题精确匹配「新的客户」且尚未选中时，模型先选该行，动作后由新截图模型复核及 AX 选中行、申请表就绪验证。已到底、已选中且表就绪或整窗视觉关闭时沿 AX 路径；接受按钮与提交仍走原 AX 实现。后台 watcher 不上传。上述 `message.history` 与 `contact.request.list` 限定分支已有真实千问两轮、MQTT 终态与独立 AX 后验，见 B35 门报告；接受提交未验收。不能仅凭其它工具的成功响应推断它调用了模型。
- B36 对直接请求的 `message.send` / `message.sendFile`，在已由 AX 证明唯一聊天输入框和目标后，于固定正文 / 附件暂存前后各作一次模型被动观察；模型不能生成正文、选附件、执行粘贴或 Return。暂存、checkpoint、提交和新外发消息证据仍由原动作层控制；`message.broadcast` 子命令不触发 B36 输入框观察。当前只有源码与 fake 测试，真实视觉发送尚待验收；既有纯 AX 发送成功不等于 B36 通过。
- `controller.describe` 返回守护进程级十进制字符串计数 `visionCaptureCount`、`visionRequestCount`、`visionHTTP200Count`，分别表示经核验的窗口截图、模型 HTTP 请求发起、固定官方端点 HTTP 200 次数。HTTP 200 在 JSON/模型决策解析前计，不等于有效选择或命令成功；MCP/MQTT 响应不含截图、模型原文或密钥。
- `controller.readiness`：逐项就绪与修复命令（查询，不建命令记录）；联网实测在守护进程后台跑，`online.state` 为 `running` 时隔一秒再调。结果里的 `fix.action` 是给人点的快捷操作类型（控制台按钮、`imctl doctor --fix`），智能体只转告，不执行。

## 2. 接入

先装守护进程（`imctl agent status` 应为 running）。二进制在 `~/Applications/imctl.app/Contents/MacOS/imctl`（家目录安装）或 `/Applications/imctl.app/Contents/MacOS/imctl`。

```bash
# 看一眼会写什么
imctl mcp config
imctl mcp install --claude-code --codex --skills --dry-run
# 真正写入
imctl mcp install --claude-code --codex --skills
```

| 目标 | 做了什么 | 手工等价 |
|---|---|---|
| Claude Code | `claude mcp add --scope user imctl -- <imctl> mcp serve` | 同左；`claude mcp list` 可见，会话里 `/mcp` 可查 |
| Codex | 在 `~/.codex/config.toml` 追加 `[mcp_servers.imctl]`（`command` = `<imctl>`、`args = ["mcp","serve"]`），已有则跳过 | 手工粘贴 `imctl mcp config` 打印的块 |
| 技能 | 把随包的 `SKILL.md` 复制到 `~/.claude/skills/imctl/` 与 `~/.codex/skills/imctl/`（工作流与安全规则，让模型知道何时读、何时发、怎么带幂等键） | 从仓库 `docs/agents/skills/imctl/SKILL.md` 复制 |

`--scope project` 会写进当前项目的 `.mcp.json`（路径是本机绝对路径，不要提交到仓库）。

## 3. 智能体该怎么用（技能里的规则）

1. **先读后写**：`account.status` → `conversation.list` → `conversation.read{target}` → `message.history{limit}`（普通读取先把企微消息区定位到最新；`scrollback:true` 加载旧页；有 `readError` 的不完整行不得用于回复，可能没有 `messageKey`；`kind: media|file|video` 的行用 `message.media{messageKey}` 取 OSS 签名地址；不再有 base64，没配 `oss.json` 时 `OSS_NOT_CONFIGURED`）；读会话默认不经白名单（`gateReads` 开着时非白名单目标回 `TARGET_NOT_ALLOWED`，改用 `client.navigate` 走过去）。
2. **发送必带 `idempotencyKey`**：按意图起一个稳定的键（例如 `reply-<会话>-<日期>-<序号>`）；重试用**同一个键**只会拿到上次的结果，绝不重发；换键 = 再发一条。
3. **发送只到白名单**：编译内置 `文件传输助手` + `policy.json.allowedTitles`（控制台策略页勾选放行）；不在白名单 → `TARGET_NOT_ALLOWED`，智能体不能自己放宽（`policy.set` 需本机先 `imctl policy remote --enable`，且那是人的决定）。
4. **群发**：`message.broadcast{targets, text, idempotencyKey}` 逐个目标发送（各自经白名单与限速，等限速而不是失败）；结果里每个目标一条。
5. **发文件**：`message.sendFile{target, url|ossKey, fileName?, idempotencyKey}`——只收 https 且域名在 `policy.json.sendFile.allowedHosts`（`imctl policy hosts`），或已配置 bucket 的 `ossKey`；证据 = 新出现的本人外发且类型相符的 media / file / video 行；`PASTE_FAILED` 表示没贴进输入框、什么都没发。回车后若无新行则为 `unknown`，不清理输入框，也不要换键补发。
6. **事件用拉的**：`event.replay{afterEventId, limit}`，`message.observed{origin:"other"}` 表示人在手机上接管了，按会话静默。
7. **不做的事**：不装 / 不重启守护进程（本机命令），不改 MQTT / 代理设置，不向真实客户发消息除非白名单里有。
8. **加群成员先 dryRun**：`group.addMembers{target, members, dryRun, idempotencyKey}` 只对放行的群生效（同发送白名单）；已在群里的成员天然算 `skipped`，先 `dryRun: true` 选一遍确认名单，再正式提交按「确定」。
9. **按手机号加人先只搜索**：`contact.add{phone, source, dryRun, idempotencyKey}` 号码不限（用户 2026-10-13 决定），发出的申请收不回：先 `dryRun: true` 看匹配，只在用户当次指定这个号码时才真实添加，不自作主张；只搜索与真实添加各有每小时上限（`RATE_LIMITED`）。

## 4. 排错

| 现象 | 原因 / 处理 |
|---|---|
| 工具回 `DAEMON_UNREACHABLE` | 守护进程没起来或套接字路径不同：`imctl status`、`imctl agent status`；`imctl mcp serve --socket <path>` |
| `TARGET_NOT_ALLOWED` | 目标不在发送白名单；策略页勾选放行（人的决定） |
| `NOT_A_GROUP` | `group.addMembers` 的目标没有成员列表（表头无人数且侧栏无 `群成员·`，不是群） |
| `MEDIA_NOT_FOUND` | `message.media` 对不上缓存文件：先 `conversation.read` 打开那个会话再问；只有守护进程运行期间到达的图片能按观察时间对应 |
| `LOCAL_GUARD` | `policy.set` 需本机开关；`imctl policy remote --enable` |
| `RATE_LIMITED` | 每会话 ≥ 3 s、全局 ≤ 20 条 / 分钟；`contact.add` 每小时真实添加 / 只搜索各有上限（`imctl policy phones`） |
| `SOURCE_NOT_ALLOWED` | `message.sendFile` 的 URL 非 https，或域名不在 `policy.json.sendFile.allowedHosts`；`imctl policy hosts` 看当前名单，放宽是人的决定 |
| `PASTE_FAILED` | ⌘V 后输入框没出现附件，什么都没发；重试要换一个新的 `idempotencyKey`（同一个键只会回放这次失败） |
| `OSS_NOT_CONFIGURED` | 本机没有 `oss.json`：`message.sendFile{ossKey}` 或 `message.media` 用不了，先 `imctl oss set`（人的决定） |
| 多个智能体 / Java 同时下命令 | 守护进程只有一条串行队列：命令按到达顺序一个个执行（`command.state{accepted}` 的 `queuedMs` 是排队时长），群发在目标之间让路 |
| Claude Code 看不到工具 | `claude mcp list` 有没有 `imctl`；`imctl mcp serve` 直接跑一下，粘一行 `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` 应回 45 个工具 |
