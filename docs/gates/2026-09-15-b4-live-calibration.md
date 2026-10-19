# 门报告：B4 活体校准与稳健性修正（2026-09-15）

计划（as-built）：`docs/superpowers/plans/2026-09-15-b4-live-calibration-fixes.md`。用户决定（09:06 CST）：接受 `client.navigate` 抢前台一闪；装包后继续 B4 活体校准。校准时安装包尚未装到系统（LaunchAgent 仍是 09-14 旧稳定副本、未授权），所以全部经**临时守护进程**（终端启动、继承授权、独立 DB / 状态 / 套接字 / 策略文件）完成；结果只关乎客户端解析与控制器逻辑。

## 条件

- 企业微信 5.0.11，消息视图，会话筛选侧栏打开，起点 文件传输助手；桌面列表 11 个会话，**没有任何群会话**（全部 `unknown`、无标记）。
- 发送只对 文件传输助手，共 4 条（`imctl-b4-1` / `-3` / `-6` / `-8`）；另 3 次尝试被 `RATE_LIMITED` 或 `LOCAL_GUARD` 拦下、未发出。导航走遍可见会话后回到 文件传输助手；真实标题只记长度；走会话清掉了 3 个未读角标。

## 校准结果

| 项 | 结果 |
|---|---|
| 策略热加载 | `imctl policy allow --file <临时> --title 文件传输助手` → 2 s 内 `controller.state{policy:"titles=1 …"}`（事件 105），`controller.describe.policy` 同步 |
| 身份桥 + `chatId:` 目标 | `imctl identity set --kind group --id b4test --title 文件传输助手` → `message.send{target:"chatId:b4test"}` 成功（303 ms，证据行 #16） |
| `RATE_LIMITED` | 同一目标串 3 s 内第二条 → `RATE_LIMITED`（867 ms） |
| **缺陷 A** 限速键按写法 | 同一会话改用标题写法紧接着发 → 未被限速。修：执行器限速键 = 经桥解析的会话标题；活体复验 `chatId:` 后 3 s 内标题写法 → `RATE_LIMITED` |
| **缺陷 B** 归因 | `chatId:` 发送的气泡被记 `origin:other`。两层原因：(1) 归因把 wire 目标串与客户端标题比；(2) AX 通知先于取证到达，命令仍 `running`，不在 `recentSends` 里。修：`recentSends` 经桥解析 id 目标，并纳入已过 checkpoint 的 `running` 发送；活体复验 `origin:controller` + `commandId` |
| **缺陷 C** 空白面板锁死 | 导航进入某会话后窗口只剩筛选表与会话表（无消息表 / 输入框 / 头部），watcher 抛 `invalid or stale AX element` → 立刻 `system` 暂停 → `conversation.read` / `client.navigate` 全部 `PAUSED`，只能人工解救（当时用进程内 `probe select` 恢复）。修：`AvailabilityTracker`——硬失败（应用不在 / 未授权 / 无窗口）立即暂停，瞬时失败连续 10 次才暂停；活体复验：同一面板上 9 s 后 `paused:[]`、日志 `watcher degraded`、`conversation.read` 回 文件传输助手 成功 |
| **缺陷 D** 空白面板重定位风暴 | 该面板下每次轮询都重定位并重订阅 24 个 AX 通知。修：无消息表 / 输入框时每 5 次轮询重定位一次 |
| **缺陷 E** 无头部时标题为空 | 修：没有头部元素时回退到选中行标题（有头部时不回退，`selectConversation` 复核不变）；活体 `account.status.activeTitle` 在该面板上给出行标题（4 字） |
| **缺陷 F** 事件字段 | `message.observed` 带 `sender:""`；桥已知群但 `conversationType:unknown`。修：sender 为空即省略；类型 unknown 时按桥补（同 `TargetResolver` 规则）；活体复验 `conversationType:group`、无 `sender` 键 |
| `client.navigate` | next 进入通知类会话 / 普通会话正常；`nextUnreadConversation` 无未读时 `changed:false`（合法）；走到空白面板时 before / after 由回退标题给出 |
| `LOCAL_GUARD` | 一次 `chatId:` 发送被 `composer not empty` 拦下（切换后输入框短暂非空），2 s 后重试成功——互锁按设计工作，记为观察 |

夹具新增 `wecom-5.0.11-blank-pane.json`（脱敏；该面板的完整窗口树）。协议文档：速率上限改为"按会话（id 经桥解析）"，`message.observed.sender?` 可缺、类型按桥补，§12 追加。

## 单测

`swift test` **231 / 68 全部通过**（+9：`AvailabilityTrackerTests` 2、`BlankPaneFixtureTests` 3、`ControlStoreTests` 2、`CommandExecutorTests` 1、`WatchEngineTests` 1；既有 `groupObservationsCarrySenderKeyTypeAndBridgeIds` 的类型断言按新规则改为 `group`）。

## 结论

B4 的策略 / 身份桥 / 限速 / 事件字段在真实客户端上闭环，且修掉了六个只有活体才暴露的缺陷（其中缺陷 C 是"守护进程把自己锁死"的严重项）。**群解析未校准**：桌面列表里没有群会话，群头部 "(N)"、发送者标签、`外部群` 标记无从验证。

## 需要用户

1. 让测试群出现在桌面「消息」列表（手机上在群里发一条即可）并告知群名，我再做群解析校准与群内发送（`policy allow --title <群名>`）。
2. `sudo installer -pkg out/imctl-0.1.0.pkg -target /` → 控制台"安装 / 更新守护进程" → 勾选 `imctld` 辅助功能（把 LaunchAgent 从旧副本切到包内新版，才能用真实守护进程而非临时进程）。
3. 其余不变：企微自建应用参数与代理主机、EMQX 凭据 / ACL、Developer ID。
