# 门报告：B9 消息侧对等、发送置前、几何可移植与图片可达性（2026-09-16 01:0x–02:1x CST）— 通过（图片一项为结论：AX 树不可达，路线待用户决定）

用户 2026-09-16 01:02 附策略页 / 会话页截图提八项：① 拉群默认成员应从通讯录下拉选择；② 「昵称名单」是什么、群名应为「客户名 + 群聊」且可配；③ 聊天图片看不到；④ 「打开选中会话」只有第一次有效；⑤ 守护进程一次约 7 秒不接 socket；⑥ 没有改群名的入口；⑦ 换 Mac / 屏幕尺寸能否兼容；⑧ 清理遗留，并要求 UI 界面能做的都能经 MQTT 消息完成。无规格 / 计划文档（用户 2026-09-15 定：不再逐次交接，记忆归 wiki）。

## 条件

- 企业微信 5.0.11；守护进程 = `~/Applications/imctl.app` 内 release 包（先装工作树版本 build 58 做活体，提交后重建 build 59 重装；签名标识不变、`trusted:true`）；控制台每次装包后 kill 旧进程再 `open -a`。
- 发送：**2 条**，都只对 `文件传输助手`（`b9-front-*`：另一应用在前台时发送；build 59 复验交还前台）。其余全部只读。
- 为确认图片可达性，用 `client.navigate{nextConversation}` 走到列表第 8 行的含图会话（真实联系人，只读；用户此前指出该会话有图）三次，`probe rowmenu` 只读该行的 AX 属性与动作，**未按任何菜单项**（该行根本没有动作）；每次经 `conversation.read` 回到文件传输助手。
- 探针输出与发送响应留在会话暂存目录，不入库；真实联系人标题、同事分区名不写入本文。

## 根因（01:4x–02:0x 活体）

| 现象 | 根因 |
|---|---|
| 守护进程一次约 7 s 不接 socket（用户 ⑤） | 执行器串行：2026-09-15 15:56 控制台一条 `message.send` 跑了 11.66 s 才失败（"no matching bubble within 10s; composer still holds the text"），后面的命令全部排队等它。那条发送失败是因为**回车投递时客户端不是活动应用**（用户在别的应用工作），客户端丢弃了这次回车 |
| 发送后企微留在前台（本轮 01:46 新发现） | `previous`（要交还前台的应用）在给输入框 `AXFocused` **之后**才读：聚焦输入框已经把客户端激活，读到的是客户端自己，于是什么也不交还；`client.navigate` 路径先读后置前，01:5x 活体交还正常 |
| 「打开选中会话」只有第一次有效（用户 ④） | 第一行是 `文件传输助手`（白名单内），其它行 `conversation.read` 按硬规则回 `TARGET_NOT_ALLOWED`；控制台只给了提示 |
| 默认成员靠手输（用户 ①） | `contact.list` 只读「我的客户」分区（同事分区折叠未展开），控制台策略页也没有候选 |
| 「昵称名单」不明（用户 ②） | 字段名 `allowNames` 的中文标签没有解释：它只在 `autoAccept = rules` 下生效，是「新的客户」卡片上的昵称清单 |
| 群名只能改后缀（用户 ②） | `groupNameSuffix` 固定「客户名 + 后缀」，没有模板 |
| 改群名没有入口（用户 ⑥） | B8 收尾只加了 `group.rename` 方法与 CLI，没有控制台控件 |
| 换机 / 换屏（用户 ⑦） | 五处几何用了绝对像素：通讯录左栏 `x < 400`、卡片表最小宽 `≥ 600`、选人面板分区 / 组缩进 `x < 70` / `< 92`、导航栏角标切片 `x < 40`、「+」按钮 `y < 60` |
| 聊天图片看不到（用户 ③） | 见下节：图片在客户端 AX 树里**没有元素、没有动作、没有描述** |

## 图片可达性（只读探针，含图会话第 3 行，246 px）

- 行：`AXRow/AXTableRow`，`actions=[]`，`AXCustomActions=[]`，`roleDescription=表格行`；唯一子元素 `AXCell`：**无子元素**、`actions=[]`、`AXDescription` 为空。
- 窗口里所有 `AXImage`（10 个）都是 `2×2` 的占位元素，位于 `x=-1`；没有任何 ≥ 20 px 的元素与该行重叠（B8 看到的悬浮 `AXImage` 不再出现，本次 `messageImages` 与行不重叠）。
- 结论：**经辅助功能拿不到图片**——没有元素可读、没有上下文菜单可开（`AXShowMenu` 不存在）、没有 URL / 文件名。三条剩余路线都需要用户决定，本轮一条也没做：
  1. 读客户端本地缓存文件（只读文件系统；macOS 会对访问其它应用容器弹「访问其它应用的数据」授权，本轮从终端尝试列目录即被该授权阻塞而放弃）——推荐，前提是用户在系统提示里允许 `imctld`；
  2. 截取该行矩形（需要「屏幕录制」权限，用户已明确不要）；
  3. 合成右键 → 复制（合成输入，硬规则禁止）。
- 现状：`message.history` 与 `message.observed` 已把这类行标为 `kind: media`，控制台显示「[非文本消息：图片 / 表情 / 文件]」占位。

## 实现

- **协议 / 守护进程（用户 ⑧ 对等）**：`policy.get`、`policy.set{allow?, deny?, contactRequests?}`（受本机开关 `policy.json.remoteEdits` 保护，关着时 `LOCAL_GUARD`，`imctl policy remote --enable|--disable`）、`controller.diagnose`（授权、窗口 / 两表 / 输入框几何、活动会话类型、行高、图片数——换机后先看它）、`controller.logs{lines ≤ 500}`；`contact.list{scope: customers|all}`（`all` 展开折叠分区，行带 `section`）；`command.state{accepted}` 增 `queuedMs`（排队 > 0 时）且 ≥ 1 s 写日志；执行器失败记录带 `error.message`；`contactRequests.groupNameTemplate`（默认 `{客户名}群聊`，后缀兜底）；`RPCMethod` 36、`tools/list` 37；协议 §6.29 / §6.34–6.37 / §7.5 / §12。
- **发送置前**：`enter` / `ctrl-enter` 前先读前台应用，再聚焦输入框、`withFront` 置前投递、气泡确认后交还前台（`details.front = kept|brought`）。
- **几何可移植**：通讯录左栏按窗口 `minX + 400`、卡片表最小宽 = 窗口宽 40 %、面板缩进相对大纲 `minX`、角标切片相对导航栏原点、「+」相对窗口顶；`GeometryPortabilityTests` 把三份夹具整体平移 / 收窄后重跑定位。
- **控制台**：策略页——默认成员 / 昵称名单改为「读取通讯录（全部 / 我的客户）→ 勾选」（逗号列表仍可手改）、群名模板字段、`remoteEdits` 开关、昵称名单说明文案；会话页——非白名单行自动用 上一 / 下一会话 走过去（不经白名单，上限 = 距离 + 2 步）再读消息，活动会话是群时显示「改群名」输入与按钮（`group.rename`，列表行为证后刷新）。
- **CLI**：`imctl policy requests --group-name-template`、`imctl policy remote`、`imctl probe rowmenu`（只读诊断：行 / 单元格 / 覆盖元素的角色、动作、属性；有 `AXShowMenu` 才开菜单并 `AXCancel`）。
- 仍只在本机：MQTT / 代理设置（凭据）、LaunchAgent 安装、对接文档页——协议 §6.37 后注明。

## 单测

`swift test`：**293 个用例、77 个套件全部通过**（上一报告 283 → +10：方法 / 工具计数、群名模板、守护进程级方法与 `LOCAL_GUARD`、失败原因入记录、发送置前两个场景（含「聚焦即激活」）、几何可移植三处、控制台走过去与改群名）。

## 活体（build 58）

| 步骤 | 结果 |
|---|---|
| `controller.diagnose` | `trusted:true`、窗口 `1920×1200`、会话表 `(159,63,252×1138)`、消息表 `(410,63,1511×933)`、15 个会话、`rowHeights 64`、`composerPresent:true` |
| `policy.get` | `remoteEdits:false`、三类类型规则全 false、1 个放行标题（测试群） |
| `policy.set{allow:[测试联系人A]}`（开关关） | `state:failed`，`LOCAL_GUARD`「remote policy edits are off on this Mac; run `imctl policy remote --enable` here first」，同时写入日志 |
| `controller.logs{lines:4}` | 4 行、358 字符，含上面那条拒绝 |
| `message.send`（Claude 在前台） | `succeeded`，`row #20 dir=outbound time=1:46`，1320 ms；`queuedMs` 缺省（未排队）；**企微留在前台** → 修正后 build 59 复验见下 |
| `client.navigate{next}`（Claude 在前台） | `succeeded`，之后前台 = Claude（导航路径交还正常） |
| `contact.list{scope:all}` | 4 行：3 行「我的客户」+ 1 行同事分区（面板开合一次） |
| 测试群 `message.history` | 2 行、都是 `message`（无图，故图片探针只能去含图会话） |
| 走到含图会话 | 三次各 7–8 步 `nextConversation`；`message.history` 2 行 = 1 `message` + 1 `media`（第 3 行，246 px） |
| `probe rowmenu` | 见「图片可达性」 |
| `conversation.read 文件传输助手` | 每次都回到文件传输助手；之后前台 = Claude |

## 活体（build 59，提交后重装）

| 步骤 | 结果 |
|---|---|
| `message.send`（Claude 在前台，02:03） | `succeeded`，`row #20 dir=outbound time=2:03`，914 ms；之后前台 = **Claude**（交还生效） |
| `controller.diagnose` | `trusted:true`、窗口 `(0,0,1920×1200)`；控制台已重开 |

## 未闭环

- 控制台策略页 / 会话页新控件待用户过目（无 UI 驱动）。
- 换机 / 换屏：几何已相对化并有平移夹具测试，但**未在第二台 Mac 上验证**——换机后先跑 `imctl call controller.diagnose`，异常时把窗口几何贴回来。
- 图片：路线待用户决定（推荐缓存文件路线，需在系统提示里允许 `imctld` 访问企微数据）。
- 接受 / 自动建群整轮复验仍需新测试账号；`media` 行方向需更多样本。
