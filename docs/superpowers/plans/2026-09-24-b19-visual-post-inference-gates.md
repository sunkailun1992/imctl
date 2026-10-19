# B19：单步视觉模型返回后门禁实施计划

> 目标口径见 `docs/superpowers/specs/2026-09-24-b19-visual-post-inference-gates.md`。本文列实施和验证顺序，不是代码或活体验收回执；实际结果以 B19 门报告为准。

## 全局约束

- 保留现有 JSON-RPC / MQTT 方法、事件和响应结构；不改 `CommandExecutor` 的不可逆 checkpoint、幂等、速率与 Response Topic 守卫。无协议字段变动则不改对外协议文档。
- 仅显式固定桌面命令可按已有三门授权上传经核验的企微窗口单帧。后台 watcher、B15 本机媒体方向判断、普通唯一 AX 路径不上传；模型不能生成任务、目标、正文、收件人、成员、URL、坐标或新按键。
- `visualChoice` 的候选复核、方法专属 `ActionKind`、当前 `ActionPolicy`、目标身份桥和暂停须在模型返回后、实际 AX 写入前结合；不能以初始化时的 `WeComActions.policy` 副本替代热更新策略。对会在选择返回后等待的调用方，还须在最后写入点复核。
- 测试只用合成 AX / 图片和假模型，不写密钥、截图、真实联系人或正文。活体发送授权按条数计算；先前 B17 已发送的 1 条测试消息不得复用作本批许可。

## Task 1：列出现有单步视觉动作与最后写入点

1. 从 `AIPlannerRoundSelector`、`WeComCommandHandler.actions(for:)`、`WeComActions.visualChoice` 和各 `visualChoice` 调用点建立方法 → `ActionKind` → 目标 → AX 写入 → 客户端后验矩阵。至少覆盖会话选行、历史滚动条、发送按钮、联系人申请 / 添加、群名称、建群确认、添加群成员入口。
2. 标出模型调用发生在 checkpoint 前或后的调用路径；发送按钮等提交路径不能只在候选返回时检查授权，必须在按按钮的最后写入点再复核。`broadcast.confirm` 的精确 `msgid` / 唯一按钮守卫不由模型替换。
3. 为每个动作区分 `expectedTitle` 可证明的活动目标、经身份桥解析的目标与无会话目标；未知或冲突不得回退到宽松标题授权。

## Task 2：让候选选择器拒绝推理期间撤销的设置

1. 在 `AIPlannerRoundSelector` 截图 / 模型返回后重新读取本机视觉设置，并核对与本轮用于上传的设置相同且 `cloudEnabled`、`fullWindowEnabled` 仍启用。设置文件变得不可读时失败关闭；新的模型选择仅能在新命令 / 新轮次使用。
2. 在模型返回后重核命令预算与方法上下文，再处理 `selectRow` / `press` / `writeText` / `scroll`、`reobserve`、`stop`。返回候选前沿用语义摘要、PID / 窗口、角色、动作、frame 与 eligible 句柄交集；不能因重观察而绕开预算。
3. Fake 测试在模型闭包内改设置、推进时钟或替换窗口，断言不返回可执行候选；原唯一 AX 路径仍不调用模型。

## Task 3：把活的命令门禁接到动作层

1. 由处理器为外部固定命令的 `WeComActions` 注入只用于本条命令的复核闭包；闭包读取当前暂停、热更新策略及目标身份桥，且核对命令方法和来源。动作层按 Task 1 的 `ActionKind`、原始 `TargetRef` 与目标身份使用该闭包，不传模型文本作为策略依据。
2. `visualChoice` 在模型返回后、候选 AX 复核后调用该门禁。调用方在最终 AX set / press 前如有另一段等待或读写，再执行同一门禁与必要的目标 / 窗口 / 元素复核。现有先授权路径保留，复核是叠加而非替换。
3. Fake 测试分别在模型闭包中撤销策略、插入暂停、更换目标身份 / 活动会话，断言截图前拒绝时零请求、推理中撤销时零 AX 写。检查监听器没有闭包、关闭视觉后仍按既有 AX 路径工作。

## Task 4：不可逆路径与回归矩阵

1. 对每个使用视觉候选的提交动作，证明推理后拒绝时不发生提交。已有 checkpoint 若位于模型推理前，明确其失败 / 未提交语义；不为“重试成功”自动换键或使用新幂等键。
2. 使用 fake 覆盖设置撤销、策略撤销、暂停、目标 / 窗口漂移、伪造候选、模型含糊、超时，检查 `CommandExecutor` 记录、checkpoint、AX set / press 次数。B18 两次可逆选行回归，MQTT 同键重放、`command.state` / `command.get` 对账及协议守卫回归。
3. `swift build`、聚焦测试、一次全量 `swift test`、`git diff --check` 与 `bash scripts/check-secrets.sh`；守卫测试不得因本批增加合成输入或 TCC API。

## Task 5：活体与交付

1. 稳定签名安装版先用显式只读 MQTT 命令核对快路径耗时、目标 AX 后验和请求数。只有自然出现视觉歧义时才记录真实整窗模型分支；没有触发就标待活体。
2. 本批没有新增发送条数授权时，发送计数为 **0**，不进行发送按钮活体试验。其它写入只在明确测试目标和原策略允许时逐项记客户端证据；不能把 fake 成功记作用户界面通过。
3. 门报告分别写源码、单测、真实模型、真实客户端、MQTT、本机安装和第二台 Mac 证据。由主智能体统一决定提交 / 推送 / 安装包 / wiki 归档口径。

## 后续阶段路线（B19 不据此宣称完成）

1. `message.history`：把滚动条或页动作纳入可逆轮次，成功由加载行数与最新位置 AX 证据决定；避免每次读历史都上传。
2. 会话目标阶段：为 `message.send`、`message.sendFile`、`group.rename`、`group.addMembers` 复用经身份桥验证的多轮选中步骤，后续正文、文件与成员仍只由原命令参数提供。
3. 联系人与群阶段：分别为 `contact.request.accept`、`contact.add`、`group.create`、`group.rename`、`group.addMembers` 定义有限状态、候选与后验；最后确认仍按各自 checkpoint 与 `unknown` 规则。
4. `broadcast.confirm` 只在助手界面有精确 `msgid` 和唯一发送按钮证据时进入提交，不能以图像相似度猜任务。`account.status`、`conversation.list`、`contact.list` 等 AX 明确时保留直接读取；`client.navigate` 不能用整窗模型扩大到未核验的窗口。
5. 每阶段单独 fake、真实客户端与 MQTT 验收，未接入或未自然触发的分支标待活体。达到所有方法覆盖前不使用“完整 AI 操控”表述。
