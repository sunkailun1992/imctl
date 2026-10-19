# B36：直接发送输入框两轮视觉观察 — 源码阶段，活体待验

## 范围与证据边界

B33 已用 MQTT 对本人文件传输助手完成文本、合成图片、合成视频与合成 PDF 各一次发送，但这些命令沿确定性 AX 路径执行，整窗截图与模型请求均为零。B34 已在非活动目标的只读 `conversation.read` 验收真实千问两轮选会话；B35 已对 `message.history` 回最新和 `contact.request.list` 进入申请表分别取得真实两轮只读证据。上述结果不能证明发送准备或提交阶段使用了模型。

B36 当前在 **1.0.14-dev 源码**中，只针对**直接请求**的 `message.send`、`message.sendFile`：目标会话与唯一可写聊天输入框先由 AX 严格确认；固定正文写入或原附件经已批准的 ⌘V 暂存前后，各用经 PID / 窗口核验的企微主窗单帧请求一次所选视觉模型。模型只能复核 / 要求重观察 / 停止，不能改目标、正文、文件来源、策略、幂等键，也不能执行粘贴或 Return。群发的逐目标 `message.send` 子命令不触发 B36 输入框观察。整窗辅助未启用时沿原 AX 路径；进入视觉路径后若模型拒绝或页面漂移，不能静默回退纯 AX 继续提交。

暂存后由 AX 精确正文值或单个原生附件对象守卫复核；在模型等待期间重新读取完整消息基线，以免把人工新发的同类行当本命令证据。不可逆点仍是原 checkpoint 与一次 Return；提交后的结果仍要求新外发消息、方向和类型等原有客户端证据。图片、视频气泡通常不暴露文件名，画面复核和类型匹配不能单独证明远端收到的字节与来源文件逐字节一致。预提交视觉失败可能留下附件 chip；outbox 源会按原清理路径删除，应由人检查输入框，不得承诺原文件仍可从草稿重新发送。

## 当前验证

| 层次 | 状态 |
|---|---|
| 规格与计划 | `docs/superpowers/specs/2026-09-26-b36-send-composer-visual-observation.md` 与同名计划记录受限观察、AX 后验、checkpoint 及失败关闭规则。 |
| 源码 | `WeComCommandHandler`、`AIPlannerReversibleRunner`、`WeComActions.submit/sendFile` 与执行器广播子命令上下文已有 B36 接线。还补上粘贴前剪贴板文件 URL 身份校验：人若在等待企微前台期间复制别的内容，停止粘贴并保留新剪贴板。 |
| fake 测试 | 两轮新鲜观察、模型停下不暂存、唯一输入框、成功文本发送仍经一次 checkpoint/提交、广播子命令不上传、提交前门变化、粘贴板竞态等覆盖。最终 `swift test -q` **819/819**、`swift build -q`、`git diff --check` 通过；敏感扫描退出 0，11 项均为既有示例/旧文档命中。fake 测试不能证明真实模型调用。 |
| 本机安装 | 稳定 Apple Development 签名的 **1.0.14 build 186** 先打 debug 包做只读活体，再打 release 包并在同一安装位安装。release pkg SHA-256 `f7e2bf19ae0f37d7ee91c5b6ba4047a7b2c9b5fa851bc36873a4a605b58ecdea`；payload 含三份执行文件、协议文档和 agent skill，`codesign --verify --deep --strict` 通过；安装版 `imctld` 与 release 构建版 SHA-256 同为 `5dd6864531a9738651f805e131ce865644a8f28f483fe80a2c54c20ce4873953`。首次 kickstart 后立刻检查尚无 socket，随后重查 `setup --check` 六项及 MQTT `controller.describe` 均通过。pkg 未签名/公证，第二台 Mac 待安装；release 包尚未执行 B36 真实发送。 |
| 真实 MQTT → 千问 → 企微 → 事件 | **待验**。本批截至本报告没有新增真实发送，也没有可归属于 B36 的真实整窗截图、模型请求与新外发消息同向证据。B33 的四条授权发送已用完；新发送须先按 `docs/ai-coding/TESTING_SPEC.md` 明确测试目标和条数。 |

## 活体通过条件

每条获授权的直接测试发送均须在同一守护进程启动周期内记录 `controller.describe` 三个视觉计数的前后差分、MQTT 命令终态、同键 `command.get`、独立企微 AX 新外发消息和事件对账；两轮截图 / 模型请求且 AX 后验通过才可写为该方法的视觉活体通过。`HTTP 200` 只说明官方端点响应，不证明模型选择有效或客户端发送成功。若目标已活动，B34 的选会话轮次为零，但 B36 输入框两轮仍应单独出现。失败或 `unknown` 不用新键自动重发。

本机 debug 和 release build 186 均完成只读 MQTT `conversation.read` 从文件传输助手切到测试群、再切回，各自得到 **4/4/4** 计数差分与成功 AX 后验；debug 包上手工停留通讯录后观察器保持 `paused=[]`，`contact.request.list` 成功且未触发后台视觉请求，详见 B34/B35 门报告。这些只读复核仍不能替代 B36 发送活体。

此报告不证明 `contact.request.accept`、建群、群改名、加成员、`client.navigate` 或其它固定桌面命令具备完整视觉活体能力，也不证明 Gemini、最终 release、第二台 Mac 已验收。所有命令是否触发视觉路径，以各自的客户端条件、配置及逐方法门报告为准。
