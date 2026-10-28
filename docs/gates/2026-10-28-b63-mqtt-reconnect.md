# 批次 B63：MQTT 重连同一时间只保留一个（2026-10-28 CST）— 通过（离线）；已安装，断线重连待活体核对

条件：只做离线验证。本批未安装、未重启守护进程，未连接真实企业微信或真实 broker（只连进程内、只监听 127.0.0.1 的假 broker），未发送、未写入、未调用视觉提供商；版本仍为 `1.0.26-dev`（与未安装的 B62 同版），基于 `main@c06e532`（B62）。项目处于观察期，维护者 2026-10-28 看过下文的故障后同意开 B63，范围限定为 `MQTTNIOLink` 的重连逻辑与离线测试，安装另行授权。

## 起因

观察期只读核对守护进程日志时发现夜间 MQTT 重连风暴。1.0.24 时期已有，B61 / B62 未改传输：

- 本地时间 10-18、10-19、10-24、10-25、10-26 的 00:00 前后各一次，每次 2.5–8 分钟；10-19 峰值约每分钟 2,200 次连接，一晚约 6 万次重连。
- 10-28 00:52 连接断开，先是 6 次 TCP 连接超时（10 s），这一段是单条重连、1→30 s 退避，正常。00:54:46 broker 回 CONNACK `notAuthorized`、00:55:16 回 `serverBusy` 之后，00:55–01:12 约 1,794 次「连上即被断」，约每分钟 100 次，01:12:41 自行收敛。
- 每次都自行恢复。AX 观察与本机 socket / MCP 不受影响；风暴期间经 MQTT 的命令、响应与事件不可靠，broker 承受大量连接。断线由 broker 一侧触发，原因未核实，不在本仓库范围。

## 根因

B2（2026-09-13）以来的重连逻辑有三处叠加：

1. TCP 已建立后才失败的连接（CONNACK 拒绝，或 CONNACK 前被关）既让 `connect` 的结果失败，又触发关闭回调，两处各排一次重连，一条重连从此分成两条。TCP 本身连不上时还没有连接对象，只有失败一处，所以 00:52–00:54 那段正常。
2. mqtt-nio 2.13.0 换上新连接时不关旧连接，且每个连接关闭都会通知关闭回调（`MQTTClient` 只在被关的仍是当前连接时才清掉它）。旧连接晚到的关闭把共享的 `connected` 置为 false 并再排一次重连，而当前连接其实还在。
3. 每次 CONNACK 成功都把退避重置为 1 s。多条重连用同一个 client id，新连接一上来 broker 就踢掉旧的（会话接管），被踢的那条 1 s 后再连、再踢回去。

## 实现

1. **`MQTTReconnectState`**（新文件 `Sources/MQTTTransport/MQTTReconnectState.swift`）：纯值类型，只做判定，不碰客户端与计时器。阶段为 idle / connecting / connected / waiting / stopped，每次尝试有编号：
   - 同一时间只有一个尝试在进行或等待；只认当前编号，旧计时器与旧尝试的迟到结果一律忽略。
   - 连接中或等待中收到的关闭不排重连，由该尝试自己的结果决定。
   - 已连接时收到关闭，而客户端仍有活连接（`MQTTClient.isActive()`），视为被替换的旧连接，当前连接保持；否则才排重连。
   - CONNACK 成功但连接已断，按失败排重连。
   - 退避 1→2→4→8→16→30 s，连接持续满 60 s 后才回到 1 s；每次延迟落在基数的后半段（基数 × (0.5 + 0.5 × 随机数)）。
2. **`MQTTNIOLink`**：判定在 `stateLock` 内做，动作在锁外执行；`isConnected` 取自同一状态；`stop()` 先停状态，再按停之前是否已连接决定是否发 retained offline；连接时长用单调时钟（与 B62 同一时钟）。
3. **日志**：`mqtt: connection closed` 只在需要重连时写；新增 `mqtt: a replaced connection closed; the current one stays up`；`mqtt: reconnecting in … s` 改为一位小数。

不变：协议（方法、字段、错误码、MCP 工具数 45）、主题与 QoS、持久会话（`cleanStart=false`、`sessionExpiryInterval=86400`）、遗嘱、client id、keepalive、命令执行、事件泵、策略与白名单、发送路径、按键、权限面、视觉上传。

## 单测

- `IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test`：**1,319 项 / 173 套件 / 10 程序全部通过**（B62 为 1,306 项 / 171 套件）。
- 同上再加 `IMCTL_FAKE_BATCH=1`：**1,319 项 / 173 套件 / 10 程序全部通过**。
- 3 项连接测试另按 CI 的 `--no-parallel` 单独连跑 3 次，均通过，每次约 11 s。
- 新增 `MQTTReconnectStateTests`（10 项，注入抖动与时刻）与 `MQTTNIOLinkReconnectTests`（3 项）。后者让真实的 `MQTTNIOLink` 连 `Tests/MQTTTransportTests/FakeMQTTBroker.swift`，按 broker 收到的 CONNECT 数断言。这 3 项先对 B62 的代码跑，都按上面的根因失败：
  - `aRefusedConnectIsRetriedOnce`（拒绝后立刻关，重试不应答）：2.6 s 内 broker 收到 3 个 CONNECT，应为 2 个。
  - `aLateCloseOfARefusedAttemptLeavesTheNextConnectionUp`（拒绝后 2 s 才关）：3.6 s 内 3 个 CONNECT、2 条仍开着，应为 2 个、1 条。
  - `aBrokerThatDropsEveryConnectionIsRetriedLessAndLessOften`（每次 CONNACK 后立刻断）：4.6 s 内 5 个 CONNECT（每秒一次），应为 3–4 个。
- 状态测试先对只有接口的空壳跑，10 项中 9 项失败；`stopEndsRetries` 对空壳本就成立，由下面的变异检查证明它能失败。
- 变异检查 6 项全被抓到：`stop()` 失效；被替换连接的关闭当真；旧尝试的失败仍重连；每次 CONNACK 都重置退避；「满 60 s」改成「超过 60 s」；`MQTTNIOLink` 关闭时不看 `isActive()`。
- `ForbiddenAPITests` 通过；`bash scripts/check-secrets.sh` 为既有 11 条示例 / 模板告警，无新增；`git diff --check` 通过。

## 安装（2026-10-28 09:55 CST）

推送后维护者授权安装 B62＋B63 并只读核对，不做真实写入：

- 构建：`main@2e91f05`，`scripts/build-app.sh release`，1.0.26 / build 13。三个可执行文件的 designated requirement 与已装的 1.0.25 / build 21 逐字相同（同一 Apple Development 证书）。SHA-256：imctl `47cfb699…`、imctl-console `79707e62…`、imctld `be834014…`。
- 安装：已装的 1.0.25 / build 21 先打包为 `out/rollback/imctl-1.0.25-build21-20261028.zip`（不入库，SHA-256 `fc555bde…`，解包后签章与三个可执行文件哈希已核对）。确认没有执行中的命令后，新包换到 `~/Applications/imctl.app`，09:55:13 `launchctl kickstart -k` 重启守护进程。没有用开发 pkg：磁盘上的 build 21 大于 13，pkgbuild 默认的 `BundleIsVersionChecked` 会跳过 bundle。步骤已写进[安装说明](../ops/installer.md)。
- 只读核对：守护进程 1.0.26-dev，由 launchd 常驻，未暂停，`trusted`（辅助功能授权保留），屏幕录制、访问企微数据与完全磁盘访问仍允许；`imctl doctor --offline` 就绪，命令行与守护进程同为 build 13；`controller.describe` 回 1.0.26-dev，视觉计数为 0。新进程启动 1 s 内 MQTT 连上（`sessionPresent=true`）并订阅命令主题，没有任何重连行。
- 命令库：unknown 仍为原有 2 条；安装后只多了两条只读的 `controller.describe`，无发送、无写入。

## 活体

断线时的重连行为要等 broker 下次断线才能看到（10-18 至 10-28 多在本地 00:00 前后）。届时只读核对：

- 每次失败只跟一行 `reconnecting in`，延迟逐次翻倍、带一位小数，不再出现每分钟上百次的「连上即被断」。
- 出现 `a replaced connection closed` 时连接保持，`imctl status` 的 MQTT 仍为已连接。
- 断线恢复后 `state` 为 retained online，命令订阅正常。

也可另装本机测试 broker 主动制造断线，需另行同意。

## 结论与未闭环

- 离线通过；10-28 09:55 已安装（与 B62 同为 1.0.26 / build 13），安装后只读核对正常；断线重连的活体核对待 broker 下次断线。
- broker 为何在夜间断线、为何先回 `notAuthorized` / `serverBusy`，不在本仓库，未核实。
- 若另有进程用同一 client id 连同一 broker，两边仍会互踢；每次连接都不满 60 s，退避会升到 15–30 s，不再是每秒多次。mqtt-nio 的关闭回调不带断开原因（例如 0x8E 会话接管），日志看不出是谁踢的。
- CONNACK 等待沿用 mqtt-nio 默认（`timeout` 为 nil，不设上限），B63 前后相同：broker 接受 TCP 却既不回 CONNACK 也不关连接时，这次尝试会一直等，不另起重连。
