imctl 1.0.14 开发安装包（arm64，Apple 芯片 Mac；macOS 15 及以上）
构建号和 SHA-256 请以同文件夹的 BUILD.txt 为准；也可运行 shasum -a 256 imctl-1.0.14.pkg 核对。

前提
- 第二台 Mac 上先装好并登录企业微信（已校准 5.0.11；其它版本 imctl doctor 会提示「未在此版本校准」）。
- 把整个文件夹拷过去（AirDrop / 网盘都行）。

安装（二选一）
A. 双击「install-on-another-mac.command」，按提示输入管理员密码，允许辅助功能、屏幕录制与「访问其他 App 的数据」；在系统设置里可给 imctl.app 打开「完全磁盘访问权限」。屏幕录制授权后若 macOS 提示，重启 imctl.app 与守护进程。
   若系统提示「无法打开，因为来自身份不明的开发者」：右键 → 打开，或在 系统设置 › 隐私与安全性 底部点「仍要打开」。
B. 终端手动：
   sudo installer -pkg imctl-1.0.14.pkg -target /
   /Applications/imctl.app/Contents/MacOS/imctl setup
   /Applications/imctl.app/Contents/MacOS/imctl setup --check      # 六项；完全磁盘访问权限可选

之后
- 打开 /Applications/imctl.app：程序坞里有图标，菜单栏也有；首次打开会弹出初始化向导；之后在「体检」页逐项检查，按钮可打开屏幕录制或完全磁盘访问权限设置页（先确认）。以守护进程的授权读回为准。
- 关闭控制台窗口后，菜单栏「打开控制台」会重新显示原窗口。
- 会话里本人消息靠右；文件传输助手是发给自己的会话，历史与 MQTT 事件统一记为本人发送并在控制台靠右。附件点击「获取地址」后可复制签名地址；控制台不自动下载图片、播放视频或打开文档。
- 历史 build 185 已验收 MQTT 向本人文件传输助手各发一条文字、图片、视频和 PDF；本包新增的视觉发送步骤仍须按 BUILD.txt 的本次验收状态判断。附件类型可从 `message.history` / `message.media` 区分。文件发送只允许输入框里的单个原生附件对象；回车后没有可靠新外发行时返回 `unknown`，不要换键重发。
- 已打开的会话再点「打开选中会话」会直接读取历史；企微辅助功能读取较慢时，控制台显示读取进度。
- 普通读取完成后会定位到最新一条；PDF / Word 等文件、视频与已确认的图片分开显示。对辅助功能方向未知、可能是图片的可见无文本媒体行，会在已获屏幕录制授权时按需截取企微窗口单帧并在内存中判断；文字、文件、视频及没有新增候选的日常轮询不截图，也不保存或上传截图。企微仍未给出足够证据的媒体或方向标为「未识别」/「方向未确认」，MQTT 也保留 unknown。
- 附件提示无法匹配时，不一定是本机没有缓存；可在企微打开原附件，再到控制台重取地址。跨天变化的图片消息时间标签会使用稳定的消息键，旧缓存对应只在能唯一核对时迁移。
- 消息解析已减少无关的辅助功能读取；实际等待时间仍取决于企业微信辅助功能响应，不能保证固定速度。
- 换机后先体检：/Applications/imctl.app/Contents/MacOS/imctl doctor（几何细节：imctl call controller.diagnose）
- 发送只到白名单（默认只有 文件传输助手），放行在策略页；MQTT 需要 imctl enroll 写本机设置（controller id 默认取本机名；控制台设置页同样预填），之后在控制台「状态 › 守护进程维护」点「安装 / 更新」以 MQTT 模式重装。
- 云端视觉默认关闭；需要时在「设置 → 视觉识别」选提供商和模型、输入该 Mac 自己的 API 密钥并启用。B16 的「添加群成员」按钮裁图与 B17 的完整企微窗口辅助分别授权；要允许后者，还须在设置页开启「允许整窗辅助」或运行 `imctl vision full-window --enable`。部分显式固定桌面命令可在经核验的 AX 候选上进行两轮企微整窗视觉复核；是否实际调用模型应以本机计数和命令证据为准，详见随包协议及 BUILD.txt。窗口可能包含其它会话预览和聊天内容；后台观察、自动申请及本机图片方向识别不上传。安装包不含密钥。默认千问 qwen3.7-plus；Gemini 可切换，但此开发机的 Gemini API 实测受地区限制。
- 接 Claude Code / Codex：/Applications/imctl.app/Contents/MacOS/imctl mcp install --claude-code --codex --skills

已知
- 包内 app 用 Apple Development 证书签名；pkg 本身未签名、未公证，双击可能被 Gatekeeper 拦截，可用上面的脚本或命令行安装。
- 「访问其他 App 的数据」的授权在更新版本后可能再弹一次；加了完全磁盘访问权限就不会。
