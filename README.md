# imctl

macOS 消息端控制器（IM Control Protocol）。一个 Swift 常驻进程（`imctld`）加运维 CLI（`imctl`），在员工日常使用、坞站合盖运行的 MacBook 上控制本机企业微信客户端：通过 Accessibility 读会话与消息、发送文本，通过企微官方 API（经云端令牌注入代理）做身份桥；接受 Java 业务服务或智能体经 MQTT / MCP 下发的控制命令，回传状态与事件。

这是按 [Apache-2.0](LICENSE) 发布的个人开源项目，与腾讯、企业微信没有隶属或官方授权关系。使用者需自行确认账号、组织和相关平台允许的使用范围，并对自己的操作与数据处理负责。

欢迎通过 issue 和 PR 参与。开发说明、协议和安全边界都在本仓库内，不需要访问维护者的私人知识库。所有改动经分支和 PR 提交，由 [@sunkailun1992](https://github.com/sunkailun1992) 本人审核后才可合入 `main`；详见 [贡献指南](CONTRIBUTING.md) 与 [维护规则](MAINTAINERS.md)。

个人项目。当前阶段：**阶段 2**（阶段 0 五道门已有结论；发送、幂等、崩溃恢复、本地传输与 MQTT 5 边缘接入已在文件传输助手 + EMQX 上端到端验证；B3 起 `imctld` 由 AX 通知驱动观察、`message.observed` 带 `origin` 接管信号、`message.history` 可回读历史、`event.replay` 供消费方对账，见 `docs/gates/`）。LaunchAgent 安装、EMQX 凭据/ACL、Java 消费方三项等用户决定：命令与文档已备好（`docs/ops/`、`docs/protocol/`）。

验收结果限于各份 `docs/gates/` 记载的版本、方法和条件。设计、fake 测试和 CI 通过不代表所有客户端版本或真实账号均已验证；未完成的活体项目仍按报告中的「待活体」处理。

## 硬规则

1. **不发全局合成键鼠事件。** 全部走 AX 动作（`AXSelectedRows` / `AXValue` / `AXPress`）。例外只有对企微进程 pid 投递的按键（`CGEventPostToPid`，仅 `KeystrokeInjector.swift`），批准过的就这几个：submit 步骤一次回车（用户决定 2026-09-12）；B7 通讯录导航用客户端自身快捷键 ⌘1–⌘8 / ⌃Tab / ⇧⌃Tab（用户 2026-09-15 批准）；发起群聊的 ⌘N 与选人面板搜索框上的一次回车（2026-09-15 活体校准新增，用户 2026-09-15 16:3x 批准）；B13 发文件把 outbox 文件 URL 粘进输入框的 ⌘V（用户 2026-09-22 17:43 批准）。再多一个按键都要用户先决定，并在仓库规格及 PR 中记录脱敏的授权依据，不是改代码就算；其余文件出现 `CGEvent` 等符号会被 `swift test` 拦截（`ForbiddenAPITests`，它同时校对上面这份按键清单）。
2. **辅助功能优先，截图按用途隔离。** B15 对方向未知的可见图片行做本机单帧判向，不上传。B16 仅在「添加群成员」按钮歧义时向所选视觉模型发送按钮裁图。B17 为显式固定桌面命令增加独立的整窗辅助许可，只截取经进程和窗口核验的企微主窗。B34 在整窗许可已启用且目标尚未活动时，让 `conversation.read` 及 `message.send`、`message.sendFile`、`group.rename`、`group.addMembers` 的目标选择主动经过视觉模型；即使已有唯一解析出的 AX 行，也执行选择前观察、AX 动作后的新鲜截图模型复核，并以 AX 活动标题严格验证结果。B35 在显式 `message.history` 确需回到最新或向更早消息滚动且只有一个可见可写消息滚动条时，以及显式 `contact.request.list` / `contact.request.accept` 进入「新的客户」需选择唯一可见、未选中的精确 AX 行时，也进行动作前后两轮视觉观察，最后分别读 AX 消息条与补入的旧行、或选中行与表。`message.history` 的两种滚动分支和 `contact.request.list` 的未选中分支各有真实千问两轮、MQTT 终态和 AX 后验证据；`contact.request.accept` 的提交没有活体写入验收。B36 为直接调用的 `message.send` / `message.sendFile` 增加唯一输入框暂存前后两次被动视觉观察，提交仍由固定 AX 动作、checkpoint 和客户端新外发消息证明；当前只有源码与 fake 测试，视觉发送活体待验。B40 在显式 `client.navigate` 可由 AX 预测下一会话时，于既有窗口菜单动作前后被动观察企微主窗口；菜单始终由固定 AX 路径操作，不给模型选择。release build 224 经 MQTT 对下一个 / 上一个会话各完成 2/2/2，并由独立 AX 证明离开和恢复本人会话；同一安装版的 `contact.list` 与加成员 `dryRun` 也有各自限定视觉验收，见 `docs/gates/2026-09-26-b45-visual-mqtt-release.md`。无须动作或整窗视觉关闭时沿 AX 路径；模型不能决定正文、文件、成员或发送动作。其余桌面步骤仍走各自的 AX 路径或受限视觉后备。截图和模型原文不进入命令响应；后台观察和自动申请不上传，旧 B16 云端开关不会自动启用整窗许可。逐方法活体证据见 `docs/gates/2026-09-26-b17-visual-coverage-audit.md`，不能把这些限定分支概括成所有桌面命令都已视觉验收。
3. **目标白名单编译进代码。** 阶段 0/1 只允许「文件传输助手」；任何阶段不向真实联系人或客户群发消息；扩大白名单是人的决定——B4 起只能经本地 `policy.json`（`imctl policy allow|deny|list`，0600，按标题 / 会话类型 / `chat_id` / `external_userid` 放行，`imctld` 热加载并发 `controller.state{policy}`），`unknown` 类型永远不能被类型规则放行；唯一例外是 `allowAll`（`imctl policy all`，B14 用户 2026-09-22「全部放开」决定），默认关、只本机、`policy.set` 不接受，开启会写守护进程日志（policy reloaded … allowAll=true）。
4. **改变客户端状态的原语默认拒绝**，全部经策略层（白名单、暂停状态、阶段授权）。
5. **仓库不含 secret、凭据、真实联系人内容。** AX 夹具录制后脱敏。
6. `submit` 是不可逆点：提交前落盘 checkpoint，重启后"有 checkpoint 无证据"一律 `unknown`，绝不重跑。

## 模块

| target | 职责 | 阶段 |
|---|---|---|
| `ControlCore` | 协议类型、命令状态机、日志与幂等、暂停 reason set；不依赖 AX 或网络 | 1 |
| `AXKit` | 通用 AX 原语、`AXBackend` 协议 + `FakeAXBackend`；不知道企微 | 0 |
| `WeComAdapter` | 企微 AX 树解析（含群会话：发送者、系统消息过滤、`messageKey`、会话类型推断、群头部成员数）；对 AX 方向未知、可能是图片的可见无文本媒体行按需截取企微窗口单帧，在内存中判断左右；目标解析（`chatId:` / `externalUserId:` 经身份桥）与复核、发送阶段；B13 文件发送（outbox → ⌘V → 回车）与 file / video 行；B14 已建群二次添加成员（添加群成员表单） | 0 只读 / 1 发送 / B4 群 |
| `imctl` | CLI：`permission` `env` `dump-tree` `probe …` `status` `call` `enroll` `mqtt` `agent` `policy` `policy hosts` `policy all` `identity` `wecom` `oss`；`probe submit/select/compose` 需 `--allow-*`；`probe addmembers` 只读（列出「添加群成员」表单的行，脱敏，自动取消）；`agent install` 只在用户决定后执行 | 0 起 |
| `MCPTransport` | 行分隔 JSON-RPC 2.0（兼容 MCP `initialize`/`tools/*`），stdio 与 Unix socket；`event.replay` 查询（不建命令记录） | 1 |
| `imctld` | 守护进程：执行器 + watcher（`WatchEngine`：AXObserver 通知去抖触发 + 兜底轮询，`message.observed.origin` 归因）+ 传输 + 状态文件（`run --stdio --socket <path> --mqtt [--no-observe] [--watch-interval]`） | 1 |
| `MQTTTransport` | MQTT 5 绑定（EMQX 实测）：`…/cmd` 命令、Response Topic 响应（只接受 `im/<id>/` 子树内的回复 topic）、`…/evt` 事件泵（游标可重放）、`…/state` retained + 遗嘱；`imctl enroll` / `imctl mqtt call|tail` | 2 |
| `imctl-console` | 菜单栏测试控制台（SwiftUI）：状态 / 会话 / 发送 / 通讯录 / 事件 / 策略 / 设置 / 诊断 / 日志 / 对接文档（随包附带的 `docs/protocol/*.md`，页面每 5 s 检查文件变化）；会话附件按需获取签名地址，不自动下载或播放；B14 策略页新增全部放开开关（二次确认）/ 按类型放行 / chatId·externalUserId 名单，通讯录页新增「添加到现有群」（先试跑）；改客户端状态只经 `imctld` 套接字（与 Java 同一路径），进程内只做只读诊断与 0600 配置文件写入；`scripts/build-app.sh` / `scripts/build-pkg.sh` 出 `imctl.app` 与 `.pkg`（`docs/ops/installer.md`） | B6 |
| `WeComAPI` | 企微官方接口客户端（经令牌注入代理，Bearer 鉴权，secret 不落本机）：`group.*` / `contact.*` / `broadcast.*` 方法、身份桥回写；`imctl wecom enroll|status|call|sync-groups`；未 enroll 时这些方法回 `UNSUPPORTED`；契约 `docs/protocol/wecom-token-proxy.md` | 3（B5） |
| `OSSClient` | 阿里云 OSS 对象存储（V4 签名，PUT / HEAD / GET / DELETE / 预签名 GET）：`message.media` 把图片 / 文件 / 视频封面传上去回签名地址，`message.sendFile{ossKey}` 从中下载；`oss.json`（0600）、`imctl oss set|status|test`；未配置回 `OSS_NOT_CONFIGURED` | B13 |

## 构建与测试

需要 macOS 15+ 和 Xcode 的命令行工具。`Package.swift` 的工具版本声明为 6.0；当前锁定依赖要求 Swift 6.2+，开发基线见本节末尾。普通构建与 fake 测试不需要企业微信账号、MQTT broker、视觉 API 密钥或辅助功能授权。

```bash
git clone https://github.com/sunkailun1992/imctl.git
cd imctl
swift --version
swift build
IMCTL_LIVE=0 IMCTL_LIVE_VISION=0 swift test
```

CI 的 `swift` 检查在 `macos-latest` 构建并运行上述非活体测试；`secrets` 检查拒绝特定高可信密钥格式与私钥。它不覆盖所有个人信息，`scripts/check-secrets.sh` 的广泛告警也仍需人工逐条判断。CI 不运行真实企微或云端视觉，不签名、安装或发布应用。

下面是本机运维与真实客户端命令。先阅读 [权限说明](docs/ops/permissions.md)，涉及修改客户端状态时遵守本地策略与测试目标限制：

```bash
swift build
swift test
IMCTL_LIVE=1 swift test   # 额外跑需要真实企微客户端与辅助功能授权的 live 测试
scripts/build-signed.sh   # 构建并用稳定身份重签 imctl 与 imctld（identifier com.sunkailun.imctl），辅助功能授权才能跨重建保持
.build/arm64-apple-macosx/debug/imctld run --stdio          # JSON-RPC/MCP over stdin/stdout（Claude Code / Codex 可直接接）
.build/arm64-apple-macosx/debug/imctld run --socket /tmp/imctl.sock   # 本地 Java 用行分隔 JSON-RPC
IMCTL_CRASH_AFTER=submit imctld run --stdio                 # 混沌：submit 后 confirm 前退出，重启后该命令 unknown
imctl enroll --broker <host>[:1883] [--controller-id <id>] # 写 ~/Library/Application Support/imctl/mqtt.json（0600，不入库）；id 默认沿用已登记的，否则取本机名小写
imctld run --mqtt                                           # 连 broker：im/<id>/{cmd,rsp,evt,state}
imctl mqtt call message.send --params '{"target":"文件传输助手","text":"hi","idempotencyKey":"k1"}'
imctl mqtt tail --seconds 10
imctl agent install --dry-run --mqtt                        # 只打印 LaunchAgent plist；真正安装是用户的决定（docs/ops/launchagent.md）；B6 起默认带 --socket（--no-socket 关闭）
imctl call client.navigate --params '{"action":"nextConversation","idempotencyKey":"n1"}'   # 经本地套接字：窗口菜单「选择下一个会话」（previousConversation / nextUnreadConversation）
imctl probe menubar                                         # 只读：列出「窗口」菜单项与 enabled 标记
imctl probe rail                                            # 只读：导航栏角标对 / 锚点列与「通讯录」计数能否归属（只输出计数与几何）
scripts/build-app.sh debug && scripts/build-pkg.sh debug    # out/imctl.app（控制台 + CLI + 守护进程，签名）与 out/imctl-<版本>.pkg（docs/ops/installer.md）
imctl policy list                                           # 编译白名单 + policy.json 规则 + 有效标题
imctl policy allow --title <测试群名> [--type group] [--chat-id <id>] [--external-user-id <id>]   # 放宽是人的决定；imctld 下一次轮询内生效
imctl identity set --kind group --id <chat_id> --title <群名>   # 身份桥（B5 由企微 API 填充前的手工入口）
imctl mqtt call message.send --params '{"target":"chatId:<id>","text":"hi","idempotencyKey":"k2"}'   # 目标语法：标题 | chatId:<id> | externalUserId:<id>
imctl wecom enroll --proxy https://<proxy-host> --token-stdin              # 代理地址 + 本机 Bearer token（0600；secret 只在代理）
imctl wecom sync-groups                                                     # groupchat/list+get → 身份桥 chat_id↔群名
imctl mqtt call group.joinway.create --params '{"chatIds":["<chat_id>"],"autoCreateRoom":true,"roomBaseName":"imctl群","roomBaseId":1,"state":"ch1"}'   # 群活码（结果 configId → group.joinway.get 取 qrCode）
```

执行器硬上限：同一会话 ≥ 3 s（`chatId:` / `externalUserId:` 经身份桥解析，与标题写法共用一个间隔）、全局 ≤ 20 条/分钟（按尝试计数），超出 `RATE_LIMITED`。守护进程对"客户端不暴露的面板"（无消息表 / 输入框 / 头部）只降级不暂停，连续 10 次失败才 `system` 暂停。`message.observed` 带 `sender` / `messageKey` / `conversationType` / 身份桥命中的 `chatId` / `externalUserId`；系统消息与时间分隔行不产生观察事件。

普通 `message.history` 先把当前会话的企微消息区定位最新，再返回最新行；无法证明到底部时明确报错，watcher 不执行此滚动。`message.history` 参数 `{"limit":40,"scrollback":true}` 会先把消息区滚到顶让客户端加载更早的历史（`gateReads` 开启时仅限策略放行会话；纯 AX，滚动条 `AXValue` / `AXScrollUpByPage`），读完滚回底部。`message.observed.origin`：`controller`（我们发的，带 `commandId`）/ `other`（人从手机或桌面发出 = 接管信号）/ `peer` / `unknown`。

对真实客户端跑探针前：`.build/arm64-apple-macosx/debug/imctl permission --prompt --open-settings`，在系统设置 › 隐私与安全性 › 辅助功能 里勾选 `imctl`。安装后的完整授权由 `~/Applications/imctl.app/Contents/MacOS/imctl setup` 请求，并用 `setup --check` 读回；屏幕录制是本机 TCC 授权。云端视觉还须配置提供商密钥并启用；整窗辅助需在本机另外执行 `imctl vision full-window --enable` 或从控制台「设置 → 视觉识别」开启。`setup --check` 通过不代表云端视觉或整窗辅助已启用。见 `docs/ops/permissions.md`。装好后用 `imctl doctor` 看每项功能是否可用与修复命令（`--fix` 逐项询问并执行修复，先确认）；控制台首次打开、未就绪时会弹出初始化向导，之后在「体检」页逐项点按钮修复。

基线：Swift 6.3.3 / Xcode 26.6 / Swift 5 语言模式 / macOS 15+。依赖版本（2026-09-11 解析）：swift-argument-parser 1.8.2（已引入）；GRDB 7.11.1、MQTT-NIO 2.13.0 按阶段引入。

## 权限与数据去向

- 本机 Accessibility 用于读取和操作企业微信窗口；按需单帧捕获另外需要屏幕录制权限。系统授权与 imctl 的云端开关分别控制，不可互相替代。
- B15 媒体方向判断在本机内存中完成；B16 在规定的控件定位分支向所选官方视觉 API 发送裁图。整窗辅助须另行在本机启用 `fullWindowEnabled`；启用后，显式固定读取命令也可能上传经核验的企微窗口单帧，其中可能含聊天正文、头像及其他会话预览。
- 云端视觉使用用户选定的千问或 Gemini 等已实现分支；具体支持范围与开关见 [权限说明](docs/ops/permissions.md) 及 [安全规范](docs/ai-coding/SECURITY_CODING_SPEC.md)。密钥只在本机配置，不能从 MQTT 远程开启云端或指定任意上传端点。imctl 不保证第三方提供商零留存。
- 后台 watcher、自动轮询及 B15 媒体方向补证据不得上传。截图、裁图和模型原文不进入仓库、日志、事件或协议响应；命令、事件及 checkpoint 中的业务数据留在本机存储，MQTT 事件按用户配置发送到 broker。

只使用自己或组织明确允许处理的数据。报告问题前先脱敏；安全问题按 [SECURITY.md](SECURITY.md) 私下报告。

## 参与开发

- [CONTRIBUTING.md](CONTRIBUTING.md)：开发环境、检查命令、fork / 分支 / PR 流程、AI 协作与脱敏要求。
- [MAINTAINERS.md](MAINTAINERS.md)：本人审核、合并与发布权限，以及 GitHub 规则的目标。
- [AGENTS.md](AGENTS.md)：AI 工具入口与工程边界；这些安全约束同样适用于人工贡献。
- [SECURITY.md](SECURITY.md)：漏洞报告与支持范围。

## 许可证

Copyright 2026 sunkailun1992。代码与文档按 [Apache License 2.0](LICENSE) 授权；第三方依赖继续适用各自的许可证。

## 文档

- `AGENTS.md` + `docs/ai-coding/` AI 编程规范入口：阅读顺序、分层与策略层次、目录、注释、设计模式、工程门禁、安全、测试分层、批次流程；改代码前先读
- `docs/superpowers/specs/` 设计规格与路线（从个人 wiki 移植）
- `docs/superpowers/plans/` 每个任务的代码级 TDD 计划
- `docs/gates/` 阶段门报告
- `docs/ops/` 运维：`launchagent.md`（常驻形态与验收清单）、`installer.md`（`imctl.app` / `.pkg` 产物、签名公证、控制台三步）、`emqx-auth-acl.md`（每机凭据与 ACL）
- `docs/protocol/im-control-protocol.md` **对外协议唯一权威**（MQTT topic、JSON-RPC 信封、全部方法 / 事件 / 错误码、重放、企微回调事件；`ProtocolDocTests` 保证与代码同步）
- `proxy/wecom-token-proxy/` 令牌注入代理（Java 17 / Spring Boot 4 / Maven；token 缓存、路径白名单、Bearer、回调验签解密 → MQTT `wecom/{corpId}/evt`；`mvn -q test`、`Dockerfile`）
- `examples/java-consumer/` Java 参考消费方（共享订阅、`(source,eventId)` 去重、`event.replay` 对账、渠道开关欢迎语、群白名单、`origin:other` 静默、可插拔 AI 回复）
- `examples/protocol-sim/` Python 协议模拟器与驱动：`python3 -m imctl_sim.cli --broker memory:// demo` 离线跑完整回路；对真实 broker / imctld 跑 `call` / `tail` / `demo`；`wecom_direct.py` 直接调企微取二维码（验证用）
- `docs/protocol/java-consumer.md` Java 消费方视角补充（订阅、命令、幂等键、`origin`、gap 对账）；`docs/protocol/wecom-token-proxy.md` 令牌注入代理契约
- `Tests/Fixtures/ax-trees/` 脱敏后的 AX 树夹具
