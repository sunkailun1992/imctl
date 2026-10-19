# B17 固定桌面命令视觉覆盖核对（2026-09-26 CST）

本表按 B34–B44、B46–B47 及 B45 整合修正后的源码和当批门报告核对模型实际参与的步骤。`AIPlannerStepContext` 允许某个动作，不等于命令曾截图或调用模型；fake AX / 假 HTTP、安装版真实千问、MQTT 终态和客户端 AX 后验分别计证。下表的活体结论始终标明 build，后续安装包不能继承旧 build 的成功。视觉只协助显式固定命令中的有限步骤，成功仍取决于 AX 客户端后验，不能称为通用自主操作代理。

| 桌面方法 | 已实现的视觉步骤与固定 AX 边界 | 证据层次 |
|---|---|---|
| `account.status`、`conversation.list` | 纯 AX 读取，没有视觉轮次；纳入 B17 固定方法范围不意味着必须上传截图 | 既有 MQTT 读取可用；不列为视觉通过 |
| `conversation.read` | 非当前目标时 B34 模型从当前窗口安全 AX 会话行候选选行，动作后取新帧复核；活动标题仍由 AX 判定 | **真实只读切换通过**：debug 与 release build 186 各两次、release build 211 又两次；release build 224 切回本人文件传输助手约 10.94 秒成功，**2/2/2**，MQTT、`command.get` 与 AX 活动标题同向 |
| `message.history` | B35 在确需返回最新或向前滚动、且存在唯一可写消息滚动条时模型选条、定值滚动并新帧复核；无需滚动不截图，历史解析和返回值仍由 AX | **限定分支真实通过**：回最新在 debug build 185、release build 215 与中间 build 222 有两轮成功证据；build 211 曾超时失败。build 222 向更早消息的首次滚动遇旧行补入后 `INTERNAL`；release build 224 相同 `scrollback:true` 场景返回 48 行、**2/2/2**、MQTT 成功并由 AX 读回回到最新 |
| `message.send`、`message.sendFile` | 非当前目标复用 B34 选行；仅**直接命令**在唯一输入框暂存固定正文 / 原附件前后做 B36 被动复核。AX 写值 / 已批准的 ⌘V、checkpoint、一次提交及新外发气泡后验不由模型替代 | B36 源码和 fake 通过；真实视觉发送 **未验**。B33 四条纯 AX 测试发送不能替代 B36；不因 B34 只读切换推定写入通过 |
| `client.navigate` | B40 在菜单可用且 AX 能预测不同的下一侧栏行时，固定 AX 菜单按压前后被动观察主窗；模型看不到 macOS 菜单，也不能选择菜单项。无需切换或菜单不可用走 AX 快路径 | build 211 截图前 `staleView`、中间 build 222 模型 `stop`；**release build 224 真实通过**：下一个与上一个会话分别约 11.27 秒和 9.23 秒、每次 **2/2/2**，MQTT、`command.get`、独立 AX 标题一致且回到原会话 |
| `contact.list` | B38 仅本命令选人面板第一次确需改动唯一联系人滚动条时，模型选条并在写值后复核；后续固定位置均为 AX，不扫描全页模型 | build 211 一次真实 HTTP 200 后模型停止；中间 build 222 **2/2/2** 成功；**release build 224 `limit:10,scope:all` 约 14.2 秒、4/4/4、MQTT 与 `command.get` 成功** |
| `contact.request.list` | B35 在唯一「新的客户」行可见且未选中时模型选行、新帧复核，AX 确认选中和申请表就绪；已选中时不上传 | **限定视觉分支真实通过**：debug build 185 两轮、MQTT 成功和 AX 后验；release build 224 已选中快路径约 5.95 秒成功且 **0/0/0**，不算本版本新模型调用 |
| `contact.request.accept` | 进入「新的客户」可复用 B35 导航；B41 对唯一待处理卡片「接受」和本命令备注弹层「完成」各作一次被动复核。固定 AX 按键、各自 checkpoint 与最终卡片 `added` 状态才决定成功；B46 收紧为卡片消失、表暂空或旧句柄均不能当作 `added` | B41 源码与 fake、B46 状态守卫测试通过；无可核对的自有待处理申请，真实接受、两次千问请求和 MQTT 终态 **未验** |
| `contact.add` | B42 拒绝接管预开搜索窗；本命令新开的唯一空白搜索窗，在写号码前、唯一来源结果按「添加」前、邀请确认前可作被动复核。号码、来源、邀请由固定 AX 与策略决定 | 源码和 fake 通过；主窗和第二窗可能高度重叠，截图无法唯一对应目标窗口时**失败关闭**；真实千问 / MQTT 邀请 **未验** |
| `group.create` | B43 在本命令「发起群聊」面板按「完成」前及 AX 已证实新群后作被动复核；逐个选人、精确已选姓名、一次确认、新插入唯一群行及群头证据由 AX 守卫 | 源码和 fake 通过；无两个可核对的自有测试成员，真实建群与两次千问请求 **未验** |
| `group.rename` | 非当前群复用 B34 选行；B37 对唯一群名字段固定写值前后被动复核，原 AX 值、checkpoint、一次 `AXConfirm` 和列表新标题决定终态；不确定草稿恢复归 `unknown` | 源码与 fake 通过；B33 两次确定性 AX 测试改名不算视觉通过，真实千问改名 **未验** |
| `group.addMembers` | 非当前群复用 B34 选行；B39 即使表头 AX 名称精确，打开本命令空选人面板时也做选标题候选与动作后复核。成员身份、`dryRun`、checkpoint 和最终「确定」仍由固定 AX 守卫 | build 215 前缀失败；**release build 224** 对自有群与已在群内的本人账号 `dryRun` 约 14.99 秒、**4/4/4**、MQTT 与 `command.get` 成功，`added=[]`。真实新增成员仍未验 |
| `broadcast.confirm` | B44 先以跨企微窗口全局唯一 `msgid` 面板和唯一可用「发送」按钮证明任务；再作被动视觉复核。checkpoint 后重扫，按后按钮消失 / 禁用由 AX 判定；同面板按钮仍在时才可选做新帧复核 | 源码与 fake 通过；无真实助手任务与专项发送授权，真实确认和千问请求均 **未验** |
| `message.broadcast` | 每个子 `message.send` 的非当前目标可复用 B34 选行；**群发子命令故意跳过 B36 输入框被动观察**。各目标策略、幂等、速率、checkpoint 与事件仍独立执行 | 无本批新增发送授权或真实群发视觉链；不能由单聊或只读选行推定群发通过 |

`policy.*`、`command.*`、`controller.*`、`event.replay`、企微官方 API 方法、后台 watcher、`message.media` 缓存与 B15 媒体方向补证据都不属于 B17 主动整窗规划入口。视觉可用还需要屏幕录制授权、`cloudEnabled`、`fullWindowEnabled` 和当前提供商密钥；不满足时按各方法的 AX 快路径或明确失败。B42 第二窗口不能唯一匹配、AX 候选不可靠、模型停止、窗口 / 策略变化或达到预算上限时失败关闭，不以像素坐标点击，也不把模型自评当作客户端成功。B45 的 release build 224 版本化活体证据见 `docs/gates/2026-09-26-b45-visual-mqtt-release.md`。Gemini、第二台 Mac 和写命令端到端结果仍需各自同版本门报告。
