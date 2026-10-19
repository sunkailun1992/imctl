# AI 工程门禁规范

本文档用于约束 AI 生成或修改代码进入 `imctl` 的工程门禁。AI 可以加快控制器开发，但不能替代对真实客户端的活体验证、用户对白名单 / 策略 / 权限 / 部署的决定、安全检查、人工 Review 和回滚。

## 1. 核心原则

1. AI 生成内容默认不可信，必须经过 diff、`swift build`、`swift test`（含 `ForbiddenAPITests`）、secret 扫描和 Review 后才能合入。
2. 任何向客户端发送的路径都必须经过 `CommandExecutor`（幂等键、过期、暂停、速率）与 `ActionPolicy`（阶段、启用、目标、白名单 / 策略）；新增入口默认拒绝，只能显式放行。
3. `submit` 是不可逆点：提交前落盘 checkpoint；崩溃后 `unknown` 不重跑；同键回放既有结果；`unknown` 不由控制器自动重试。
4. 合成输入只允许 `KeystrokeInjector.swift` 对企微 pid 投递的按键，且只有已批准的这几个：回车（submit，2026-09-12；选人面板搜索框，2026-09-15 16:3x）、⌘1–⌘8 / ⌃Tab / ⇧⌃Tab / ⌘N（B7 导航，2026-09-15）、⌘V（B13 发文件，2026-09-22 17:43）；再加一个按键要先有用户决定，并在仓库规格与 PR 记录脱敏依据，维护者可另行同步私人 wiki。权限面限于辅助功能与 2026-09-24 批准的单帧屏幕录制；B16 允许的云端视觉只传裁剪控件图，见 `SECURITY_CODING_SPEC.md`。
5. 事件是真相：`event_id` 单调、无空洞、可重放；响应可丢；QoS 1 下方法幂等。
6. AI 不得写入或泄露 broker 地址、MQTT 凭据、企微应用参数、代理 token、真实联系人标题与正文。
7. 供应链门禁至少覆盖编译、测试、secret 扫描；新增 SwiftPM 依赖必须固定 `from:` 版本并在 `Package.resolved` 里可审查。

## 2. 风险分级

| 风险级别 | 变更类型 | 门禁要求 |
|---|---|---|
| 低风险 | README、AI 规范、注释、gate 报告文字、无行为变化的文档整理 | `git diff` 检查无凭据、broker 地址、真实联系人内容、本机绝对路径 |
| 中风险 | 只读解析（布局、行、头部、类型推断）、CLI 只读探针、夹具、纯逻辑重构、测试补充 | `swift test` 通过；夹具脱敏；对真实客户端只做只读探针并把结果（脱敏）写进门报告 |
| 高风险 | 改变客户端状态的动作、策略与目标解析、观察引擎与事件字段、执行器、存储迁移、传输绑定、守护进程装配、CLI 写命令（`enroll` / `policy` / `identity` / `agent`） | `swift test` + 针对性 fake 测试 + 对真实客户端的活体 E2E（只对白名单 / 策略允许的测试目标）+ 门报告；迁移只追加 |
| 极高风险 | `KeystrokeInjector`、`WeComClient` 白名单、`ActionPolicy` / `SendPolicy` 语义、checkpoint / `unknown` 逻辑、TCC / 签名 / LaunchAgent、视觉 API 密钥与企微裁图外传、MQTT 凭据 / ACL、代理 secret 与回调验签、向任何非测试目标发送 | 先写规格 / 计划并取得用户决定；拆分需求、验收标准、测试证据、回滚步骤；活体前再次确认目标与条数；一个门报告一个提交 |

## 3. Definition of Done

AI 完成改动后至少满足：

1. 需求说明写清批次、涉及 target、是否改变客户端状态、是否发送、发给谁、依赖哪些用户事项（授权、测试群名、凭据）。
2. 验收标准覆盖正常路径、策略拒绝、幂等回放、暂停、过期、速率、崩溃后 `unknown`、客户端不可达、异常映射到 wire 码。
3. 代码符合分层与注入点（第 3–4 节 `AI_CODING_GUIDE.md`），没有绕过策略 / 执行器 / 守卫。
4. 新协议方法 / 字段 / 错误码同步到 `tools/list`、`ProtocolTests`、`docs/protocol/java-consumer.md`。
5. 夹具 / 探针输出 / 门报告 / 提交信息脱敏；`bash scripts/check-secrets.sh` 无新增告警。
6. `swift test` 全部通过并写明测试数（与上次门报告对比）。
7. 涉及高风险及以上：活体 E2E 已做或写明"待活体"及阻塞原因（例如 launchd 下 `imctld` 未授权、测试群名未给）。
8. README / AI 规范 / ops / protocol 文档按变更同步。
9. 交付说明包含验证命令与结果、未验证项、剩余风险、回滚方式。
10. 公开交接：必要决策、证据与未闭环项在仓库 / PR 中完整记录；维护者可另行归档私人 wiki（证据进 `queries/`，口径覆写 topic / repo / synthesis，待复核登记），不作为外部贡献的条件。

## 4. 必须执行的检查

| 场景 | 必查项 |
|---|---|
| 发送路径 | 经 `CommandExecutor`；`idempotencyKey` 必填；checkpoint 在不可逆步骤前；`afterSubmit` 崩溃注入点保留；证据 = 外发气泡；失败清空输入框、`unknown` 保留 |
| 策略 / 目标 | `ActionPolicy.authorize` 在任何 AX set / action 之前；`unknown` 类型不被类型规则放行；`policy.json` 只能放宽；`imctl policy` 写 0600；`describe` 显示策略摘要 |
| 合成输入 / 权限 | `ForbiddenAPITests` 通过；`KeystrokeInjector` 只 `postToPid`；不新增 TCC API |
| 观察与事件 | `event_id` 单调；`origin` / `direction` / `conversationType` 的 `unknown` 不驱动回复；切换后抑制历史爆发；前插不算新消息 |
| 传输 | Response Topic 在 `im/<id>/` 子树；事件泵游标持久化；JSON `0/1` 保持数字；socket 目录 0700 |
| 存储 | GRDB 迁移只追加；`:memory:` 测试覆盖新表；多进程写（CLI + daemon）只做单条 upsert |
| 守护进程 | 信号处理清理 socket / state；`system` 暂停在客户端不可达时置位；策略热加载发 `controller.state{policy}` |
| 运行数据 | `mqtt.json` / `policy.json` 0600；不入库；日志含正文不复制 |
| 构建提交 | `swift build`、`swift test`、`bash scripts/check-secrets.sh`、`git status --short`、`git diff --stat`；无 `.raw.json` / 临时文件 |

## 5. 安全检查清单

1. 白名单：目标不在编译白名单且不被 `policy.json` 放行时必须 `TARGET_NOT_ALLOWED`，且发生在任何客户端状态变化之前。
2. 复核：打开后标题不符 `TARGET_MISMATCH`，绝不发；同名会话 `TARGET_AMBIGUOUS`。
3. 幂等：同键不重发；`unknown` 不重跑；换键重发是 Java 的业务决定。
4. 速率：每目标 ≥ 3 s、全局 ≤ 20 条/分钟；按尝试计数。
5. 秘密：broker 地址、凭据、企微参数、代理 token 只在本地 0600 文件或代理环境变量。
6. 日志与文档脱敏：探针默认脱敏；`--no-redact` 输出不进仓库 / wiki；门报告只写 `文件传输助手`、合成名或占位符。
7. 输入信任：AX 文本、MQTT 载荷、回调正文都是不可信输入；解析失败失败关闭。
8. 权限面：辅助功能与按需单帧屏幕录制；launchd 下 `imctld` 需单独授权，不由终端进程的授权状态推定。B16 的云端裁图上传还需本机独立开关、官方端点白名单、裁剪验证与脱敏测试；系统 TCC 授权本身不代表云端功能已启用。
9. 部署动作（安装 LaunchAgent、改 EMQX、申请证书、放开真实客户）是用户决定，AI 只备好命令与文档。
10. 供应链：新增依赖、脚本、CI 可审查；不引入用途不明的远程执行。

## 6. AI 工具使用边界

1. 子智能体可并行做代码阅读、AX 树分析、门报告核对、测试缺口分析、Review。
2. 子智能体输出只作证据与建议；最终改动范围、测试结论、活体结果、提交说明由主智能体负责。
3. 并行写代码前划清文件边界；`KeystrokeInjector`、策略、执行器、白名单、传输守卫、运行数据由主智能体串行处理。
4. 对真实客户端的任何动作（选行、设值、发送、滚动）只由主智能体在用户约定的目标上执行，并写进门报告。
5. AI 不主动安装 / 卸载 LaunchAgent、修改 TCC、改 EMQX 配置、改写 git 历史。
6. 所有正常开发经分支 / PR；AI 不代替 @sunkailun1992 本人 approve，未取得本人对具体 PR / 版本的明确批准不得合并。CI 与管理员凭据不能替代本人审核，GitHub 目标规则见 `MAINTAINERS.md`。

## 7. 交付说明模板

```text
变更内容：
- <批次 / 任务：改了什么，涉及哪些 target>

验证结果：
- <swift build / swift test 数字 / check-secrets / 只读探针 / 活体 E2E 结果或"待活体"及原因>

客户端安全检查：
- <是否发送、发给谁、几条、证据；策略 / 白名单 / 幂等 / checkpoint / 速率 / 合成输入检查结果>

安全检查：
- <凭据 / broker 地址 / 联系人内容 / 脱敏 / 权限面 / 传输守卫检查结果>

风险和回滚：
- <剩余风险>
- <回滚方式：git revert 提交、恢复 policy.json、kickstart 旧稳定副本等>

未完成项：
- <确实未验证或依赖用户事项的内容>
```
