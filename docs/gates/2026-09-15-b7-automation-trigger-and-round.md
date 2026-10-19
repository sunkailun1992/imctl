# 门报告：B7 补丁——自动化触发不再依赖角标 + 远程模式整轮（2026-09-15 16:1x CST）— 通过

接续 `docs/gates/2026-09-15-b7-contacts-navigation-refront.md`（同日 `4bb6a8d`）与 B7 未闭环项「自动化整轮」。用户 16:08 指出：有人申请新客户后能看到红点，但人工点一下红点就没了、好友并没有加上，卡片仍显示「接受」。

## 条件

- 企业微信 5.0.11；守护进程 = `~/Applications/imctl.app` 内 release 包 build 54（`build-pkg.sh release` → `installer -target CurrentUserHomeDirectory` → `launchctl kickstart -k`），签名标识不变、`trusted:true`。
- 通讯录 › 新的客户 有 3 张卡：1 张新的 `pending`（不是 测试联系人A，本报告只记状态与长度）、2 张 `added`（真实联系人 + 测试联系人A）。
- 只用 `remote` 模式（只发事件、由业务侧逐条决定），**0 次接受、0 条发送**；策略改动：`imctl policy requests --auto-accept remote` → 20 s 后 `--auto-accept off`。

## 活体事实

| 项 | 结果 |
|---|---|
| 角标（用户点过之后） | `state.json.newCustomersBadge = 0`，而 `contact.request.list` 仍返回 1 张 `pending`——**角标是未读计数，人工点开即清零，不等于待处理** |
| 守护进程自己读一次之后 | `newCustomersBadge = 1`（又回来了）——角标不稳定，不能只在「变大」时跑一轮 |
| 旧触发（B7 `25633e6`）在此场景 | 守护进程 16:03 重启时角标已是 0：`lastBadge=0`、无「变大」→ 永远不进通讯录，pending 请求无人处理 |

## 实现

- `RequestRoundTrigger`（`Sources/WeComAdapter/Contacts/RequestTrigger.swift`，纯状态，6 个单测）：一轮的触发 = 角标**任何变化**（清零后等 30 s 再进，人多半还在那页）、策略从 `off` 切到非 `off`、守护进程启动且策略非 `off`；角标 > 0 期间每 30 min 扫一轮；失败一轮 5 min 后重试；两轮 ≥ 60 s、进行中不叠加、`off` 不进通讯录。`poll` 返回原因（`start` / `badgeChanged` / `switchedOn` / `sweep` / `retry`）写进日志。
- `RequestAutomation` 改用它（`runRound` 返回是否读到卡片，失败进入重试）；执行器、策略、接受与建群逻辑不变。
- 文档：规格 §7 活体修正、协议 §6.32 触发说明。

## 单测

`swift test`：**266 个用例、74 个套件全部通过**（上一报告 260 → +6）。

## 活体

| 步骤 | 结果 |
|---|---|
| 16:16:13 kickstart（策略 `off`） | 首次轮询 `start` 记为待办，`off` 不进通讯录 |
| 16:16:16 `--auto-accept remote` | 16:16:17 `policy reloaded` → `requests: round (switchedOn, badge 1)` |
| 一轮 | 导航 2 步到站（中途前台再次被拿走，`⌃Tab2 refront(...)` 后到站，4.2 s）→ 回消息视图 → `requests: 3 card(s), 1 new, 0 to accept` |
| 事件 | `contact.request.observed{name:<5 chars>, greeting:<7 chars>, source:wechat, status:pending}`（event_id 22682）；无 `accepted`、无 `group.created` |
| 16:16:36 `--auto-accept off` | 热加载，之后无轮次 |

## 结论与未闭环

- **通过**：B7 未闭环项「自动化整轮（`remote` 下产出 `contact.request.observed`）」关闭；触发不再依赖角标变大。
- 新的 `pending` 请求**不是 测试联系人A，未接受**——是否为用户的测试号、要不要用它验「接受 → 打招呼」原地刷新，由用户定。
- 代价（用户可调）：策略非 `off` 时，每次守护进程启动会进一次通讯录；人工清零角标后 30 s 守护进程会进一次；失败每 5 min 重试一次。
- 仍未闭环：≥ 2 人真实建群（待第二测试成员）、群解析（待测试群）、⌘N / 面板回车确认、run A 观察到的守护进程 ~7 s 不接 socket、`GroupPicker` 同类前台风险。
