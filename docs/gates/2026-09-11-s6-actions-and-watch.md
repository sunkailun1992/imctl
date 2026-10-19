# S6：受限动作（G0-3 只读部分）与 watch 基线（G0-5 部分）— 2026-09-11 19:1x CST

条件：企微 5.0.10，窗口在另一 Space，`client_active=false`，前台是另一应用；全部经 `ActionPolicy`（白名单 `["文件传输助手"]` + `--allow-*`）。零合成事件，零 `performAction`。

## 前置发现：活动会话可能没有输入框

19:1x 时活动会话已被切到一个不可回复的会话（系统/通知类账号）：消息表占满 1138 高，无 `AXTextArea`，正文为居中的 `AXStaticText`。`WeComLayout.composer` 因此改为可选；夹具 `Tests/Fixtures/ax-trees/wecom-5.0.10-no-composer.json`。会话表已按活动时间重排（文件传输助手从第 2 行变为第 6 行）——**行序不是身份**，解析必须按标题匹配。

## G0-3 只读部分：通过

| 步骤 | 结果 | 证据 |
|---|---|---|
| `probe select --allow-select 文件传输助手` | verified=true，0.84 s | 活动标题由另一会话变为文件传输助手；`AXSelectedRows` 设值即生效；前后 `client_active=false`、frontmost 不变 |
| `probe compose --allow-compose imctl-probe` | verified=true（读回 11 字符） | 输入框 `AXValue` 接受程序化设值 |
| 设值后重扫按钮 | 29 → 29，无新按钮 | **企微没有向 AX 暴露"发送"按钮**；输入框动作只有 `AXShowMenu` |
| `--clear` | verified=true | 清空后会话行无草稿/未读 badge，`composer: 0 chars` |
| 菜单栏扫描 | 无"发送"菜单项 | 「窗口」菜单有"选择下一个/上一个/下一个未读会话"（`AXPress`），可作切换后备 |

阶段 1 的 submit 候选（按顺序验证，开始前向用户确认）：① 对输入框 `AXConfirm`（未列出但可尝试）；② 输入框 `AXValue` 末尾附加换行是否触发发送（低概率）；③ 都不行 → 路线页的 `CGEventPostToPid` 只作救急验证，主线转方案 B。

## G0-5 部分：watch 基线（空闲 60 s，`--mode both --interval 1`）

```
polls=61 events=0 relocations=0 errors=0 lock_changes=0
cpu: user=0.20s sys=0.10s          # ≈0.5% 单核
poll_ms: max=69 mean=28
subscribe added=24 unsupported=      # app/window/两表/输入框共 24 个通知全部注册成功
```

- 每次轮询取一次 `WatchSnapshot`（会话表 + 消息表 + 输入框），28 ms；1 s 间隔下 CPU 可忽略。
- 空闲期无通知到达；通知 vs 轮询的延迟对比要等有真实消息（夜间运行 + 手机发消息）。

## 门状态

| 门 | 状态 |
|---|---|
| G0-1 | 通过 |
| G0-2 | 未定（仍无入站/出站对照样本；两次观察的正文都居中） |
| G0-3 | 只读部分通过；`AXPress`/提交留阶段 1；无发送按钮是已知风险 |
| G0-4 | 夜间运行中（见 phase0 报告） |
| G0-5 | 会话表/切换/输入框可读可写可复核；观察机制两路都可用；登录态与类型标记未测 |
