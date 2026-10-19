# 批次 P1 / J1 / 协议模拟器：令牌注入代理、Java 参考消费方、Python 模拟器与协议文档（2026-09-14 20:1x–2026-09-15 00:3x CST）— 单测通过、无部署、无真实企微

条件：没有代理主机、没有自建应用参数、没有 broker 上的代理/消费方账号，因此**没有部署代理、没有连接真实 broker、没有调真实企微接口、没有真实二维码**；全部用假 HTTP、记录式发布器、内存总线验证。桌面客户端未触碰。产物：`proxy/wecom-token-proxy/`（Java 17 / Spring Boot 4.0.4 / Maven）、`examples/java-consumer/`（同栈）、`examples/protocol-sim/`（Python 3，标准库）、`docs/protocol/im-control-protocol.md`（权威协议）+ `ProtocolDocTests`。计划：`docs/superpowers/plans/2026-09-14-p1-j1-sim-proxy-consumer-simulator.md`。

## 实现

- **协议文档**：`docs/protocol/im-control-protocol.md` 语言中立地定义 topic、连接参数、JSON-RPC 信封与命令记录视图、26 个方法的参数/结果、5 类事件的字段、重放与 gap 对账、企微回调事件、15 个错误码、典型流程与变更记录；`Tests/MCPTransportTests/ProtocolDocTests.swift` 核对每个 `RPCMethod` / `ControlEventKind` / `ControlError.allCodes` / `tools/list` 名称 / topic 都出现在文档里；`controller.state.paused` 统一为数组（`68671dd`，`swift test` 200 / 59）。
- **Python 模拟器**（`cd9fe53`）：`MockController` 按协议应答全部方法（幂等、暂停、限速、策略、身份桥、事件日志与 `event.replay`、API 路线假实现、`sim.inbound|takeover|callback|reset`）；`ImctlClient` 驱动（Response Topic / Correlation Data、事件游标与 gap 对账、`wait_for`、二维码下载）；`MemoryBus`（进程内）与 `MqttBus`（paho MQTT 5）；CLI `mock` / `call` / `tail` / `demo` / `qr`；`wecom_direct.py` 直接调企微取二维码（只为用户自验）。`unittest` 9 个通过；`--broker memory:// demo` 离线跑通 46 个事件的完整回路。
- **P1 代理**：`AccessTokenService`（缓存、提前 300 s 刷新、单飞）、`WeComForwarder`（40014/42001/40001 刷新重试一次，其余 errcode 原样透传）、`PathAllowlist`（16 接口 + `media/upload`，拒绝 `..`/`?`/`//`）、`BearerAuthFilter` + `RateLimiter`（每 token 每分钟）、`ProxyController`（`POST /wecom/**`、`GET /healthz`，审计行不含正文）、`WeComCrypto`（WXBizMsgCrypt：SHA-1 签名、AES-256-CBC、32 字节 PKCS#7、receive id 校验）、`XmlFlattener`（禁 DOCTYPE）、`CallbackRelay` + `CallbackController`（GET 回显 / POST 验签解密 → `EventSequence` 持久单调 id → MQTT `wecom/{corpId}/evt` QoS 1 + user properties → `success`；发布失败 500 让企微重试）、`HiveMqEventPublisher`（MQTT 5 持久会话）/ `LoggingEventPublisher`；`application.yml` 只列环境变量键；`Dockerfile` 多阶段、非 root。
- **J1 消费方**：`EventStore`（`(source, eventId)` 去重与游标，内存实现可换表）、`Reconciler`（空洞 / 重连 / 控制器重新上线 → `event.replay` 循环）、`Consumer`（`origin:peer` 且 `chatId` / `externalUserId` 在白名单 → `conversation.read` + `message.history` → `ReplyPolicy` → `message.send{chatId:…, idempotencyKey, ttlMs, issuedAtMs}`；`messageKey` 去重；`origin:other` 静默 30 分钟；回调 `add_external_contact` 且 `State` 在渠道开关 → `contact.welcome.send`（附群活码链接）+ `contact.remark.set`；`change_external_chat/create|update` → `group.get`）、`ReplyPolicy`（回声 / OpenAI 兼容 `chat/completions`）、`MqttCommands`（Response Topic `im/{id}/rsp/{instance}`）、`MqttRunner`（共享订阅 `$share/imctl-consumers/…`）。

## 单测

| 项目 | 命令 | 结果 |
|---|---|---|
| imctl（Swift） | `swift test` | 200 个测试 / 59 套件通过（含 `ProtocolDocTests`） |
| protocol-sim（Python） | `python3 -m unittest discover -s tests -t .` | 9 个通过 |
| wecom-token-proxy（Java） | `mvn -q test` | 12 个通过（crypto 往返 / 拒绝、token 缓存与重试、白名单、限流、序列持久化、回调中继、`@SpringBootTest` 端到端：401 / 404 / 200 注入 token / healthz / GET 回显 / POST 中继） |
| java-consumer（Java） | `mvn -q test` | 6 个通过（白名单回复、忽略非对等/未知/静音、接管静默、gap 重放顺序、上线对账一次、渠道欢迎与群创建回写） |

`bash scripts/check-secrets.sh` 仅既有 1 条历史命中。

## 未做 / 待用户事项

- 部署：固定公网 IP 主机（出口 IP 进自建应用可信 IP）、HTTPS 域名、自建应用参数（corpid / agentid / secret / 回调 Token / EncodingAESKey）、broker 上的代理与消费方账号；之后 `imctl wecom enroll`、企微后台"测试回调"、真实扫码。
- 真实二维码只在真实接口打通后产生：经代理走 `group.joinway.create|get` / `contact.way.create`，或用户自验用 `examples/protocol-sim/imctl_sim/wecom_direct.py qr`（需本机出口 IP 可信）。
- `broadcast.confirm` 的真实群发助手窗口形状、`message.observed` 在真实群上的形态仍待测试群校准（B4 活体清单）。
- 语音消息：员工↔客户会话无官方发送接口、桌面 AX 无录音路径；只能文本 + 欢迎语 / 群发附件（image / link / miniprogram / video / file）。
- 消费方的 `EventStore.Memory` 与内存静默表是参考实现；接入真实业务时换持久表。
