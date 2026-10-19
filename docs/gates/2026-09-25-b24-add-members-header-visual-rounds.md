# B24 `group.addMembers` 打开面板可逆视觉轮次门报告

## 范围与当前结论

- 只改显式 `group.addMembers` 的右侧标题栏“打开添加群成员面板”前缀；AX 唯一精确命中仍零上传。模型仅选择当轮 AX `press` 候选，最多 4 轮 / 2 次按压 / 24 秒；面板标题和空已选表由 AX 读回证明。
- 成员搜索、`确定`、checkpoint、幂等、协议与 MQTT 字段保持 B14 原路径。本批未操作真实企微，发送和加人数量均为 **0**。

## 代码与 fake 证据

| 核对点 | 验证 |
|---|---|
| 专属入口 | 普通 runner 保持 `selectRow` / `scroll`，即使方法为 `group.addMembers` 也在截图前拒绝 `press`；新入口仅允许该方法 + 添加成员目标 + 定位阶段的 `press`。 |
| AX 快路径 | 唯一 `AXHelp` / `AXValue` 精确命中的 fake 读回成功，截图和模型调用均为 0。 |
| 两轮与错误面板 | 首次 AXPress 不起效后第 2 轮成功；错误面板先取消读回关闭才作第 2 次按压。取消未关闭时止步；按后已有预选行的面板也被取消且不进入选人。 |
| 中途复核 | 方法、暂停、视觉许可、策略、窗口、人数和候选 frame 变化时停止，零 AXPress / 零 checkpoint；危险语义按钮未进入模型候选。正确面板已打开而侧栏人数被遮挡的 fake 仍可用面板自身的空已选表读回。 |
| 后验 | 只承认新鲜“添加群成员”面板且已选表存在、行数为 0；整套 B24 fake 均为 dryRun，无 `确定` 和 checkpoint。 |

## 验证与交付

| 层次 | 回执 |
|---|---|
| `swift build` | 通过；外部依赖与旧文件的编译 warning 不属于 B24。 |
| 聚焦与全量 `swift test` | B24 新 suite **12/12**、B14 添加成员旧 suite **30/30**，聚焦 **42/42**；全量 **711/711** 通过（9 个测试产物计数之和），live 套件未启用。 |
| 合并后的回归 | B23/B24/B25 合并后 `swift build`、全量 **723/723** 通过；首次全量运行的旧 `FileFetcher` 取消回调即时断言波动在单项与第二次全量复跑中通过，未改下载代码。 |
| 守卫、diff 与 secret 扫描 | 全量含 `ForbiddenAPITests` / 协议守卫通过；`git diff --check` 通过；secret 扫描仍为 11 条既有示例 / 文档 warning，本批新增文件无命中。 |
| 源码提交 / 推送 | B24 隔离提交 `95ac28f`，主线 cherry-pick 与共享钩子人工合并提交 `a9659c9`；合并版本 `96d2848` 已推送 `main`。 |
| 签名包、本机安装与第二台 Mac | 1.0.11 build 171 已打包并安装至唯一的 `~/Applications/imctl.app`；代码签名验证通过，pkg SHA-256 `83c3610a73420b1053e9f2aa43e54f15bde4acea95d92c417e15c1f7756fa74c`。第二台 Mac 四文件目录及 ZIP 已重做，ZIP SHA-256 `7f2908fd7e831c791de48bf0e6db8ea38c42db878062f4efbcc51ba0090d5e71`，CRC 与内部 pkg hash 一致；第二台 Mac 未安装。 |
| 显式 MQTT / 真实企微视觉分支 | 只读 `controller.describe`、`account.status`、本人文件传输助手 `conversation.read` 成功，守护进程与窗口可达；没有执行真实 `group.addMembers`，fake 结果不构成活体验收。 |

## 未闭环

1. 真企微标题栏歧义样本、云端请求、按压和 AX 面板读回仍待活体。
2. `group.addMembers` 的后续成员搜索和不可逆确认未做多轮模型规划；这一批没有加人授权。
