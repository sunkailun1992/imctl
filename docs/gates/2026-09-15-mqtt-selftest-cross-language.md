# MQTT 快速自验：新版 imctld 经真实 EMQX 走通协议，Python 模拟器 ↔ Java 消费方跨语言回路（2026-09-15 00:40–00:55 CST）— 通过；桌面发送未验（客户端不在消息视图）

用户要求"快速自验调用 mqtt 一下"。条件：用户 LAN 上的 EMQX 5.9.3（地址只从本机 `mqtt.json` 读取并写入临时目录，事后删除，本页不记）；最新构建的 `imctld`（含 B4/B5，`c06998b` 后工作树）以**独立 controller id `mac-01-selftest`** 从本终端启动（终端进程继承桌面应用的辅助功能授权，故 `system` 暂停解除），常驻的旧 LaunchAgent 守护进程 `mac-01` 未触碰；企微客户端 5.0.11，当前处在 32 px 行的非消息列表视图，活动会话为通知账号"邮件提醒"；策略文件为临时空文件；未 enroll 代理。同一 broker 上另起 Python mock 控制器 `mock-01` 与 Java 消费方 `java-selftest`（共享组 `imctl-selftest-consumers`，群白名单 `wrMOCK000001`，渠道 `imctl-demo`）。**向真实客户端发送 0 条**：唯一一次 `message.send` 因当前视图没有 `文件传输助手` 行而 `TARGET_NOT_FOUND`，无副作用。

## 1. Swift CLI `imctl mqtt call` → 新版 imctld（真实 broker）

| 方法 | 结果 |
|---|---|
| `controller.describe` | `succeeded`：`policy=titles=1 …`（策略文件 `imctl policy allow` 写入后 2 s 内被守护进程热加载，日志 `policy reloaded`，事件 2 `controller.state{policy}`）、`wecomApi=disabled`、`targetSyntax`、`protocol=im-control/0.1` |
| `account.status` | `windowReachable=true`、`activeTitle=邮件提醒`、`activeType=unknown`、`composerPresent=false`、9 行 |
| `conversation.list` | 9 行（标题脱敏），`conversationType=unknown`，无 `文件传输助手` 行——客户端在非消息视图 |
| `message.history{limit:5}` | `[]`（通知账号的行全判 `system`，被过滤） |
| `group.list` | `failed` / `UNSUPPORTED`（未 enroll 代理，符合设计） |
| `message.send` → 文件传输助手 | `failed` / `TARGET_NOT_FOUND`（当前列表无该行，无副作用） |
| 同键重放 | 同一 `commandId`，不重跑 |
| 3 s 内第二条 | `failed` / `RATE_LIMITED`（"attempted 1467 ms ago"），按尝试计数 |
| `event.replay{afterEventId:0}` | 22 条按序：`controller.state{clientAvailable:true, paused:[]}`（数组）、`controller.state{policy}`、每命令 3 条 `command.state`，错误码 `UNSUPPORTED` / `TARGET_NOT_FOUND` / `RATE_LIMITED` 落在 `command.state.errorCode` |

守护进程日志：`mqtt: connected … sessionPresent=false`、`observer: subscribed 23 notifications`、`client available; system pause lifted`。观察：活动会话无输入框时每次轮询都重定位并重新订阅 AX 通知（B3 的"区域缺失即重定位"规则），对通知类账号是每秒一次的无谓开销，记入待改进。

## 2. Python 驱动 → 新版 imctld（真实 broker）

`imctl_sim.cli call --controller-id mac-01-selftest controller.describe` → `succeeded`（同上字段）；`event.replay{afterEventId:20}` → 5 条（21–25），含 `RATE_LIMITED`；`tail` 5 s 期间另一进程调 `account.status`，实时收到事件 26–28（`accepted` → `running` → `succeeded`）。

## 3. Python mock ↔ Java 消费方（真实 broker，跨语言）

mock 事件流（`event.replay`）证明整条回路：

| eventId | 事件 |
|---|---|
| 8 | `conversation.read chatId:wrMOCK000001` 成功（驱动切换 mock 的活动会话到群） |
| 10 | `message.observed{origin:peer, sender:张三, text:营业时间？, conversationType:group, chatId:wrMOCK000001}`（驱动 `sim.inbound`） |
| 13 / 16 | Java 消费方对 mock 发 `conversation.read`、`message.history` 成功 |
| 20 / 21 | 消费方 `message.send` 成功，mock 发出 `message.observed{origin:controller, text:"[imctl consumer] 收到：营业时间？"}`；消费方日志 `reply to chatId:wrMOCK000001 -> succeeded` |
| 24 / 27 | 驱动 `sim.callback add_external_contact{State:imctl-demo, WelcomeCode}` 经 `wecom/wwmock/evt` → 消费方 `contact.welcome.send` + `contact.remark.set` 成功 |
| 31–36 | 第二次回调再次触发欢迎语与备注 |

## 4. 发现并修正

- **驱动订阅竞争**：Python 驱动与 Java `MqttCommands` 都在订阅回复 topic 后立即发布命令；mock 回复快于 broker 处理 SUBACK 时响应丢失，表现为偶发 15 s 超时（本次 `sim.callback` 与一次 `event.replay`；命令本身已被 mock 执行，事件 24/27 可证）。修正：`MqttBus.start()` 等 CONNACK、`subscribe()` 等 SUBACK（≤5 s）；Java `listen()` 等 SUBACK。mock 增加 `SIGUSR1` 线程栈转储便于排障。控制器侧（`MQTTNIOLink`）无此问题：它先订阅 `cmd` 再发布状态。
- 桌面发送未能验证：客户端当前不在"消息"视图，`文件传输助手` 不在最左表格里；需人点回消息列表后再验（旧结论"定位前先核视图"再次成立）。

## 结论

- **通过**：新版守护进程的 MQTT 命令 / 响应 / 事件 / 重放 / 策略热加载 / 限速 / API 路线 `UNSUPPORTED` 在真实 broker 上成立；协议文档定义的信封和字段被 Swift CLI、Python 驱动、Java 消费方三方一致解析；扫码加人回调 → 欢迎语 → 备注、客户发言 → AI 回复回路在 mock 上跨语言闭环。
- **未验**：真实桌面发送（视图问题）、真实企微接口与二维码（仍需自建应用参数与代理部署）、群发助手窗口。
