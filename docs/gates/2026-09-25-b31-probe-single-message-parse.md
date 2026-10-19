# B31 `probe messages` 单次解析门报告

## 条件与范围

上一发布基线为 1.0.12 build 179；B26–B30 门报告记录 `probe messages --json` 直接 AX 只读样本约 30.33 秒，旧 1.0.11 CLI 对同一窗口约 26.75 秒。样本说明当前 AX 读取慢，不能归因于本批，也不能作为本批提速结果。

本批目标是去除 `ProbeMessagesCommand.collect()` 的消息表重复解析，保持消息键与完整探针输出、系统 / 时间行及默认脱敏语义。只读 CLI 路径，协议、MQTT、watcher、策略、权限与客户端写入不变。规格与计划分别见 `docs/superpowers/specs/2026-09-25-b31-probe-single-message-parse.md`、`docs/superpowers/plans/2026-09-25-b31-probe-single-message-parse.md`。

## 验证记录

| 层次 | 状态与证据 |
|---|---|
| Fake AX 单次解析 | `ProbeCommandTests` 统计一次 `collect(reader:)` 对消息表 `AXChildren` 读取恰为 1；系统 / 时间 / 消息行保留，只有消息行有键，正文默认脱敏。`MessageKeyStabilityTests` 核对已解析行的自聊方向、重复键及部分读取边界。 |
| 聚焦与全量 | B31 聚焦通过；B31 完成时 `swift build -q` 通过，`swift test -q` **754/754** 通过。之后 B32 追加用例，另见 B32 门报告。 |
| 安全与 diff | `bash scripts/check-secrets.sh` 退出 0，11 条仓库既有样例 / 历史路径告警，无 B31 新增命中；`git diff --check` 通过。 |
| 真实企微只读对照 | `scripts/build-signed.sh debug` 只重签 `.build`，未安装；默认脱敏 `probe messages --json` 退出 0、JSON 有效、耗时 **1.92 秒**，44 行且 44 个消息键（消息 30、媒体 4、文件 8、视频 2）。只记录统计，不落盘或提交正文。与此前样本的窗口及时间条件不同，不能证明固定倍率的提速。 |
| 客户端写入 / 发送 | **0**；只读探针没有切换会话、发送或修改客户端。 |

## 结论与未闭环

Fake 证明消息表读取从 2 次降为 1 次，真实客户端只读探针可正常返回；单次 1.92 秒不能归因为本批的固定速度收益。MQTT `message.history`、watcher 和其它桌面命令不经过此 CLI 探针路径，耗时问题仍需单独定位。回滚仅撤销本批 `ProbeMessagesCommand` 和 `WeComReader` 的单次解析复用，不影响安装版或运行数据。
