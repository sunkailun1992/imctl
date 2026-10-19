# 批次 B3：观察者并入 imctld、历史回读、接管信号、事件对账、常驻/收口准备（2026-09-13 23:2x–23:3x CST）— 通过（历史"加载更多"待有历史的会话验证）

条件：企微 5.0.11，窗口在另一 Space、非前台；`imctld run --socket <0700 目录>/imctl.sock --mqtt --watch-interval 1`（AXObserver 开、去抖 150 ms）；对端 = Unix socket 行分隔 JSON-RPC（脚本）、`imctl mqtt call`、另一进程的 `imctl probe submit`。broker 仍为用户 LAN 的 EMQX 5.9.3（地址只在本地 `mqtt.json`）。本批向文件传输助手发出 **2 条**测试消息：`imctl-b3-origin-1`（经 imctld）、`imctl-b3-other-1`（经 `probe submit`，模拟"人从别处发出"）。**没有安装 LaunchAgent、没有改 EMQX 配置、没有扩大白名单。**

## 实现

- `WeComAdapter/Watch/`：`WatchEngine`（定位/快照/diff/归因/重定位，纯逻辑）、`WeComObserver`（订阅 24 个标准通知）、`OriginClassifier`（同一条发送只消费一次）；`WatchDiff` 识别"历史前插"（尾对齐）不再当新消息；`DaemonWatcher` 改为定时器 + 通知去抖 + 落库 + 状态文件（`--no-observe`、`--debounce`）。
- `message.observed.origin ∈ {controller(带 commandId), other, peer, unknown}`：`ControlStore.recentSends`（10 分钟内 succeeded/unknown 的 `message.send`）供归因；`origin=other` 的外发气泡即接管信号。
- `message.history{limit, scrollback}`：新动作 `scrollHistory`（策略层、白名单）；`WeComLayout.messageScrollArea`；`loadOlderMessages` 把消息区所有可设 `AXScrollBar.AXValue` 置 0（到顶）等行数增长，两轮不增长即停，结束置 1（底部）；`probe scrollback --allow-scroll [--strategy bar|page] [--no-restore]`。
- `event.replay{afterEventId, limit}`：`RPCDispatcher` 层查询，直接读事件表，不建命令记录、不发 `command.state`；`tools/list` 11 个。
- `MQTTBinding.resolvedResponseTopic`：Response Topic 不在 `im/<id>/` 子树内改用 `im/<id>/rsp`（每机 ACL 收紧不丢回复）。
- `imctl agent install|uninstall|status`（plist：RunAtLoad、KeepAlive{SuccessfulExit:false}、ThrottleInterval 5、ProcessType Interactive、LimitLoadToSessionType Aqua、日志 `~/Library/Logs/imctl/`）；`--dry-run` 只打印。`scripts/build-signed.sh` 优先 Developer ID Application（本机没有该证书，仍用 Apple Development）。
- 文档：`docs/ops/launchagent.md`、`docs/ops/emqx-auth-acl.md`、`docs/protocol/java-consumer.md`。
- 顺带修正：(1) `JSONValue` 把 JSON `0/1` 解析成布尔（请求 `id:1` 曾被回显为 `true`，`afterEventId:1` 失效）；(2) 消息表加载超过一屏后 AX 报表格 frame `y=-5`，旧标题启发式（表格顶之上的静态文本）丢标题、又把滚出视口的时间标签当标题，导致 `activeTo:""` 事件与 `probe submit` 失败 → 改为以滚动区顶为界并排除滚动区内的元素；(3) B2 计划文件里的 broker 地址已脱敏（git 历史仍有，是否改写历史由用户定）。
- `swift test` **155** 个测试（B2 时 131）。

## E2E

| 步骤 | 结果 |
|---|---|
| 启动 | `observer: subscribed 24 notifications`；MQTT `sessionPresent=true`；`account.status` 活动会话 文件传输助手、8 行会话 |
| `message.history{limit:40}` | 12 行，36 ms |
| `message.history{limit:40,scrollback:true}` | 12 → 12 行，3231 ms（两轮 1.5 s 等待无增长后停止），之后再读 44 ms |
| `message.send imctl-b3-origin-1`（socket） | succeeded 106 ms，`row #12 dir=outbound time=23:24`；事件 20–25：`command.state ×3` → `conversation.activity` → **`message.observed{origin:controller, commandId:BDE07870…}`** → `conversation.activity{preview}` |
| 观察者路径 | 日志 `observer: 2 event(s) via ax:AXRowCountChanged in 290 ms`（150 ms 去抖 + 一次轮询）；state.json `notifications=4, observedViaNotification=2`；发送后 1 s 兜底轮询未先于通知 |
| `event.replay{afterEventId:0,limit:2}` | 返回事件 1–2、`count=2`、`lastEventId=19`，0 ms；后续对账均用它读取 |
| 标题缺陷 | 13 行后 `account.status.activeTitle` 先为 `""`、再为 `星期五 9:18`（滚出视口的时间标签）；修正并重启后恢复 `文件传输助手`（表格 frame `y=-5` 保持） |
| `probe scrollback --strategy bar --no-restore` | 滚动条 `[1,1] → [0,0]`，dump 证实表格 frame `y` 从 -5 变 63（**视图确实到顶**），行数 13 → 13 |
| `probe scrollback --strategy page` | 活体报 `AXScrollUpByPage` 不支持（AX 列出但拒绝执行） |
| `probe scrollback --strategy bar`（恢复） | 滚动条回 `[1,1]`；期间事件流只有 `conversation.activity{timeLabel}`，**无任何 `message.observed`** |
| `probe submit --auto --allow-submit imctl-b3-other-1`（另一进程） | succeeded 113 ms，`row #13`；imctld 事件 48 **`message.observed{origin:other, text:imctl-b3-other-1}`**（无 commandId），`observer: 1 event(s) via ax:AXRowCountChanged in 290 ms` |
| `imctl mqtt call controller.describe` | 经 broker 正常响应（回复 topic 在 `im/mac-01/rsp/cli-<pid>` 子树内） |
| `imctl agent install --dry-run --mqtt --socket …` | 打印完整 plist；`~/Library/LaunchAgents` 无 imctl 项；`agent status` → `loaded: false`、`plistPresent: false` |
| `kill -TERM` | `received signal 15`，retained `im/mac-01/state` → `online:false`，socket 文件已清理 |

## 结论与未闭环

- **通过**：AXObserver 通知驱动观察（通知→观察 290 ms，含去抖）；`origin` 归因（controller 带 commandId / other 接管信号）；`event.replay` 对账查询；Response Topic 守卫；`agent` 命令与文档就绪但未安装。
- **机制成立、效果待验**：历史回读把视图滚到顶且不产生假观察事件，但文件传输助手行数未增长——该会话很可能只有 13 条（09-11 夹具时只有 1 条 `9:18`），需要一个确有更早历史的白名单会话才能验证"到顶即加载更多"；`AXScrollUpByPage` 在 5.0.11 上不可用，只能走滚动条 `AXValue`。
- **待用户决定**：装 LaunchAgent（`docs/ops/launchagent.md`）；EMQX 每机凭据与 ACL（`docs/ops/emqx-auth-acl.md`，需仪表盘操作）；Java 共享订阅组名与消费方仓库位置（`docs/protocol/java-consumer.md`）；Developer ID Application 证书需在 Apple Developer 账号创建（本机只有两张 Apple Development）；B2 计划文件 git 历史中的 broker 地址是否改写。
- 未做：7 天连续运行（依赖常驻形态决定）；`command.cancel` 仍是空操作。
