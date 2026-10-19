# B25 消息滚动条边缘 AX 证据门报告

## 范围

解决 `message.history` 普通最新读取将内容内部滚动条当成消息区主轨道、偶尔进入 B21 视觉轮次并超时的问题。根据实际 AX 树，主轨道贴近父消息区右边缘，内部轨道离右边缘约 160 px；本批只读取这类几何证据筛候选，不改命令或模型的授权边界。本批发送 0 条。

## 验证

| 层次 | 回执 |
|---|---|
| Fake AX | `ScrollbackTests` 与 `AIPlannerHistoryIntegrationTests` 聚焦 **19/19** 通过。新增内部轨道值 0 但边缘轨道值 1 时零写入，以及内部轨道值 1 但边缘轨道值 0 时只写边缘轨道；两个几何不同的边缘轨道仍走有界模型轮次。 |
| 合并测试、构建、敏感信息 | B25 隔离提交 `fd3e4e1`、主线 cherry-pick `f0c513e`；与 B23/B24 合并后 `swift build`、全量 **723/723** 通过。第一次全量运行有旧 `FileFetcher` 取消回调即时断言波动，单项及第二次全量复跑通过，未改下载逻辑。`git diff --check` 通过；secret 扫描仍为 11 条旧示例 / 文档 warning，本批无新增命中。 |
| 安装与只读 MQTT | 1.0.11 build 171 已签名打包并安装至唯一的 `~/Applications/imctl.app`；`setup --check` 六项通过，守护进程二进制 hash 与包内一致。合并源码 `96d2848` 已推送。本人文件传输助手 `message.history{limit:1}` 连续 5 次成功，每次约 1.13–1.28 秒；显式 `message.history{limit:25,scrollback:true}` 成功返回 25 条，随后最新读取再次成功。`controller.describe`、`account.status`、`conversation.read` 也成功。均为只读操作、发送 0 条。1.0.10 的 12 次读取为 10 成功、1 `CLIENT_UNAVAILABLE`、1 B21 视觉轮次超时，不作为本批成功回执。 |

## 未闭环

真实客户端的滚动条形状可能随窗口或企微版本变化；无边缘证据时仍会进入有界视觉选择。1.0.11 的 5 次普通读取和 1 次显式回溯不能证明长期无超时；此前 1 次 `CLIENT_UNAVAILABLE` 没有保留详细 AX 操作名，需要后续单独定位。
