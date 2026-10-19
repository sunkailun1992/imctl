# 门报告：B7 收尾——⌘N / 回车批准、测试号接受与 ≥ 2 人真实建群、三处活体修正（2026-09-15 16:3x–20:3x CST）— 通过（两项修正待下一次活体）

接续 `docs/gates/2026-09-15-b7-automation-trigger-and-round.md`。用户 16:32 决定：新的申请人是测试号（下称测试号 2，名字不入库）；⌘N 与选人面板搜索框回车**批准**；测试号 2 作为 ≥ 2 人建群的第二成员；触发代价接受；控制台重开需核实。

## 条件

- 企业微信 5.0.11；守护进程 = `~/Applications/imctl.app` 内 release 包（先 build 55 含本报告修正的工作树版本，提交后重建为 build 56），`installer -target CurrentUserHomeDirectory`，签名标识不变、`trusted:true`。
- 动作只对测试账号：接受 1 次（测试号 2，经守护进程 `rules` 轮次）、建群 1 次（成员 = 测试号 2 + 测试联系人A + 本人，经 `imctl call group.create`）；**0 条消息发送**；策略改动：`--auto-accept rules --allow-name <测试号 2> --auto-group perPerson --default-member 测试联系人A`，轮次后 `--auto-accept off`（`autoGroup` / 名单 / 默认成员保留在 `policy.json`）。

## 实现

- **⌘N / 回车已批准**：README、规格 §7、`KeystrokeInjector` 注释改为「用户 2026-09-15 16:3x 批准」；`GroupPicker` 的 ⌘N 与每个成员的回车都经 `withFront`（失去前台先置前），`createGroup` 结果多 `refronts`；`withFront` 从 `openContacts` 抽出共用。
- **接受校验重定位表**（活体修正 A）：「完成」后客户端重建卡片表，旧元素 3 s 内失效；`contactRequestAccept` 每次轮询重新定位表，缺失 / 失效 / 为空算未落定，非空列表里卡片消失算已接受。
- **自动化幂等键**（修正 B）：`RequestDecision.attemptKey`——执行器对同一键一律回放（失败也回放），上次失败 / 过期 / 取消换 `…-r<ms>` 新键；成功、`unknown`、进行中回放。`RequestAutomation` 的 accept / group 键都经它。
- **建群等客户端切到新群**（修正 C）：`createGroup` 在「完成」前记头部，之后最多等 `groupOpenTimeout` 10 s 直到头部带成员数、或异于之前、或由成员名拼成；结果与 `group.created` 事件带 `opened`；`verified` = 面板关闭且已打开。
- 测试基座：`FakeAXBackend.onRead` 钩子（第 N 次读后改树）。协议 §6.32 / §7.8 与规格 §7 同步。

## 单测

`swift test`：**271 个用例、74 个套件全部通过**（上一报告 266 → +5：面板每键前置前、重建表后接受、失败后换键、异步开群等待、无成员数的外部群头部）。一次全量运行里 `axConfirmOnFixtureFails`（0.3 s 超时的夹具探针）在并行负载下失败一次，单独连跑 3 次与再次全量均通过——计时抖动，未改断言。

## 活体

| 步骤 | 结果 |
|---|---|
| 进程核实（用户「关闭并重开」控制台后） | 只剩 09:33 启动的旧控制台进程（关窗不退出菜单栏应用，重开只是激活旧进程）；`kill -TERM` 后 `open -a` 重开，得到新进程；守护进程单实例（launchd pid 一致，`state.json` 一致）；20:27 再次装包后同样重开控制台 |
| `rules` 轮次（16:39，build 55 前版本） | 策略切换 1 s 内 `round (switchedOn, badge 1)` → 列表 3 张卡、1 待接受 → 接受：客户端**已接受**（随后 `contact.request.list` 测试号 2 = `added`，会话列表出现其单聊），但命令 `failed CLIENT_UNAVAILABLE: invalid or stale AX element`（完成后表重建）→ 未进入建群；修正 A、B 由此而来 |
| `group.create{members:[测试号 2, 测试联系人A]}`（16:43） | 命令 3.3 s「成功」但 `title:文件传输助手, memberCount:""`；4 s 后客户端切到新外部群（`conversation.activity` 08:43:20，会话列表多一行、`badge:外部`、标题 = 成员名以顿号相连含本人）；修正 C 由此而来。**≥ 2 人真实建群成立**（面板 ⌘N、两次回车、完成均到位，`refronts=0`） |
| 群头部（20:2x，只读 raw dump，未存） | 头部文本框 = 17 字符成员名串，**无 "(N)"**；`account.status.activeType = unknown`——外部群头部不带成员数，`conversationType` 无法由头部判定 |
| 修正 A / B / C 活体 | 单测覆盖；A 需新的待接受请求、C 需再建一个群才能活体复验，本轮未做 |
| 发送 | 0 条 |

## 结论与未闭环

- 通过：⌘N / 回车纳入批准范围并同样每键前置前；测试号 2 已接受、三人外部群已建；接受与建群的活体事实进规格 §7 与协议。
- 待下一次活体：修正 A（把测试号 2 删了重新申请即可复验）、修正 C（再建群一次）。
- 新发现：外部群头部无成员数 → 群解析（`conversationType:group`、sender 归因）不能依赖头部 "(N)"，需要另一信号（行角标「外部」+ 顿号标题、消息区发送者标签）——待用户给出可发消息的测试群并批准 `policy allow` 后校准；向新群发消息未授权、未做。
- 仍未闭环：守护进程一次 ~7 s 不接 socket；`requestedName` 不生效（改名未实现）；`auto-accept-<sha16>` 对测试号 2 的失败记录仍在库中（下次同名同打招呼语会用新键）。
