# B31 `probe messages` 单次解析计划

## 目标与约束

目标是让 `ProbeMessagesCommand.collect()` 在一次 AX 消息表解析后同时生成消息键与完整探针行。仅触及只读 `WeComReader` 转换、CLI 探针及其测试；不改 `message.history`、watcher、协议、权限、策略、模型或客户端状态。默认脱敏与原输出契约必须保持；活体验证只读、发送数 0。参照规格 `docs/superpowers/specs/2026-09-25-b31-probe-single-message-parse.md` 和 B26–B30 发布门报告。

## 任务 1：先写失败测试

1. 在 `Tests/imctlTests/ProbeCommandTests.swift` 为 `ProbeMessagesCommand` 增加可注入 `WeComReader` 的收集路径测试。用合成 / 已脱敏 Fake AX 树定位消息表，设 `FakeAXBackend.onRead` 只统计该表的 `AXChildren`，调用一次 `collect(reader:)`，断言计数为 1。计数在 `WeComReader` 初始化后开始，避免把布局定位混入解析次数。
2. 同一测试或独立测试放入消息、系统通知、时间分隔行：断言完整行索引 / 顺序、原始方向、消息键存在或为空，以及默认脱敏 JSON / 文本字段。以独立的原 `chatMessages()` 结果作键规则对照时，先完成对照并清零计数，再执行被测收集路径。
3. `Tests/WeComAdapterTests/MessageRowParserTests.swift` 或相邻测试覆盖“预解析行转聊天行”与原 `chatMessages()` 的键和筛选等价，尤其文件传输助手方向归一、重复元组出现次数、首个 `readError` 之后无键。测试仅用合成姓名与正文。

## 任务 2：实现单次解析

1. 在 `WeComReader` 提取接受 `[MessageRow]` 与确定 `conversationTitle: String` 的纯转换方法（例如 `chatMessages(from:conversationTitle:now:calendar:)`）。原 `chatMessages(conversationTitle:now:calendar:) throws` 仍解析一次并转发给该方法，不改变现有调用方签名或语义。
2. 在 `ProbeMessagesCommand.collect()` 先取一次活动标题和一次 `messages()`，用同一批行生成键索引映射与原样完整行。为 Fake 计数测试提供 `collect(reader:)` 内部入口；公开 CLI 参数、`MessagesOutput` 的属性和渲染保持不变。**键来自转换后的聊天行，方向及其它显示字段来自未转换的完整行。**
3. 不修改 `MessageRowParser` 的分类 / 几何判断，不为探针引入行缓存、自动重试、截图或云端调用。

## 任务 3：验证与门报告

1. 运行聚焦测试、`swift build -q`、`swift test -q`、`bash scripts/check-secrets.sh`、`git diff --check`；在门报告记录各测试数及新增告警情况，不能从既有 B30 数字推断本批通过。
2. 主智能体用稳定安装版或经稳定身份签名的 CLI，对同一企微窗口运行默认脱敏 `probe messages --json` 的只读前后对照；只记录耗时、行数、退出状态与必要的脱敏结构，不把原始 JSON、`--no-redact` 或截图入库。写入 / 发送 / 客户端操作数均为 0。
3. 在 `docs/gates/2026-09-25-b31-probe-single-message-parse.md` 分开写 Fake、构建测试、活体三层结果；如果没有可比活体样本，维持“待实测”，不宣布性能改善。回滚只撤销本批纯读重构，恢复探针原双解析路径。
