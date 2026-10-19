# B45：固定 MQTT 命令的视觉链与安装版验收（2026-09-26 CST）— 限定只读与 dryRun 通过，写命令待验

## 范围与证据口径

目标是让显式发起的企业微信桌面命令在固定协议参数、策略和 AX 后验约束下，按需由千问对经核验的企微窗口做多轮观察。模型只能选择本方法允许的 AX 候选或阻止当前步骤，不能改目标、正文、成员、按键、幂等键或决定成功。`account.status`、`conversation.list` 等确定性 AX 路径无须制造截图。此能力是面向企业微信固定命令的有界视觉辅助，不是可执行任意任务的通用代理。

本报告把源码与合成 fake 测试、安装版真实模型调用、MQTT 终态和独立客户端 AX 后验分开记录。`visionCaptureCount / visionRequestCount / visionHTTP200Count` 是守护进程进程级累计值；同一命令前后差值能证明截图、请求和官方端点 HTTP 200，却不能单独证明模型选择正确、AX 操作完成或命令成功。报告不保存截图、模型原文、密钥、签名地址或会话正文。

## 实现与静态门禁

- 版本为 `1.0.14-dev`。源码基线 `19fec68` 的 `git rev-list --count HEAD` 为 **224**；文档提交可能使后续 Git 计数变化，安装包内 build 号以实际产物读回为准。
- B35 在确需向更早消息滚动且消息滚动条唯一时，把第一次向上滚动也纳入模型选条、固定 AX 写值、第二帧复核；无需滚动或预算为零时不截图。企微向前补入旧行后可能立即重新归一化滚动条，不再单凭值接近零判断成功，而要求同一会话的滚动条朝顶部移动、消息表行数增加且首行句柄变化。B34 目标选择、B38 本命令联系人选人面板、B39 添加群成员标题、B40 导航前后及 B41–B43 命令自有弹层的视觉面按窗口归属收紧。企微同 PID 的独立辅助窗只有与主窗几何不重叠时才可作为当前命令的子窗；重叠或归属不明时失败关闭。B40 还把已由 AX 独立证明的选中行仅作为只读图像锚点，图中文字过小本身不判冲突；若画面显示不同会话或冲突弹窗，模型仍可停止。
- B47 有处理器 → 假截图 → 假千问 HTTP → fake AX → 命令事件的集成测试，覆盖的是合成 `group.create` 场景，不代表所有真实写命令都已调用模型。
- `swift test -q`：**903/903 通过**，含 `ForbiddenAPITests`；`bash scripts/check-secrets.sh` 退出码 0，仍有 11 条已知 warning；`git diff --check` 通过。测试层不向第三方上传真实图片，也不产生真实客户端写入。

## 已有安装版活体证据

下表只记实际运行过的版本。条件为本机已授权的企微客户端、稳定签名的 `imctld`、本机启用的千问 `qwen3.7-plus` 与整窗辅助；命令经 MQTT 发起。所有目标均限本人测试对象；本批到此处没有新增发送。

| 安装版与方法 | MQTT / AX 结果 | 单命令视觉计数与结论 |
|---|---|---|
| build 211 `conversation.read`，测试群与本人文件传输助手间切换 | 两次只读切换分别有 MQTT 成功终态、`command.get` 同一结果和 AX 活动标题读回 | 每次 **2/2/2**；这两个只读切换的真实千问多轮成立 |
| build 211 `message.history` 回最新 | 第一次滚动后未完成第二轮，约 62 秒超时，命令失败 | **2/2/2** 不可记为通过；计数不是终态证据 |
| build 215 `message.history{limit:5,scrollback:false}` 回最新 | 从较早位置返回 5 行，约 7.28 秒；MQTT 与 `command.get` 同为成功，AX 消息滚动条为 1 | **2/2/2**；build 215 的回最新分支通过 |
| build 211 `client.navigate` | 画面截取前因客户端出现独立辅助窗而被旧窗口守卫判为 `staleView` | **0 次模型请求**；未通过。B40 守卫随后收紧，最终 build 224 的复验见下文 |
| build 215 `group.addMembers{dryRun:true}`，自有测试群 / 本人测试号 | 前缀视觉调用发生，但命令在打开添加成员动作处停止；没有提交成员写入 | **3/3/3** 不可记为成功。B39 面板归属与标题候选随后修正，最终 build 224 的复验见下文 |
| build 211 `contact.list{limit:10,scope:all}` | 窗口归属已触发视觉，但模型停止了当前步骤；没有得到成功 MQTT 终态 | 有真实 HTTP 200；未通过。B38 子面板截取随后修正，最终 build 224 的复验见下文 |

## build 222 中间安装版读回

此版本是导航继续排障前的**中间安装版**，不能直接称为本批最终包。`out/imctl-1.0.14.pkg` 的 SHA-256 为 `fd86f67606fa7a2b6dc4f9782b334df1f596bf7eb03ed8b7a8d2d4c3cc532dd7`；签名应用 1.0.14/build 222 已安装在本机，已安装 `imctld` 与构建版 SHA-256 一致。`setup --check` 六项通过；千问 `qwen3.7-plus`、`cloudEnabled`、`fullWindowEnabled` 与 `keyPresent` 的本机读回均为启用。包不含密钥。

| 方法 | MQTT / AX 结果 | 单命令视觉计数与结论 |
|---|---|---|
| `contact.list{limit:10,scope:all}` | 约 10.87 秒返回 `succeeded`，`command.get` 对同一命令也为成功；随后恢复本人文件传输助手 | **2/2/2**；本机 build 222 的选人面板限定视觉分支成立 |
| `client.navigate{action:nextConversation}` | 约 5.86 秒安全停止；模型认为当前候选不可用，无导航成功终态 | **1/1/1**；首轮真实云端调用成立，导航**未通过**，后续需修正并重验 |
| `group.addMembers{dryRun:true}`，自有测试群 / 本人测试号 | 约 19.02 秒 `succeeded`，`command.get` 同为成功；`dryRun=true`、`added=[]`，本人已在群内而跳过，未按最终确认；其后切回本人文件传输助手的 `conversation.read` 约 10.32 秒成功 | 命令 **4/4/4**，包含非当前目标的 B34 两轮与打开本命令成员面板的 B39 两轮；切回命令另有 **2/2/2**。只证明 `dryRun` 前缀，不证明真实新增成员 |
| `message.history{scrollback:true,limit:60}` | 从消息滚动条约 0.444、40 行开始；企微向前补入消息后约 48 行、滚动条约 0.121，命令以 `INTERNAL` 失败 | **2/1/1**；有第一轮云端请求和 AX 滚动，但没有成功的两轮后验或 MQTT 结果。补入行后的新布局由后续源码修正并复验 |
| `message.history{scrollback:false,limit:5}` | 约 11.3 秒 `succeeded`，`command.get` 对账；独立 AX 读回消息滚动条 `[1,0]` | **2/2/2**；build 222 回最新分支再次通过，与向更早消息失败分开计 |
| `contact.request.list`（已选中） | 约 9.83 秒 `succeeded`；其后恢复本人文件传输助手 | **0/0/0**；AX 快路径正确避免无用上传，不构成此版本的申请表视觉选择验收 |

## release build 224 安装版最终读回

`out/imctl-1.0.14.pkg` SHA-256：`6cfd7fe805a0a9720fd9f9746decfbd4a617a92263049cbca80794f6ff55ec94`。1.0.14/build 224 的应用已以稳定身份签名并安装到本机；包中与已安装的 `imctld` SHA-256 相同，均为 `d43258c6e200360ee41069f62c72355d02767d5bdcfc23fcdce027b767e362b8`。`setup --check` 六项通过；本机配置读回千问 `qwen3.7-plus`、`cloudEnabled=true`、`fullWindowEnabled=true`、`keyPresent=true`，但密钥没有进入安装包或报告。以下各项均为安装版显式 MQTT 调用，`command.get` 与命令终态对账；只向所选千问官方端点上传当前命令经核验的企微窗口单帧。

| 方法与起点 | MQTT / 客户端读回 | 视觉计数与结论 |
|---|---|---|
| `client.navigate` 下一个会话 | 约 11.27 秒 `succeeded`；独立 AX 读回确实离开本人文件传输助手 | **2/2/2**；固定菜单动作前后两轮真实视觉通过 |
| `client.navigate` 上一个会话 | 约 9.23 秒 `succeeded`；独立 AX 读回回到本人文件传输助手 | **2/2/2**；可逆导航与恢复均通过 |
| `message.history{scrollback:true,limit:60}` | 从 40 行、消息滚动条约 0.444 起步；约 17.63 秒 `succeeded`，返回 48 行。企微补入旧行后继续读取并回最新；独立 AX 探针最终读回滚动条 `[1,0]`，活动会话仍为本人文件传输助手 | **2/2/2**；向更早消息首次滚动的真实两轮与 MQTT 终态通过，替代 build 222 的失败证据 |
| `contact.list{limit:10,scope:all}` | 约 14.2 秒 `succeeded`，得到限定条数的联系人列表 | **4/4/4**；选人面板的真实多轮在此安装版通过 |
| `group.addMembers{dryRun:true}`，自有测试群 / 本人测试号 | 约 14.99 秒 `succeeded`；`added=[]`，本人已在群内而跳过，没有按最终确认或实际新增成员 | **4/4/4**；B34 选群与 B39 命令自有面板前缀在 `dryRun` 中通过，真实新增成员仍待验 |
| `conversation.read` 回本人文件传输助手 | 约 10.94 秒 `succeeded`，AX 活动标题读回相同 | **2/2/2**；非当前目标的 B34 真实选行与复核通过 |
| `contact.request.list`（已选中目标行） | 约 5.95 秒 `succeeded`，AX 快路径完成读取 | **0/0/0**；避免无意义截图，不作为此安装版的申请表视觉选择证明 |

`event.replay{afterEventId:55890}` 回取 124 条事件；这 7 个 build 224 命令各自均有 `accepted → running → succeeded`，共 7 个成功终态，与 MQTT 响应及 `command.get` 一致。回放核验只比对命令 ID 与状态，没有把消息正文或截图写入报告。

对上述 `client.navigate` 下一个会话的原幂等键再发同一 MQTT 请求，返回原 `commandId` 和 `succeeded`；三项视觉计数均未增加，独立 AX 读回仍在本人文件传输助手，没有再次导航。

第二台 Mac 随包目录 `out/imctl-1.0.14-第二台Mac/` 已打包为 `out/imctl-1.0.14-第二台Mac.zip`，SHA-256 `66fc9e02d2feae4912674074dd29bc3faee14d4e9d8ba2a52af496351c872fbb`；ZIP CRC 与内部 pkg 的 SHA-256 均通过。它是可拷贝安装材料，**不是**第二台 Mac 已安装、授权或验收的证据。

本批**新增发送数为 0**。B36 直接发送文字、PNG、MP4、PDF 的四条新测试消息尚待本批独立的目标与条数确认；此前 B33 的纯 AX 发送授权和结果不能挪作本版本视觉发送证据。

## 未闭环与交付边界

- B36 直接发送的真实视觉暂存前后复核 **未验**。B33 的四条真实发送在旧 build 184 只走 AX，不能算 B36 千问链验收；本批没有借用旧授权再次发送。
- `contact.request.accept` 缺本人待处理申请；`contact.add` 缺可核对的本人测试号码；`group.create` 缺第二个自有测试成员；`broadcast.confirm` 缺真实任务及专项发送授权。这些真实写命令仍待活体。`group.rename` 的旧确定性 AX 改名不算新视觉链验收。
- Gemini、第二台 Mac 安装、本机长期常驻和其它未知企微窗口布局没有由上述本机千问测试证明。模型不确定、窗口重叠、AX 后验缺失或时间预算用尽时，按现有守卫返回明确失败或 `unknown`，不改用坐标点击、额外按键或重复提交。
- 本报告只验收到上述固定方法的限定视觉步骤、只读结果及 `dryRun`。仓库提交与远端推送回执、第二台 Mac 包分发和 Wiki 归档分别核对，不用本机安装替代其它设备验收。
