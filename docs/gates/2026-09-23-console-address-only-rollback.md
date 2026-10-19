# 控制台媒体回退为按需地址（2026-09-23）

## 用户反馈与决定

build 136 的行内媒体实用反馈是：打开会话变慢、图片未展示、点击视频后应用退出。用户决定控制台只用于检查，主要通过 MQTT 获取与操控数据；附件恢复为文件地址，不在控制台自动加载或播放。用户另明确「文件传输助手」消息都是自己发给自己，显示时应在右侧。

## 修改边界

- 会话滚动时不调用 `message.media`。图片、文件、视频都由用户点「获取地址」才请求签名地址；显示并可复制完整地址。取地址不再顺带下载封面或图片，也不启动 `VideoPlayer` 或本机默认应用。
- 「文件传输助手」在控制台显示为自己发出的消息并靠右；其他会话保持 AX 方向读数。此处只改显示，不改 `message.history` / `message.observed` 数据及 MQTT 语义。
- 守护进程、MQTT、策略、白名单、发送和授权配置均不更改。已知企微缓存确实不存在的行仍会回 `MEDIA_NOT_FOUND`，不能凭空恢复附件。

## 验证

| 项目 | 结果 |
|---|---|
| `swift build --product imctl-console` | 通过 |
| `swift test --quiet` | 517 项通过（9 个测试目标；live 套件默认跳过） |
| `git diff --check` | 通过 |
| build 137 app 与 pkg 包内 app | `codesign --verify --deep --strict` 均通过，包内 `CFBundleVersion=137`；pkg 为未签名、未公证开发包 |
| 本机安装 | `~/Applications/imctl.app` 为 build 137；`imctl setup --check` 五项通过 |
| MQTT 守护进程 | 未重启；安装前后同一 PID，`agent status` 仍 loaded / active |
| 第二台 Mac 随包文件 | pkg、说明、BUILD.txt、zip 均已更新；解压 zip 后包内 pkg SHA-256 与构建产物相同 |
| 新版真人界面 | CUA native pipe 仍关闭，地址按钮与聊天排版待用户侧点检 |

代码提交 `d8fc1aa`。pkg SHA-256：`278898b90c92947d888e83a29a00a0cda008a90f5062eb20c81736dfccf93077`。用户指出的 build 136 视觉、性能与视频崩溃问题是实际使用证据；build 137 的地址按钮尚待用户侧点检。发送 0 条。
