# B10 设计：读会话默认不经白名单、白名单可见可配、改群名入口、Claude Code / Codex 接入、图片缓存路线（2026-09-16）

用户 2026-09-16 09:25 对 B9 的四条答复 + 09:28 补充：① 已过目策略页 / 会话页新控件；② 图片按推荐的缓存文件路线；③ 「打开选中会话」的白名单没看到在哪配置，而且**默认不要限制**；④ 这个插件要能给 Codex 和 Claude Code 自动控制的能力；⑤ 没看到改群名的地方（附截图：活动会话是测试群，右栏没有改群名控件）。

## 1. 读会话默认不经白名单（用户 ③）

- 现状：`conversation.read` / `message.history{scrollback}` 经 `ActionPolicy.authorize(.selectConversation | .scrollHistory)`，目标必须在编译白名单或 `policy.json`；这是 B1 起的硬规则（打开会话被视为发送的前置）。
- 决定：白名单只管**会改变对方可见状态**的动作（`submit`、`composeText`、`renameGroup`、`showComposerMenu`）；`selectConversation`、`scrollHistory` 是只读动作（改变的是本机客户端的活动会话），**默认不经白名单**。`message.send` 在选会话之前就已 `authorize(.submit)`，放开只读动作不影响发送门。
- 可配：`policy.json.gateReads`（默认 `false`）。`true` 时恢复旧行为。`imctl policy reads --gate | --open`；`policy.set{gateReads?}`（仍受 `remoteEdits`）；控制台策略页开关。
- 控制台会话页的「走过去」回退只在 `gateReads = true` 时才会触发，保留。

## 2. 白名单可见可配（用户 ③「没看到配置」）

- 策略页把「放宽 / 收回」块改名为「发送白名单」：列出生效标题（编译内置 `文件传输助手` + `policy.json.allowedTitles`，各带「收回」；内置项不可收回），从会话列表**勾选**放行（不再手输标题；手动输入仍留给 `chatId:` 等），说明文字写清白名单管发送 / 改群名，读会话默认不管。
- 数据来源：`policy.get`（`allowedTitles`、`gateReads`）+ `controller.describe.allowlist`（编译项）。

## 3. 改群名入口（用户 ⑤）

- 根因：`activeIsGroup` 按「列表里 `selected = true` 的行」判断；截图里列表是上一次读取的（粗体行是 测试联系人A），活动会话已换到测试群，于是控件被藏起来。
- 改：按活动标题匹配行（回退到选中行）；改群名行**始终显示**，不是群时禁用并写明「活动会话不是群」；导航 / 打开后列表已重读。

## 4. Claude Code / Codex 自动控制（用户 ④）

- 现状：`imctld run --stdio` 能在 stdin/stdout 上说 MCP，但那是**整个守护进程**（执行器 + 观察者 + 数据库），第二个实例会和 LaunchAgent 里的守护进程抢客户端与数据库。
- 决定：加**桥** `imctl mcp serve`——stdio 上的 MCP 服务端（`initialize` / `tools/list` / `tools/call`，换行分隔 JSON-RPC，正是 MCP stdio 传输），每个 `tools/call` 转发到运行中的守护进程套接字（`UnixSocketClient`），工具清单与守护进程共用 `RPCDispatcher.toolDescriptors()`。一个守护进程、多个客户端（控制台、CLI、Java / MQTT、智能体），策略 / 幂等 / 事件 / 串行执行全部不变；智能体拿到的能力 = Java 的能力，发送仍只到白名单。
- 接入：`imctl mcp config` 打印 Claude Code 的 `claude mcp add` 命令与 Codex 的 `config.toml` 块（可执行文件绝对路径按当前二进制解析，不写死）；`imctl mcp install --claude-code --codex --skills [--dry-run]` 代做：Claude Code 走 `claude mcp add --scope user imctl -- <exe> mcp serve`，Codex 在 `~/.codex/config.toml` 追加 `[mcp_servers.imctl]`（已有则跳过），技能 `SKILL.md` 复制到 `~/.claude/skills/imctl/` 与 `~/.codex/skills/imctl/`（随包 `Contents/Resources/agents/skills/imctl/SKILL.md`，源 `docs/agents/skills/imctl/SKILL.md`）。
- 文档：`docs/protocol/agents-mcp.md`（随包进对接文档页）。写清：工具即协议方法；`message.send` 必带 `idempotencyKey`（同键重放不重发）；读会话默认可用；发送只到白名单；事件用 `event.replay` 拉。
- 不做：桥不自造幂等键（重试语义归调用方）；不给智能体本机凭据 / 安装类操作（与 MQTT 侧一致）。

## 5. 图片缓存路线（用户 ②）— 分两步

- 事实（B9）：图片在客户端 AX 树没有元素；企微 5.0.11 是沙盒应用（`com.apple.security.app-sandbox`），数据在 `~/Library/Containers/com.tencent.WeWorkMac/Data` 与 `~/Library/Group Containers/88L2Q4487U.com.tencent.WeWorkMac`（及同前缀）——都受 macOS「访问其它 App 的数据」保护，第一次访问会弹系统提示，**阻塞到用户点选**。
- 第一步（本轮）：`controller.mediaCache{limit?, refresh?}`——守护进程在**后台线程**扫描上述根目录（只读；按扩展名与文件头识别图片 / 视频；深度与节点上限；不读内容），返回 `{status: ready|pending|unavailable, roots, elapsedMs, scanned, files:[{root, path, size, modifiedMs, kind}], directories:[{path, images}]}`；扫描未完成（含等待授权）时立即返回 `pending`，不占执行器队列。授权提示归 `imctld`（launchd 下自己的 TCC 身份），用户点「允许」一次即可；误点「不允许」时在 系统设置 › 隐私与安全性 › 完全磁盘访问权限 里加 `imctl.app`。
- 第二步（拿到清单后）：消息 ↔ 文件对应（优先按会话目录，其次按时间窗：`message.observed{kind: media}` 的观察时刻 ±N s 内新出现的文件），`message.history` 的 media 行带 `mediaRef`，新增 `message.media{messageKey}` 返回内容（base64，大小上限，MQTT 包上限内），控制台会话页直接显示缩略图。第二步的取证与设计另起一节记入门报告。

## 6. 单测与活体

- 单测：`ActionPolicy` 只读动作默认放行 / `gateReads` 后拒绝、`submit` 仍拒绝；`SendPolicy` 解码默认；`policy.set{gateReads}`；`MCPProxy` 经真实套接字：`initialize` → `tools/list`（38）→ `tools/call controller.describe` 成功、`message.send` 缺键 `isError`；`imctl mcp` 子命令与 Codex 配置合并幂等；控制台 `activeIsGroup` 按活动标题；`controller.mediaCache` 路由与 pending。
- 活体：读非白名单会话直接成功；控制台策略页勾选放行 / 收回；`imctl mcp serve` 用 MCP 握手脚本走通；`controller.mediaCache` 触发授权提示 → 允许 → 清单；第二步按清单再做。
