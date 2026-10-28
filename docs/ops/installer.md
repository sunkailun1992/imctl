# 安装包与控制台

## 产物

| 文件 | 内容 | 脚本 |
|---|---|---|
| `out/imctl.app` | `Contents/MacOS/imctl-console`（控制台，`com.sunkailun.imctl.console`）+ `imctl` + `imctld`（保持 `com.sunkailun.imctl`，辅助功能授权跨升级保持） | `scripts/build-app.sh [debug|release]` |
| `out/imctl-<version>.pkg` | 装到 `/Applications/imctl.app`（或 `~/Applications`）；`postinstall` 只做 `/usr/local/bin/imctl` 链接 | `scripts/build-pkg.sh [debug|release]` |

版本来自 `IMCTLVersion.string`（去掉 `-dev`），build 号 = `git rev-list --count HEAD`。`out/` 不入库。1.0.5 增加 B16 的本机独立云端视觉设置；1.0.6–1.0.11 逐步加入 B17 整窗许可、固定命令视觉后备、目标选择、历史滚动、申请表导航与操作前复核。1.0.13 build 185 在 B33 验收了 MQTT 向本人发送文字、图片、视频、PDF 各一条，**当时均是纯 AX 发送、视觉计数为零**，见 `docs/gates/2026-09-26-b33-mqtt-desktop-e2e.md`。

当前源码版本为 **1.0.26-dev**（[B62 门报告](../gates/2026-10-28-b62-ax-review-minors.md)：B61 审查的次要问题；[B63 门报告](../gates/2026-10-28-b63-mqtt-reconnect.md)：MQTT 重连同一时间只保留一个）。本机当前安装 **1.0.26 / build 13**（`main@2e91f05` 构建，2026-10-28 09:55 安装，只读核对通过），签章 designated requirement 与 1.0.25 / build 21、1.0.24 / build 9 相同，TCC 授权保留；build 号按 `main` 的提交数计，小于 B61 分支构建的 build 21，不是回退。1.0.25 / build 21 与 1.0.24 / build 9 的回滚包在本机 `out/rollback/`（不入库）。B61 的 1.0.25 / build 21 见 [B61 门报告](../gates/2026-10-27-b61-ax-call-timing-batch-reads.md)（AX 逐次计时与批次读取，2026-10-27 只读实测通过）。B60 时期的 1.0.23 / build 8、1/2 次实际改名与还原经过见 [B60 门报告](../gates/2026-10-19-b60-group-name-field-resize.md) 与 PR #9 最终回执。公开迁移与旧私有仓库删除记录见 [公开迁移报告](../gates/2026-10-19-public-migration.md)。以下保留历史安装记录：截至 2026-10-13，`out/b54-build302/imctl-1.0.17.pkg` 为 **release build 302**（B54 分支 `7305846` 构建；之后只有文档提交，代码与合入后的 main 相同），SHA-256 `869fde088e0e95124539707efd6d1b0fa10ea802751a3c6d759bf6acf1330cc5`；同一张 Apple Development 证书签名，已安装到本机（新 Mac），包内与已安装的 `imctld` SHA-256 一致。完整测试 **1173/1173** 通过；`imctl doctor --offline` 就绪（按手机号加人：号码不限，每小时最多添加 20 次、搜索 60 次）；包中不含视觉 API 密钥；`contact.add` 在本机企业微信 5.0.12（繁体界面）上未校准，见 `docs/gates/2026-10-13-b54-verification-invite.md`。B53 的 release build 288（SHA-256 `78a03e02bd83b58097bcb04e0b6483bb3214e794b4d3f50040af247fadedffe8`）见 `docs/gates/2026-10-13-b53-guided-setup.md`。B52 的 release build 269（SHA-256 `01fc357ee5dbe271efd06c674d8852d92b94b38aeec552b5ce290b4ae7813007`）见 `docs/gates/2026-10-12-b52-readiness-doctor.md`。以下是此前旧 MacBook（已抹掉）上 build 224 的记录：截至 2026-09-26，`out/imctl-1.0.14.pkg` 为 **release build 224**，SHA-256 `6cfd7fe805a0a9720fd9f9746decfbd4a617a92263049cbca80794f6ff55ec94`，完整测试 **903/903** 通过，`setup --check` 六项通过。默认千问 `qwen3.7-plus` 的本机云端、整窗开关及密钥状态均已读回启用，包中不含视觉 API 密钥。真实 MQTT 安装版已验收 `client.navigate` 往返（每次 2/2/2）、`message.history` 向更早消息滚动（2/2/2、旧行补入后成功）、`contact.list`（4/4/4）、`group.addMembers{dryRun:true}`（4/4/4、无实际新增）和 `conversation.read`（2/2/2）；每项均有命令终态、`command.get` 与相应 AX 后验。`contact.request.list` 已选中快路径成功且 **0/0/0**，不算视觉模型调用。这 7 个 build 224 命令经 `event.replay` 对账均有 `accepted → running → succeeded`。这里的三项数字依次是截图 / 模型请求 / HTTP 200 增量，单看数字不代表成功；旧 build 211/222 的失败及修正过程见 `docs/gates/2026-09-26-b45-visual-mqtt-release.md`。B36 真实视觉发送及其它未列明的写命令尚未活体验收；当前本机安装也不等于第二台 Mac 已安装或验收。逐方法上限和证据见 `docs/gates/2026-09-26-b17-visual-coverage-audit.md`。

## 给别的 Mac 安装

`packaging/pkg/companion/` 里有随包分发的两份文件：`install-on-another-mac.command`（双击：安装 → `imctl setup` → `setup --check`）与 `README-另一台Mac.txt`（前提、两种装法、之后要做的事、已知问题）。本批可拷贝产物为 `out/imctl-1.0.14-第二台Mac.zip`，SHA-256 `66fc9e02d2feae4912674074dd29bc3faee14d4e9d8ba2a52af496351c872fbb`；ZIP CRC 与其中 pkg 的 SHA-256 已校验，尚未在第二台 Mac 安装。版本沿革：1.0.0 build 70；1.0.1 build 74 修 macOS 27.0 完全磁盘访问权限探测；1.0.2 build 110 加 B13 文件与 OSS；1.0.3 build 132 加 B14 群成员与策略；1.0.4 新增按需单帧方向判断和屏幕录制授权。build 136 的行内媒体方案因加载慢、视频崩溃而撤回，见 `docs/gates/2026-09-23-console-address-only-rollback.md`；当前控制台只在用户点击后获取签名地址，不自动下载或播放。build 139 修复当前活动会话的重复 AX 读取与控制台等待超时；build 141 增加最新消息定位、保守媒体分类与 AX 读取消重；本轮修复 `-25201` 行读取、显式历史默认到最新、文件传输助手在 MQTT 也统一为本人方向，并让守护进程复用未变化的消息快照，见 `docs/gates/2026-09-23-conversation-ax-latest-performance.md`。随后恢复菜单栏重新显示隐藏窗口，并跳过消息行无关子元素的 AX 几何读取，见 `docs/gates/2026-09-23-console-reopen-row-reads.md`。打开其他会话时消息已返回却呈空白的列表位置问题，见 `docs/gates/2026-09-24-console-empty-chat-viewport.md`；AX 实际时延仍会波动。目标 Mac 安装与授权仍需在那里读回。需要 OSS 的机器先 `imctl oss set`。

1. 在开发机 `scripts/build-pkg.sh release` 得到 `out/imctl-<version>.pkg`（应用图标 `packaging/console/icon/AppIcon.icns`，改图用 `make-icns.sh` 重生成）。
2. 拷到目标 Mac，`sudo installer -pkg imctl-<version>.pkg -target /`（或 `-target CurrentUserHomeDirectory` 装到 `~/Applications`）。没有 Developer ID 签名 + 公证时，双击 pkg 会被 Gatekeeper 挡，右键 › 打开 或用上面的命令行。
3. 目标 Mac 上跑 `<imctl.app>/Contents/MacOS/imctl setup`：装 LaunchAgent，请求辅助功能、屏幕录制与「访问其他 App 的数据」授权；如屏幕录制尚未允许，会打开对应设置页，完全磁盘访问权限可在控制台「体检」页点这一项的「打开系统设置」后添加。按 macOS 提示重启应用及守护进程后，用 `imctl setup --check` 复查六项。见 `docs/ops/permissions.md`。
4. 企微已校准的版本是 5.0.11；其它版本不会被拦下，`imctl doctor` 会提示「未在此版本校准」，能否使用以它的可读性检查为准；几何见 `docs/ops/portability.md`。
5. 接 Claude Code / Codex：`imctl mcp install --claude-code --codex --skills`（`docs/protocol/agents-mcp.md`）。
6. `imctl doctor`：逐项列出能不能用、卡在哪、怎么修（默认做联网实测，含一次合成图视觉调用；`--offline` 只看本机；`--fix` 逐项询问并执行修复，先确认），见 `docs/protocol/im-control-protocol.md` §6.45。控制台首次打开、未就绪时会弹出初始化向导，之后可在「体检」页或菜单栏「初始化向导…」重新运行。

## 签名与公证

- 开发：Apple Development（`scripts/signing-identity.sh` 选择：`IMCTL_SIGN_IDENTITY` → Developer ID Application → Apple Development），`.pkg` 不签名。安装：`installer -pkg out/imctl-<version>.pkg -target CurrentUserHomeDirectory`（装到 `~/Applications`，不需要 sudo）或 `sudo installer -pkg … -target /`。
- 发布：`IMCTL_HARDENED=1 IMCTL_INSTALLER_IDENTITY="Developer ID Installer: …" IMCTL_NOTARY_PROFILE=<profile> scripts/build-pkg.sh release`（先 `xcrun notarytool store-credentials <profile>`）。换成 Developer ID Application 后 designated requirement 变化，首次要重新勾选辅助功能。
- 安装包不直接修改 launchd 与 TCC；`imctl setup` 和控制台（初始化向导、体检页的「安装并请求授权」按钮）由守护进程请求屏幕录制授权。B15 本机图片方向判定不上传，后台观察和自动申请也不上传企微截图；不申请输入监控。
- B16 的按钮裁图与 B17 的整窗辅助共用屏幕录制权限，但有**独立本机开关**。默认提供商为千问 `qwen3.7-plus`，可切换 Gemini；密钥只在目标 Mac 的本机受限存储中设置，不随 pkg / 第二台 Mac 压缩包分发。整窗辅助仅对显式固定桌面命令使用，需在「设置 → 视觉识别」另点允许或执行 `imctl vision full-window --enable`，并用 `imctl vision status --json` 核对 `fullWindowEnabled`。B34–B44、B46 的模型参与点是当前命令预先限定的 AX 候选选择或动作前后被动观察；B47 假传输集成验证了整条执行链。模型不负责决定发送内容、目标或提交，也不能凭 HTTP 200 宣称操作成功。旧 B16 开关不会自动开启整窗；第二台 Mac 要单独配置和授权。千问使用固定官方端点；Gemini Developer API 曾在本机返回地区限制，配置存在不代表可用。真实验收边界以本节和 B17 视觉覆盖门报告为准。

## 本机更新已装的应用

LaunchAgent 从 `~/Applications/imctl.app/Contents/MacOS/imctld` 启动时，`scripts/install-daemon.sh` 会按设计拒绝（它只更新独立的 `bin/` 目录）。这时直接替换应用：

1. 用与已装版相同的签名身份构建：`IMCTL_SIGN_TEAM` / `IMCTL_SIGN_TEAM_ID` 指向本机证书的团队，`IMCTL_OUT_DIR=out/<批次>-candidate scripts/build-app.sh release`；`codesign -d -r-` 核对三个可执行文件的 designated requirement 与已装版逐字相同，否则辅助功能授权会失效。
2. 确认没有执行中的命令；把已装版打包回滚：`ditto -c -k --keepParent ~/Applications/imctl.app out/rollback/imctl-<版本>-build<号>-<日期>.zip`，解包核对签章与哈希。
3. `ditto --norsrc --noextattr` 把新包复制到 `~/Applications` 下的临时名，`codesign --verify --deep --strict` 通过后用 `mv` 换下旧包，再 `launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl`。
4. `imctl status`、`imctl doctor --offline`（不加 `--offline` 会跑联网实测，含一次合成图视觉调用）、`imctl call controller.describe`。

不用开发 pkg 做这件事：pkgbuild 默认 `BundleIsVersionChecked`，磁盘上已有更大 build 号（例如分支构建）时会跳过 bundle，安装看似成功却没有替换。

## 安装后的三步（控制台）

1. 打开 `imctl.app` → 菜单栏图标 → 打开控制台。
2. 状态页「安装 / 更新守护进程」= `imctl agent install --socket ~/Library/Application Support/imctl/run/imctl.sock [--mqtt]`（守护进程路径 = 包内 `imctld`）。
3. 控制台首次打开会弹出初始化向导：第 1 步「安装与授权」点按钮（先确认），并检查辅助功能与屏幕录制：`imctld` 负责读写客户端和按需判断无文本媒体行方向；`imctl 控制台` 的辅助功能只在用体检页「界面诊断」时需要。屏幕录制权限由守护进程读回，不以控制台自身权限推定。云端开关与提供商 / 密钥状态在「设置 → 视觉识别」单独核对；屏幕录制授权本身不启用云端上传。

## 控制台能做什么 / 不能做什么

- 经守护进程套接字（与 Java 同一路径，策略 / 幂等 / 速率 / 事件一致）：`conversation.list|read`、`message.history|send`、`client.navigate`、`controller.pause|resume`、`event.replay` 实时跟踪。
- 经 CLI：`agent install|uninstall|status`、`policy list|allow|deny`；`launchctl kickstart -k` 重启。
- 进程内只读：体检页的「界面诊断」（布局、活动会话、窗口菜单）；写 `mqtt.json` / `wecom-proxy.json`（0600）。
- 不做：任何绕过守护进程的客户端写操作；业务回复仍由 Java 决定。视觉模型只能给显式固定命令选择受约束的 AX 候选，不能修改目标、正文、策略、幂等键或凭自身判断报告成功。逐方法 B17 覆盖以门报告为准。

## 开发期直接跑

```bash
scripts/build-app.sh debug
IMCTL_SOCKET=/tmp/x/run/s.sock IMCTL_STATE=/tmp/x/state.json IMCTL_CLI=.build/arm64-apple-macosx/debug/imctl out/imctl.app/Contents/MacOS/imctl-console   # 从终端启动：环境变量覆盖、继承终端的辅助功能授权
open out/imctl.app                                                                                                                                  # 作为普通应用启动：默认路径，需要自己的授权
```

## 验证

B60 仅对本命令固定写值后、同一群名字段的宽度变化作受限相容，位置/高度、唯一编辑器、原会话与窗口、政策/权限/模型停止权均保留。首次 checkpoint 后验证失败不再自动写回原名；旧列表行可能是缓存，不能证明服务端未改名。未知结果也不自动切回其他应用使字段失焦；写前失败与已验证成功仍按原规则归还前景。当前现场保持停止，不重启、更新或激活应用来处理未知名称；待维护者明确授权后才安排更新与剩余一次还原。

B59 开发时本机已安装 1.0.22/build 7，一次获准请求通过群名稳定检查但在 prepare/round 1 被模型 stop，零名称写入、实际改名仍 0/2。1.0.23-dev 修正合成像素已证实的整窗 JPEG 上下翻转；它不改变模型否决或权限。安装、签章与受限现场最终结果见 [B59 门报告](../gates/2026-10-19-b59-window-image-orientation.md) 关联 PR 的回执，不能将离线方向通过视为群名已改成功。

B58 开发时本机已安装 1.0.21/build 6，与 B57 公开合并源码树一致；一次获准请求仍在 B37 prepare/round 0 零写入失败，真实群名修改尚未验收。1.0.22-dev 先补固定拒绝类别，不能将诊断或候选构建等同于修复成功；后续安装与受限验证的最终回执见 [B58 门报告](../gates/2026-10-19-b58-group-name-guard-diagnosis.md) 所链接的 PR。

`codesign --verify --deep --strict out/imctl.app`；`pkgutil --payload-files out/imctl-<v>.pkg`；装后 `~/Applications/imctl.app/Contents/MacOS/imctl version`；`imctl call controller.describe`。

`controller.describe` 的 `visionCaptureCount`、`visionRequestCount`、`visionHTTP200Count` 是守护进程级十进制累计值，可在一次显式命令前后读回核对是否实际截屏、发起模型请求以及官方端点是否返回 HTTP 200。`visionCaptureCount` 只累加取图、编码与截后 AX 复核全部完成的 observation；零值不排除曾取图后在复核失败。HTTP 200 在响应解析前计，不证明模型选择、AX 后验或命令成功。响应不包含截图或模型原文；`setup --check` 的权限读回也不证明视觉链路已运行。

## 卸载

控制台「卸载」（`imctl agent uninstall`）→ 删除 `imctl.app` 与 `/usr/local/bin/imctl` → 数据在 `~/Library/Application Support/imctl`、日志在 `~/Library/Logs/imctl`，按需删除。
