# 会话 AX 容错、最新历史与观察性能（2026-09-23）

条件：企微 5.0.11 正在运行，本机 imctl 1.0.3 build 146；运行时代码截至 `ad55443`。本批只读验证期间发送 0 条、客户端会话切换 0 次、策略和凭据改动 0 项。活动会话是文件传输助手；只记录汇总，不保存消息正文、签名地址或真实联系人。

## 实现

- 显式普通 `message.history` 先确认企微消息区已到最新位置，必要时只移动该会话的滚动条，再读最新行；守护进程观察轮次不滚动或切换客户端。控制台普通加载滚到最后一条，回滚保留阅读位置，失败时清空旧会话内容并给出错误。
- 消息行 `AXValue -25201` 重读一次；仍不可读就给 `readError=AX_VALUE_UNAVAILABLE`，不把它错认成图片，也不为该行及后续行生成不稳定的消息键或观察事件。其他 AX 错误继续明确失败。
- `WeComLayout` 定位时不下钻消息表的所有行。守护进程完整读过消息后，以活动标题、选中会话预览和消息表行句柄判断是否复用消息快照；AX 通知、证据变化、重新定位和每 10 次成功轮询强制完整读，错误后弃用缓存。会话元数据、输入框状态和角标仍在每轮读取。
- 文件传输助手是自我会话，其 `message.history` 和 `message.observed` 方向统一为 `outbound`；其他会话只按客户端证据判断。PDF / Word 文件使用 `kind=file` + `fileType`，视频使用 `kind=video`，无文本媒体使用 `kind=media` + `mediaType=image|unknown`；类型规则在 socket 和 MQTT 相同。控制台附件只在点击后取签名地址，不自动下载、预览或播放。

## 验证

| 项目 | 结果 |
|---|---|
| `swift test --quiet` | 539 项、9 个测试目标全通过；覆盖 AX 容错、最新滚动、控制台过期响应、媒体类型、文件传输助手方向和 watcher 缓存失效 / 定期兜底 |
| `git diff --check` / `check-secrets.sh` | 通过；secret 扫描有 11 条既有示例 warning，新增内容不含凭据、聊天正文或签名地址 |
| build 146 制品 | `out/imctl.app` 和展开 pkg 内 app 均 `codesign --verify --deep --strict` 通过，包内版本均为 146；开发 pkg 未签名、未公证。build 146 pkg SHA-256：`78417b941e22e8528caa22c3da96ffaf18370a885aaa6bc312ac9b4a778135fa` |
| 本机安装 | `~/Applications/imctl.app` 更新为 build 146，带 MQTT 的现有 LaunchAgent 重启、控制台重新打开；安装前 accepted/running 命令 0 条，`setup --check` 五项通过 |
| 本机 socket 历史 | build 145 两次 `message.history(limit=30, scrollback=false)` 为 12.763 / 16.971 秒；build 146 两次为 9.679 / 8.698 秒。build 146 均回 20 行：文本 6、文件 8（PDF 5、Word 3）、视频 2、无文本媒体 4；方向全为 `outbound`、不完整行 0 |
| 本机 MQTT 只读往返 | `controller.describe` 0.116 秒；`message.history(limit=30, scrollback=false)` 8.733 秒，20 行及类型分布与 socket 一致，方向全为 `outbound`、不完整行 0 |
| 守护进程观察负载 | build 145 状态约 164 秒仅完成 14 轮；build 146 约 76 秒完成 26 轮，均 0 错误。这只是不同时间窗的现场读数，不是固定吞吐保证 |

## 边界与后续

- 另一次 build 146 直接 AX 探针仍用了约 19.389 秒，说明企微 AX 耗时会波动；不能把上述两次历史读取写成稳定时延承诺。若再现超时，先查客户端模态框、当前负载与守护进程轮询，再取分段样本。
- 本机本轮没有再次触发 `-25201`；该路径以 fake AX 回归验证。没有真实新消息样本验证行句柄变化时的 MQTT 时延；若企微在没有通知和预览变化时原位改写同一行，最迟在定期完整轮询时发现。
- 四条无文本媒体没有足够客户端证据，保持 `mediaType=unknown`；其他私聊无方向锚点时仍可为 `direction=unknown`。真实头像像素未取得，控制台仍用身份占位图；企微缓存不存在的旧图片 / 文件不能凭空恢复。
- CUA 仍报 `native pipe closed before response`，未直接点检新版控制台的最新定位与排版。第二台 Mac 的安装、授权、几何和 MQTT 需在目标机验收。
