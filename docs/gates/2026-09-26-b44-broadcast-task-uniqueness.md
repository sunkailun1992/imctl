# B44 群发确认任务唯一性门（2026-09-26 CST）

## 变更

显式 `broadcast.confirm` 在按「发送」前遍历企微主窗内的 sheet 和同进程独立窗口，要求只有一个面板同时包含「群发」及请求的完整 `msgid` AX 文本，并且该面板只有一个可用的发送按钮。checkpoint 前和之后均重新扫描，面板或按钮句柄变化即停；checkpoint 后失败由命令执行器归为 `unknown`。

## 证据

- `swift test --filter BroadcastConfirmTests -q`：5/5 通过。Fake 覆盖唯一面板成功、缺 `msgid` / 多发送按钮 / 同窗重复面板与跨窗口重复任务拒绝，以及 checkpoint 后按钮变化时零按键。
- 本批真实群发助手任务样本与发送授权均无；真实 `broadcast.confirm` 调用 **0 次**，千问整窗调用 **0 次**。当前仅完成确定性 AX 安全门，未声称该方法已具备或通过多轮视觉活体验收。

## B44 视觉补充（源码与 fake）

全局窗口列表枚举失败现在直接拒绝，避免将未知的其他企微窗口当作不存在。显式 `broadcast.confirm` 在原 AX 唯一证明后，对同一任务窗口的唯一发送按钮作有界被动视觉复核；模型仅能 `verify/reobserve/stop`。每次模型前后及 checkpoint 后按键前均重验原任务、PID/窗口/面板/按钮句柄、策略/暂停/录屏和冻结的视觉设置。按后按钮消失或禁用时按 AX 证据收口；按钮仍在同一面板时可二次观察，但不能据模型自评宣布成功。

- 聚焦 fake：`swift test -j 2 --filter B44BroadcastVisualTests -q` **7/7**；`swift test -j 2 --filter BroadcastConfirmTests -q` **6/6**。包含跨窗 `AXWindows` 枚举失败时 checkpoint=0、按键=0，以及 checkpoint 后策略变化不再按键。
- 真实群发确认 **0 次**，真实模型请求 **0 次**；当前没有真实群发助手任务 AX 样本，也未取得专项发送授权。该方法的视觉活体验收仍待完成。
