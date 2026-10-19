# AGENTS.md

本文件是 `imctl` 仓库的 AI 编码入口。AI 修改本仓库前，必须先阅读本文件，再按任务风险阅读 `docs/ai-coding/` 对应规范、当前批次的规格 / 计划 / 门报告和真实 Swift 代码。

公开协作入口见 `CONTRIBUTING.md`，维护与合并规则见 `MAINTAINERS.md`。本仓库文件与当前 issue / PR 必须提供完成开发所需的脱敏规则和证据；维护者的私人 wiki 是可选补充，外部贡献者无需访问它。缺少安全授权或需求依据时，向维护者确认，不自行推断。

## 项目定位

- 项目名称：`imctl`（CLI `imctl`、守护进程 `imctld`、协议 IM Control Protocol）
- 项目类型：macOS 消息端控制器，控制本机企业微信桌面客户端，接受 Java 业务服务 / 智能体经 MQTT 或 MCP 下发的命令并回传事件
- 技术栈：Swift 6.3.3 / Swift 5 语言模式、SwiftPM 单包、macOS 15+、swift-testing、GRDB（SQLite）、mqtt-nio（MQTT 5）、swift-argument-parser、ApplicationServices（Accessibility）
- 外部系统：企业微信 macOS 客户端（`com.tencent.WeWorkMac`，经辅助功能树读写；方向未知的可见媒体行可按需截取单帧窗口画面）、用户 LAN 上的 EMQX、企微开放平台（只经云端令牌注入代理，`WeComAPI` 尚未实现）、Java 消费方（另建仓库 / `examples/`）；B16 允许显式添加群成员在 AX 定位失败后调用用户选定的官方视觉 API；B17 用户另行授权显式固定桌面命令在本机验证企微窗口后按需上传该窗口单帧，以支持有界 AI 多轮观察与 AX 定位
- 核心风险：向真实联系人或客户群误发消息、合成输入越出唯一例外、辅助功能之外的权限面、企微画面上传范围过大或被后台轮询触发、视觉 API 密钥或截图泄漏、模型把画面中的指令当命令、secret / 凭据 / broker 地址 / 真实联系人内容入库、幂等失效导致重复发送、崩溃后重跑不可逆步骤、把模型判断或设计口径当成已验收事实

## 修改前阅读顺序

1. `README.md`：定位、硬规则、模块表、构建 / 测试 / 运行命令
2. `docs/ai-coding/README.md`：规范目录、阅读顺序、维护规则
3. `docs/ai-coding/AI_CODING_GUIDE.md`：分层、命令管线、策略层次、运行数据、协议变更规则、提交规则
4. `docs/ai-coding/AI_DIRECTORY_STRUCTURE_GUIDE.md`：SwiftPM target、子目录、夹具、文档与脚本的归属
5. `docs/ai-coding/AI_COMMENT_STYLE_GUIDE.md`：Swift 文档注释、带日期的客户端事实、Shell / Markdown / JSON 夹具的注释规则
6. `docs/ai-coding/AI_DESIGN_PATTERN_GUIDE.md`：`AXBackend` 端口 + Fake、策略对象、命令管线、快照 diff 等既有模式与禁止过度抽象
7. `docs/ai-coding/AI_ENGINEERING_GUARDRAILS.md`：风险分级、Definition of Done、必查项、交付说明模板
8. `docs/ai-coding/SECURITY_CODING_SPEC.md`：合成输入、权限面、白名单与策略、不可逆点、secret、日志正文、传输与代理安全
9. `docs/ai-coding/TESTING_SPEC.md`：单测 / 守卫测试 / live 测试 / 门报告的分层与写法
10. `docs/ai-coding/AI_AUTOMATION_WORKFLOW.md`：规格 → 计划 → 批量实现 → 一次 `swift test` → 活体 E2E → 门报告 → 分支 / PR；维护者可另行归档私人 wiki
11. 运维手册（项目记忆，改动后同步）：`docs/ops/permissions.md`（一次性授权与检查）、`docs/ops/portability.md`（换 Mac / 换屏）、`docs/ops/installer.md`（给别的 Mac 安装）、`docs/protocol/agents-mcp.md` + `docs/agents/skills/imctl/SKILL.md`（Claude Code / Codex 接入）
12. 当前批次的 `docs/superpowers/specs/`、`docs/superpowers/plans/`、`docs/gates/`，以及目标 Swift 文件及其上下游

涉及发送路径、策略与白名单、`KeystrokeInjector`、TCC / 签名 / LaunchAgent、MQTT 凭据、代理与回调、事件语义时，不得只读摘要，必须继续阅读对应真实代码、既有门报告及规格 / issue / PR 中记录的用户决定。维护者可补充私人 wiki 的脱敏依据，不能把外部贡献者无法访问的页面作为唯一依据。

## 项目边界

- **不发全局合成键鼠事件。** 全部走 AX 动作 / 属性。例外只有对企微进程投递的按键，只允许在 `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`，批准过的就这几个：回车（submit，用户 2026-09-12 决定；选人面板搜索框上的那次，2026-09-15 16:3x）、⌘1–⌘8 / ⌃Tab / ⇧⌃Tab / ⌘N（B7 通讯录导航与发起群聊，用户 2026-09-15 决定）、⌘V（B13 发文件粘贴 outbox 文件 URL，用户 2026-09-22 17:43 决定）。再多一个按键都要用户先决定，并在仓库规格及 PR 中记录脱敏的授权依据（维护者可另行同步私人 wiki）；其它文件出现 `CGEvent` 等符号会被 `ForbiddenAPITests` 拦截，它同时校对这份按键清单。
- **权限面限于辅助功能与屏幕录制。** B15 已实现：仅对 AX 无法判方向的可见媒体行按需截取企微窗口单帧，在内存中判断左右，不保存、不上传，证据不足仍是 `unknown`。B16 用户 2026-09-24 允许：显式添加群成员的 AX 定位失败时，上传相关控件裁图到选定的官方视觉 API。B17 用户进一步允许：由 MQTT / MCP / 本地调用明确发起的**固定桌面协议命令**可按需上传**经 PID、窗口与当前命令核验的企微窗口单帧**，让模型在该命令允许的 AX 候选中规划下一步，再观察和复核；默认千问，可在本机切换 Gemini，密钥只在本机配置。B17 全窗上传另需本机 `fullWindowEnabled` 明确启用（`imctl vision full-window --enable`），旧配置缺字段默认为 false；B16 `cloudEnabled` 单独开启不授权全窗。完整窗口可能包含聊天正文、头像和其他会话信息，调用方与本机设置必须明确此数据去向；截图、模型请求和响应不落盘或进入日志 / 事件 / 协议。守护进程的后台 watcher、自动轮询、B15 媒体方向补证据不得因此上传；仅有系统屏幕录制授权也不等于启用云端。录屏请求只在守护进程的 `controller.permissions{prompt:true}`，截图只在 `WeComScreenCapture.swift`；不用全屏录制或输入监控。`ForbiddenAPITests` 校对权限例外。B17 的实现与活体验收边界见当批规格和门报告，不能将授权当作已上线证据。B52 用户 2026-10-10 允许：显式 `controller.readiness`（`imctl doctor`、控制台「体检」）在云端视觉已开启且有密钥时，用程序在内存里画的合成图（两个灰色方块，不截屏、不含本机或企微内容）走一次 B16 请求，证明提供商、模型与密钥可用；后台路径与控制台定时刷新不得触发，结果只留错误类别。
- **目标白名单编译进代码**（`WeComClient.fileTransferAssistantTitle`）；扩大只能经本地 `policy.json`（`imctl policy`），且是用户明确授权的人的决定；公开证据只记录脱敏的范围与授权，不记录真实目标（维护者可另行同步私人 wiki）。任何阶段不向真实联系人或客户群发消息；开发期只对用户自己的测试群和本人微信测试号。`policy.json` 可以携带显式的 `allowAll`（「全部放开」）开关——用户 2026-09-22 决定，默认关，只经本机 `imctl policy all` / 控制台改（`policy.set` 永远不接受），开启后守护进程日志与 `controller.describe.policy` 可见；开着时 `ActionPolicy.allows` 对任何目标放行。`allowAll` 是类型规则的唯一例外（类型规则永远不放行 `unknown`；`allowAll` 是用户明确开启、只本机、有日志的唯一例外）——标题 / chatId / externalUserId 规则本就不检查类型，被放行的标题一样以 `unknown` 通过。
- **改变客户端状态的原语默认拒绝**，全部经 `ActionPolicy`（阶段 → 启用 → 目标 → 白名单 / 策略），策略在代码里，文件只能放宽标题 / 类型 / 平台 ID。按手机号加人（`contact.add`）：用户 2026-10-13 决定不再要求号码白名单，任何号码都可搜索与发申请（对方通不通过由对方决定，发出的申请收不回）；只收手机号形式；真实添加与只搜索各有每小时上限（默认 20 / 60，`imctl policy phones`，0 即关闭，`policy.json` 无法解析时都按 0）；控制台真实添加前再确认一次，智能体技能要求先只搜索、只加用户当次指定的号码；幂等键与 `unknown` 不自动重试照旧。
- **`submit` 是不可逆点**：提交前落盘 checkpoint，重启后"有 checkpoint 无证据"一律 `unknown`，绝不重跑；同幂等键回放既有结果。
- **响应是便利、事件是真相**：`event_id` 单调、可重放；QoS 1 下状态变更方法用 `idempotencyKey` 同键不重做，只读方法重投可能重新读取及按 B17 设置重新上传；MQTT Response Topic 只接受 `im/<id>/` 子树。
- **协议文档与代码同步**：`docs/protocol/im-control-protocol.md` 是对外（多语言 / 多平台）对接的唯一权威；改方法、事件字段、错误码、topic 必须同一提交更新它，`ProtocolDocTests` 会拦截遗漏。
- **模型只在固定协议命令的桌面执行步骤内协助规划和定位**：回不回、回什么仍由 Java / 调用方决定；imctl 不接收模型生成的自由文本任务。模型不得改变方法、目标、收件人、成员、发送正文、文件来源、策略、幂等键或已批准的按键集合；输出只映射到当前命令事先允许的 AX 候选与动作。每轮重读并核对 PID、企微窗口、活动会话、候选角色 / 动作和目标，动作后由客户端证据决定结果；模型自评不能使命令成功。不可逆步骤仍由 `ActionPolicy`、`CommandExecutor`、checkpoint、幂等与限速控制，证据不足用 `unknown`，模型不得自行换键或重试。画面变化、候选含糊或达到轮次 / 时间上限时停止；不能把 B17 计划或 fake 测试冒充活体验收。B54：每次请求模型在守护进程日志写一行固定类别（方法、目标种类、阶段、轮次、结果、耗时）；命令因视觉结束时在记录上写 `diagnosis`；两者都不含截图、模型原文、标题、名字、号码或验证语。
- **只读结论不等于验收**：设计规格、计划、单测通过与活体门报告分层记录，报告写"待活体"就是待活体。

## AI 工程门禁

- 改动前按 `docs/ai-coding/AI_ENGINEERING_GUARDRAILS.md` 判风险；发送路径、策略、`KeystrokeInjector`、TCC / 签名、MQTT 凭据、代理 secret、回调验签默认极高风险。
- 不能为了编译或测试通过而绕过策略层、幂等键、checkpoint、`ForbiddenAPITests`、Response Topic 守卫或脱敏。
- 活体测试中任何**发送**动作只对白名单 / 策略允许的测试目标，并在门报告写明发了几条、内容、证据；探针输出默认脱敏，`--no-redact` 输出不得进入仓库或 wiki。
- LaunchAgent 安装、EMQX 凭据 / ACL、Developer ID 证书、放开真实客户 / 客户群等是用户决定；AI 只把命令与文档准备到"用户一个决定就能执行"。
- B53：控制台体检页、初始化向导与 `imctl doctor --fix` 的快捷修复只执行预定义的动作类型；执行类先确认，会重启守护进程的在有命令执行时拒绝；任何客户端都不执行报告里的命令文字。安装常驻等仍是用户的决定：由用户点按钮并确认。

## 多智能体协作规则

- 子智能体可以并行做代码阅读、AX 树分析、门报告核对、测试缺口分析和 Review。
- 子智能体不得独立修改 `KeystrokeInjector`、`ActionPolicy` / `SendPolicy`、`WeComClient` 白名单、`CommandExecutor` 不可逆点、传输守卫或运行数据文件，也不得对真实客户端执行发送。
- 最终改动范围、测试结论、活体结果与提交说明由主智能体统一收口。

## 公开贡献与合并

- 外部贡献者使用 fork + 分支 + PR；已有写权限的协作者也走工作分支和 PR，不直接推送 `main`。开工、提交前、推送前先 `git fetch`；未推送的本地提交跟进上游后重新验证，已推送的分支不改写，禁止强推（含 `--force-with-lease`）。
- 全库 CODEOWNER 是 @sunkailun1992。第三方 GitHub 账号提交的改动须本人对具体 PR / 版本审核批准、必要 CI 通过、评审对话解决后才可合并；追加可审查的新提交须重新审核。
- 本人 2026-10-19 授权的协作例外：由本人 GitHub 账号发起、本人和 AI 共同开发且处于用户已授权任务范围内的 PR，在当前版本必要 CI 全部通过、评审对话解决后，AI 可直接合并，无需逐 PR / head 再询问批准；新增提交后必须重新核对最新版本的 CI。AI 不代替本人 approve，不伪造审核，不将此例外用于第三方账号的 PR。仅持有 owner 凭据不构成任务授权，也不授权跳过 CI 或自行修改 GitHub 规则。
- 仓库权限、规则集、发布、真实客户端动作和安装各自需要对应授权，不能由 PR 或 CI 通过推定。具体目标设置与本人账号的协作例外见 `MAINTAINERS.md`，实际生效情况以 GitHub 为准。
- 公开 issue、PR、日志、截图和夹具遵守本文件的脱敏要求；安全问题按 `SECURITY.md` 私下报告。贡献者不自行升版本、打发布标签或发布安装包。

## 验证命令

```bash
swift build
swift test                       # 单测 + 守卫测试（ForbiddenAPITests）；live 套件默认跳过
IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test # CI / 普通贡献：显式关闭真实客户端和云端视觉测试
IMCTL_LIVE=1 swift test          # 需要真实企微客户端与辅助功能授权
bash scripts/check-secrets.sh    # warning-only：疑似 secret、IP、本机绝对路径
scripts/build-signed.sh          # 稳定身份重签（TCC 授权跨重建保持）
scripts/install-daemon.sh        # 复制到稳定目录并 kickstart 已装的 LaunchAgent
```

`.github/workflows/ci.yml` 的 `swift` 检查只做构建和非活体测试；`secrets` 检查用 Python 标准库拒绝特定高可信密钥格式及私钥。广泛扫描仍为 warning-only，退出码为 0 不能当作已经脱敏的证明；新文件、动态菜单、截图与公开讨论还需人工复核。CI 不使用仓库 secrets，不签名、安装或发布，不执行真实企微操作。

涉及发送、策略、观察者、传输或守护进程时，还必须对真实客户端做一次活体 E2E 并写 `docs/gates/<日期>-<批次>-<主题>.md`，写清条件、发送条数、证据和未闭环项。

## 禁止事项

- 禁止把 broker 地址、MQTT 凭据、视觉 API 密钥、企微 corpid / secret / agentid / 回调 Token / EncodingAESKey、代理 Bearer token、真实联系人标题或消息正文写入代码、测试、夹具、文档、提交信息或 wiki。
- 禁止修改 `WeComClient.fileTransferAssistantTitle` 或在代码里硬编码新的目标白名单。
- 禁止在 `KeystrokeInjector.swift` 之外使用 `CGEvent*` / `IOHIDPostEvent` 或输入监控 API；屏幕录制只允许上述按需单帧场景。B17 全窗上传仅限当前显式固定桌面命令、当前已验证的企微窗口，且屏幕录制、`cloudEnabled` 与 `fullWindowEnabled` 三门都通过；不得截取整屏、其它应用、后台观察轮询，也不得发送截图 URL、接收任意 API 地址、跟随重定向或自动转发给另一家。禁止在按键文件里加全局 tap、鼠标、PSN 投递，或已批准清单（回车、⌘1–⌘8、⌃Tab、⇧⌃Tab、⌘N、⌘V）之外的按键。
- 禁止绕过 `CommandExecutor` 直接调用适配器发送，禁止跳过 checkpoint 或在 `unknown` 后自动重试。
- 禁止提交 `.raw.json` 夹具、`docs/gates/*.raw.*`、`--no-redact` 输出、本机绝对路径、`.build/`、临时脚本。
- 禁止用夹具测试通过、`--dry-run` 输出或设计文档冒充活体验收；禁止在未安装 / 未授权时把 LaunchAgent、TCC 或 7 天运行写成已完成。
