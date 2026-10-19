# 测试分层规范

## 定位

`imctl` 控制的是真实客户端与真实账号，测试的重点是：纯逻辑在 fake 上可完整验证；对真实客户端的验证只在明确条件下做、只读优先、发送受限、结果写成门报告。"夹具测试通过"和"活体验收通过"是两件事，永远分开记录。

## 分层

| 层 | 工具 | 对象 | 何时跑 |
|---|---|---|---|
| 单元测试 | swift-testing（`@Suite` / `@Test` / `#expect` / `#require`），`FakeAXBackend`，`ControlStore(":memory:")`，`FakeHandler` / fake link | 协议类型、策略、执行器、存储、解析、动作、观察引擎、分发器、MQTT 绑定、CLI 解析与 `--from-fixture` 探针 | `swift test`，每次提交前 |
| 守卫测试 | `ForbiddenAPITests` 扫描 `Sources/` | 合成输入与额外 TCC API | 随 `swift test` |
| 混沌测试 | `IMCTL_CRASH_AFTER=submit`、`exitHook`、`CrashInjected` | submit 后 confirm 前崩溃 → 重启后 `unknown` 不重跑 | 单测 + 阶段 1 活体 |
| live 测试 | `IMCTL_LIVE=1 swift test` | `LiveAXBackend` 对真实客户端的只读假设 | 本机、有授权时 |
| 活体 E2E（门） | `imctld` + `imctl mqtt call` / socket 脚本 / `probe …` | 完整回路、观察延迟、归因、重放、常驻 | 每个批次收尾，写 `docs/gates/` |

公开 CI 的 `swift` 检查在 `macos-latest` 先构建，再显式以 `IMCTL_LIVE=0`、`IMCTL_LIVE_VISION=0` 跑 `swift test`。这关闭真实 AX 与视觉提供商测试，不需要企微账号、API 密钥、broker 或系统授权；首次解析 SwiftPM 依赖仍需联网。CI 不签名、安装、发布或做活体验收。

## 单元测试规则

- 解析逻辑对**录制并脱敏的夹具**（`Tests/Fixtures/ax-trees/`）或**合成夹具**（`GroupFixture` 这类测试代码）做测试；不依赖真实客户端。
- 动作测试断言 `FakeAXBackend.recordedSets` / `recordedActions`：策略拒绝前必须为空；成功路径只有预期的 set / action。
- 客户端反应用 `reactions` / `replaceChildren` / `mutate` 模拟（发送后出现气泡、清空输入框、预览变化）。
- 时钟、随机、进程退出、按键投递全部经闭包注入（`now`、`exitHook`、`postReturnKey`），测试不 sleep 超过必要（`verifyTimeout` 缩到 0.05–0.3 s）。
- 存储测试用 `:memory:`，覆盖迁移后的新表；不写本机路径。
- 每个 wire 错误码至少一个测试；`tools/list` 数量、CLI 子命令列表有测试，改协议 / 命令时同步更新。
- 测试不含真实联系人标题 / 正文；用 `文件传输助手`、`«hash»` 或合成名（`imctl测试群`、`小明·a1b2c3`）。
- B16 云端视觉测试只用**合成裁图和假传输**，不计费、不上传活体截图：先断言策略拒绝与 AX 唯一路径零截图 / 零请求，再断言候选 ID 严格匹配、AX 重读复核、裁图外合成像素不进入请求、三家固定官方端点 / 认证头 / 重定向拒绝、缺密钥 / 429 / 超时 / 坏响应失败关闭。日志与状态测试不得打印密钥、图片字节或企微内容；B16 时常规 MQTT 读取与观察的云端调用数为零。B17 新授权后，显式固定读取命令与后台观察须分别测试；旧配置缺少 `fullWindowEnabled`、只开 `cloudEnabled`、未获屏幕录制授权三种条件都要断言整窗截图和请求为零。
- B17 每个桌面协议方法至少覆盖一个正常多轮 fake 和一组失败分支；跨方法覆盖 AX 唯一时不上传、策略 / 暂停 / 白名单拒绝前不截图、窗口 PID / frame / 活动会话变化即停、伪造候选 ID / 越权动作 / 画面提示词注入无 AX 写、每轮重读、最大轮次和总时限、API 429 / 超时 / 畸形响应、缺授权 / 缺密钥 / 禁用、上传只含经验证的企微窗口单帧。测试用合成窗口与假传输，不录制真实正文。`message.send` / `message.sendFile` / 群与联系人修改及 `broadcast.confirm` 还需覆盖不可逆前 checkpoint、提交后证据不足为 `unknown`、同键回放无二次动作、模型失败不换键；`broadcast.confirm` 的旧 `{msgid}` 调用须验证稳定派生本机幂等键，泛化助手面板 / 不匹配 `msgid` / 多发送按钮须在 checkpoint 与 AXPress 前拒绝，`message.broadcast` 子命令仍逐个受原门禁。
- MQTT 契约测试覆盖同一固定命令从 `/cmd` 到受限 Response Topic `/rsp` 的 JSON-RPC 记录，Correlation Data 原样回显，`accepted/running/terminal` 的 `command.state` 顺序、`event.replay` 对账、超时后用同键得到同一 `commandId`。模型步骤、截图字节、密钥与原始输出不得进入响应 / 事件 / 日志；模型只能提供候选，方法结果须由 AX 后验状态决定。协议文档守卫除名称覆盖外还要核查本批数据与生命周期约定。

## 夹具录制与脱敏

```bash
.build/arm64-apple-macosx/debug/imctl dump-tree --root main-window --output Tests/Fixtures/ax-trees/wecom-<版本>-<视图>.json
.build/arm64-apple-macosx/debug/imctl dump-tree --root main-window --raw --output /tmp/x.raw.json   # 排障用，不提交
```

- 默认脱敏：保留 `文件传输助手`、UI 文案（按钮 / 菜单）、时间标签；其余文本替换为同一 dump 内一致的 `«hash»`。
- 录制后人工检查菜单中的动态账号名称、最近文件名与路径；即使位于按钮 / 菜单，也不得把个人或业务信息当作固定 UI 文案保留。
- 夹具文件名带客户端版本与视图；加载器注释写录制日期与用途。
- 不为了让测试通过手改录制夹具；需要不同形态时新建合成夹具。
- 真实客户群不录夹具；群解析用合成夹具，活体只在用户的测试群上校准。

## live 与活体规则

- 前置：企微客户端运行、窗口可达（可在另一 Space）、当前进程辅助功能 trusted（`imctl permission`）。
- 只读探针（`probe conversations|messages|watch`、`dump-tree`、`status`、`env`）可随时做；输出默认脱敏。
- 受限动作（`probe select|compose|scrollback|menu`）需 `--allow-*` 旗标且目标在白名单 / 策略内。
- 发送（`probe submit --auto --allow-submit`、`message.send`）只对白名单 / 策略允许的测试目标，先确认目标与条数，测试文本带批次前缀（如 `imctl-b4-…`），事后在门报告写明每一条。
- 守护进程活体依赖 launchd 下 `imctld` 自身的辅助功能授权；未授权时 `state.json` 为 `paused ["system"]`，活体结果只能写"待"。
- B16 的真实云端试点另需守护进程屏幕录制授权、本机云端开关与所选提供商密钥；先核对裁图区域和目标会话，再只在用户测试群做显式、可复核的受限动作。门报告分别记录云端请求数、耗时、AX 写和发送条数；第三方收到裁图这一事实须写明。缺任一条件不得把 fake 测试称为活体验收。
- B17 活体验收先用无发送的固定读取 / 导航命令，核对上传的是当前企微窗口、模型轮数 / 延迟、真实 AX 结果和 MQTT 回执；再对已允许的本人测试号或只有本人的测试群做受控发送 / 改动，逐项核对返回字段、终态事件与客户端证据。完整窗口可能包含非目标会话内容，门报告仅写**上传了经核验的企微窗口单帧及请求次数**，不保存或贴出原图。模型成功返回候选但未得到客户端证据的命令不得记为通过；未实测的方法标“待活体”。
- 活体不跑 `swift test`（会把 `.build/` 重签 ad-hoc）；活体用稳定副本或先 `scripts/build-signed.sh`。

## 门报告模板

文件：`docs/gates/YYYY-MM-DD-<批次>-<主题>.md`

```markdown
# 批次 <X>：<主题>（<日期时间 CST>）— <通过 | 部分通过 | 待活体>

条件：客户端版本、窗口 Space / 前台状态、传输（socket / MQTT / stdio）、broker（只写"用户 LAN 的 EMQX"）、发送目标与条数、测试文本。

## 实现
- 本批代码变化与测试数（对比上一批）。

## 单测
- `swift test` 数字；守卫测试。

## 活体 / 只读探针
| 步骤 | 结果 |
|---|---|
| … | 数字、延迟、事件 id、证据（脱敏） |

## 结论与未闭环
- 通过 / 机制成立效果待验 / 待用户决定 / 未做。
```

## 必跑命令

```bash
swift build
swift test
bash scripts/check-secrets.sh
IMCTL_LIVE=1 swift test        # 可选，本机有授权时
```

涉及高风险及以上改动时，再按门报告模板做一次活体 E2E 并提交报告。
