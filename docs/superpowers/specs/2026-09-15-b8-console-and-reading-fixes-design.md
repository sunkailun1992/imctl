# B8 设计：控制台读取 / 发送修正与外部群解析校准（2026-09-15 21:0x 用户提出）

## 1. 用户提出的事项（21:08，附三张控制台截图）

1. 新申请复验暂无新账号，稍后再找（不做）。
2. 发一条测试消息做群解析校准（授权对三人外部群发 1 条）。
3. 设置页是否显示完整。
4. 会话页：只有第一次能读到消息，切换会话后读到的仍是上一个会话；含图片的会话读不出图片消息。
5. 发送页：目标不该是自由输入，应从已读取的会话 / 通讯录里选。

## 2. 活体事实（21:1x–21:2x，5.0.11，全部只读或已授权动作）

- `client.navigate` 需要 `idempotencyKey`；守护进程侧 `message.history` 在切换后读到的是新会话（对照 6 步到 含图会话，返回 3 行），**陈旧的是控制台**：`navigate()` 只刷新列表不刷新消息，`open()` 失败（非白名单 `TARGET_NOT_ALLOWED`）时列表保留上一次的消息。
- 含图会话的消息表（夹具 `wecom-5.0.11-image-message.json`，脱敏）：行 0 = 时间 + 文本；行 1、2 = **居中的 `AXTextArea`**（系统通知，现被当消息、方向 unknown）；行 3 = **空行、高 246 px**（图片消息，单元格无子元素）；一个 122 px 的 `AXImage` 悬浮在表之外（y 与该行不重叠）。
- 三人外部群（夹具 `wecom-5.0.11-external-group.json`）：头部标题是 **`AXTextField`**（可编辑群名，y 20），其下 y 44 的 `AXStaticText` 是横幅「由企业微信用户创建的外部群…」；`WeComLayout` 只把静态文本当标题 → 活动会话读成横幅 → `message.send` / `conversation.read` 报 `TARGET_MISMATCH`。列表行的「外部」标签落在 **badge 文本区**（有时带 U+200B），不是静态文本 → 类型仍 unknown。
- 设置页缺：MQTT `keepAliveSeconds`；代理 `corpId` / `agentId` / `timeoutSeconds`；未展示派生 topic。

## 3. 口径

- **标题**：会话表右侧、视口上方的 `AXTextField` 与 `AXStaticText` 都是标题候选，取最靠上者；搜索框只在会话表左侧找。
- **行标签**：badge 文本区的值去掉零宽 / 空白后等于列表标签（微信 / 外部 / 外部群）时算 marker，badge 置空；`conversationType` 由此判 group / customer。
- **消息行**：无文本子元素且高 ≥ 100 px 的行 = `media`（非文本消息：图片 / 表情 / 文件），`text` 无；若消息区有 `AXImage`（宽 ≥ 40）与该行纵向重叠则用它推方向，否则 unknown。居中的 `AXTextArea` 正文 = `system`。`message.history` 行与 `message.observed` 事件带 `kind`（`message` | `media`）；控制台显示「[非文本消息]」。
- **控制台会话页**：切换（上一 / 下一 / 未读 / 打开）后自动重读消息；活动会话变化先清空旧消息；读取失败清空并在消息栏显示错误；非白名单目标给出「用上一 / 下一会话切换或在策略页放行」的提示。
- **控制台发送页**：目标从已读取的会话标题与好友列表中选择（Picker），保留「手动输入」项给 `chatId:` / `externalUserId:`；进入页面自动读取会话列表。
- **设置页**：补 keepAlive、corpId、agentId、超时；只读展示 cmd / rsp / evt / state 四个 topic。
- 不改：策略与白名单语义（读会话仍经 `selectConversation` 门）、发送路径、`KeystrokeInjector`。

## 4. 待用户

- 群解析校准需在标题修正部署后重发 1 条（已授权）；接受 / 自动建群复验等新账号。

## 5. 校准结果（21:37，门报告 `docs/gates/2026-09-15-b8-console-reading-and-external-group.md`）

- 三人外部群：行 `conversationType: group`（badge 槽「外部」）、头部标题来自文本框、`message.send` 成功、`message.observed.conversationType = group`、`kind = message`；含图会话读出 `message` + `media` 两行，通知已过滤。
- 未定：公司全员群行的 badge「全员」是否作为内部群标签；群内入站消息的发送者归因待测试号发 1 条。
