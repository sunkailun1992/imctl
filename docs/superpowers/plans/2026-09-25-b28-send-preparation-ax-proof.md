# B28 实施计划：发送准备阶段的 AX 证据边界

1. 在 `WeComLayout.locate` 用会话表、消息区、窗口几何缩小可写 `AXTextArea` 候选。恰好一个才设置 `composer`；多于一个标记 `composerAmbiguous`。复用现有布局扫描，不新增完整树/截图读取。
2. `WeComActions.submit` 与 `sendFile` 在输入框歧义时停止于任何内容暂存之前。保持原动作授权顺序，普通唯一输入框继续原 AX 路径。
3. 文本：`setComposer` 读回后，提交前复核活动会话、输入框句柄、原文；失败清理仅限仍属于本次暂存的内容。提交后的消息 AX 读取失败由 checkpoint 记录为 `unknown`。
4. 附件：`⌘V` 后等待暂存信号的同时检查文本仍空；提交前再核活动会话、句柄、空文本和信号。任何含糊情形不按 Return；不让模型决定文件路径或粘贴/提交动作。
5. 用假件验证错误路径的零写入/零 Return/剪贴板恢复与 `unknown`，运行聚焦及全量 Swift 测试、构建、diff/secret 守卫。报告区分 fake 与真实客户端；主任务再决定安装与只读 MQTT 验收。
