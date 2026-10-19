# B22 AXRole / AXFrame 瞬态读取门报告

## 范围与结论

- 源码提交 `0ca1a42`：`AXElement.role()` 读取 `AXRole`、`frame()` 读取 `AXFrame` 及其回退使用的 `AXPosition` / `AXSize` 时，仅对该属性、该操作名的第一次 `-25201` 即时重读一次。第二次失败原样传播；其它错误、unsupported 和原有回退语义不变。
- 未增加整条命令、全局 AX backend 或写操作的重试；`AXValue` 旧逻辑保持原样，`title()` 等其它 getter 不扩展。没有协议、策略、截图、权限、传输、按键或运行数据变化。本批发送 **0 条**消息。
- 此修复针对观察到的瞬时 `get AXRole` / `get AXFrame` 错误；fake 测试通过不等于 `message.history` 间歇失败已彻底消除。

## 代码与 fake 验证

| 核对点 | 证据 |
|---|---|
| 一次瞬态后成功 | Fake backend 对 `AXRole`、`AXFrame` 的第一次读取返回对应 `-25201`，第二次成功；每个属性恰好读取两次，AX set / action 均为零。 |
| frame 回退 | `AXFrame` unsupported 时，`AXPosition` 或 `AXSize` 各自仅在匹配的瞬态错误下重读一次，其它属性仍按原次数读取。 |
| 失败边界 | 连续 `-25201` 原样抛第二次错误；其它错误码或不匹配操作名仅读一次；其它 getter 不增加重读。 |
| 可选属性 | unsupported 的 role / frame 仍返回原有可选结果；frame 可继续从 position + size 合成。 |

## 构建、安装与活体证据

| 层次 | 回执 |
|---|---|
| 聚焦 fake 与全量测试 | B22 提交前聚焦 fake 通过；与 B21 合并后全量 **699/699** 通过（9 个测试可执行产物计数之和），live 套件未启用。 |
| `swift build` / diff / secret 扫描 | 合并后的 `swift build`、`git diff --check` 通过；`scripts/check-secrets.sh` 退出 0，仍为 11 条既有示例 / 文档 warning，本批无新增命中。 |
| 源码推送、签名包、安装、第二台 Mac 包 | 源码、版本与门报告 `d7ca1e6` 已推送 `main`；1.0.10 build 166 签名应用验证通过，包 SHA-256 `ea17ae6c3427a1dc5da793f48863e4a00628f0b957de68e1c9c8adf3c8319eec`；唯一 `~/Applications/imctl.app` 覆盖安装，安装版 `imctld` 哈希与构建产物相同，`setup --check` 六项通过。第二台 Mac ZIP SHA-256 `28bbdcedc1fbcb51ffa55f7b1472ae3898abb42c2cd92a5f23f049578d0a8f45`，目标机未安装。 |
| 已安装版只读 MQTT `message.history` | 本人文件传输助手 `limit:1` 连续 12 次：10 次成功、1 次 `CLIENT_UNAVAILABLE`（探针只留错误码，未保留原始错误操作名）、1 次 `UNSUPPORTED`（B21 视觉选条轮次 `timeout`，约 26.8 秒）。`controller.describe`、`account.status`、`conversation.read` 成功；没有真实写入。这个样本不能证明 AX 瞬态故障已经消除。 |

## 未闭环

1. 真实企微 AX 树的瞬态错误是否只发生在这四个属性，仍需后续只读样本；此批不重试整个命令，也不掩盖连续失败。
2. 新安装版 `message.history` 已有 1 次 `CLIENT_UNAVAILABLE`；下一次须只保留错误码与 AX 操作名（不留消息内容），再定位是否仍是 `-25201`。另有 1 次 B21 视觉轮次超时，属于独立失败边界。
3. 第二台 Mac 的安装、TCC 和 MQTT 需在目标机另行验收；本批没有客户端写入或发送验收。
