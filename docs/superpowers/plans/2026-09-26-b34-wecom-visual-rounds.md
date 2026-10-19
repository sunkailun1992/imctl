# B34：企微视觉选会话与动作后复核实施计划

> 本页是实施顺序；是否通过以 B34 门报告的真实证据为准。目标契约见 `docs/superpowers/specs/2026-09-26-b34-wecom-visual-rounds.md`。B33 的真实企微模型请求为零，不把之前的 AX 成功记录写成视觉成功。

## 全局约束

- 仅扩展显式 `conversation.read` 及四个写入命令的**可逆目标选中前缀**。模型没有自由文本工具、坐标点击、任意截图、消息正文或提交决策权。写入流程的原策略、白名单、checkpoint、速率、幂等与 `unknown` 保留；本批活体不发送消息。
- 截图前须通过当前企微 PID / 主窗口、屏幕录制、`cloudEnabled`、`fullWindowEnabled`、方法 / 来源 / 目标及暂停检查；每轮后重新检查。截图、请求与回复只在内存中；`controller.describe` 只暴露 `visionCaptureCount`、`visionRequestCount`、`visionHTTP200Count` 三个全局累计数。
- 保持最多两次可逆选行、六次模型轮次和 40 秒总预算。第二轮是**选行后的新窗口截图与模型观察**，随后仍由 AX 严格证明目标。没有 AXRow / AX 动作的像素目标停止；不增加按键、鼠标、权限种类或跨模型重试。
- 子智能体不对真实企微执行动作。主智能体负责受控活体、门报告、安装和发布；无法实测的项如实记“待活体”。

## Task 1：先建立动作后视觉观察的失败测试

1. 在 `Tests/WeComAdapterTests/` 用 fake AX、合成窗口与假模型构造唯一解析行。外部 `conversation.read`、目标未激活、三门开启时断言首轮 `selectRow`，AX 行被选中后仍发起**第二次新截图**；模型第二轮只可 `verify` / `reobserve` / `stop`，本机再读 AX 头部后返回。主动路径不能被原 `settlePostcondition` 在第一轮后提前结束。
2. 覆盖模型第二轮 `stop`、头部不符、截图失败、客户端在推理时换 PID / 窗口 / 会话、整窗许可或策略撤销、候选角色 / frame / 句柄变化、超预算。断言停止前不触碰 composer、不发送、没有 checkpoint。第一次选行未生效时允许一次新观察再选，但后续仍需动作后视觉轮次与 AX 后验。
3. 覆盖已经激活目标和整窗未启用时的原 AX 路径；前者不制造截图，后者保留原结果语义。测试只使用合成目标和假密钥；不保存真实窗口或模型回复。

## Task 2：限定候选并接入 `conversation.read`

1. 在 `WeComCommandHandler` 内，先解析固定 `target`、按原读策略核对，再判断当前活动头部。目标未激活且视觉三门已开时进入主动视觉路径，**已解析的唯一 AX 行也进入**，避免只有自然 parser miss 才能触发模型。精确同名行先返回歧义，不能交给模型猜。
2. 当目标的 AX 标题缺失但会话表有可见、可操作的 `AXRow` 时，只读 `conversation.read` 可让模型从本轮行候选中选择。模型选后重新取得窗口、候选及活动头部；`activeTitle` 必须严格等于请求标题，平台 ID 目标还须继续匹配原身份桥。错行、消失行或纯像素无 AX 动作，均停止并返回现有失败语义。
3. 用方法限定的两个相位执行：定位相位允许 `selectRow` / `reobserve` / `stop`；动作后相位重新截图，只允许 `verify` / `reobserve` / `stop`。对不需动作的观察轮次，若现有 `AIPlannerObservation` 要求至少一个可操作候选，应增加受限的只读观察形态，而不是给模型虚构可执行动作。第二轮返回 `verify` 仍必须执行本机 AX 严格后验。
4. 在模型返回与 AX 写入前重核来源、方法、暂停、视觉设置、策略、目标身份、企微 PID / 窗口 / frame、候选角色 / 动作 / frame。保留旧可逆流程的总预算和错误映射；无可靠结果不得报告 `succeeded`。

## Task 3：四个写入命令复用目标前缀

1. `message.send`、`message.sendFile`、`group.rename`、`group.addMembers` 保持原方法自己的政策检查、文件取源与不可逆提交顺序；只在目标未激活、三门已开时复用 B34 视觉选会话。它们提供的候选必须是唯一精确 AX 标题行；AX 标题缺失、重名与身份漂移一律在任何后续写入前停止。
2. 视觉前缀通过两个真实观察相位并由新鲜 AX 活动头部证明目标后，回到原动作实现。模型无权选择发送按钮、群名、成员、文件、正文或提交时机。回归既有 checkpoint、`unknown`、同键与 `message.broadcast` 子命令语义。
3. Fake 集成至少证明四个方法各自经过选行与动作后复核才抵达原动作；模型第二轮拒绝、策略 / 暂停中途变更、错行与窗口漂移时，原动作和 checkpoint 都没有执行。原目标已激活时不额外调用模型。

## Task 4：增加可核对的匿名计数

1. 在进程内累计 `captureCount`、`requestCount`、`successCount`，分别界定为完成当前企微窗口截帧、向所选视觉提供商发起请求、固定官方端点返回 HTTP 200 的次数。`successCount` 在 JSON / 模型决策解析之前计，不能代表有效选择、AX 后验或企微命令成功。`controller.describe` 分别以 `visionCaptureCount`、`visionRequestCount`、`visionHTTP200Count` 返回三个数值，不落盘、不返回截图、候选文本、模型回复、目标或密钥。
2. 测试在策略拒绝、后台 watcher、B15 方向、本机整窗关闭时三个数均不增长；HTTP 非 200 时请求数增长而成功数不增长；HTTP 200 但 JSON 无效时成功数仍增长、命令失败关闭。`controller.describe` 本身不能引发截图或改变企微窗口。
3. 如 `controller.describe` 对外结果字段增加，同一提交同步 `docs/protocol/im-control-protocol.md`、`ProtocolDocTests` 与消费方说明，旧客户端仍可忽略新字段。命令前后差分须结合该命令的 MQTT 回执核对，不把全局累计数误称为数据库中的逐命令审计记录。

## Task 5：构建、安全回归与真实活体

1. 运行聚焦 fake、`swift build`、全量 `swift test`、`ForbiddenAPITests`、`git diff --check` 和 `bash scripts/check-secrets.sh`；检查源码、测试、文档与随包说明，确保无截图、Base64、原始模型文本、密钥、broker 地址或真实聊天内容。必要时按高风险改动复核候选重验、策略和恢复路径。
2. 稳定签名安装后，`setup --check` 核对六项授权，本机设置核对千问 `qwen3.7-plus`、`cloudEnabled` 和 `fullWindowEnabled`；不打印密钥。先以只读 / 可逆操作让文件传输助手不是当前活动会话，再记 `controller.describe` 三计数基线，发一条显式 MQTT `conversation.read{target:"文件传输助手"}`。记录命令 ID 与终态、计数差值、两轮顺序与耗时、新鲜 AX 活动标题；不保存或展示真实截图与模型响应。模型拒答或地区限制按真实结果记录，不切端点或提供商掩盖失败。
3. 活体发送数为 **0**。不得用 B33 的四条已发送消息重复冒充本次视觉验收；写入命令可用 fake 与只读检查证明接线，但没有新的发送授权与真实视觉提交证据时标“目标前缀待活体”或“后续动作 AX-only”。后台观察期核对云端计数不增长。
4. 门报告逐层给出源码、fake、真实 Qwen、企微 AX、MQTT、本机安装、第二台 Mac 的证据；明确仍为 AX-only 的方法和下一批要补的表单阶段。主智能体负责提交推送、安装包、wiki 归档与回滚说明，不能把设计目标写成已交付事实。
