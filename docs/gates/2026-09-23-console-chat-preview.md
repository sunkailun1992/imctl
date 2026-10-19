# 控制台聊天布局与图片视频内预览（2026-09-23）

> build 135 初版记录。build 136 的行内预览后来因性能和视频崩溃被用户否决；现行地址模式见 `2026-09-23-console-address-only-rollback.md`。

## 需求与范围

用户明确会话应采用常见聊天布局：本人发出的消息靠右，对方消息靠左；图片和视频应由 imctl 直接显示或播放，PDF 等文档交给本机默认应用。本批只修改 `imctl-console` 的会话视图与媒体打开路径，不改守护进程、消息方向推断、协议、发送、策略、白名单或运行数据。

## 实现

- 消息气泡按 `message.history.direction` 布局：`outbound` 靠右、`inbound` 靠左，带各自头像占位；`unknown` 居中标记方向未确认，避免把无证据的图片误排到任一侧。消息键从正文移到悬停提示。
- 图片缩略图可点击，在 imctl 的预览窗口放大；视频封面与“播放视频”在取回正片后打开内嵌 `VideoPlayer`。没有正片时保留企微播放后刷新的提示；无缓存图片保留具体 `MEDIA_NOT_FOUND` 与重试入口。
- `ConsoleModel.prepareMedia` 只负责已配置 OSS 链接的下载、签名/大小等既有校验与本地缓存；文件卡片再通过 `openDocument` 调用 macOS 默认应用。图片与视频不调用 `NSWorkspace.open`。过期签名地址刷新失败时不继续用旧地址。
- 文件/视频仍按需取回，滚动聊天记录不会批量占用守护进程的媒体上传队列。真实头像像素来源仍未找到，本批沿用身份占位图。

## 验证

| 项目 | 结果 |
|---|---|
| `swift build --product imctl-console` | 通过 |
| `swift test` | 515 项通过（9 个测试目标；live 套件默认不运行） |
| `git diff --check` | 通过 |
| `bash scripts/check-secrets.sh` | 11 条既有 warning，无本批新增命中 |

本批没有向企微发送消息，也没有切换客户端会话或改变策略。图片/视频在新窗口内的真人点击、窄窗气泡排版和目标 Mac 安装仍需视觉点检；构建与单测不作为这些验收的替代。

## 制品与本机安装读回

- 代码提交 `a07f7f0` 已推送；由此提交构建的 1.0.3 build 135 `imctl.app` 和 `imctl-1.0.3.pkg` 已生成。独立 app 和包内 app 均通过 `codesign --verify --deep --strict`，包内 `CFBundleVersion=135`。pkg SHA-256 为 `2ebbcfba9fe2998966f0312dc4e0127dbf224f1a8377d94466988ca390aa92ca`；pkg 本身是未签名开发包，未公证。
- 本机 `~/Applications/imctl.app` 从 build 134 替换为 build 135，旧 app 留在应用数据目录的 backup 子目录；新 app 签名通过，`imctl setup --check` 五项均通过。只改控制台，现有 LaunchAgent 未重启、策略未改。
- CUA 能看到 imctl 进程，但读取已安装 app 时返回 `Sky Computer Use native pipe closed before response`，无法对新会话页做真人点击与窄窗视觉点检。视频实际播放与 PDF 外部打开在此批均标为待验；之前外发 PDF 的媒体取回活体结果见 `2026-09-23-console-media-open.md` 与 Wiki 后续回执。
