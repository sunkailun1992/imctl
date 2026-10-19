# 阶段 1 任务 P1-1：提交路径验证（2026-09-12 00:0x CST）— 两种纯 AX 策略均失败

目标：文件传输助手（活动会话）。策略 `ActionPolicy(phase1, enabled: [.submit], allowlist: [文件传输助手])`。每次一种策略、一条文本、不重试；submit 前写 checkpoint（`~/Library/Application Support/imctl/checkpoints/`），不可逆动作前再次核对活动标题与输入框身份（TOCTOU 修复 `3dbc06b`）。企微 5.0.10，窗口在另一 Space，`client_active=false`。

| 策略 | 动作 | 结果 | 证据 |
|---|---|---|---|
| `ax-confirm` | 输入框 `AXValue` = 文本 → `performAction("AXConfirm")` | **failed**：`AXConfirm unsupported by composer`（`kAXErrorActionUnsupported`），0.13 s；未发出，输入框已清空 | checkpoint `1A131A7F…` state=failed |
| `newline` | 输入框 `AXValue` = 文本 + `"\n"` | **failed**：10 s 内无匹配外发气泡，输入框仍保留文本（含换行）；清空 | checkpoint `674A5B2C…` state=failed |

前后 `client_active=false`、frontmost 不变；消息表 5 行未变（最后两条仍是 昨天 20:33 / 20:52）；无残留草稿。

## 结论

- 输入框（`AXTextArea _NS:30`）只支持 `AXShowMenu`；`AXConfirm` 被拒绝；程序化换行不触发发送。**在"零合成事件 + 纯 AX 动作"约束下，企微 5.0.10 没有提交路径。**
- 未试的零合成事件候选（都只是读或可撤销的 UI 状态变化，成功概率低）：
  1. 对输入框 `AXShowMenu` 打开上下文菜单，看是否有"发送"菜单项（读完对菜单 `AXCancel` 关闭）。
  2. 把企微激活到前台（`NSRunningApplication.activate`，非合成输入）后再设值重扫按钮，看"发送"按钮是否只在窗口活跃时暴露。
- 路线页的救急项：`CGEventPostToPid(wecomPid, Enter)` —— 只投递给企微进程的键盘事件，不经系统级事件队列，不影响人在其他应用的输入；但它就是合成键盘事件，违反硬约束 #7，且会被 `ForbiddenAPITests` 拦截。若采用，需要用户明确解除该约束并限定为"只对企微 pid、只发回车、只在 submit 步骤"。方案 B 已被用户否决。

## 决定项（用户）

1. 是否先做上面两个低概率候选（各约 1 分钟，可撤销）。
2. 是否把 `CGEventPostToPid` 作为正式提交路径（解除硬约束，限定范围），或者放弃自动发送、只做只读观察 + 人工发送。

## 第二轮（00:32 与 01:08 CST）— `enter` 策略成功，G1 发送证据首次取得

用户 01:02 决定："没有发送按钮，只有回车发送" → 允许 **唯一例外**：在 submit 步骤向企微进程投递一次回车（`CGEventPostToPid`，`KeystrokeInjector.swift` 是全仓库唯一允许出现 `CGEvent` 的文件；`ForbiddenAPITests` 检查该文件只用 `postToPid(`、不含全局 tap / HID / 鼠标 / 其它键）。

| 时间 | 策略 | 结果 | 备注 |
|---|---|---|---|
| 00:32:02 | `context-menu` | failed：`AXShowMenu` 后无菜单出现 | 丢失结果的那轮所跑，检查点为证 |
| 00:32:04 | `send-button` | failed：设值后 26 → 26 个按钮，无新按钮 | 同上 |
| **01:08:45** | **`enter`**（`--auto` 首个候选） | **succeeded**：`return -> pid 45487`，115 ms 后消息表出现 row #6 `dir=outbound time=1:08`，输入框为空 | 企微未激活（`client_active=false`，前台仍是其它应用），窗口仍在另一 Space |

- 序列：precheck（输入框空）→ compose（AXValue 设值复核）→ checkpoint pending → verify_target（活动标题与输入框身份复核）→ AX 设 `AXFocused` → `CGEventPostToPid` 回车（按下/抬起各一次）→ 200 ms 轮询取证 → checkpoint succeeded。
- 00:43 消息表出现一条不属于 imctl 的外发消息（检查点目录无记录），应为用户自己发的。

## 结论

- **G1 的"对文件传输助手 N 秒内观察到匹配气泡"通过**（N = 0.115 s）。
- 硬约束 #7 改写为：不发全局合成事件；唯一例外是 submit 步骤对企微 pid 的一次回车。企微设置若改为 Ctrl+Enter 发送，`--strategy ctrl-enter` 已备。
- 未闭环：同键只发一次（幂等键，阶段 1 核心）、submit 与 confirm 之间杀进程 → unknown 的混沌测试、同名会话拒绝、人留草稿中止（已有 LOCAL_GUARD）。
