# B37 群改名标题编辑两轮视觉观察 — 代码与 fake 通过，活体待验

## 范围

显式 `group.rename` 在固定目标会话已选中后，对同一群名 `AXTextField` 的写值前后各做一次经核验的企微窗口观察。模型只可复核、重观察或停止；请求群名、策略、checkpoint、唯一 `AXConfirm` 与列表选中行后验仍由原命令负责。`group.create` 与视觉关闭的确定性 AX 路径保持原状。

## 源码与 fake 证据

- `AIPlannerReversibleRunner.observeGroupNameField` 只接受 `.groupRename`、群名字段目标及 `AXTextField`；输出允许集合只有 `verify/reobserve/stop`。前后两次复用同一模型配置，重观察计入命令级 6 轮、40 秒预算。
- 处理器锁定企微窗口/PID/位置、右侧标题带唯一可写字段句柄/角色/位置、原群选中行、策略及本机录屏和视觉设置。右标题带扫描最多 128 个非表格 AX 节点；歧义或超限失败关闭。编辑字段改值后标题栏可提前回显请求名，但选中列表行仍必须是原群。
- 动作层只在两次被动观察和精确 AX 读回通过之后落原 checkpoint 并最多确认一次。模型 `stop`、非法 `writeText/press`、权限失效、双编辑框、策略/字段/选中行漂移均在确认前停下；没有自动纯 AX 降级。写值后若准备失败，只在同窗、同原群选中行、同字段且值未被他人改动时把草稿恢复原名并读回；无法证明恢复时先记录不确定 checkpoint，让 MQTT 返回 `unknown`，避免留下可失焦提交的草稿却报 `failed`。
- 原批 `swift build -q` 及主工作树 `swift test -q` **825/825** 通过。追加安全修复后 `swift test -q --filter B37GroupRenameVisualTests`：6/6 通过；本轮最终全套测试与发布包结果另记总门报告。Fake 成功例证明两次截图/决策、一次字段 AXValue 写入、一次 checkpoint、一次 AXConfirm 与列表行新标题后验；失败例证明零确认，并区分可证明回滚的 `failed` 和无法证明回滚的 `unknown` checkpoint。

## 活体边界

本 B37 批次真实群改名 **0 次**；没有千问两轮请求、企微列表行及 MQTT 终态的活体同向证据。B33 已完成的两次测试群改名沿确定性 AX 路径，不能充当本批视觉验收。主执行者须在明确的新目标/次数授权下单独核对安装版的模型计数、客户端选中行和事件；未做之前 `group.rename` 的 B37 视觉分支仍为**待活体**。
