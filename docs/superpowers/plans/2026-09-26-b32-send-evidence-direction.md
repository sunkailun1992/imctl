# B32 发送结果的方向与新消息证据实施计划

## 目标与约束

目标是让 `message.send` 和 `message.sendFile` 只在有新的外发消息证据时返回成功。发送路径属极高风险；只用已有 AX/消息解析、`ActionPolicy`、checkpoint 和已批准的按键，不修改目标白名单、运行数据、视觉上传范围或消息正文。变更须保持 `CommandExecutor` 的同键幂等和崩溃后 `unknown` 语义。

## 分步实施

1. 在 `SubmitTests` 增加失败测试：同文入站或未知方向的新行、旧行因历史加载而索引变化、旧同文前插，均不能成为成功证据；另外验证 `文件传输助手` 的新消息经自聊归一化可成功。断言后验不足时 checkpoint 不是 `succeeded`，且没有第二次提交动作。
2. 在 `WeComActions.submit` 将基线与后验统一读取 `reader.chatMessages(conversationTitle: active)`；提交前若消息键因 AX 读取错误而不完整，失败关闭。确认仅接受正文完全相同、键不在基线、方向 `outbound` 的行。取证前后复核活动会话；可见消息不保持原前缀或候选与旧行不可区分时不报成功。保留既有超时、输入框清理、`unknown` 与崩溃钩子。
3. 复核 `SendFileTests` 已覆盖的新外发、入站及文件名错配，再加未知方向、请求类型不匹配、会话切换、旧媒体前插与基线读取不完整的负例。`SendFile.swift` 提交前失败关闭部分基线，取证要求 `FetchedFile.kind` 与消息行类型对应；不放宽视频无文件名的既有规则。
4. 同步 `docs/protocol/im-control-protocol.md` §6.5、§6.43：文本成功需要新外发同文行；图片也需要新外发方向，未知方向时结果为 `unknown`。不新增协议字段或错误码。
5. 跑聚焦 Fake、`swift build -q`、全量 `swift test -q`、`bash scripts/check-secrets.sh` 与 `git diff --check`；将测试数和新增告警写入门报告。仅主智能体按测试目标做活体，记录命令、客户端气泡、MQTT 终态与事件，不能用 Fake 代替活体。

## 交付与回滚

门报告逐层区分代码审查、Fake、签名构建、真实客户端和 MQTT 证据，记录实际发送条数；若未获新的活体条数授权，不发送，标待活体。回滚是撤销 B32 代码与协议提交并恢复上一已签名版本，不清除未知命令的 checkpoint，也不换键补发。
