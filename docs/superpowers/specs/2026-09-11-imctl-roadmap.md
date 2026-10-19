# imctl 开发路线与阶段门

来源：个人 wiki `synthesis/imctl开发路线与阶段计划.md`（2026-09-11 版）。代码级任务计划在 `docs/superpowers/plans/`；门报告在 `docs/gates/`。工期是估算不是承诺；门失败改走后备并重跑，不跳门。

## 技术基线

Swift 6.3.3（Xcode 26.6，Build 17F113）、Swift 5 语言模式（`swiftLanguageModes: [.v5]`）、SwiftPM 单包、macOS 15+。依赖（2026-09-11 解析）：swift-argument-parser 1.8.2、GRDB 7.11.1、MQTT-NIO 2.13.0。

## 模块结构

| target | 类型 | 职责 | 依赖 | 加入阶段 |
|---|---|---|---|---|
| `ControlCore` | library | 协议类型（Codable）、命令状态机、阶段与不可逆点、SQLite 日志与幂等存储、暂停 reason set、事件游标；不依赖 AX 或网络 | GRDB | 1 |
| `AXKit` | library | 通用 AX 原语、AXObserver 桥接、权限检测；`AXBackend` 协议 + `FakeAXBackend`；不知道企微 | ApplicationServices | 0 |
| `WeComAdapter` | library | 解析会话表/消息区/输入框，方向与发送者推导，目标复核，发送阶段；对录制 JSON 夹具做单元测试 | AXKit, ControlCore | 0 只读 / 1 发送 |
| `imctl` | executable | CLI | 以上 + swift-argument-parser | 0 起 |
| `MCPTransport` | library | stdio JSON-RPC 2.0 绑定；阶段 1 测试驱动，生产默认关闭 | ControlCore | 1 |
| `imctld` | executable | LaunchAgent 守护进程 | 全部 | 2 |
| `MQTTTransport` | library | MQTT 5 绑定、enroll、遗嘱/retained state、重放 | MQTT-NIO, ControlCore | 2 |
| `WeComAPI` | library | 企微官方接口客户端（经令牌注入代理）、身份桥 | ControlCore | 3 |

目录：`Sources/<target>/`、`Tests/<target>Tests/`、`Tests/Fixtures/ax-trees/*.json`、`docs/superpowers/specs|plans/`、`docs/gates/`、`adapters/wecom/`（阶段 3）。

## 阶段 0：只读探针

| 门 | 探针 | 退出条件 |
|---|---|---|
| G0-1 TCC 身份稳定 | `imctl permission`，`imctl-dev` 签名后连续三次改代码重建 | 授权不再弹窗，`AXIsProcessTrusted` 持续为真 |
| G0-2 方向/发送者可推导 | `imctl probe messages` 对文件传输助手与一个内部会话 | 私聊稳定分 inbound/outbound；群能读到发送者标签；夹具测试通过 |
| G0-3 免焦点操作链（只读部分） | `probe select --allow-select 文件传输助手`、`probe compose --allow-compose "test" --clear` | 企微在后台/其他 Space/隐藏时 `AXSelectedRows` 切会话成功、输入框接受设值、发送按钮可定位；`AXPress` 留到阶段 1 |
| G0-4 锁屏遮挡下 AX 刷新 | `probe watch --seconds 28800` 合盖锁屏夜间运行，手机向文件传输助手发消息 | 新消息进入 AX 树的延迟可测且稳定，App Nap 未阻断；否则转 B |
| G0-5 账户/会话表/变化检测 | `imctl env`、`probe conversations`、`probe watch` 对比 AXObserver 与轮询 | 能读登录名/企业名与未登录态；外部私聊/外部群标记可识别；行失效重建后重解析可靠；选定策略并记录 CPU |

产出：`docs/gates/<日期>-phase0-report.md` 与同名 wiki query；A/B 决定写进 wiki topic 页。

## 阶段 1：核心与安全目标发送

- `ControlCore`：命令状态机、submit 前 checkpoint、GRDB 日志与幂等键、暂停 reason set、`event_id` 游标；fake 单元测试覆盖崩溃恢复（`IMCTL_CRASH_AFTER=submit` 注入）。
- `WeComAdapter` 发送路径 locate → open → verify_target → precheck_input → compose → submit → confirm；证据 = 匹配外发气泡；`local_guard` 检测。
- `MCPTransport` 作本地测试驱动。
- 门 G1：对文件传输助手 N 秒内观察到匹配气泡；submit 与 confirm 之间杀进程后重启为 unknown 且无重复；同键只发一次；同名会话拒绝；人留草稿时中止。**开始发送测试前向用户再确认一次。**

## 阶段 2：传输、完整回路与生命周期（v0.1 收口）

- `MQTTTransport`、`imctl enroll`、遗嘱/retained state、重放与 gap 对账；`imctld` LaunchAgent、电源断言、环境上报。
- 最小 Java 消费方只为跑通回路。
- 门 G2：受控外部客户（用户自己的微信）完整回路；锁屏、显示休眠、断网、客户端重启/升级、登出登入、手机接管各有结果；7 天连续运行；Developer ID 签名后 TCC 保持。

## 阶段 3 / v0.2

`WeComAPI` 与身份桥、令牌注入代理、客户群发送者识别、运行时能力降级与已验证版本表、签名配置包与 `adapter validate/activate/rollback`、远程 `admin.*`、智能体模式（千问 / DeepSeek）、菜单栏状态（可选）。每项进入前重新 brainstorming → writing-plans。

## v0.1 完成定义

1. 阶段 0–2 全部门关闭，或已改走后备方案并在后备上重跑并关闭。
2. `imctld` LaunchAgent 连续运行 ≥ 7 天（含夜间锁屏），`controller.state` 连续，日志审计零重复发送。
3. 文本自动回复完整回路在受控外部客户上跑通：`conversation.activity` → `conversation.read` → `message.send` → `ui_observed`，经 MQTT 与最小 Java 消费方，记录中位延迟。
4. 暂停/恢复、`origin: other` 接管信号、submit 与 confirm 之间崩溃后的 `unknown` 处理均有混沌测试结果。
5. Developer ID 签名，TCC 授权跨更新保持。
6. wiki 有 `repos/imctl.md`、各阶段门报告 query，topic 页口径改为实测。

## 首个冲刺 S0–S7

| # | 任务 | 验收 |
|---|---|---|
| S0 | 环境核对 | xcode-select 指向 Xcode、Swift 6.3.3、gh 已登录、git 身份 |
| S1 | 建仓、Package.swift、.gitignore、README、specs 移植、推送私有远端 | `swift build` 通过，远端存在 |
| S2 | `AXKit` 原语 + `AXBackend` / `FakeAXBackend` + 单元测试 | fake 测试通过；live 需 `IMCTL_LIVE=1` |
| S3 | CLI `permission` / `env` / `dump-tree` / `version`，默认只读 | 对真实企微 `dump-tree` 无动作，输出存夹具与 `docs/gates/` |
| S4 | `imctl-dev` 签名接入构建，重建三次验证 G0-1 | 授权只弹一次 |
| S5 | `WeComAdapter` 只读解析 + `probe conversations` / `probe messages` | 夹具测试通过 |
| S6 | `probe watch`（AXObserver vs 轮询）、`probe select` / `probe compose --clear`（白名单 + `--allow-*`） | G0-3 只读部分与 G0-5 结果；白名单外一律拒绝 |
| S7 | 夜间合盖锁屏 `probe watch`，写门报告，同步 wiki | 五道门各有结论 |

## 工程规则

- TDD：ControlCore、状态机、日志、幂等、适配器解析先写失败测试；AX live 测试隔离在 `IMCTL_LIVE=1`。
- 动作策略默认拒绝，策略在代码里不在配置里。
- 禁止合成键鼠事件、禁止申请录屏与输入监控权限。
- Swift 5 语言模式起步，严格并发阶段 2 再评估；避免 `!` 与 `unsafeBitCast`。
- 小步提交，`feat/fix/test/docs/chore` 前缀与 AI 协作署名。
- 不提交 secret、凭据、客户数据；夹具脱敏（标题替换为占位符，仅保留文件传输助手）。

## 风险与回退

| 风险 | 表现 | 回退 |
|---|---|---|
| 输入框不接受程序化设值或发送按钮无 AX 动作 | G0-3 / G1 失败 | 方案 B 虚拟机（`CGEventPostToPid` 只作救急验证，不进主线代码） |
| 锁屏下 AX 树不刷新 | G0-4 失败 | 不锁屏（政策）或方案 B |
| ad-hoc 签名反复授权 | G0-1 失败 | `imctl-dev` 自建证书；仍失败则提前申请 Developer ID |
| 企微升级改变 AX 结构 | 夹具测试失败 | 重录夹具、改选择器；阶段 3 配置包机制正式化 |
