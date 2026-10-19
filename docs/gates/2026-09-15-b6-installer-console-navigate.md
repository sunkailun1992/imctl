# 门报告：B6 安装包、测试控制台与菜单驱动会话导航（2026-09-15）

计划：`docs/superpowers/plans/2026-09-15-b6-installer-console-navigate.md`（含 as-built 变更）。用户决定（2026-09-15）：做安装包、做一个能做控制操作方便测各种问题的 UI；不引入 LLM 操控客户端（模型仍只在 Java 侧）。

## 条件

- 客户端 企业微信 5.0.11（`com.tencent.WeWorkMac`），消息视图，会话筛选侧栏打开，文件传输助手 为活动会话；控制器从终端启动（继承辅助功能授权）。
- 只对 文件传输助手 发送（1 条）；导航只按「窗口」菜单项，每次 next 后立即 previous 恢复；真实联系人标题一律脱敏（只记长度）。
- 已装的 LaunchAgent（旧稳定副本，未勾选辅助功能）全程未动。

## 实现

| 项 | 内容 |
|---|---|
| 布局修复 | `WeComLayout.locate`：会话表 = 高度 ≥ 半窗的最左表；消息表 = 会话表右侧最宽的表。筛选侧栏（`AXTable`，-1,484,162×242）不再被当成会话表。夹具 `wecom-5.0.11-filter-panel.json`（脱敏，消息行截为 3 行） |
| `client.navigate` | `RPCMethod` 27 个；`NavigateAction {nextConversation, previousConversation, nextUnreadConversation}`；需 `idempotencyKey`；受暂停集合；`ActionKind.navigate`（无目标）；`tools/list` 28；协议文档 §6.11 / §12 |
| 适配器 | `WeComMenuBar.items/menuItem`（应用元素 → `AXMenuBar` → `窗口` → `AXMenu`）；`WeComActions.navigate`：`AXFrontmost` 置前 → 等菜单项 enabled → `AXPress` → 前后活动标题 → 焦点还给之前的前台应用（`frontmostPid` / `restoreFrontmost` 可注入）；`WeComCommandHandler.clientNavigate`；`imctl probe menubar`（只读）；`FakeAXBackend` 应用节点派生 `AXMainWindow` / `AXWindows` |
| 本地通道 | `MCPTransport.UnixSocketClient`（每次调用一条连接，`RPCError` / `TransportError`）；`imctl call <method> [--params] [--socket]`；`IMCTLPaths.database/stateFile/runDirectory/socket/logDirectory`；`imctl agent install` 默认 `--socket`（`--no-socket` 关闭）；`state.json` 增 `trusted` / `socket` |
| 控制台 | 新 target `imctl-console`（SwiftUI `MenuBarExtra` + 窗口；状态 / 会话 / 发送 / 事件 / 策略 / 设置 / 诊断 / 日志）；改客户端状态只经守护进程套接字，launchd / 策略经 CLI，进程内只读诊断与 0600 配置写入；`IMCTL_SOCKET` / `IMCTL_STATE` / `IMCTL_CLI` 开发期覆盖 |
| 打包 | `scripts/signing-identity.sh`、`build-app.sh`（`out/imctl.app`：控制台 `com.sunkailun.imctl.console` + `imctl` / `imctld` 保持 `com.sunkailun.imctl`）、`build-pkg.sh`（`out/imctl-<版本>.pkg`，未签名开发版；`IMCTL_HARDENED` / `IMCTL_INSTALLER_IDENTITY` / `IMCTL_NOTARY_PROFILE` 出发布版）；`packaging/`（Info.plist 模板、distribution、安装器文案、postinstall 只做 CLI 链接）；`docs/ops/installer.md` |

## 单测

`swift test`：**222 个用例、66 个套件全部通过**（B5+ 之后 +22：布局 2、协议 / 执行器 / 分发器 3、导航 5、伪后端 1、处理器 1、探针 1、套接字客户端 2、路径 1、控制台 5 + 既有断言更新）。`ForbiddenAPITests` 通过（`AXFrontmost` 是 AX 属性写，不是合成事件）。

一次陷阱：插入 `clientNavigate` 后 `WeComAPITests` 4 个用例把方法解析成"前一个"（`groupList` → `clientNavigate`），是 `.build` 里 `WeComAPI` 的旧目标文件按旧枚举布局链接；`swift package clean` 后全部通过。

## 活体

| 项 | 结果 |
|---|---|
| `probe conversations`（侧栏打开） | 64 px 行、11 个会话、`#1 * 文件传输助手`（修复前输出的是 8/32 px 的筛选行） |
| `probe menubar` | 「窗口」19 项，含 `选择下一个会话` / `选择上一个会话` / `选择下一个未读会话`，非前台时 `[disabled]` |
| 临时守护进程（`--socket`） | `state.json`：`trusted:true`、`socket` 路径、`paused:[]`、`active:文件传输助手`、`conversations:11`、`observer:true` |
| `imctl call client.navigate` | 修复前（只 AXPress）：`changed:false`；`AXFrontmost` 后：next → `enabled:true, changed:true, after ≠ 文件传输助手`；previous → `changed:true, after == 文件传输助手`；同键回放同一 commandId、不再按 |
| 焦点归还 | 导航后前台应用不是企业微信（`NSWorkspace` 读数） |
| 控制台（`out/imctl.app`，环境变量指向临时守护进程，AX 驱动） | 窗口 + 状态项（`message.badge.waveform`）；状态页显示 pid / 授权 / 套接字 / 事件 id / describe；会话页读取列表→打开 文件传输助手→12 条消息；下一会话（活动标题变为 4 字符的真实会话）→ 上一会话（回到 文件传输助手）；发送页向 文件传输助手 发 1 条 `imctl console b6` → `command.state succeeded`，事件流 `message.observed{origin:controller, direction:outbound}` 文本一致；事件页拉取、日志页记录 `message.send` / `client.navigate` / `conversation.*` / `message.history`；状态项菜单列出 打开控制台 / 刷新 / 暂停 / 重启 |
| 安装包 | `out/imctl-0.1.0.pkg`（debug 版 25.5 MB）；`installer -target CurrentUserHomeDirectory` → `~/Applications/imctl.app`；`codesign --verify --deep --strict` 通过；包内 CLI `version` 与 `call controller.describe` 正常；payload 里的 `._*` 记录只剩 `com.apple.provenance`（macOS 14+ 系统管理、不可剥离的属性，pkgbuild 正常序列化，无害）；外置盘（exFAT）带来的 AppleDouble 垃圾靠"在内置盘暂存 + `ditto --noextattr` + `xattr -cr`"消除 |

## 结论

B6 通过：安装包、控制台、`client.navigate` 三项都在真实客户端上闭环；筛选侧栏缺陷修复。协议只加了一个方法（`client.navigate`）与两个状态键，wire 兼容。

## 未闭环 / 需要用户决定

1. **导航会短暂抢前台**：`AXFrontmost` 让企业微信成为前台 ≤ 1 s，随后归还焦点。无人值守的坞站机无所谓；日常用机上会看到一闪。不接受则只能放弃菜单导航（左侧导航栏按钮在 AX 树里是禁用切片，无法 `AXPress`）。
2. **LaunchAgent 仍是旧稳定副本**：切到 `/Applications/imctl.app/Contents/MacOS/imctld`（控制台"安装 / 更新守护进程"或 `imctl agent install`）需 `sudo installer -pkg … -target /`，并在辅助功能里勾选 `imctld`；控制台诊断页要单独勾选 `imctl 控制台`。
3. **Developer ID**：现在是 Apple Development 签名、未签名 pkg；发布版需 Developer ID Application + Installer 与 notary profile（脚本已支持）。
4. **视图切换不可达**：客户端若停在通讯录 / 工作台等视图，仍需人点回「消息」。
5. `nextUnreadConversation` 未在有未读时验证（当时无未读）；`command.cancel` 仍是 no-op。

## 追加修正（2026-09-15 09:4x–10:0x，用户实际使用控制台后）

| 现象 | 原因 | 修正 |
|---|---|---|
| 会话页"读取列表"为空、无提示 | 控制台后面是旧守护进程（未授权、`system` 暂停），`conversation.list` 回 `CLIENT_UNAVAILABLE`，错误只进了日志页 | 会话 / 发送 / 事件页内联显示最近一次调用错误（`lastError`）与守护进程状态提示（`daemonHint`：未运行 / 未授权 / system 暂停 / 旧版） |
| 点"安装 / 更新守护进程"后 `state.json` 消失、LaunchAgent「已装入 否」 | `agent install` 先 bootout 再立刻 bootstrap，launchd 尚在拆旧任务，bootstrap 报 `5: Input/output error`；旧守护进程已退出、新任务没装入 | `agent install`：等标签消失（≤ 3 s）后 bootstrap，失败重试 ≤ 4 次，以最终 `launchctl print` 为准；状态页内联显示安装 / 重启 / 卸载的输出（`lastAgentAction`）。手动 bootstrap 后任务已运行（pid 41306，包内守护进程，`trusted:true`） |
| 守护进程日志每 3 s "published 3 event(s)" | 控制台每 3 s 全量刷新调 `controller.describe`（它是命令，产生 3 个 `command.state` 事件并经 MQTT 发布）| 周期刷新只读 `state.json`（`refreshLocal`），launchd 状态与 `describe` 只在打开 / 点刷新 / 每 60 s |

装回 `~/Applications`（`installer -target CurrentUserHomeDirectory`）并 `launchctl kickstart -k` 后，用户机上的守护进程即为含 B4 活体修正的版本。

