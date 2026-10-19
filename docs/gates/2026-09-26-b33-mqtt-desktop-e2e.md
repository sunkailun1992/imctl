# B33：MQTT → 企微桌面命令活体端到端验收（2026-09-26 CST）— 部分通过

## 条件与改动

- 本机 macOS 27.0、企微 5.0.11；四条实际发送在稳定 Apple Development 签名的 `~/Applications/imctl.app` 1.0.13 **debug build 184** 上执行，LaunchAgent 从该包内启动。之后从同一源代码构建 **release build 185** 安装包并安装，最终安装版只做授权与 MQTT 只读复查，未再发送。`setup --check` 六项均通过（辅助功能、屏幕录制、企微数据、完全磁盘访问、客户端、LaunchAgent）。传输为本机守护进程连接用户 LAN 的 EMQX，测试命令由 `imctl mqtt call` 发起；不记录 broker、凭据、签名地址或截图。
- 用户授权向自己的「文件传输助手」各发 1 条纯文本、合成 PNG、合成 MP4、合成 PDF，每条只提交一次；另授权只在已有自有对象上测试群名恢复、加成员 / 建群条件满足时的操作。
- 首次 PNG 尝试在**回车和 checkpoint 前**因企微返回单个 U+FFFC 原生附件对象而被旧守卫拒绝（`LOCAL_GUARD`）；`message.history` 无新行，原幂等键回放同一失败记录，未发出图片。人工核对只有一个原生附件对象后清空未发送的暂存项。修复后以新键进行唯一一次实际提交。
- `SendFile.swift` 接受严格的单个 U+FFFC、字符数 1、唯一 `AXUnknown` 子元素形态；旧版空 AXValue 形态也限制为一个对象，粘贴前已有对象拒绝。回车后无新外发证据一律 `unknown` 且保留输入框，避免覆盖人工编辑。协议线格式、策略、按键、视觉权限均未变化。

## 门禁与安装

| 项目 | 结果 |
|---|---|
| 构建与测试 | `swift build -q` 通过；最终 `swift test -q` **771/771** 通过，含原生附件、多个附件拒绝、旧暂存附件拒绝及提交后草稿保留；`git diff --check` 通过。 |
| 敏感扫描 | `bash scripts/check-secrets.sh` 退出 0；11 个既有示例 / 旧文档命中，本批无新增凭据命中。 |
| 安装与授权 | `scripts/build-app.sh debug` 签名、`codesign --verify --deep --strict` 通过；新包复制到唯一安装位，旧包移入废纸篓；LaunchAgent kickstart 后 `setup --check` 六项通过。首次立刻检查时 socket 尚未创建，约 1 秒后守护进程运行并通过复查。 |
| 最终桌面包 | `scripts/build-pkg.sh release` 得 `out/imctl-1.0.13.pkg`，app build 185；pkg SHA-256 `cb91d5d673d1b55e84c0d1804dbec81d9e2b6c676ccd8d32e2f08f4146016b4a`。`pkgutil --payload-files` 含三执行文件、协议文档和 agent skill；app 严格签名校验通过，pkg 本身未签名 / 未公证。随包第二台 Mac 四件套 ZIP SHA-256 `a06381d007eccdbcb54650f440978e975319f746c41c088f7e7744d283cc2c58`，CRC / 内含 pkg 哈希一致。 |
| 最终本机安装 | `installer -target CurrentUserHomeDirectory` 成功；`~/Applications/imctl.app` Info.plist build 185，安装版 `imctld` 与构建版 SHA-256 一致；重启 LaunchAgent 后六项授权仍通过，安装版 MQTT `controller.describe` 成功。第二台 Mac 尚未安装。 |

## MQTT 活体与客户端证据

| 步骤 | 终态与后验 |
|---|---|
| `account.status`、`conversation.list`、`conversation.read`、`message.history` | 安装版 MQTT 全部成功；会话列表 19 条，文件传输助手读回 23 条，最新历史 23 条。历史回滚 60 条在此前同批安装前活体可用；文件传输助手消息方向为本人外发。 |
| `contact.list`、`contact.request.list` | 安装版 MQTT 成功，分别返回 5 联系人、2 条申请记录；未接受申请。 |
| `client.navigate` | 安装版 `nextConversation` / `previousConversation` 都改变活动会话（约 0.76 / 0.55 秒），各自同键回放同一命令；最后显式恢复文件传输助手。 |
| `message.send` | 仅 1 条文本 `imctl-b33-e2e-text-20260926-de591e81`；`succeeded`，历史新增且仅新增 1 条本人外发文本；同键回放同命令 ID；事件 52635–52637 accepted→running→succeeded，52645 `message.observed{origin:controller}`。 |
| `message.sendFile` PNG | 仅 1 次实际回车；`succeeded`，新 `media/outbound` 行，**本次可见历史页** 20→21；同键回放同命令 ID，事件 53016–53018 终态，53023 `message.observed{kind:media,origin:controller}`。 |
| `message.sendFile` MP4 | 仅 1 次实际回车；`succeeded`，新 `video/outbound` 行且时长 `00:01`，本次可见页 21→22；同键回放同命令 ID，事件 53028–53031 终态，53036 `message.observed{kind:video,origin:controller}`。 |
| `message.sendFile` PDF | 仅 1 次实际回车；`succeeded`，新 `file/outbound` 行，文件名与提交名一致、`fileType:pdf`，本次可见页 22→23；同键回放同命令 ID，事件 53043–53045 终态，53049 `message.observed{kind:file,origin:controller}`。 |
| `message.media` 对上述 3 行 | MQTT 查询分别返回 `image`、`video`、`file`；图片缓存副本为 JPEG，视频封面为 JPEG 且 `body:uploaded`，PDF 为 `application/pdf`；各有签名地址但未在报告保存。类型与附件 URL 可区分；缓存副本不证明与提交原件逐字节相同。 |
| `group.rename` | 仅对 `imctl测试群` 改为验收临时名一次、改回一次；两个 MQTT 命令均 `succeeded`，活动标题读回原名，事件均 accepted→running→succeeded。 |
| `group.addMembers` | 对已在该测试群的自有测试成员做 `dryRun`：`succeeded`、`added=0`、`skipped=alreadyMember`；没有按最终确定，也没有邀请事件。 |
| `command.get`、`event.replay` | 四条发送和两次改名的原始记录均 `succeeded`；新增三种附件的终态事件及 `message.observed` 与客户端新行对得上。合成附件的临时 OSS 源对象在验收后已删除。 |

本批发送总数 **4 条**（文本、PNG、MP4、PDF 各 1），目标只有自己的文件传输助手；群名操作 2 次并恢复原名；未添加成员、未创建群、未接受申请、未加联系人、未群发。

历史数字是每次读取时的**可见页计数**，并非会话全量累计：文本验收后客户端窗口与守护进程重启使下一次 PNG 的读取基线仍为 20 行。每条发送都以当次基线的新 `messageKey` 和本人的方向单独核对。

## AI 与未闭环范围

本批上述确定性 AX 路径没有制造歧义候选；按执行路径，本批 B17 企微整窗截图 **0 帧**、云端模型请求 **0 次**、模型轮次 **0 轮**，因此**没有取得真实企微整窗 → 千问模型 → 多轮候选 → 客户端后验**的活体证据。这些 0 是本机路径判断，不是提供商账单的独立核对。模型配置与屏幕录制授权就绪不能替代该证据。当前实现是固定 MQTT 方法的 AX 主流程与歧义视觉后备，并非所有命令都有 Codex 式通用规划。Gemini 在此前本机合成请求曾受地区限制，本批未重测。

`group.addMembers` 的真实新增缺未入群的自有测试成员；`group.create` 缺可核对身份的第二自有测试联系人；`contact.add` 缺自有测试手机号；`contact.request.accept` 当前无明确自有待处理申请；`message.broadcast` 需要四条之外的额外发送授权；`broadcast.confirm` 缺真实代理 `msgid` 与助手面板样本。这些方法有 fake 门禁或旧批次活体，但**本批不能记为端到端通过**。用户回复精确测试对象 / 额外条数后再单独验收。第二台 Mac 安装与云端视觉真实歧义分支也未验。

回滚：上一版 1.0.13 build 183 的安装包可恢复应用；保留本机命令 / checkpoint 数据，同键对账，不对已提交的附件换键重发。
