# B18 `conversation.read` 有界可逆视觉轮次门报告

## 结论与范围

- 本批只在显式 `conversation.read` 的侧栏标题解析遗漏、但原始 AX 行顶部有唯一精确标题时启用多轮视觉选行。已打开目标或解析出的唯一 AX 行仍直接读取，不上传窗口。最多 2 次可逆选行、6 次模型轮次、40 秒；每次动作后由新鲜 AX 活动标题判断，最终还需活动会话头部一致。
- 模型只能在当前方法和当前 AX 候选中选择 `selectRow`、重新观察、请求核验或停止。它不能更改目标、发送内容、策略或宣告成功。本批不改 MQTT/MCP 协议、不发送消息，也不扩大其它桌面方法的 AI 步骤。
- B17 的一条本人文件传输助手纯文本测试消息已在 B17 门报告和 wiki 记录；该许可已经用完，**本批发送 0 条**。

## 代码与 fake 证据

| 核对点 | 结果 |
|---|---|
| 命令入口 | 仅外部 `conversation.read`，且视觉开关开启、几何解析漏掉目标、原始 AX 行的顶部精确标题可见时进入；通常路径仍由原 `WeComActions.selectConversation` 执行。 |
| 每轮门禁 | 截图前和模型返回后重核时间预算、命令方法与来源、暂停、目标身份桥、当前策略；模型返回后重读本机视觉设置，整窗许可或提供商/密钥变化即拒绝写 AX。 |
| 候选与写入 | PID/窗口与候选经 `AIPlannerObservation` 验证，模型返回后重验语义摘要；写 `AXSelectedRows` 前再从当前企微窗口重读唯一精确标题行并比对句柄。重名、无行、旧句柄失败。 |
| 后验 | 模型 `verify` 无法自行使命令成功；选行后最长约 1.5 秒只读等待企微更新活动标题，不再上传截图；标题和最终头部的 AX 读回相符才返回原有 `conversation.read` 结构。 |
| 合成测试 | 13 个 runner 测试含丢失首选行、跨轮新句柄、延迟更新标题无需第二次上传、伪造候选、超时/超轮次、观察或截图期间预算/门禁变化阻止上传、推理期间撤销整窗许可禁止 AX 写；3 个 handler 集成测试含两轮落实、推理期间策略/暂停撤销。 |
| 回归 | `swift build` 通过；改动后全量 `swift test` **652/652** 通过。`git diff --check` 与 `scripts/check-secrets.sh` 通过；新增文件没有密钥、真实联系人、聊天正文、broker 地址或截图。 |

## 活体与发布证据

- 源码提交 `d5b09d9182dee75d0c5395cd0b060d2bee2da226` 已推送。由此提交构建的 1.0.7 build 158 应用通过 `codesign --verify --deep --strict`；`out/imctl-1.0.7.pkg` 含 imctl、imctld、imctl-console 三个可执行文件，SHA-256 为 `5445473935cddfcf41bb6858c60f3733073f7ef17df6a8881f8622a9706d598c`。构建曾出现文件扩展属性 / owner 写入警告，包结构、签名和安装均通过读回。
- 本机 `installer -target CurrentUserHomeDirectory` 成功，已重启 LaunchAgent；`~/Applications/imctl.app` 读回版本 1.0.7、build 158、签名有效，`setup --check` 六项通过。视觉配置在本机读回为千问 `qwen3.7-plus`、整窗开关已启用，密钥仅本机私有设置。
- MQTT 显式只读 `conversation.read`：本人文件传输助手（原已打开）`succeeded`，再选 `imctl测试群` `succeeded`，最后切回文件传输助手 `succeeded`；每次返回活动标题与目标相同，耗时均小于 2 秒。随后 `conversation.list` 确认两个标题解析可见，文件传输助手被选中。普通 AX 路径按代码不会调用模型；本次没有触发标题解析遗漏。**真实企微整窗多轮分支未验，不能用上述普通路径成功代替。** 本批发送 0 条。
- 第二台 Mac 包 `~/Desktop/imctl-1.0.7-第二台Mac.zip` 已重做，SHA-256 为 `60da7a8a9e20aaa1eb2c45fda23adaa8de389643b5786bb103bf0de4c7b7df1a`；zip CRC 和包内 pkg 哈希与上文一致。第二台 Mac 尚未安装，TCC、模型密钥与 MQTT 均未在目标机验收。
- B17 仍是多数方法的固定 AX 流程加歧义时单步视觉候选选择；**所有桌面命令的统一多轮 AI 规划还未完成**。本批不能称为 Codex 等价的完整客户端代理。

## 未闭环

1. 真实企微整窗模型请求与多轮选行、跨屏/缩放/窗口移动、Gemini 地域限制仍未活体验证。
2. `message.history`、发送、联系人和群操作尚未接入本可逆轮次循环；不可逆方法仍需各自的 checkpoint 与后验门，不能因本批放宽。
3. 后续发送要单独获得条数授权，不得重用 B17 的一次许可。第二台 Mac 实际安装与授权仍待目标机完成。
