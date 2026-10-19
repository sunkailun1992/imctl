# AI 目录管理规范

本规范约束 AI 在 `imctl` 中新增、移动、拆分和命名目录的方式。目录管理必须基于当前 Swift / SwiftPM 单包的真实结构，不能把 Java、Node.js、Xcode 工程或通用模板规则直接套进来。

## 1. 总原则

- 目录结构优先遵守 SwiftPM 约定：`Sources/<Target>/`、`Tests/<Target>Tests/`，target 名与目录名一致，`Package.swift` 是唯一真相。
- 每个 target 一个职责，依赖只能自上而下（见 `AI_CODING_GUIDE.md` 第 3 节）；新增跨层依赖先改规范再改 `Package.swift`。
- 目录变更必须降低维护成本：更容易定位职责、更少交叉依赖、更清晰的测试与验收边界。
- 不为了"整齐"批量移动发送路径、策略、传输或守护进程文件；结构调整必须和本次目标直接相关，且与行为修改分开提交。
- 新目录必须有明确归属，不允许 `Common`、`Utils`、`Misc`、`Helpers`、`Temp`、`Backup` 这类低信息目录。

## 2. 标准依据

- Swift Package Manager：`Sources/<Target>` 与 `Tests/<TestTarget>` 的默认路径、资源与可执行 target 约定。
- Swift API Design Guidelines：类型与文件命名一致，一个文件一个主类型或一组紧密相关的小类型。
- 本仓库既有拆分：按职责子目录（`Protocol/`、`Policy/`、`Store/`、`Executor/`、`Checkpoint/`；`Actions/`、`Handler/`、`Watch/`；`Commands/`、`Host/`、`Probe/`），文件按职责拆小。
- GitHub 平台约定：`.github/workflows/`、`.github/copilot-instructions.md`。
- 文档约定：CommonMark Markdown 正文承载规则，不依赖隐藏注释。

## 3. 仓库根目录

```text
.
├── AGENTS.md
├── README.md
├── Package.swift
├── Package.resolved
├── .gitignore
├── .github/
├── Sources/
├── Tests/
├── docs/
├── scripts/             构建 / 签名 / 安装 / 打包 / 密钥扫描脚本
├── packaging/           应用包 Info.plist 模板、pkg distribution / 资源 / postinstall（B6）
├── examples/            Java 参考消费方、Python 协议模拟器
└── proxy/               wecom-token-proxy（Java）
```

规则：

- 根目录只放入口、构建文件和平台配置；细分规范放 `docs/ai-coding/`。
- 不提交 `.build/`、`.swiftpm/`、`DerivedData/`、`*.xcodeproj`、`.DS_Store`、证书 / 描述文件、`.env`（已在 `.gitignore`）。
- 新增顶级目录（如 `examples/`、`proxy/`）前先在本文件登记职责与语言栈。

## 4. Sources

当前 target 与子目录职责：

| 目录 | 职责 |
|---|---|
| `Sources/ControlCore/Protocol/` | Codable 协议类型：方法、参数、错误、事件、命令记录、方向 / 来源 / 会话类型、目标引用、消息键、身份 |
| `Sources/ControlCore/Policy/` | `ActionKind`、`ActionPolicy`、`SendPolicy`（policy.json）、`PolicyProvider`、`RateLimiter` |
| `Sources/ControlCore/Executor/` | `CommandHandler` 协议、`CommandExecutor` 管线 |
| `Sources/ControlCore/Store/` | `ControlStore`（GRDB 迁移、查询） |
| `Sources/ControlCore/Checkpoint/` | submit checkpoint 模型与文件存储 |
| `Sources/ControlCore/Readiness/` | B52 就绪体检的纯逻辑：事实（`ReadinessFacts`）、判定规则（`ReadinessEvaluator`）、联网实测的缓存与并发执行（`ReadinessOnlineState`、`ReadinessProbeRunner`）、修复命令的路径替换；B53 动作类型与确认文字（`ReadinessAction`）、本机客户端判断（`ReadinessClient`） |
| `Sources/ControlCore/` 根 | `IMCTLVersion`、`IMCTLPaths` 等跨 target 常量 |
| `Sources/AXKit/` | 后端协议、Live / Fake 后端、元素包装与遍历、节点快照、dumper、脱敏、观察者、权限 |
| `Sources/WeComAdapter/` 根 | 客户端常量、布局定位、行解析、方向推断、时间标签、头部解析、类型推断、目标解析、错误 |
| `Sources/WeComAdapter/Actions/` | 动作集合与 submit / scrollback / 菜单策略；`KeystrokeInjector.swift` 是唯一允许 `CGEvent` 的文件 |
| `Sources/WeComAdapter/Contacts/` | 通讯录视图与导航栏角标、「新的客户」卡片、接受备注弹窗、发起群聊面板解析、接受决策（B7；只解析与定位，动作在 `Actions/`） |
| `Sources/WeComAdapter/Handler/` | 协议方法到适配器的绑定 |
| `Sources/WeComAdapter/Watch/` | 快照、diff、引擎、观察者订阅、来源归因 |
| `Sources/MCPTransport/` | JSON 模型、分发器、stdio / Unix socket 服务 |
| `Sources/MQTTTransport/` | 设置、绑定、链路协议与 mqtt-nio 实现 |
| `Sources/imctld/` | `main.swift`（参数与装配）、运行时、观察者驱动、路径、就绪体检装配（`DaemonReadiness`、`WatchHealth`） |
| `Sources/imctl/Commands/` | 一个子命令一个文件；子命令组（`agent`、`mqtt`、`policy`、`identity`）在同一文件内 |
| `Sources/imctl/Host/` | 宿主探测：环境、签名、LaunchAgent、树报告；`imctl doctor` 的渲染与兜底（`Doctor`）、`--fix`（`DoctorFix`） |
| `Sources/imctl/Probe/` | 探针会话、客户端状态、watch 运行器、树摘要（`ProbeTreeSummary`：覆盖层与带标签控件的诊断行） |
| `Sources/imctl-console/` | 菜单栏测试控制台（SwiftUI）：`Model/`（可测：`DaemonState`、`CLIRunner`、`DaemonControl`、`RPCService`、`Diagnostics`、`ConsoleModel`）、`Views/`（一页一文件）、`ConsoleApp.swift`；B53 体检页（`ReadinessPageView`、`ReadinessComponents`）、初始化向导（`SetupWizard`、`SetupWizardView`）、设置表单组件（`SettingsForms`）；改客户端状态只经守护进程套接字 |
| `packaging/` | `console/Info.plist.in`（应用包模板）、`pkg/distribution.xml.in`、`pkg/resources/`（安装器文案）、`pkg/scripts/postinstall`；`scripts/build-app.sh` / `build-pkg.sh` 消费，产物在 `out/`（忽略） |

新增规则：

- 新协议类型放 `ControlCore/Protocol/`，不放传输层；传输层只做信封与编码。
- 新的客户端动作放 `WeComAdapter/Actions/`，必须经过 `ActionPolicy`；不在 CLI 或守护进程里直接操作 AX。
- 新 CLI 子命令放 `imctl/Commands/<Name>Command.swift` 并注册到 `IMCTL.swift`；`CommandParsingTests` 会核对子命令列表。
- 新 target（如 `WeComAPI`）：`Package.swift` 加 `.target` / `.testTarget` / `.library`，目录 `Sources/WeComAPI/`（`Client/`、`Commands/`、`Bridge/`）与 `Tests/WeComAPITests/`；网络只经 `URLSession` + 可注入的 `URLProtocol` 伪代理。
- 个人微信适配器不存在（4.1.13 无 AX 树）；不预建 `WeChatAdapter` 目录。

## 5. Tests

```text
Tests/
├── ControlCoreTests/        协议、策略、执行器、存储、checkpoint、守卫测试 ForbiddenAPITests
├── AXKitTests/              Fake / Live 后端、dumper、脱敏、观察者
├── WeComAdapterTests/       解析、动作、处理器、观察引擎；FixtureLoading、GroupFixture 等夹具助手
├── MCPTransportTests/       分发器、Unix socket
├── MQTTTransportTests/      绑定（fake link）
├── imctlTests/              CLI 解析与 --from-fixture 探针
└── Fixtures/ax-trees/       脱敏后的录制 AX 树 wecom-<版本>-<视图>.json
```

规则：

- 测试 target 与库 target 一一对应；跨 target 的行为在最上层的那个测试 target 里测。
- 夹具只放脱敏 JSON；`*.raw.json` 已 gitignore；合成夹具用 Swift 代码构造，不提交生成的 JSON。
- live 测试文件名以 `Live` 开头或后缀（如 `LiveAXBackendTests.swift`），并用 `IMCTL_LIVE` 门控。
- 测试资源不放 `Sources/`；`Sources/` 里不放 `Tests` 子目录。

## 6. docs

| 目录 | 内容 | 命名 |
|---|---|---|
| `docs/ai-coding/` | AI 规范（本目录） | 大写下划线 |
| `docs/superpowers/specs/` | 设计规格与路线（口径） | `YYYY-MM-DD-<主题>-design|roadmap.md` |
| `docs/superpowers/plans/` | 代码级 TDD 计划 | `YYYY-MM-DD-<批次>-<主题>.md`（批次如 `s1`、`b3`、`b4`、`p1`） |
| `docs/gates/` | 门报告与实测数据（脱敏） | `YYYY-MM-DD-<门或批次>-<主题>.md`；夜跑日志 `.jsonl` / `.stdout.txt`；`*.raw.*` 禁止 |
| `docs/ops/` | 运维：LaunchAgent、EMQX 凭据与 ACL、代理部署（规划） | 小写连字符 |
| `docs/protocol/` | 对外契约：Java 消费方、代理契约（规划） | 小写连字符 |

长期产品文档不放根目录；`README.md` 只放定位、硬规则、模块表和命令。

## 7. scripts 与 .github

- `scripts/`：本地工具脚本（构建签名、安装守护进程、secret 扫描）；一律 `#!/usr/bin/env bash` + `set -euo pipefail`，不写本机路径，可用环境变量覆盖默认值。
- `.github/copilot-instructions.md`：轻量转发；`.github/workflows/ci.yml` 的 `swift` 在 macOS runner 构建并执行非活体测试，`secrets` 用 Python 标准库拒绝特定高可信凭据格式和私钥。`IMCTL_LIVE` 与 `IMCTL_LIVE_VISION` 都固定为 `0`，不需要辅助功能或真实密钥；不签名、安装或发布。

## 8. 规划中的非 Swift 目录

| 目录 | 语言 / 构建 | 规范来源 |
|---|---|---|
| `proxy/wecom-token-proxy/` | Java 17 / Spring Boot 4.0.4 / Maven（已建，P1） | 本目录与 `AI_COMMENT_STYLE_GUIDE.md` 的 Java 规则（历史模板来自同级 `quantitative-trading-ai` / `utils`，无需访问）；`README.md`、`Dockerfile`、`src/main|test`；`mvn -q test` |
| `examples/java-consumer/` | Java 17 / Spring Boot 4.0.4 / Maven（已建，J1） | 同上；只做契约演示，不含业务；`mvn -q test` |
| `examples/protocol-sim/` | Python 3（标准库；对真实 broker 才需 paho-mqtt） | 协议模拟器（mock 控制器）+ 业务侧驱动 + 直接调企微取二维码的验证脚本；`tests/` 用 `unittest` 与内存总线，零依赖 |

这些目录与 SwiftPM 无关，`swift build` 不扫描它们；各自的密钥只经环境变量，`application.yml` 只放占位符；Maven 的 `target/` 与 Python 的 `.venv/`、`out/`、`__pycache__/` 已 gitignore。

## 9. 目录变更检查

- `swift build` 与 `swift test` 通过；`Package.swift` 与目录一致。
- `README.md`、`AGENTS.md`、本文件、`AI_CODING_GUIDE.md` 第 3 / 5 节同步更新。
- `git diff --stat` 里纯移动与行为改动分开。
- `bash scripts/check-secrets.sh` 无新增告警。
