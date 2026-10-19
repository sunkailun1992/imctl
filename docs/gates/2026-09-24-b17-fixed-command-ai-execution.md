# B17 固定桌面命令视觉辅助门报告（开发版，未全范围验收）

## 范围与结论

- 用户要求固定 MQTT 命令在 imctl 内完成 AI 辅助观察、受限操作、复核并返回结果；另授权显式命令按需向所选云端模型上传经核验的完整企微窗口。默认千问 `qwen3.7-plus`，可在本机切换 Gemini；DeepSeek 当前不支持视觉输入。窗口可能包含聊天正文、头像及其它会话预览。
- 本批实现**AX 优先、视觉候选选择后备**：AX 唯一证据不足且动作提供合格候选时才截单帧，模型只能在固定方法允许的候选中选择或停止；命令成功仍由客户端 AX 事实判断。`conversation.read` 另有最多两轮的可逆会话选择、重新观察和复核。**没有实现所有方法统一的多轮 AI 规划**，不能称为 Codex 等价的全自动视觉代理。
- MQTT 方法、参数、topic 与结果字段不变。不可逆动作前有 checkpoint；后验不足为 `unknown`，同幂等键不重做。`message.broadcast` 的不确定子命令使父命令保持 `unknown`。

## 条件与证据层次

| 项目 | 2026-09-24 核对 |
|---|---|
| 源码与安装 | `main` 原基线 `fa24202`；B17 代码版本 `1.0.6-dev`，应用 / pkg 版本 1.0.6、build 157。`codesign --verify --deep --strict`、pkg 包内三执行文件和本机安装读回通过；最终提交哈希与制品 SHA-256 在交接回执记载。 |
| 本机授权 | `setup --check` 六项通过，包括辅助功能、屏幕录制、企微数据与 LaunchAgent。 |
| 云端开关 | 本机 `cloudEnabled=true`、`fullWindowEnabled=true`、千问 `qwen3.7-plus`；密钥仅本机私有配置，未入仓库。旧配置缺整窗字段为 false。 |
| 提供商 | 千问对**合成图片**的实际 API 请求成功；Gemini 合成图请求返回 `FAILED_PRECONDITION` 地区限制，代码报固定错误，不重试或换提供商。 |
| 全窗上传 | 真实企微窗口尚未触发 B17 歧义分支，真实截图云端请求 **0**；合成 API 成功不等于真实全窗验收。 |
| MQTT 只读 | 用户 LAN 的 EMQX 上 `account.status`、`conversation.list`、`conversation.read`、`message.history` 返回 `succeeded`；不记录 broker 地址、凭据或聊天正文。 |
| 写入 | 本批仅向本人文件传输助手发送 1 条纯文本测试消息；原幂等键对账成功，正文仅留在本机私有命令记录。其它写入 0。 |

## 逐方法矩阵

“fake”是合成 AX / HTTP 传输，不是活体。表内“可视觉选”均只在 AX 歧义且有合格候选时触发；没有模型参与的成功命令不能称为 AI 操控已验收。

| 固定方法 | 实际执行路径与验证边界 |
|---|---|
| `account.status` | 纯 AX 读取，活体 MQTT 成功；无视觉步骤。 |
| `conversation.list` | 纯 AX 列表，活体 MQTT 成功；无视觉步骤。 |
| `conversation.read` | 核对目标与策略后选行；解析遗漏且行标题唯一时可视觉选行；选中不落实可重新观察并再选一次。fake 两轮成功 / 停止通过，活体 MQTT 成功但未用模型。 |
| `message.history` | 显式读取定位最新或回滚；多个不重合滚动条时可视觉选，fake 通过；活体 MQTT 成功返回 5 行，未用模型。 |
| `message.send` | 目标、编辑框、提交、气泡后验；发送按钮歧义时可视觉选。fake checkpoint 与候选通过；本人文件传输助手活体 1 条成功，未触发模型。 |
| `message.sendFile` | 来源 / 文件头校验、粘贴、提交、附件气泡后验；会话选择可视觉后备。fake checkpoint 通过；本批未发文件。 |
| `client.navigate` | 固定 AX 窗口菜单位于核验窗口外，不交给整窗模型；禁用项不按且恢复焦点，fake 通过；本批未活体。 |
| `contact.list` | 通讯录 AX 读取；无视觉步骤，本批未活体。 |
| `contact.request.list` | AX 读取；表出现但行未渲染时有界等到完整卡片或明确空态，fake 通过；本批未活体。 |
| `contact.request.accept` | 唯一待处理卡片、备注弹层与状态后验；多个完成按钮时可视觉选，fake / checkpoint 通过；本批未接受。 |
| `contact.add` | 号码策略、搜索、匹配、提交与状态后验；含糊控件可视觉选，fake / checkpoint 通过；本批未添加。 |
| `group.create` | 固定选人面板与群头后验；含糊控件可视觉选，fake / checkpoint 通过；本批未建群。 |
| `group.rename` | 先核目标策略，再选会话改名并复核；含糊字段可视觉选，fake / checkpoint 通过；本批未改名。 |
| `group.addMembers` | 群头按钮含糊时可用 B16 裁图或 B17 整窗选择，选人后核对群人数 / 系统行；fake / checkpoint 通过，本批未加成员。 |
| `broadcast.confirm` | 只在助手 AXSheet / 独立窗口出现精确 `msgid` 与唯一发送按钮时按；不靠模型猜任务。fake 拒绝与 checkpoint 通过；本机无代理配置、助手形态未活体确认。 |
| `message.broadcast` | 每目标独立 `message.send` 子命令；fake 验证不确定子命令使父命令 `unknown`，同键不重做；本批未群发。 |

## 跨方法门与测试

- `AIPlannerObservation` 限企微 PID、AX 主窗口、活动会话、候选角色 / 动作 / 位置；图片仅内存，裁去窗外像素，最长边 1920，JPEG ≤2 MB。模型只回当轮候选 ID / 停止；选中后重读语义摘要、句柄、角色、位置及窗口。单条命令最多 6 次模型轮次、40 秒；单步请求 8 秒。后台 watcher 与自动申请不安装此视觉入口。
- 屏幕录制、`cloudEnabled`、独立 `fullWindowEnabled` 三门都要通过。合成测试覆盖窗外像素不上传、旧窗口、伪造候选、越权步骤、超预算、HTTP 异常和过大响应。真实全窗歧义分支尚待验收。
- `swift build` 通过；`swift test` 全量 **636/636** 通过，包含 37 个 AIPlanner 测试与守卫测试。`git diff --check` 通过；`check-secrets.sh` 退出 0，仅 11 个既有测试 / 示例 / 旧计划警告，本批无新增命中。签名与本机 build 157 安装读回通过，`setup --check` 六项均通过。首轮全量测试因旧版本断言与禁用菜单测试期望过时失败，修正后重跑通过。

## 活体记录

| 命令 | 模型请求 | 脱敏结果 | 写入数 |
|---|---:|---|---:|
| `account.status` | 0 | MQTT `succeeded`，客户端可达 | 0 |
| `conversation.list` | 0 | MQTT `succeeded`，有会话列表 | 0 |
| `conversation.read`（本人文件传输助手） | 0 | MQTT `succeeded`，活动标题一致 | 0 |
| `message.history`（本人文件传输助手） | 0 | MQTT `succeeded`，5 行包含文件、媒体、文字类型 | 0 |
| 千问合成图片 API | 1 | HTTP 成功，结构化候选可解析；非真实企微窗口 | 0 |
| Gemini 合成图片 API | 1 | 地区限制；固定错误码、不重试 | 0 |
| `message.send`（本人文件传输助手） | 0 | MQTT `succeeded`，约 3.1 秒，checkpoint 已写；原幂等键 `command.get` 同一记录，事件 accepted→running→succeeded 及 `message.observed{origin:controller}`，历史仅 1 条匹配的 `outbound` 行 | 1 条纯文本 |

## 未闭环

1. 多数方法仍是固定 AX 流程和歧义时视觉候选后备，没有跨步骤统一的 AI 规划；“所有桌面命令像 Codex 一样多轮视觉操控”未验收。
2. 真实企微整窗经 B17 云端分支的端到端请求，以及跨屏、缩放、窗口移动和延迟未实测。Gemini 在此环境受地区限制，不自动切回千问。
3. 已获准且已执行的 1 条本人测试消息不构成后续发送授权；其它写入方法未活体测试。`broadcast.confirm` 缺真实助手样本和代理；第二台 Mac 安装、授权、密钥设置未验。
4. MQTT 同步等待可能短于命令执行；超时后保留原幂等键，查 `command.state`、`event.replay` 和 `command.get`，不得换键盲重试。
