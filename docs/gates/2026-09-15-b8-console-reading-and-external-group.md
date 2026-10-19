# 门报告：B8 控制台读取 / 发送修正与外部群解析校准（2026-09-15 21:0x–21:4x CST）— 通过（控制台页面待用户过目）

规格 `docs/superpowers/specs/2026-09-15-b8-console-and-reading-fixes-design.md`，计划 `docs/superpowers/plans/2026-09-15-b8-console-and-reading-fixes.md`。用户 21:08 提出五项并授权向三人外部群发 1 条测试消息做群解析校准。

## 条件

- 企业微信 5.0.11；守护进程 = `~/Applications/imctl.app` 内 release 包（先装工作树版本 build 56 做活体，提交后重建 build 57 重装），签名标识不变、`trusted:true`；控制台每次装包后 kill 旧进程再 `open -a`。
- 发送：**1 条**，`imctl-b8-group-1`，目标 = 三人外部群（测试号 2 + 测试联系人A + 本人；`policy allow --title` 放行，保留）；其余全部只读。含图会话与外部群各录一份**脱敏**夹具（`wecom-5.0.11-image-message.json`、`wecom-5.0.11-external-group.json`）；群标题含本人姓名，不入文档。

## 根因（21:1x 活体）

| 现象 | 根因 |
|---|---|
| 会话页切换后仍显示上一会话的消息 | 守护进程侧 `message.history` 已跟随切换（对照 6 步到含图会话返回其 3 行）；控制台 `navigate()` 只刷新列表不重读消息，`open()` 对非白名单目标失败（`TARGET_NOT_ALLOWED`）时旧消息留在页面；执行器方法的失败是结果里的 `state:"failed"` + `error`，控制台把它当成功 |
| 含图会话读不出图片 | 图片消息行 = 单元格无子元素的 246 px 行，图片是表外悬浮的 `AXImage`（本例与该行不重叠）；两条系统通知是**居中的 `AXTextArea`**，之前被当成消息、方向 unknown |
| 向三人外部群发送 `TARGET_MISMATCH`（"active is 由企业微信用户创建的外部群…"） | 外部群头部标题是 **`AXTextField`**（可编辑群名，y 20），其下 y 44 的静态文本是横幅；`WeComLayout` 只把静态文本当标题 |
| 群行 `conversationType: unknown` | 「外部」标签落在 badge 文本区（有时带 U+200B），不是静态文本 marker |
| 设置页不全 | 少 `keepAliveSeconds`、`corpId` / `agentId` / `timeoutSeconds`，无派生 topic |

## 实现

- `WeComLayout`：标题候选含会话表右侧、视口上方的 `AXTextField`；搜索框只在会话表左侧找；收集消息区图片帧 `messageImages`。
- `ConversationRowParser`：badge 值去零宽 / 空白后等于列表标签 → marker（badge 置空）。
- `MessageRowKind.media`（无文本子元素、高 ≥ 100 px 的行；方向取重叠的最大图片，否则 unknown）；居中且宽 ≤ 表宽一半的 `AXTextArea` = `system`；`chatMessages` 含 media；`message.history` 行与 `message.observed` 事件带 `kind`。
- 控制台：`navigate` 后重读消息、切换先清空旧消息、读取失败清空并在消息栏显示、非白名单目标给「上一 / 下一会话或策略页放行」提示；执行器失败记录按失败处理；发送页目标改 Picker（会话标题 + 好友列表，保留手动项）；设置页补 keepAlive / corpId / agentId / 超时并展示四个 topic；`socketPathOverride` 供测试。
- 协议 §5 / §6.3 / §6.6 / §7.4 同步。
- 认知修正：5.0.10 主窗口夹具唯一一行是像素级居中的 412 px 文本区（偏移 −0.5 px，与两条活体通知一致）——是通知不是消息，4 处旧断言据此改写（`GroupParsingTests` / `WeComCommandHandlerTests` / `WatchDiffTests` / `ProbeCommandTests`）。

## 单测

`swift test`：**278 个用例、75 个套件全部通过**（上一报告 271 → +7：文本框标题、badge 标签、media 与居中通知、history / 事件 `kind`、控制台切换重读与失败清空、设置往返）。

## 活体（build 56，21:37）

| 步骤 | 结果 |
|---|---|
| `conversation.list` | 三人外部群与两个旧「群聊」行 `conversationType: group`、`markers: 外部`；另见公司全员群行 badge「全员」（未定义为标签） |
| `conversation.read` 三人群 | `active` = 群标题（文本框）、`conversationType: group`、`composerPresent: true` |
| `message.send imctl-b8-group-1` | `succeeded`，`row #2 dir=outbound time=21:37`，77 ms |
| 事件 | `message.observed{conversationType: group, kind: message, direction: outbound, origin: controller, commandId}`；`conversation.activity` 该行 `type: group`、`preview: imctl-b8-group-1` |
| `message.history` 三人群 | `[(message, outbound, imctl-b8-group-1)]`，无发送者标签（本人消息） |
| 含图会话（7 步到达） | `[(message, inbound, 9:32), (media, unknown)]`——通知已过滤，图片消息成 media 行 |
| 发送 | 1 条（上表） |

## 结论与未闭环

- 通过：群解析在**外部群**上校准——类型来自行标签、标题来自文本框、发送与事件带 `group`；含图会话可读；控制台三处修正有单测。
- 待用户：三张控制台页面（会话 / 发送 / 设置）过目；群内**入站**消息的发送者归因需测试号从手机在群里发 1 条（本人消息无发送者标签）；「全员」是否作为内部群标签。
- 仍未闭环：守护进程一次 ~7 s 不接 socket；改群名；接受 / 自动建群复验（等新账号）。
