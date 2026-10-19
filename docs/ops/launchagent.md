# imctld 常驻形态：LaunchAgent（2026-09-14 已安装，验收进行中）

用户 2026-09-14 00:15 CST 决定安装。安装形态：`~/Library/LaunchAgents/com.sunkailun.imctl.plist` 指向**稳定副本** `~/Library/Application Support/imctl/bin/imctld`（不是 `.build/`，因为 `swift test` 会把 `.build/` 里的二进制覆盖成 ad-hoc 签名，launchd 重启时就会失去 TCC），带 `--mqtt --socket ~/Library/Application Support/imctl/run/imctl.sock --watch-interval 1.0`。

## 它做什么

- `RunAtLoad` 登录即启；`KeepAlive = {SuccessfulExit: false}`：崩溃或非零退出 5 s 内重启（`ThrottleInterval = 5`），`launchctl bootout` / SIGTERM 的正常退出不重启。
- `LimitLoadToSessionType = Aqua`：只在登录的 GUI 会话内；`ProcessType = Interactive`：不按后台任务限速。
- stdout/stderr 到 `~/Library/Logs/imctl/imctld.out.log` 与 `imctld.log`（launchd 追加写，无轮转）。
- 环境变量 `IMCTL_LAUNCHD=1`：守护进程启动时若未获辅助功能授权，会主动调用 `AXIsProcessTrustedWithOptions(prompt)` 让系统弹一次授权提示并把 `imctld` 加进辅助功能列表（也可手工 `imctld run --prompt-accessibility`）。

## 关键事实：launchd 下 TCC 是守护进程自己的

从终端（含 Claude Code）运行时，子进程继承"负责进程"（终端应用）的辅助功能授权，所以 `imctl permission` 显示 trusted 不代表 `imctld` 自己被授权。launchd 直接拉起时没有可继承的父进程，**`imctld` 必须自己出现在 系统设置 › 隐私与安全性 › 辅助功能 里并被勾选**。2026-09-14 00:20 实测：LaunchAgent 首次启动即 `process is not trusted for Accessibility`，守护进程发出系统提示后等待用户勾选；勾选后无需重启，下一次轮询即 `client available; system pause lifted`（待验）。

## 安装 / 更新

```bash
scripts/install-daemon.sh            # 构建 + 稳定身份签名 + 复制到 ~/Library/Application Support/imctl/bin + 若已装则 launchctl kickstart -k
"$HOME/Library/Application Support/imctl/bin/imctl" agent install --mqtt --socket "$HOME/Library/Application Support/imctl/run/imctl.sock"   # 首次安装（需先 imctl enroll）
"$HOME/Library/Application Support/imctl/bin/imctl" agent status
```

安装包形态（B6，2026-09-15）：`/Applications/imctl.app/Contents/MacOS/imctld`，由控制台「状态 › 安装 / 更新守护进程」或包内 `imctl agent install` 安装；`--socket` 默认开启（`~/Library/Application Support/imctl/run/imctl.sock`，`--no-socket` 关闭），控制台与 `imctl call` 都走它；`state.json` 增 `trusted`（守护进程自己的授权）与 `socket`。见 `installer.md`。

先看再装：`imctl agent install --dry-run --mqtt` 只打印 plist。可选：`--watch-interval 5`（有 AXObserver 时放慢兜底轮询）、`--no-observe`、`--no-load`。

## 验收清单（2026-09-14 结果）

| 项 | 命令 / 观察 | 通过标准 | 结果 |
|---|---|---|---|
| 安装与装入 | `agent install` → `agent status` | `loaded: true, state: active` | **通过**（00:18 CST，pid 8319） |
| 更新二进制 | `scripts/install-daemon.sh`（kickstart -k） | 新 pid，`lastExitCode 0`，无重复发送 | **通过**（pid 8319 → 9736） |
| 崩溃重启 | `kill -9 <pid>`；8 s 后 `agent status` | 新 pid；socket 重新绑定；日志正常启动 | **通过**（pid 9736 → 10291，`socket: listening` 重新出现） |
| 与 broker 一致 | `imctl mqtt tail --seconds 3` | retained `…/state` `online:true` 且 pid 与 state.json 一致 | **通过**（pid 10291 两处一致） |
| TCC（launchd 下自己的授权） | 日志无 `not trusted`；state.json `paused` 无 `system` | 辅助功能列表里 `imctld` 已勾选 | **待用户勾选**：首次启动已弹系统提示 |
| TCC 跨更新保持 | 勾选后再 `scripts/install-daemon.sh` | 不重弹、watcher 正常 | 待验 |
| 登录自启 | 注销再登录；`agent status` | `state: active`，`imctl status` 的 `daemonAlive = true` | 待用户注销/登录（助手不能注销当前会话） |
| 7 天连续运行 | 每天 `imctl status`、`grep -c "watcher error" ~/Library/Logs/imctl/imctld.log` | 无非预期 `system` 暂停；事件游标单调 | 从 TCC 勾选之时起计 |

## 卸载

```bash
"$HOME/Library/Application Support/imctl/bin/imctl" agent uninstall
```

## 日志与轮转

launchd 只追加写。轮转选项：`/etc/newsyslog.d/imctl.conf`（需 sudo）或定期截断。当前不做。

## 未决

- `ProcessType` 取 `Interactive` 还是 `Standard`：先按 Interactive 跑 7 天，看 CPU（`probe watch` 基线 ≈ 0.5% 单核）。
