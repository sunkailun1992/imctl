# 门报告：B7 补丁——通讯录导航在客户端失去前台后继续（2026-09-15 16:0x CST）— 通过

接续 `docs/gates/2026-09-15-b7-contacts-requests-groups.md` 的未闭环项「守护进程重启后首次通讯录导航失败」。方法：superpowers `systematic-debugging`（先逐步取证，再修）。规格活体修正见 `docs/superpowers/specs/2026-09-15-contacts-requests-groups-design.md` §7。

## 条件

- 企业微信 5.0.11，消息视图；守护进程 = `~/Applications/imctl.app` 内 release 包（`scripts/build-pkg.sh release` → `installer -target CurrentUserHomeDirectory` → `launchctl kickstart -k`，build 53，签名标识不变、辅助功能 `trusted:true`）。
- 调用经本地 socket（`imctl call contact.request.list`）；0 条消息发送；只投递已批准的 ⌘8 / ⌃Tab；导航期间企微短暂前台，结束回消息视图并把前台还给之前的应用。
- 通讯录 › 新的客户 仍是 2 张 `added` 卡；用户全程在本机工作（IDE / 浏览器）。

## 根因

| 证据 | 内容 |
|---|---|
| 原始两次失败（SQLite `commands` / `events`） | 04:14:22Z（重启后 22 s）与 06:03:48Z（重启后 43 s）各 11.8 s / 12.0 s 失败 `contacts view did not appear after 6 tab steps`；两次都在命令开始 0.8–1.0 s 内出现 `conversation.activity activeTo:""`——激活与 ⌘8 已落地，此后 11 s 无变化；同一守护进程稍后的调用 3.8–4.2 s 成功 |
| 逐步 trace 复现（15:53，kickstart 后立即调用，修复前） | `front=yes landed=true` 激活落地 → ⌘8 落地（视图指纹 03b869→e4708a，焦点 `AXTextArea`）→ 焦点移到 `AXTable`、⌃Tab1 落地（指纹→63bef4）→ **自 ⌃Tab1 起 `front=no`**，⌃Tab2–6 指纹不再变化 → 12.0 s 失败。调用前用户前台是 IDE，一分钟后是浏览器（HID 空闲 0 s）：用户在操作 |
| 对照 | 同一守护进程不重启（run A）与重启后立即调用（run B）都 2 步成功、全程 `front=yes`——**重启不是触发条件** |
| 确定性复现（C） | 调用开始 3.17 s 后用 osascript 把 `imctl-console` 置前：`front=no` 自 ⌃Tab1，⌃Tab2–6 被丢弃，13.35 s 失败——与原失败签名完全一致 |

结论：客户端只在自己是活动应用时响应投递到 pid 的快捷键；`bringToFront` 只在开头做一次，导航中途前台被拿走（活体里是用户点回 IDE / 终端；两次原始失败都在用户刚敲完命令的几秒内）后，其余 ⌃Tab 全部被静默丢弃。"重启后首次"是巧合。

## 实现

- 取证：`WeComActions.trace` 钩子；`openContacts` 每步 note（前台 / 焦点角色 / 文本计数 / 视图指纹 / 时延，不含任何内容），失败信息带完整步骤；守护进程把 trace 接到日志（`configureActions`）；`RequestAutomation` 记录 list 的失败信息；`WeComContactsView.scan`（`Scan`：texts / left / signature / showing / fingerprint / ms，`isShowing` 复用）；`moveFocusOffTextInput` 返回 `FocusMove`（前后角色、候选数、是否移动），探针同步打印。
- 修复：每次投递前 `lostFront`（NSWorkspace 前台 pid ≠ 客户端，或客户端自己的 `AXFrontmost` 为 false）→ `bringToFront` 后再投递，trace 标 `refront(...)`；`bringToFront` 改为等两侧都落地（工作区前台 pid 与客户端 `AXFrontmost`），未知不等。
- 未改：白名单、策略、`KeystrokeInjector`（键仍只有 ⌘1–⌘8 / ⌃Tab / ⇧⌃Tab / ⌘N + 回车）、协议方法 / 事件 / 错误码。

## 单测

`swift test`：**260 个用例、73 个套件全部通过**（B7 257 → +3：trace 与失败信息、`scan` 无内容摘要、`FocusMove`；失去前台后每键重新置前的回归用例用合成 `AXApplication` 节点 + 主窗口夹具，模拟「⌃Tab1 落地后用户点走、未激活时按键被忽略」）。`ForbiddenAPITests` 通过。

## 活体

| 步骤 | 结果 |
|---|---|
| 修复前复现（instrumented build 53，kickstart 后立即调用） | 失败 12.02 s；trace 如上（`front=no` 自 ⌃Tab1） |
| 对照 run A（不重启） | 成功 2 步；执行 4.9 s，但 CLI 端 12.06 s——命令在 CLI 发出 7 s 后才被守护进程接受（同一窗口内控制台请求与 describe 也一起排队），见未闭环 |
| 对照 run B（kickstart 后立即调用） | 成功 2 步 5.18 s |
| 确定性复现 C（3.17 s 置前 imctl-console） | 失败 13.35 s，签名同原失败 |
| 修复后 C'（3.22 s 置前 imctl-console） | `⌃Tab2 refront(front=yes landed=true axFrontmost=true 545ms)` → 成功 5.77 s |
| 修复后连续 3 次 kickstart + 立即调用 | 5.21 / 5.17 / 5.14 s，均 2 步到站，2 张卡 `added`，回消息视图 `back=true` |
| 发送 | 0 条 |

## 结论与未闭环

- **通过**：关闭条件（连续 3 次重启后首次调用成功）达成；根因是中途失去前台而非重启。
- 未闭环 / 观察：
  - run A 里守护进程有 ~7 s 不接受 socket 请求（日志无输出，之后请求成批落地），疑似主运行循环里的 watcher 卡在慢 AX 调用（消息视图 texts=87、单次扫描 300–600 ms）；未定位。
  - `GroupPicker`（⌘N + 一次回车）同样只在开头置前一次，同类风险未改——待用户确认 ⌘N 后一并用 `lostFront` 处理。
  - 导航会把企微置前，用户点走后每键再拉回（最多 7 次、≤ 12 s）；用户正在打字时按键会落进企微。是否加「用户活跃时延后导航」由用户决定。
- 用户事项不变：⌘N / 面板回车确认、第二测试成员、退出并重开 `imctl.app`（旧控制台进程仍每 3 s 调 describe）。
