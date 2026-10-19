# 批次 B2：MQTT 5 边缘接入（EMQX）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 IM Control Protocol 绑定到用户的 EMQX 5.9.3（LAN，MQTT 5，当前匿名可连、authz 默认放行）：命令经 `im/{controller_id}/cmd` 进入，响应回 MQTT 5 Response Topic（缺省 `…/rsp`）并回显 Correlation Data，事件按 `event_id` 顺序 QoS 1 发布到 `…/evt`（游标持久化、可重放），`…/state` retained + 遗嘱表示存活。用 `imctl mqtt call/tail` 充当最小 Java 消费方做端到端。

**Architecture:** 三层。`MQTTBinding`（纯逻辑，可测：命令分发到 `RPCDispatcher`、响应路由、事件泵与 kv 游标、状态载荷）→ `MQTTLink` 协议（测试用 `RecordingLink`）→ `MQTTNIOLink`（MQTT-NIO 2.13 v5 客户端：持久会话 `cleanStart=false` + `sessionExpiryInterval`，遗嘱 retained offline，订阅 cmd QoS 1，回调放到串行队列执行命令，250 ms 事件泵，指数退避重连）。设置 `MQTTSettings` 存本地 `~/Library/Application Support/imctl/mqtt.json`（0600，不入库），`imctl enroll` 写入。

**Tech Stack:** mqtt-nio 2.13.0（`MQTTClient` v5 API），swift-nio `NIOCore`/`NIOFoundationCompat`。

## Global Constraints

- broker 地址、凭据只进本地设置文件；仓库与 wiki 只记"EMQX 5.9.3、LAN、匿名接入、authz 放行"。
- 传输层不含企微语义；`message.send` 的白名单、幂等、checkpoint 全在执行器。
- QoS 1 下重复投递由执行器幂等键吸收；事件游标只在发布成功后前进。
- `imctld` 默认不开 MQTT，需 `--mqtt`；无设置文件即报错退出。

---

### Task 1: kv 表 + `MQTTSettings` + `MQTTLink` + `MQTTBinding`（已完成）

- `ControlStore` 迁移 v2 `kv(key, value)`；`MQTTSettings`（topic 布局、0600 保存）；`OutboundMessage`/`MQTTLink`；`MQTTBinding.handleCommand` / `pumpEvents` / `statePayload`。
- 测试 8 个（topic 布局、响应路由、Response Topic 覆盖、通知无响应、事件泵顺序与游标、失败不前进、状态载荷、设置文件权限）。

### Task 2: `MQTTNIOLink`（live）

**Files:** `Sources/MQTTTransport/MQTTNIOLink.swift`；`Package.swift` 加 swift-nio 的 `NIOCore`、`NIOFoundationCompat` 产品。

```swift
public final class MQTTNIOLink: MQTTLink {
    public init(settings: MQTTSettings, log: @escaping (String) -> Void)
    public func start(binding: MQTTBinding)      // 连接（持久会话 + 遗嘱）、订阅 cmd、发布 state online、启动事件泵、断线退避重连
    public func stop()                           // 发布 state offline、断开、关闭事件循环
    public func publish(_ m: OutboundMessage) throws   // v5 publish，属性：correlationData / userProperty；同步等待 PUBACK
    public var isConnected: Bool
}
```

- 入站 `MQTTPublishInfo`（topic == cmd）→ 提取 `.responseTopic` / `.correlationData` → 串行队列 `binding.handleCommand`。
- 事件泵：`DispatchSourceTimer` 250 ms，连接时 `binding.pumpEvents()`。

### Task 3: CLI：`imctl enroll`、`imctl mqtt call`、`imctl mqtt tail`

**Files:** `Sources/imctl/Commands/EnrollCommand.swift`、`Sources/imctl/Commands/MQTTCommands.swift`

- `enroll --broker host[:port] --controller-id <id> [--username --password] [--config <path>]`：写 `mqtt.json`（0600），打印 topic 布局。
- `mqtt call <method> [--params <json>] [--timeout 15] [--config]`：作为"Java"：自带回复 topic `im/{id}/rsp/cli-<pid>` + correlation；发布到 cmd；等待匹配响应；打印。
- `mqtt tail [--seconds 10]`：订阅 `im/{id}/#`，逐行打印 topic 与载荷。

### Task 4: `imctld run --mqtt [--mqtt-config <path>]`

- 启动 `MQTTNIOLink` + `MQTTBinding`（同一 executor/dispatcher/store）；`DaemonRuntime` 持有，关停时 `stop()`（state offline）。

### Task 5: 端到端（EMQX 5.9.3）

1. `imctl enroll --broker <broker-host> --controller-id <本机 id>`（地址只落本地文件，不写进仓库）。
2. `imctld run --mqtt --watch-interval 1` 后台；EMQX API 看到 `imctl-<id>` 连接与 retained `…/state` online。
3. `imctl mqtt call conversation.list`、`account.status`；`imctl mqtt call message.send --params '{"target":"文件传输助手","text":"imctl-b2-mqtt","idempotencyKey":"…"}'` → succeeded；同键再次 → 同 commandId。
4. `imctl mqtt tail --seconds 6` 看到 `command.state` 与 `message.observed` 事件（QoS 1、event_id 单调）。
5. `kill -TERM` 守护进程 → retained state 变 offline；重启后事件游标不重复发布。
6. 结果写 `docs/gates/2026-09-13-b2-mqtt-e2e.md`。

## 执行结果（2026-09-13 18:2x）

- Task 1–5 完成：131 个测试；E2E 见 `docs/gates/2026-09-13-b2-mqtt-e2e.md`（send 92/84 ms，回放同 id，事件 2→15 单调，retained 状态 online→offline，重启不重发）。
- 偏离：企微中途升级 5.0.11，刚启动无消息表 → 消息表改可选；watcher 加重定位与切换会话去抖；`account.status` 加 `clientRunning`；watcher 自动 `system` 暂停。
