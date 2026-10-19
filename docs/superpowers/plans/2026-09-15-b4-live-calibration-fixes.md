# B4 活体校准与稳健性修正（as-built，2026-09-15）

> 计划在校准中产生：活体先跑，每个缺陷各补一个失败测试再修，最后一次 `swift test`。用户决定（09:06 CST）：接受 `client.navigate` 抢前台一闪；装包后继续 B4 活体校准。

**Goal:** 在真实客户端上校准 B4（策略热加载、`chatId:` 目标经身份桥、`RATE_LIMITED`、事件字段、群解析），并修掉校准暴露的稳健性缺陷。

**Global Constraints:** 同 B6；发送只对 文件传输助手（本轮 2 条：`imctl-b4-1`、`imctl-b4-3`）；导航后恢复 文件传输助手；真实标题只记长度；临时守护进程从终端启动。

## 校准发现 → 任务

| # | 发现（临时守护进程，2026-09-15 09:1x） | 修正 | 测试 |
|---|---|---|---|
| 1 | 导航进入某会话后：窗口只剩筛选表与会话表（无消息表 / 输入框 / 头部），watcher 抛 `invalid or stale AX element` → 立刻 `system` 暂停 → `conversation.read` 也 PAUSED，无法自救 | `AvailabilityTracker`：硬失败（应用不在 / 未授权 / 无窗口）立即暂停，瞬时失败连续 10 次才暂停；`DaemonWatcher` 用它 | `AvailabilityTrackerTests` 2 |
| 2 | 该面板下每次轮询都重定位并重订阅 AX 通知 | `WatchEngine.relocateWhenAbsentEvery = 5` | `BlankPaneFixtureTests.engineThrottlesRelocation…` |
| 3 | 该面板下 `activeTitle` 为空，导航 before / after 无意义 | `WeComReader.activeConversationHeader` 在没有头部元素时回退到选中行标题（有头部时不回退） | `BlankPaneFixtureTests` 2（夹具 `wecom-5.0.11-blank-pane.json`） |
| 4 | `chatId:b4test` 发送成功，但 `message.observed` 记 `origin:other`（归因把 wire 目标串与客户端标题比） | `ControlStore.recentSends` 经桥把 id 目标解析成标题（`conversationTitle(for:)`） | `ControlStoreTests.recentSendsResolveIdTargets…` |
| 5 | 同一会话用 `chatId:` 与标题两种写法在 3 s 内各发一条，第二条未被 `RATE_LIMITED` | 执行器限速键 = `store.conversationTitle(for:)` | `CommandExecutorTests.rateLimitIsPerConversationNotPerSpelling` |
| 6 | 事件 `sender:""`；桥已知群但 `conversationType:unknown` | `WatchEngine`：sender 为空则省略；类型 unknown 时按桥补（同 `TargetResolver`） | `WatchEngineTests.bridgeFillsTheType…` |
| 7 | 修 4 之后复验仍 `origin:other`：AX 通知先于取证到达，命令还是 `running`，不在 `recentSends` 里 | `recentSends` 纳入已过 checkpoint 的 `running` 发送 | `ControlStoreTests.recentSendsIncludeInFlightSends…` |

## 校准通过项（复验：`origin:controller` + `commandId`、`conversationType:group`、无 `sender` 键、按会话 `RATE_LIMITED`、空白面板不再暂停）

策略热加载（`controller.state{policy}` 事件 105，2 s 内）；`identity set` + `chatId:` 发送（303 ms，事件带 `chatId`）；同目标 3 s 内 `RATE_LIMITED`；`client.navigate` next 进入通知类会话 / 回读；`conversation.read` 回 文件传输助手。

## 未校准

桌面会话列表里没有任何群会话（11 行全 unknown、无标记），群头部 "(N)"、发送者标签、`外部群` 标记无法校准——需用户让测试群出现在桌面列表并告知群名。
