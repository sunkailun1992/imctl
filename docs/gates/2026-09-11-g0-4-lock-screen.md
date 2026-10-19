# 门 G0-4：锁屏遮挡下 AX 刷新（2026-09-11 20:5x CST 判定）— **失败**（同会话锁屏期间 AX 树不可读）

数据源：`2026-09-11-night-watch.stdout.txt` / `.jsonl`（`probe watch --seconds 28800 --interval 1 --mode both`，19:15:37 起，pid 18202，仍在运行）。时间戳为 UTC，下文换算成 CST。

## 时间线

| CST | 事件 | 含义 |
|---|---|---|
| 19:15:37 | start，24 个通知注册成功 | 基线：活动会话文件传输助手，8 个会话，1 条可见消息 |
| 19:18:23 / 19:33:26 / 19:48:29 | 每 15 分 03 秒一次 `AXRowCountChanged` + `AXSelectedRowsChanged`（会话表） | 企微周期性重建会话列表；前两次内容无变化（无 diff），第三次让缓存元素失效 → `relocate ok=true`（60 ms） |
| 19:58:19.04 | poll 报 `invalid or stale AX element` | 锁屏瞬间元素失效 |
| 19:58:19.09 | `relocate` 失败：`could not locate WeCom region conversationTable`；同 tick 记 `screen_locked=true` | 锁屏期间 `AXMainWindow` 仍可取到，但窗口后代里**找不到任何 AXTable**（子树不可读或为空） |
| 19:58:20–23 | 每秒重复：元素失效 + 重定位失败（共 5 次） | 整个锁屏期间 AX 读不到内容 |
| 19:58:24.06 | `screen_locked=false`；随后的 poll **用原来缓存的元素成功** | 解锁即恢复；元素未被销毁，只是锁屏期间不可解析 |
| 20:01:05 | `AXApplicationActivated` | 用户把企微切到前台（解锁状态） |
| 20:01:25.17 | `AXRowCountChanged` ×2 + `AXSelectedRowsChanged` → 20:01:25.40 diff：`message count 1 -> 2`，`message #1 added dir=outbound time=20:01`，会话表重排（文件传输助手 → #1） | 手机发的第 1 条；**通知 → 观察 233 ms**（含 150 ms 去抖） |
| 20:01:26.87 | `AXRowCountChanged` → 20:01:27.04 diff：`message count 2 -> 3`，`message #2 added dir=outbound` | 第 2 条；**173 ms** |
| 20:01:32 | `AXApplicationDeactivated` | 用户切走 |

## 结论

1. **G0-4 未关闭，首个样本不利**：锁屏的 5 秒内，企微 AX 树对本进程不可读（缓存元素 `invalidUIElement`，重新从 `AXMainWindow` 定位也找不到表）；解锁后立刻恢复。5 秒太短，不能排除是锁屏过渡期的瞬时效应，需要 **≥ 5 分钟持续锁屏、并在锁屏 2 分钟后从手机发消息** 的复测：
   - 若整个锁屏期间持续不可读、解锁后才补出消息 → G0-4 失败，方案 A 只能配"不锁屏"政策（合盖外接屏常亮、无口令屏保）或转方案 B 虚拟机。
   - 若只在锁屏/解锁前后几秒不可读、其余时间通知与 diff 正常 → G0-4 通过，watcher 只需容忍过渡期错误。
2. **两条手机消息不是锁屏样本**：它们在解锁状态、企微处于前台时到达（20:01:05–20:01:32 之间），只证明观察链路本身：AXObserver 通知先于轮询，通知→观察 173–233 ms；轮询路径也会在 ≤ 1 s 内看到。
3. **G0-2 补充**：手机发到文件传输助手的短消息在桌面端显示为右贴边 `AXTextArea`（x=1887–1894，表 310–1921），`DirectionInference` 判 `outbound`，符合"同账号消息为出站"。此前那条 35 字符正文（x=909–1321，居中）仍未解释（可能是长文本/卡片的布局），入站样本仍缺。
4. **G0-5 补充**：企微每 ~15 分钟重建会话列表，会让缓存的 AX 元素失效；`WatchRunner` 的"出错即重定位"策略有效（60 ms）。会话行相对时间标签（"2分钟前"）已纳入解析与脱敏保留模式。

## 复测步骤（给用户）

1. watch 仍在运行到 03:15；不需要重启。
2. 锁屏（合盖状态不变），**保持锁屏至少 5 分钟**；锁屏 2 分钟后用手机向文件传输助手发 1 条，再过 1 分钟发第 2 条；然后解锁。
3. 读 `docs/gates/2026-09-11-night-watch.stdout.txt`：看 `lock screen_locked=true` 到 `=false` 之间是否有 `ax`/`poll` 行，还是只有 `error`/`relocate ok=false`。

## 第二次读数（用户锁屏 ≥5 分钟后，20:5x CST）

| CST | 事件 |
|---|---|
| 20:18:32 | 周期性 `AXRowCountChanged` + `AXSelectedRowsChanged`（15 分钟节律延续：20:18、20:33、20:48） |
| 20:23:24 – 20:23:28 | 第一次锁屏 4 秒：poll 元素失效、重定位失败 |
| **20:24:28 – 20:30:26** | **第二次锁屏 5 分 58 秒：每秒 poll 都报 `invalid or stale AX element`，每秒从 `AXMainWindow` 重定位都报 `could not locate conversationTable`，共 362 次连续失败；期间 0 条 AX 通知** |
| 20:30:26 | `screen_locked=false`；解锁后的第一次 poll 即成功（原缓存元素恢复可用） |
| 20:33:40 | `AXRowCountChanged` → 194 ms 后 diff：`message #3 added dir=outbound time=20:33` |
| 20:52:09 | `AXRowCountChanged` → 187 ms 后 diff：`message #4 added dir=outbound time=20:52` |

- 两条消息的桌面端时间标签是 20:33 与 20:52，都在解锁（20:30:26）之后；锁屏期间没有任何消息进入 AX 树（也无法判断是否有消息到达客户端）。
- 锁屏 6 分钟内失败连续、无一例外，解锁后瞬时恢复，且新建元素（重定位）同样失败：不是过渡期效应，是**锁屏期间用户会话内的进程读不到企微的 AX 子树**（`AXMainWindow` 仍返回元素，但其后代为空/不可解析）。

## 判定

**G0-4 失败（方案 A 在锁屏下不可用）。** 与路线页"锁屏下 AX 树不刷新 → 不锁屏（政策）或方案 B"一致，需要用户决定：

| 选项 | 含义 | 代价 |
|---|---|---|
| A′ 不锁屏政策 | 控制器 Mac 永不锁屏（合盖外接屏常亮、屏保不要口令），员工离开也不锁 | 与员工日常用机的安全习惯冲突；任何一次锁屏 = 控制中断，需要 `system` 暂停原因 + 解锁后自动恢复 |
| B 虚拟机 | 企微与 `imctld` 跑在 macOS 客体（Virtualization.framework / Tart / UTM），宿主随便锁；客体会话永不锁 | 内存 4–8 GB、客体单独登录企微（设计上员工本就不在宿主用企微）、客体内 TCC/签名重做一遍、需复验 G0-1/G0-3 |
| C 第二用户会话 | 主题页已不推荐（非活动会话的 AX 同样受限） | — |

推荐：**先做 B 的最小验证**（一台 macOS 客体 + 企微 + 本 CLI 的 `probe watch`，宿主锁屏 ≥5 分钟），因为 A′ 只是把风险转成政策；如果 B 验证通过，阶段 1 直接在客体里做。

## 决定（2026-09-11 21:44，用户）

采用 **A′**：控制器 Mac 一直开着、不锁屏；极少发生的更新或锁屏不需要解决。方案 B 不做。落实到代码：锁屏 → `controller.pause` 的 `system` 原因，解锁 → 自动恢复并重定位（阶段 2 的 `imctld` 实现）。
