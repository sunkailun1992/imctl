# 1.0.1：完全磁盘访问权限探测在 macOS 27.0 上的假阴性（2026-09-22 16:1x–16:5x CST）— 通过

条件：macOS 27.0（26A428，2026-09-17 01:14 CST 从 26.6.2 升级，14:00 重启）；企业微信 5.0.11，主屏窗口 `(0, 30, 1920×1170)`，行高 64；守护进程 1.0.0 build 70 → 1.0.1 build 73（`~/Applications/imctl.app`，LaunchAgent）；传输 Unix socket（CLI）+ stdio MCP（Claude Code 会话）；本批**未发送任何消息**，只读探针与授权检查。

## 现象

- 接续交接里的第一件事：`imctl setup --check`。企微未开与打开后都报 `完全磁盘访问权限: no`、`访问企微数据: unknown`，退出码 2；控制台状态页同样 ✘。用户在系统设置里把 `imctl.app` 的完全磁盘访问权限关了再开（16:27 / 16:34），`launchctl kickstart -k` 重启守护进程（16:33），仍 `no`。
- 根因：1.0.0 的 `hasFullDiskAccess` 只试读 `~/Library/Application Support/com.apple.TCC/TCC.db`；**macOS 27.0 上该目录不存在（ENOENT）**，于是永远 `no`，且 `permissions()` 因此跳过企微容器探测。授权本身在：系统 TCC 库 `/Library/Application Support/com.apple.TCC/TCC.db` 里 `kTCCServiceSystemPolicyAllFiles | com.sunkailun.imctl.console | allowed`（按 bundle 记，覆盖包内 `imctld`）；`controller.permissions{probe:true}` 返回 `wecomData: granted` 且不弹框。
- 9/22 16:0x 交接快照里的「FDA 报 no」是同一个假阴性，不是升级丢了授权；升级是否动过该条目无法回溯（条目 `last_modified` 已被今天的开关覆盖）。

## 实现

- `WeComCommandHandler.hasFullDiskAccess(home:systemRoot:)`：先试用户级、再试系统级 TCC 库，任一可读即 `yes`；无 FDA 时两者都打不开（系统级目录受保护，EPERM）。
- `IMCTLVersion` 1.0.0 → 1.0.1；随包文件（`packaging/pkg/companion/`）、`docs/protocol/im-control-protocol.md` 示例、`docs/ops/permissions.md`（探测原理、27.0 事实、判据）、`docs/ops/installer.md`（第二台 Mac 若是 27.0 应装 1.0.1）同步。
- 新增 `Tests/WeComAdapterTests/PermissionsProbeTests.swift`（真实临时文件、无 mock）：用户级可读 → yes；仅系统级可读 → yes（27.0 事实，改前失败）；两者都打不开（mode 000）→ no。

## 单测

- `swift test`：324 用例 / 84 套件全过（上一批 321 / 83）；`ForbiddenAPITests` 通过；`bash scripts/check-secrets.sh` 11 条命中均为既有（`examples/` 与 `proxy/` 的占位 URL），本批文件 0 条。

## 活体 / 只读探针

| 步骤 | 结果 |
|---|---|
| 1.0.0 `setup --check`（企微未开 / 已开） | 辅助功能 trusted、FDA `no`、企微数据 `unknown`、退出码 2 |
| 用户开关 FDA + `kickstart -k`（pid 905 → 18560） | 仍 `no`（探测缺陷，非授权问题） |
| `ls ~/Library/Application Support/com.apple.TCC/` | No such file or directory；系统级库存在且本会话（持 FDA 的宿主）可读文件头 |
| 系统 TCC 库查询（只读） | `SystemPolicyAllFiles` 有 `com.sunkailun.imctl.console` allowed；`Accessibility` 有 bundle 条目 + 旧路径 `…/imctl/bin/imctld` 条目 |
| `controller.permissions{probe:true}`（1.0.0） | `wecomData: granted`，无对话框 |
| 安装 `out/imctl-1.0.1.pkg`（`-target CurrentUserHomeDirectory`）+ `kickstart -k`（pid 53208） | 日志 `imctld 1.0.1 running`、`client available; system pause lifted`；辅助功能授权保持；策略 `titles=2` 不变 |
| 1.0.1 `setup --check` | 五项全 ✔（FDA `yes`、企微数据 `granted`），退出码 0 |
| MCP `controller.permissions`（不传 probe） | `fullDiskAccess: yes`、`wecomData: granted`；`controller.describe` version 1.0.1 |
| 27.0 上读路径（升级后首次） | `account.status` 18 行、`conversation.list` 外部群标记与「全员」角标解析正常、`controller.diagnose` 几何同 1.0.0、`conversation.read imctl测试群` + `message.history` 方向 / 群内发送者 / 时间标签正常 |

## 结论与未闭环

- 通过：1.0.1 修正探测，macOS 27.0 上五项全 ✔；读路径在 27.0 上零改动通过。
- 未做 / 待活体：**发送路径未在 27.0 上复验**（1.0.0 事实全在 26.x 校准；下次对 `文件传输助手` 发一条即可）；切换 FDA 后是否必须重启守护进程未单独验证（本批重启过一次）。
- 待用户：是否打 tag `v1.0.1`；第二台 Mac 改装 `imctl-1.0.1.pkg`（桌面 `imctl-1.0.1-第二台Mac/`）并回报 `setup --check` / `controller.diagnose`。
- 顺带事实：pkg 的 `postinstall` 只在 `-target /` 时链接 `/usr/local/bin/imctl`，家目录安装要用 `~/Applications/imctl.app/Contents/MacOS/imctl` 全路径；守护进程 `errors` 计数在企微未开时每分钟涨 60，是 watcher 的「client is not running」，无害。

## 2026-09-22 17:03 补记：macOS 27.0 上发送路径复验 — 通过

条件同上，守护进程 1.0.1 build 74；用户 17:02 批准后发 **1 条**到 `文件传输助手`（编译白名单），文本「imctl 1.0.1 macOS 27.0 发送复验 17:03」，幂等键 `verify-27.0-文件传输助手-20260922-1`，经 Claude Code 的 stdio MCP 桥。

| 步骤 | 结果 |
|---|---|
| `conversation.read 文件传输助手` → `message.history` | active、composer、20 行；末行 #19（outbound，星期三 12:10） |
| `message.send` | `succeeded`，evidence `row #20 dir=outbound time=17:03`，`latencyMs` 2048（checkpoint 在 +2008 ms） |
| `message.history` | #20 outbound，文本一致，`timeLabel` 17:03 |
| `event.replay{afterEventId: 35198}` | 35199–35201 `command.state` accepted / running / succeeded；35202 `conversation.activity` 该会话预览更新；35208 `message.observed` `origin: controller` 带同一 `commandId`（succeeded 后 1.29 s） |
| 同键重发 | 回放同一 `commandId` / `createdMs` / 结果，`event.replay{afterEventId: 35211}` 无新的 `message.send` 事件 → 未发第二条 |

结论：发送路径（聚焦输入框 → 置前 → pid 级回车 → 外发气泡取证 → 交还前台）在 27.0 上零改动通过；至此 1.0.0 在 26.x 校准的客户端事实在 27.0 上读 / 发都复验过。

顺带观察（未查）：`文件传输助手` 里 9/16 11:01 的图片行本次读为 `media: unmatched`（9/16 B11 门里曾 `assigned`）——是重装 / 重启后 `media-index.json` 的对应丢了，还是行的 `messageKey` 变了，留待复核。
