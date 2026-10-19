# B31 `probe messages` 单次解析规格

## 背景与范围

`ProbeMessagesCommand.collect()` 先调用 `WeComReader.chatMessages()` 取得消息键，再调用 `messages()` 输出完整消息表。前者内部也调用 `messages()`，因此同一条只读探针会遍历并解析消息表两次。B26–B30 发布后的只读对照显示直接 AX 探针耗时偏高；现有样本不能确定这一次重复解析占了多少时间。

本批仅调整 `imctl probe messages` 的读路径与 `WeComReader` 的消息键复用入口。它不是 MQTT `message.history` 或 watcher 的重构，不改变协议、客户端状态、云端视觉权限、模型调用、策略、白名单、按键、checkpoint 或幂等语义。风险等级按只读 CLI / 纯逻辑重构记为**中风险**。

## 行为契约

1. 一次探针先读取活动会话标题，再调用 `messages()` **一次**得到完整的 `MessageRow` 数组；从同一数组筛出聊天消息并分配 `messageKey`，之后由原完整数组生成 `MessagesOutput.Row`。不为取键再次遍历 AX 消息表。
2. `WeComReader.chatMessages()` 原公开签名及调用方行为不变；将其筛选、文件传输助手方向归一、规范化时间、同元组出现次数和首个部分读取错误之后不分配键的规则复用到一个接受已解析行与会话标题的纯转换入口。
3. 探针完整输出仍保留消息、媒体、文件、视频、系统通知、时间分隔及空行原有索引和顺序。系统、时间、空行没有消息键；消息键只按既有规则对应原表索引。探针 `direction` 仍取完整原始行，不借复用键的机会改变其显示语义。
4. 文本与 JSON 字段、默认脱敏、`--no-redact` 选择、`composerLength`、消息表边界与错误传播保持原状。探针输出和门报告不含真实联系人标题、正文、签名地址或本机绝对路径。
5. 一次读到的行作为同一视图快照处理；客户端在读取过程中变化仍可能使 AX 失败或结果不完整，不能用缓存行推断成功。该改动不新增重试或写入。

## 验收

- Fake AX 计数测试在 `ProbeMessagesCommand.collect` 的同一条路径上统计消息表 `AXChildren` 读取，要求仅一次；同时核对从该批行生成的消息键与既有 `chatMessages()` 规则一致。
- 脱敏合成夹具覆盖聊天消息与系统 / 时间行的完整输出、索引、方向及空键；覆盖首个部分读取错误之后的键不继续分配。
- 聚焦测试、`swift build`、全量 `swift test`、`bash scripts/check-secrets.sh`、`git diff --check` 通过后，才做已授权的默认脱敏**只读**活体 `probe messages --json` 对照。记录样本次数、行数、退出状态与耗时；写入和发送数为 **0**。
- 活体前后需在相同企微窗口与可比行数下测量，且把 AX 系统状态波动列为限制。未实测不得声称耗时改善，也不能将 Fake 计数直接换算成真实提速。
