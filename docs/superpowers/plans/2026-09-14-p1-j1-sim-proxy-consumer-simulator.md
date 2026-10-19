# 批次 P1 / J1 / 协议模拟器 Implementation Plan（随实现同步写成，2026-09-14）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把协议做成多语言可对接的形态：一份权威协议文档 + 门禁测试；一个 Python 模拟器（mock 控制器 + 业务侧驱动）让没有 Mac / 企微账号的对接方离线联调并跑完整回路；Java 令牌注入代理（P1）与 Java 参考消费方（J1）作为生产侧的两个参考实现。

**Architecture:** 文档是唯一权威（`docs/protocol/im-control-protocol.md`），`ProtocolDocTests` 用代码枚举反查文档；模拟器与两个 Java 项目都只依赖文档定义的 topic / 信封 / 字段。代理只有 token 注入、白名单、回调验签解密转 MQTT，无业务；消费方只发命令、决定回复，安全限制在控制器侧仍然生效。

**Tech Stack:** Swift（文档门禁）、Python 3 标准库（+ paho-mqtt 对真实 broker）、Java 17 / Spring Boot 4.0.4 / Maven / HiveMQ MQTT 5 客户端 / JUnit 5 / AssertJ。

## Global Constraints

- 不部署、不连真实企微、不连真实 broker；所有 HTTP / MQTT 用假实现或内存总线。
- secret、bearer token、broker 凭据只在环境变量或本机 0600 文件；`application.yml` 只列键名；`target/`、`.venv/`、`out/` 忽略。
- 消费方只按 `chatId:` / `externalUserId:` 发送，从不按标题；模拟器的二维码是 `mock.invalid` 占位。
- 工作方式：批量实现后各项目一次测试（`swift test`、`unittest`、`mvn test`）。

---

### Task 1: 权威协议文档 + 门禁（已完成，`68671dd`）

- [x] `docs/protocol/im-control-protocol.md`（§1 角色 … §12 变更）
- [x] `Tests/MCPTransportTests/ProtocolDocTests.swift`：`RPCMethod.allCases`、`ControlEventKind.allCases`、`ControlError.allCodes`、`RPCDispatcher.toolDescriptors()` 名称、五个 topic 字符串、`im-control/0.1`
- [x] `ControlError.allCodes`、`ControlEventKind: CaseIterable`、watcher 的 `paused` 统一为数组

### Task 2: Python 模拟器（已完成，`cd9fe53`）

- [x] `imctl_sim/protocol.py`、`bus.py`（`MemoryBus` / `MqttBus`）、`mock_controller.py`、`driver.py`、`cli.py`、`wecom_direct.py`
- [x] `tests/test_sim.py`（9 个：通配匹配、常量与目标语法、describe 与 state、chatId 发送与事件链与幂等与限速、策略/未知/暂停、读/历史/入站/接管、群活码/联系我/欢迎语/群发/回调、API 关闭 UNSUPPORTED、gap 重放）
- [x] `--broker memory:// demo` 离线冒烟

### Task 3: P1 令牌注入代理

**Files:** `proxy/wecom-token-proxy/pom.xml`、`src/main/java/com/kellen/wecomproxy/{config,auth,token,forward,crypto,callback,event,mqtt,util}/*`、`src/main/resources/application.yml`、`Dockerfile`、`README.md`
**Tests:** `WeComCryptoTest`、`AccessTokenAndForwarderTest`、`RateLimiterAndSequenceTest`、`CallbackRelayTest`、`ProxyEndToEndTest`

- [x] 失败测试：crypto 往返与拒绝；token 缓存直到过期前 300 s、gettoken 错误上抛；转发注入 token 并在 42001 时刷新重试一次、其它 errcode 透传；白名单归一化与遍历拒绝；限流每 token 60 s 窗口；序列跨实例持久；回调验签 → 一条事件（topic / user properties / payload 字段）、坏签名 SecurityException、发布失败上抛；端到端 401 / 404 / 200 / healthz / GET 回显 / POST 中继
- [x] 实现（见 gate 报告"实现"节）
- [x] `mvn -q test`：12 个通过

### Task 4: J1 Java 参考消费方

**Files:** `examples/java-consumer/pom.xml`、`src/main/java/com/kellen/imctlconsumer/{core,mqtt,policy}/*`、`ConsumerApplication`、`ConsumerProperties`、`application.yml`、`README.md`
**Tests:** `ConsumerTest`

- [x] 失败测试：白名单群 peer 消息 → `chatId:` 回复 + 历史 + 幂等键 + ttl，重复 eventId / 重复 messageKey 忽略；非白名单 / 无桥 ID / controller / unknown / 策略沉默 → 不发；接管静默 30 分钟后恢复；空洞 → `event.replay{afterEventId:1}` 且按序处理 two/three/four；上线对账只一次；回调欢迎（含群活码链接）+ 备注唯一化，渠道关闭不发，群创建 → `group.get`
- [x] 实现（`EventStore` / `Reconciler` / `Consumer` / `ReplyPolicy` / `MqttCommands` / `MqttRunner`）
- [x] `mvn -q test`：6 个通过（修正：重放后把游标推过已存的活体事件）

### Task 5: 门报告与提交

- [x] `docs/gates/2026-09-14-p1-j1-proxy-consumer-simulator.md`
- [ ] Commit + push；wiki 归档

## Self-review

- 规格覆盖：§2 代理 / Java 消费方职责、§3 事件（代理 `wecom/{corpId}/evt`）、§6 AI 回路、§7 群发（消费方未实现群发调度，留业务侧）、§8 代理与回调、§10 各组件单元验收。用户新增要求：完整 MQTT 协议文档 + 实时同步（Task 1）、py/java 模拟验证（Task 2 / 4）、二维码（`wecom_direct.py` 与 `group.joinway.get` / `contact.way.create`，真实值待接口打通）。
- 占位扫描：无。
- 类型一致性：Java 消费方与 Python 驱动都按文档字段名（`eventId`、`kind`、`payload.origin`、`messageKey`、`chatId`）解析；代理事件 `eventId` / `kind` / `corpId` / `payload` 与文档 §9 一致。
