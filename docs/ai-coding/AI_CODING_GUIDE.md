# imctl AI 编程指南

> 面向 AI / Codex / 新协作者的快速扫描说明。先读本文件，再改代码。

涉及目录、注释、设计模式、风险门禁、安全、测试与批次流程时，必须同时阅读本目录下的 `AI_DIRECTORY_STRUCTURE_GUIDE.md`、`AI_COMMENT_STYLE_GUIDE.md`、`AI_DESIGN_PATTERN_GUIDE.md`、`AI_ENGINEERING_GUARDRAILS.md`、`SECURITY_CODING_SPEC.md`、`TESTING_SPEC.md` 和 `AI_AUTOMATION_WORKFLOW.md`。

## 1. 项目定位

`imctl` 是一个 Swift 常驻进程（`imctld`）加运维 CLI（`imctl`），在员工日常使用、坞站合盖常开不锁屏（隔离方案 A′）的 MacBook 上控制本机企业微信客户端：

- 通过 Accessibility 读会话表、消息区、输入框，发送文本（AX 设值 + AX 聚焦 + 对企微 pid 一次回车）。
- 通过 MQTT 5（EMQX）或本地 MCP / JSON-RPC 接受 Java 业务服务 / 智能体的命令，回传状态与事件；事件是真相，可按 `event_id` 重放。
- 后续通过企微官方 API（经云端令牌注入代理）做群活码 / 联系我 / 欢迎语 / 群发 / 备注与身份桥（`WeComAPI`，v0.2 规划中）。

个人项目；服务公司业务不改变归属。阶段与验收状态以本仓库 `docs/gates/` 为准，`README.md` 顶部的阶段描述只是摘要。维护者可另行维护私人 wiki，外部贡献不需要访问；开发所需的决策必须在仓库或当前 issue / PR 中提供脱敏依据。

## 2. 构建与运行

```bash
swift build
swift test                                  # 单测 + ForbiddenAPITests；live 套件默认跳过
IMCTL_LIVE=1 swift test                     # 需要真实企微客户端 + 辅助功能授权
scripts/build-signed.sh [debug|release]     # 构建并用稳定身份重签 imctl / imctld（identifier com.sunkailun.imctl）
scripts/install-daemon.sh                   # 复制到 ~/Library/Application Support/imctl/bin 并 kickstart 已装的 LaunchAgent
bash scripts/check-secrets.sh               # warning-only 扫描疑似 secret / IP / 本机绝对路径
.build/arm64-apple-macosx/debug/imctld run --stdio                       # JSON-RPC / MCP over stdio
.build/arm64-apple-macosx/debug/imctld run --socket <0700 目录>/imctl.sock --mqtt
.build/arm64-apple-macosx/debug/imctl status
.build/arm64-apple-macosx/debug/imctl probe conversations|messages       # 只读探针，默认脱敏
```

外盘路径首次构建若因旧 `.build` 缓存失败，先 `swift package reset`。`swift test` 会把 `.build/` 下的二进制重签成 ad-hoc，因此常驻守护进程只从稳定目录运行，不从 `.build/` 运行。

运行环境要求：macOS 15+（开发机 macOS 26.x arm64）、Xcode 26.6 / Swift 6.3.3、企微客户端（已验证 5.0.10 / 5.0.11）、辅助功能授权（终端进程与 launchd 下的 `imctld` 分别授权）。普通构建和 fake 测试不需要真实企微或系统授权；当前锁定依赖要求 Swift 6.2+，CI 显式设置 `IMCTL_LIVE=0` 和 `IMCTL_LIVE_VISION=0`。

## 3. 目录与 target 分层

| target | 职责 | 允许依赖 | 不允许 |
|---|---|---|---|
| `ControlCore` | 协议类型、命令状态机与执行器、GRDB 存储（命令 / 事件 / 暂停 / kv / 身份桥）、策略（`ActionPolicy` / `SendPolicy` / `RateLimiter`）、checkpoint | GRDB | 任何 AX、网络、AppKit |
| `AXKit` | 通用 AX 原语：`AXBackend` 协议、`LiveAXBackend`（唯一接触 `AXUIElement`）、`FakeAXBackend`、`AXNode` 夹具、观察者桥、脱敏 | ApplicationServices、CryptoKit | 任何企微知识 |
| `WeComAdapter` | 企微 AX 树解析（布局定位、会话行、消息行、方向、群会话）、目标解析与复核、动作（select / compose / submit / scroll / menu）、命令处理器、观察引擎与归因 | AXKit、ControlCore | 网络、传输 |
| `MCPTransport` | 行分隔 JSON-RPC 2.0 + MCP `tools/*`、`event.replay` 查询、stdio / Unix socket 服务 | ControlCore | 适配器 |
| `MQTTTransport` | MQTT 5 绑定：命令 / 响应 / 事件泵 / retained state + 遗嘱、`mqtt.json` 设置（0600） | ControlCore、MCPTransport、mqtt-nio、swift-nio | 适配器 |
| `imctld` | 守护进程：执行器 + 观察者（通知去抖 + 轮询兜底）+ 传输 + 状态文件 + 策略热加载 | 全部库 | 业务决策 |
| `imctl` | CLI：`permission` `env` `dump-tree` `probe …` `status` `enroll` `mqtt` `agent` `policy` `identity` | 全部库、AppKit（仅 probe activate） | 常驻逻辑 |
| `imctl-console` | 菜单栏测试控制台：状态 / 会话 / 发送 / 事件 / 策略 / 设置 / 诊断 / 日志 | 全部库、SwiftUI / AppKit、`UnixSocketClient` | 任何绕过执行器 / 守护进程套接字的客户端写操作；LLM 驱动 |
| `WeComAPI`（规划） | 企微官方接口客户端（经代理、Bearer 鉴权）、API 路线命令、身份桥填充 | ControlCore、Foundation URLSession | 持 secret、直连企微 |

依赖方向只能自上而下（executables → 传输 / 适配器 → ControlCore / AXKit）。`Package.swift` 里每个库对应 `Sources/<Target>/` 与 `Tests/<Target>Tests/`。

## 4. 关键约束与数据流

**命令管线**（`CommandExecutor`，串行）：accept → 幂等键查重 → 过期（`ttlMs + issuedAtMs`）→ 暂停 reason set `{api, local_guard, system}` → 速率硬上限（每目标 ≥ 3 s、全局 ≤ 20 条/分钟）→ `running` → 处理器 → 终态 `succeeded / failed / unknown / cancelled / expired`。每次状态变化都是一条 `command.state` 事件。

**发送阶段**（`WeComActions.submit`）：locate → open → verify_target → precheck_input（人留草稿 = `LOCAL_GUARD`）→ compose → **submit（不可逆点，之前落盘 checkpoint）** → confirm（证据 = 匹配的外发气泡）。崩溃后 `running + checkpoint` 一律 `unknown`，绝不重跑。

**策略层次**（由内向外，只能收紧不能放宽）：

1. 编译白名单 `WeComClient.fileTransferAssistantTitle`（代码，改它是人的决定）。
2. `policy.json`（`SendPolicy`，`imctl policy allow|deny`）：按标题 / 会话类型 / `chat_id` / `external_userid` 放行；`unknown` 类型永远不能被类型规则放行。
3. `ActionPolicy.authorize(kind, resolved:)`：阶段 → 启用集合 → 目标存在 → 允许；所有改变客户端状态的原语都经过它。
4. 执行器速率硬上限 `RateLimiter`（`RATE_LIMITED`）。
5. Java 侧策略（回不回、给谁、按会话静默）只能更严。

**目标语法**：`message.send.target` / `conversation.read.target` 接受纯标题（开发期）、`chatId:<id>`、`externalUserId:<id>`；ID 经身份桥表 `identities`（`group` / `customer` → 标题）解析，未命中 `TARGET_NOT_FOUND`，多个同名 `TARGET_AMBIGUOUS`，打开后不符 `TARGET_MISMATCH`。

**观察**：`WatchEngine` 定位 → 快照（`WatchSnapshot`）→ diff（`WatchDiff`，尾对齐识别历史前插）→ 归因（`OriginClassifier`：`controller` 带 commandId / `other` = 接管信号 / `peer` / `unknown`）→ 事件草稿；`DaemonWatcher` 负责定时器、AX 通知去抖、落库、`system` 暂停、状态文件。`message.observed` 携带 `sender`、`messageKey`（会话 + 发送者 + 时间 + 文本 + 同元组序号的 SHA-256 前 16 hex，不含行索引）、`conversationType`、身份桥命中时的 `chatId` / `externalUserId`。

**会话类型推断**只在有证据时给 `group`（头部成员数 / 发送者标签 / 列表"外部"标记）或 `customer`（"微信"标记 / "名字@公司"）；`internal` 不推断，只能靠标题规则放行。

## 5. 关键文件索引

| 关注点 | 文件 |
|---|---|
| 白名单常量 | `Sources/WeComAdapter/WeComClient.swift` |
| 唯一合成输入例外 | `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`（守卫：`Tests/ControlCoreTests/ForbiddenAPITests.swift`） |
| 策略 | `Sources/ControlCore/Policy/ActionPolicy.swift`、`SendPolicy.swift`、`PolicyProvider.swift`、`RateLimiter.swift` |
| 协议类型 / 错误码 | `Sources/ControlCore/Protocol/RPCTypes.swift`、`ControlEvent.swift`、`TargetRef.swift`、`MessageKey.swift`、`Identity.swift` |
| 执行器与不可逆点 | `Sources/ControlCore/Executor/CommandExecutor.swift`、`Sources/ControlCore/Checkpoint/` |
| 存储 | `Sources/ControlCore/Store/ControlStore.swift`（GRDB 迁移只追加，不改旧迁移） |
| 布局与解析 | `Sources/WeComAdapter/WeComLayout.swift`、`ConversationRow.swift`、`MessageRow.swift`、`ConversationHeader.swift`、`ConversationTypeInference.swift` |
| 目标解析与处理器 | `Sources/WeComAdapter/TargetResolver.swift`、`Handler/WeComCommandHandler.swift` |
| 动作 | `Sources/WeComAdapter/Actions/WeComActions.swift`、`Submit.swift`、`Scrollback.swift`、`ComposerMenu.swift` |
| 观察 | `Sources/WeComAdapter/Watch/`、`Sources/imctld/DaemonWatcher.swift` |
| 传输 | `Sources/MCPTransport/RPCDispatcher.swift`（`tools/list` 描述）、`Sources/MQTTTransport/MQTTBinding.swift`（Response Topic 守卫） |
| 守护进程入口 | `Sources/imctld/main.swift`、`DaemonRuntime.swift` |
| CLI | `Sources/imctl/IMCTL.swift`、`Sources/imctl/Commands/` |
| 签名 / 安装 | `scripts/build-signed.sh`、`scripts/install-daemon.sh`、`Sources/imctl/Host/LaunchAgent.swift` |

## 6. 运行数据与配置

全部在 `~/Library/Application Support/imctl/`，不入库：

| 文件 | 内容 | 权限 | 写入方 |
|---|---|---|---|
| `imctl.sqlite` | 命令、事件、暂停原因、kv 游标、身份桥 | 默认 | `imctld`（`imctl identity` 亦可写） |
| `state.json` | 守护进程状态（轮询 / 通知 / 暂停 / 策略摘要） | 默认 | `imctld`，退出时删除 |
| `checkpoints/` | submit checkpoint（含目标与文本） | 默认 | 适配器 |
| `mqtt.json` | broker、controller id、可选凭据 | 0600 | `imctl enroll` |
| `policy.json` | 白名单放宽规则 | 0600 | `imctl policy`，`imctld` 按 mtime 热加载并发 `controller.state{policy}` |
| `run/imctl.sock` | Unix socket | 目录 0700 | `imctld` |
| `bin/` | 稳定副本 `imctl` / `imctld` | 0700 | `scripts/install-daemon.sh` |

日志在 `~/Library/Logs/imctl/`（LaunchAgent）。本地日志与 checkpoint 含消息正文：依赖 FileVault，不复制到仓库或 wiki。

## 7. 协议变更规则

- **`docs/protocol/im-control-protocol.md` 是对外协议的唯一权威文档**（语言中立：MQTT topic、JSON-RPC 信封、全部方法/事件/错误码、状态与重放、企微回调事件），与代码同一提交更新；`Tests/MCPTransportTests/ProtocolDocTests.swift` 会核对每个 `RPCMethod`、`ControlEventKind`、`ControlError.allCodes`、`tools/list` 名称和 topic 是否都出现在文档里，缺一个 `swift test` 失败。`java-consumer.md` / `wecom-token-proxy.md` 只写各自视角的补充，不复制定义。
- 新方法：`RPCMethod` + `CommandHandler` / `APICommandHandler` + `CommandExecutor.execute` 分支 + `RPCDispatcher.toolDescriptors`（`tools/list` 数量有测试）+ 协议文档；产生客户端或平台副作用的方法必须 `requiresIdempotencyKey`。
- 查询（不建命令记录、不发 `command.state`）走 `RPCDispatcher` 层，如 `event.replay`。
- 新事件字段：`WatchSnapshot` / `WatchEngine.draft` / 处理器输出 + 契约文档；字段缺失时省略而不是填假值；`origin`、`direction`、`conversationType` 的 `unknown` 是合法值。
- 新错误码：`ControlError` 的 `code` 是 wire 字符串，同时加进 `ControlError.allCodes`、`ProtocolTests` 与协议文档。
- 协议版本字符串 `im-control/0.1` 在冻结前不升；破坏性变更先写规格，并在 issue / PR 记录用户决定；维护者可另行同步私人 wiki。

## 8. 客户端事实与夹具

- 已验证的客户端版本与行为写进代码注释（带日期与版本，见注释规范）和 `docs/gates/`；未验证的版本按运行时降级思路对待。
- 定位只用角色 + 几何 + 可设属性，不用 `_NS:*` 自动生成的标识符或固定坐标。
- 夹具：`imctl dump-tree --root main-window --output Tests/Fixtures/ax-trees/wecom-<版本>-<视图>.json` 录制后默认脱敏（保留 `文件传输助手` 与 UI 文案）；`--raw` 输出必须 `.raw.json` 且已 gitignore。群会话夹具用测试代码合成（`GroupFixture`），不录真实客户群。

## 9. 阶段、门与文档流

`docs/superpowers/specs/`（口径）→ `docs/superpowers/plans/<日期>-<批次>-<主题>.md`（代码级 TDD 计划；可用 writing-plans 辅助）→ 实现 → `docs/gates/<日期>-<批次>-<主题>.md`（实测：条件、发送条数、证据、结论、未闭环）→ PR。规格是口径不是实测；门关闭后以门报告为准并回写。维护者可另行归档私人 wiki（证据进 `queries/`，口径覆写 topic / repo / synthesis），不作为外部贡献的前置条件或验收门槛。

## 10. 版本

- 构建标识在 `Sources/ControlCore/IMCTLVersion.swift`（`string`、`bundleIdentifier`）。`bundleIdentifier` 与签名 identifier 必须保持 `com.sunkailun.imctl` 不变，否则 TCC 授权丢失。
- `-dev` 后缀表示未打 tag 的开发版本；关闭一个阶段门或发布给目标 Mac 时打不可变 tag `v<major>.<minor>.<patch>` 并去掉 `-dev`。
- 纯文档 / 规范 / 注释改动不改版本；改变协议或运行时行为的批次可在 gate 关闭时递增 patch；不兼容协议或运行数据格式变更才升 minor，并写迁移与回滚。
- GRDB 迁移只追加新的 `registerMigration`，永不修改已发布的迁移。

## 11. 分支与提交

- `main` 是唯一长期分支，必须始终可 `swift build` / `swift test`。所有正常开发走短分支 `feature|feat|fix|docs|chore|refactor|test/<scope>-<desc>` 和 PR，不直接推 `main`；外部贡献者推自己的 fork，已有写权限的协作者也不绕过 PR。
- 提交信息和 PR 标题使用英文 Conventional Commits，前缀 `feat(scope)` / `fix(scope)` / `test` / `docs(gates|specs|ops|protocol|ai-coding)` / `chore` 等，正文写清结果与验证方式；有 AI 参与时署名实际参与的模型。PR 描述可用中文或英文，按 `.github/pull_request_template.md` 填写。
- 提交前：`IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test` 通过、`bash scripts/check-secrets.sh` 告警逐条人工判断、`git diff --check` 通过、`git status --short` 无 `.raw.json` / 临时文件 / 本机路径。CI 的 `secrets` 是另一项高可信格式检查，不能代替广泛扫描和个人信息复核。
- 开工、提交前、推送前先 `git fetch`；未推送的本地提交跟进最新上游后重跑验证，已推送的分支通过追加提交或合并 `main` 跟进，禁止强推（含 `--force-with-lease`）。遇到他人的未提交改动或无法解决的冲突就报告，不覆盖。
- 全库 CODEOWNER 为 @sunkailun1992。第三方 GitHub 账号的 PR 须本人对具体版本批准、所需 CI 通过且评审对话解决后才可合并；追加可审查的新提交须重新审核。AI 不代替本人 approve；本人账号与 AI 在已授权任务内的协作按根目录 `MAINTAINERS.md` 的例外处理，当前版本必要 CI 全部通过、评审对话解决后可直接合并，新增提交后重新核对最新 CI。持有 owner 凭据本身不构成任务授权。具体权限见 `MAINTAINERS.md`；GitHub 规则实际是否生效以仓库设置为准。
- 一个门报告一个提交；规范与代码可同一提交但交付说明分开写。
- 不改写已推送历史；历史中的敏感内容（如早期计划里的 broker 地址）是否改写由用户决定。
- 外部贡献者不自行修改发布版本、打发布标签或发布安装包；提交内容按 Apache-2.0 授权，见 `CONTRIBUTING.md`。

## 12. 与 Java 侧和代理的关系

- Java 只发命令、只做消息业务，契约在 `docs/protocol/java-consumer.md`；参考消费方规划在 `examples/java-consumer/`。
- 云端令牌注入代理 `wecom-token-proxy`（Java 17 / Spring Boot 4，Maven）规划在 `proxy/wecom-token-proxy/`，只做 token 缓存、路径白名单、回调验签 / 解密转 MQTT、Bearer 鉴权、审计（不含正文）；企微应用参数只进它的环境变量。
- Java 代码遵循本仓库 `AI_COMMENT_STYLE_GUIDE.md` 的 Java / YAML 规则与各子项目 README 的验证方式；历史规范模板来自同级 `quantitative-trading-ai` / `utils`，外部贡献者不需要这些仓库。与 imctl 契约相关的约束以本仓库协议及安全规范为准。
