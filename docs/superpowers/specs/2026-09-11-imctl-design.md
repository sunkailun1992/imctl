# imctl 设计规格（v0.1 草案）

来源：个人 wiki `topics/macOS企业微信Rust控制器与Java对接.md`（标题 imctl，2026-09-11 版）。本文只移植设计口径；证据链与变更史留在 wiki。协议字段未冻结，任何一项经真实验证后以实测覆写。

## 1. 定位

imctl 是 macOS 消息端控制器：Swift 常驻进程控制本机企业微信（后续个人微信），通过统一控制协议接受 Java 业务服务或智能体的命令，回传状态与事件。命名：CLI `imctl`、守护进程 `imctld`、协议 IM Control Protocol。

## 2. 已定决策

1. **部署**：员工日常使用的 MacBook，坞站合盖运行（外接屏、AC、`SleepDisabled`），员工不碰企微/微信。控制器与人共用一个 macOS 会话，不共用企微；一机一账号一 `controller_id`。
2. **本地执行器 Swift 单一代码库**，含企微客户端 UI 路线与官方 API 路线；API 优先、无法调用的能力才走 UI；路线按能力静态决定并写进能力描述。
3. **Java 只发控制命令、只做消息业务**：不对接企微 API，不感知桌面客户端；目标只用 `external_userid` / `chat_id`。
4. **云端只有令牌注入代理**：固定出口 IP、持 corp secret、刷 access_token、转发 HTTPS，不含企微语义。会话存档 SDK（`WeWorkFinanceSdk`）只有 Linux/Windows 库，是唯一云端例外。
5. **边缘接入 MQTT**，JSON-RPC 2.0 作信封；智能体经 MCP 绑定复用同一核心。
6. **无 GUI**：LaunchAgent + `imctl` CLI；权限面只有辅助功能。签名配置包双槽验证/激活/回滚；配置只管"在哪找"，代码管"能不能动"。
7. **硬约束**：不发合成键鼠事件（禁用 `CGEvent`），全部走 AX 动作；企微窗口独立 Space 并隐藏，系统层关闭企微通知。隔离方案 A（同会话纯 AX）先验证，B（macOS 虚拟机）为后备，C（第二用户会话）不推荐。
8. **命令阶段** locate → open → verify_target → precheck_input → compose → **submit（不可逆点）** → confirm；submit 前落盘 checkpoint，重启后"有 checkpoint 无证据"一律 `unknown`、绝不重跑。暂停是 reason set `{api, local_guard, system}`。
9. **大模型 API 控制**（首期千问/DeepSeek）只在回复内容、异常处理、维护三处进入循环，不进入执行步骤；属 v0.2。

## 3. 分层与职责

| 层 | 责任 |
|---|---|
| Java 业务服务 | 业务身份映射、AI/RAG、回复策略、群路由、按会话的人工接管策略、业务审计 |
| 控制协议 | 方法与事件、能力/版本、标识分层、命令状态与证据、错误分类、重放与幂等约束；平台中立并带 `platform` |
| imctl（Swift） | AX 原语、企微 UI 适配器、企微 API 客户端、单串行执行器、日志与幂等存储、暂停/互锁、技术审计、配置包与自检、身份桥 |
| 令牌注入代理 | 固定 IP、secret 托管、token 注入；无业务、无企微语义 |

决策 vs 机制：Java 决定"回不回、回什么"；imctl 决定"此刻能否执行"（客户端就绪、未暂停、输入框未被占用、限速硬上限）与"目标复核是否一致"。imctl 从不自动重试，`unknown` 对它是终态；Java 重试必须换新幂等键。

## 4. 协议语义（未冻结）

- **证据阶梯**：可见消息、会话活动信号（低保真）承诺；完整入站事件**不存在**；客户端提交并观察到外发气泡是 `succeeded`；平台送达永远 unknown；API 路线另有更强的 `platform_ack`。
- **读模型**：会话表 diff 出 `conversation.activity`；Java 按需 `conversation.read`（改变客户端活动会话）；发送前本来就要打开并复核会话；不定时遍历全部会话。
- **方法**：`controller.describe`、`account.status`、`conversation.list`、`conversation.read`、`message.send`（异步、只文本）、`command.get` / `command.cancel`、`controller.pause` / `controller.resume`。
- **事件**：`controller.state`、`account.changed`、`conversation.activity`、`message.observed`（仅当前会话，带 `direction` / `sender_label` / `origin`）、`command.state`。
- **标识分层**：JSON-RPC `id` 只关联请求响应；`idempotency_key` Java 生成、控制器持久化 ≥ 24h；`command_id`、`event_id`（单调）控制器生成；`conversation_ref` 是"指纹 + 最后已知位置"的短期句柄，不是 AX 指针也不是平台 ID。
- **命令状态**：accepted / running / succeeded / failed / unknown / cancelled / expired。过期用相对 `ttl_ms` 加 `issued_at`（算传输延迟）。
- **目标复核**：控制器把 `external_userid` 解析为自己通过 API 设下的备注标题并核类型：0 个 `TARGET_NOT_FOUND`、多个 `TARGET_AMBIGUOUS`、打开后不符 `TARGET_MISMATCH`，绝不发；每条命令带账户指纹。
- **暂停**：Java 只能增删 `api`；`local_guard` 防意外触碰（人留草稿、人正在操作）；`system` 覆盖锁屏、未登录、AX 失权、显示休眠。手机接管以 `origin: other` 的外发气泡为信号，按会话静默是 Java 策略。
- **MQTT 语义**：响应是便利、事件是真相（共享订阅、任一 Java 实例落库）；QoS 1 下所有方法必须幂等；遗嘱消息 + retained state 表存活；重放两层——broker 缓冲是快路径、控制器日志按 `event_id` 重放是真相；每台 Mac 独立凭据与 topic ACL（`im/{id}/cmd|rsp|evt|state`）。
- **运行时降级**：未经适配验证的企微版本自动只读，`describe` 标 `degraded: untested_client_version`。本地日志含正文：FileVault、保留期、脱敏。

## 5. 平台能力与路线

| 能力 | 路线 | 依据与限制 |
|---|---|---|
| 员工↔客户私聊、客户群即时发送 | 仅 UI | 官方无对应即时发送接口 |
| 入站消息观察 | UI 可见窗口 | 会话存档只适合延迟审计，SDK 仅 Linux/Windows |
| 入群二维码、客户备注（身份桥）、客户/群 ID | 官方 API（经代理） | 需自建应用客户联系权限、可见范围、可信 IP；`add_join_way` 用 `state` 承载幂等键 |
| 建群 + 拉外部客户 | UI 复合流程，v0.1 之后 | 无 API；风控风险最高 |
| 个人微信 | 后续适配器 | 无普通账号官方发送接口，封号风险远高于企微 |

企微 API 在 Swift 侧约十个接口（`externalcontact/list`、`remark`、`groupchat/*`、`user/get` 等），URLSession + Codable 手写，token 全在代理。

## 6. 生命周期与本机环境

- 合盖运行：外接屏持续绘制；控制器自持禁止空闲显示/系统休眠断言；**锁屏遮挡下企微 AX 树是否刷新是 P0 门**。
- 无人值守 ≠ 零接触：登录失效报 `login_required`，人扫码；企微/macOS 更新靠运行时降级 + 已验证版本表。
- 开发机 2026-09-11 快照：macOS 26.6.2 arm64，`AppleClamshellState = Yes`，`SleepDisabled 1`，两块外接屏，AC；企微 `com.tencent.WeWorkMac` 5.0.10。

## 7. 可替换机制与运维接口

- 可换项：签名的适配器配置包（选择器、路由表、版本表；不重启）、运行参数、凭据（只本地 CLI，`imctl enroll` 一次）、平台适配器模块与控制器本体（签名二进制）。
- 三条规则：配置只管"在哪找"、代码管"能不能动"；双槽候选 → `selftest` 只读校验 → 激活 → 可回滚；配置包与二进制都签名，公钥编进二进制。
- `imctl` CLI（install / status / pause / resume / permission / env / config / adapter / dump-tree / probe / selftest / logs / update / enroll）是 v0.1 唯一运维界面；远程 `admin.*` 独立 ACL 与签名；MCP 绑定开发期给智能体，生产默认关闭或只读。

## 8. 验证顺序

阶段 0 只读：独立进程 TCC 身份稳定 → 消息方向可推导 → 免焦点操作链 → 锁屏遮挡下 AX 刷新 → 账户/会话表/变化检测。阶段 1 对文件传输助手：发送证据、不可逆点与 unknown、幂等/目标复核/互锁。阶段 2 受控外部客户：完整回路、桌面生命周期、MQTT 绑定。阶段 3：客户群、官方 API 线、智能体模式。对文件传输助手的只读观察不关闭任何一门。

## 9. 边界与禁区

- 任何阶段不向真实联系人或客户群发消息；阶段 0 只读加受限动作；阶段 1 发送只对文件传输助手且开始前再确认；白名单编译进代码，扩大需人决定。
- 不用固定坐标、标题同名或点击成功代替会话身份与送达证据；方向未知的消息不驱动自动回复；可见预览不冒充完整入站。
- 大模型不进入每条回复的执行步骤；模型提出的配置变更必须走签名与验证流水线；生产员工 Mac 上不做完全自主的适配器自修复。
- 官方能力分别判断：客户群入群方式、群发、会话存档、微信客服、智能机器人互不推定。
