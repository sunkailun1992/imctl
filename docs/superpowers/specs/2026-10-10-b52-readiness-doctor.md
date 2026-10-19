# B52：就绪体检 `controller.readiness` 与 `imctl doctor`

## 背景与目标

- 2026-10-10 换到新 Mac 后，imctl 要从零安装与配置；屏幕录制未登记、通讯录角标归属 `unknown`、MQTT / 视觉 / 策略未配置等问题，都要逐条命令手查（`setup --check`、`env`、`status`、`vision status`、`oss status`、`policy list`、`probe rail`）。现有检查只看"配置在不在"，不看"功能能不能用"。
- 用户 2026-10-10 定的目标：**拿到安装包或开源仓库的任何人，能自己引导完成初始化**。整体拆三期：A 就绪体检（本批 B52）→ B 初始化向导（命令行交互式 `imctl setup` + 控制台首次启动引导，复用本批结果）→ C 源码构建引导（随开源清理再启动）。不做配置迁移。
- 本批交付：守护进程查询 `controller.readiness`（本机 socket / MQTT / MCP 都可调用），命令行 `imctl doctor` 渲染报告并在守护进程不可达时给兜底报告，控制台状态页最小体检区。体检只报告、不修复。

## 口径：能力与判定

每项能力的状态只有四种：`ok`（✔ 可用）、`fail`（✘ 必需项或已启用的可选项检查失败）、`disabled`（○ 可选模块未配置，不算失败）、`unknown`（? 依赖项不可用，无法判断）。

| id | 能力 | 必需 | 本机检查 | 联网实测 |
|---|---|---|---|---|
| `daemon` | 守护进程 | 是 | launchd 常驻、版本、暂停原因（`system` 暂停归到 `wecom` 说明） | — |
| `wecom` | 企业微信客户端 | 是 | 在运行；版本（已校准 5.0.11；其他版本只提示「未在此版本校准」，不判失败）；守护进程最近一次轮询能读到主窗与会话列表（停在通讯录页算可达，附提示） | — |
| `read` | 读取会话与历史 | 是 | 辅助功能 `trusted`，且 `daemon`、`wecom` 为 `ok` | — |
| `send` | 发送消息 | 是 | `read` 为 `ok`；白名单各类规则条数（编译内置的文件传输助手恒在）；`allowAll` 开启或策略文件读不了时状态仍为 `ok`，附提醒 | — |
| `media` | 图片判向与取回 | 是 | 屏幕录制 `granted`、访问企微数据 `granted`；不弹框确认后者需要完全磁盘访问权限，缺它时本项 `fail` 并指向添加该权限（与 `setup --check` 一致） | — |
| `contactAdd` | 按手机号加人 | 否 | 号码白名单非空即启用；每小时上限；`read` 为 `ok` | — |
| `autoAccept` | 自动接受好友申请 | 否 | 策略 `autoAccept` 非 `off` 即启用；通讯录角标能按结构归属（B49） | — |
| `vision` | 视觉兜底 | 否 | 云端开关开启即启用；配置文件可读（0600）、当前提供商密钥存在、模型已选、屏幕录制；整窗开关只作信息 | 合成图调用一次模型（沿用 B16 视觉客户端的固定提示词、固定端点与 8 秒超时） |
| `mqtt` | MQTT 对接 | 否 | `mqtt.json` 存在即启用；可解析；守护进程以 MQTT 模式运行；已连接 | QoS 1 发布到 `im/<controllerId>/readiness` 并收到 broker 确认 |
| `oss` | OSS 对象存储 | 否 | `oss.json` 存在即启用；可解析 | 1 KB 往返：写入 → 查询 → 预签名下载比对 → 下载比对 → 删除 |
| `agents` | Claude Code / Codex 接入 | 否 | 任一边已注册即启用。已注册的一边：`~/.claude.json` 用户级 `mcpServers.imctl` 或 `~/.codex/config.toml` 的 `[mcp_servers.imctl]` 命令路径指向当前应用包内的 `imctl`，技能文件与应用包内 `SKILL.md` 内容一致；未注册的一边只提示，不计失败 | 启动包内 `imctl mcp serve`，完成 `initialize` 与 `tools/list`（须含 `controller.readiness`）后关闭 |
| `wecomApi` | 企微官方 API 代理 | 否 | `wecom-proxy.json` 存在即启用；可解析 | `GET <baseURL>/healthz`（不带令牌；结果不含 corpId） |

- 必需项与现在 `setup --check` 的必需口径一致，另加企微可读性。
- `unknown` 只在某项能力依赖的能力或权限不为 `ok` 时出现（例如企业微信未运行时，`read` 及其下游为 `unknown`；未授辅助功能时 `wecom` 的可读性为 `unknown`，由 `read` 报 `fail`）。
- **就绪** = 全部必需项 `ok`，且每个已启用的可选项 `ok`。`unknown` 不单独计失败，因为按上一条它的上游一定已有 `fail`。
- 每个 `fail` 附修复指引：一条可直接复制的命令，或系统设置路径；没有简单修法的（如角标布局不识别）写清原因与查看命令（`imctl probe rail`）。`disabled` 的能力附「怎么启用」。修复命令以 `imctl ` 开头，渲染方在 `imctl` 不在 PATH 时换成应用包内的完整路径。
- **下一步**：按上表顺序取第一个 `fail` 的修复指引。

## 接口与执行

### 查询 `controller.readiness`

- **分发器层面的查询**（与 `event.replay`、`message.media` 一样）：不进命令记录、不产生 `command.state` 事件，也不进入执行器的串行队列。只读：不导航、不点击、不按键、不弹框、不改任何配置、不重启任何进程。
- 本机检查只用守护进程已有的状态：授权读回（`permissions(prompt:false, probe:false)`）、watcher 最近一次轮询、暂停原因、策略、各配置文件、MQTT 连接状态、两边智能体的注册文件。不读 AX 树，调用应在约 1 秒内返回（完全磁盘访问权限在时，访问企微数据的探测最多 4 秒）。
- 参数：`online`（布尔，默认 `true`，做联网实测）、`refresh`（布尔，默认 `false`，忽略缓存重测）。
- 联网实测在守护进程自己的后台队列执行，同一时间最多一轮。需要时由本次请求触发，本次返回 `online.state: running`，能力状态先按本机检查判定；调用方轮询，直到 `done`。完成的结果在内存保留 300 秒；`refresh` 受全局最短 60 秒间隔约束，不区分请求来自本机 socket、MQTT 还是 MCP，间隔内直接返回上次结果。守护进程重启后结果清空。本机检查每次都重新读。
- 一轮的总期限 40 秒；各探测的超时：视觉沿用客户端固定 8 秒、MQTT 10 秒、OSS 每个请求 15 秒、MCP 握手 10 秒、代理健康检查 10 秒。到期未完成记 `fail`，类别 `timeout`。
- `online: false` 时不触发实测，相应检查项标 `tested: false`；能力状态只按本机检查判定，命令行渲染为「✔（未实测）」。
- 结果字段：`ready`、`nextStep`、`nextStepCapability`、`capabilities[]`（`id`、`title`、`required`、`status`、`checks[]`、`fix`、`warnings`）、`online{state: skipped|running|done, testedMs, nextRefreshAllowedMs}`、`version`、`generatedMs`。检查项只给状态、计数、错误类别（如 `timeout`、`network`、`auth`、`http4xx`、`http5xx`、`response`、`mismatch`、`cleanup`）与耗时。
- 暴露：本机 socket、MQTT、MCP 都经分发器可用；MCP `tools/list` 由 44 项变为 45 项，`RPCMethod` 数量不变。同一提交更新 `docs/protocol/im-control-protocol.md`，`ProtocolDocTests` 覆盖。

### 命令行 `imctl doctor`

- 用法：`imctl doctor [--json] [--offline] [--refresh] [--wait <秒>] [--socket <path>]`。经 socket 调 `controller.readiness`；`state` 为 `running` 时每秒轮询一次，最多 `--wait` 秒（默认 45）。`--json` 输出最后一次结果，`--offline` 即 `online: false`，`--refresh` 即 `refresh: true`。
- 报告为中文：第一行「就绪 / 未就绪」与「下一步」；随后按能力列出 ✔ ✘ ○ ?；每个 ✘ 下面是修复说明与命令。
- 守护进程不可达，或守护进程版本早于 B52（答「method not found」）时给兜底报告：应用包是否存在、LaunchAgent 文件是否存在与是否已加载、`imctld` 是否在运行、企业微信是否在运行及其版本；下一步指向 `imctl setup`（版本过旧时指向重新安装）。
- 退出码：`0` 就绪；`2` 未就绪；`3` 守护进程不可达或版本过旧。
- `imctl setup --check` 保持不变（安装脚本依赖其六项输出与退出码）；`imctl setup` 结束时多打印一行，提示运行 `imctl doctor` 查看完整体检。

## 安全与隐私

- **不碰企微界面**：企微的可读性只用 watcher 最近一次轮询的结果；不触发 B15 判向截图或 B17 整窗上传。
- **视觉实测只发合成图**（用户 2026-10-10 决定的新出网路径）：图片在内存中用位图绘制（固定的两个灰色方块，不含文字），不调用任何截屏接口，不含本机或企微内容；只在云端视觉已开启且当前提供商有密钥时发送；沿用 B16 视觉客户端的固定提示词、固定官方端点、拒绝重定向与 8 秒超时。模型回答不进结果、日志或事件，只保留错误类别与耗时。该客户端本就不计入 `visionCaptureCount`、`visionRequestCount`、`visionHTTP200Count`（这三项保留给门报告核对显式命令），结果里以 `tested` 说明本次是否真的调用了模型。
- **MQTT 实测**：QoS 1 发布到 `im/<controllerId>/readiness`，载荷只有一个随机数。该主题在 `docs/ops/emqx-auth-acl.md` 的 `im/${username}/#` 范围内，Java 消费方不订阅。broker 回的拒绝原因码记为 `rejected`。结果不含 broker 地址、用户名。
- **OSS 实测**：对象名为 `<baseDir>/imctl-readiness/<随机>`，内容为 1 KB 固定字节；中途失败也尝试删除，删除失败记 `cleanup`。结果不含桶名、对象名与密钥。
- **MCP 握手与注册检查**：只启动应用包内自带的 `imctl mcp serve`，只发 `initialize` 与 `tools/list`（两者由该进程本地回答，不回调守护进程，不会和正在处理的体检请求互等）；读取 `~/.claude.json`、`~/.codex/config.toml` 时只取 `imctl` 条目的命令路径，不读取、不输出其他条目（这两个文件含其他凭据）。
- **代理健康检查**：`GET <baseURL>/healthz` 不带令牌；响应只判断 HTTP 200 与 `status: ok`，不返回其中的 corpId；发生重定向即记失败。
- **输出与日志脱敏**：结果、日志、事件中不出现密钥、手机号、会话名、群名、broker 地址、桶名、corpId；外部错误的原文只用于归类，不进结果。守卫测试用含这些值的配置执行体检并断言全部缺席。
- **后台不调用**：watcher、自动接受、媒体判向等后台路径不调用体检；控制台的定时刷新也不调用。只有显式 `controller.readiness` 请求才做联网实测。
- 需同步更新：`AGENTS.md` 项目边界的权限面条目、`docs/ai-coding/SECURITY_CODING_SPEC.md`（B16 路径的触发条件），并在 Wiki 记录用户决定。

## 控制台

- 状态页新增「体检」区：「运行体检」按钮、「只做本机检查」开关、「重新实测」按钮（传 `refresh: true`，受 60 秒间隔约束）。经现有 socket 客户端调 `controller.readiness`，`running` 时每秒轮询，最多 45 秒。
- 打开页面不自动执行。上次结果只保存在内存，显示测试时间；每个 ✘ 显示修复命令并可一键复制（复制按钮放在已允许使用剪贴板的 `ResultPane.swift` 里复用）。
- 首次启动引导与"边问边配"属于 B 期，本批不做。

## 测试与验收

- 单测（swift-testing，各检查经测试缝注入替身）：
  - 每项能力的 `ok` / `fail` / `disabled` / `unknown` 判定与修复指引；就绪规则与「下一步」排序；企业微信停在通讯录页为 `ok` 带提示；缺完全磁盘访问权限时 `media` 为 `fail`。
  - 缓存 300 秒、`refresh` 最短 60 秒（注入时钟）；两个调用方同时请求只起一轮；永不返回的探测在期限到时记 `timeout`，之后还能起下一轮；`online: false` 时不发起任何网络请求。
  - 实测在跑时，体检请求仍在约 1 秒内返回。
  - 合成图生成确定且不调用截屏接口；`ForbiddenAPITests` 不放宽。
  - 不泄密守卫：含密钥、号码、会话名、broker 地址、桶名的配置与外部错误原文跑完，结果中全部缺席。
  - 命令行：中文报告与 JSON 固定样本、兜底报告、旧版守护进程、三种退出码、PATH 缺失时的完整路径。
  - MCP 工具列表含新方法；协议文档守卫通过。
- 变异验证：在临时副本中逐条删去关键保证（缓存与最短间隔、只用合成图、脱敏、后台不调用、只读不写、`online: false` 不联网、兜底报告），每处都须有测试变红。
- 独立审查至少一轮，直到无严重与重要问题。
- 活体验收（本机，写门报告 `docs/gates/<日期>-b52-readiness-doctor.md`）：
  1. 按现状执行：必需项全部 `ok`，`agents` 为 `ok`，其余可选项 `disabled`，结论就绪。
  2. 用户配置千问密钥（以及 MQTT，如提供 broker）后再执行：相应联网实测为 `ok`，并核对缓存与 `refresh` 间隔。
  3. 故障演练：退出企业微信后执行，`wecom` 为 `fail` 并给出修复指引、下游为 `unknown`；停止守护进程后执行，得到兜底报告与退出码 3。

## 前提与范围

- 前提：本机原无代码签名身份。用户已于 2026-10-10 在 Xcode 新建 Apple Development 证书（与旧证书不同团队），构建时用 `IMCTL_SIGN_TEAM` / `IMCTL_SIGN_TEAM_ID` 选中它；新签名的第一个版本装上后，辅助功能、屏幕录制、完全磁盘访问权限要重新授权一次。
- 版本：`IMCTLVersion` 改为 1.0.15-dev，门关闭时按规则定为 1.0.15。原定的「独立验证窗口邀请提示」顺延为 B53。
- 不在本批：初始化向导（B 期）、源码构建引导与开源清理（C 期）、配置迁移（用户已否决）、Developer ID 签名与公证（用户另定）、本机通讯录角标布局适配（另开批次）。

## 计划阶段核实后的修正（2026-10-11）

写实施计划时读代码，发现 2026-10-10 版本的规格有几处与代码不符，已按下述修正：

- 代码里没有企业微信版本闸门，`docs/ops/installer.md` 与第二台 Mac 说明里「其它版本守护进程自动只读」不成立：版本改为只提示，并在本批更正这两份文档。代码里也没有行高校准值，去掉行高检查。
- 执行器、本机 socket 与 MQTT 命令都是串行处理：同步跑最长 35 秒的实测会挡住其他所有命令，轮询又会让每次调用都写一条命令记录并经 MQTT 推三条事件。因此改为分发器层面的查询加后台实测与轮询，去掉 `cached` 字段，改用 `online.state` 与 `testedMs`。
- 企业微信停在通讯录页时 `controller.diagnose` 整体失败；改为用 watcher 最近一次轮询判断可读性，不再另读 AX 树。
- 不弹框确认「访问企微数据」只能靠完全磁盘访问权限，所以 `media` 实际要求它，与 `setup --check` 一致。
- 视觉客户端只接受 JPEG、提示词与 8 秒超时写死在代码里：视觉实测改为复用 B16 客户端，不新增提示词与端点。
- 控制台的剪贴板 API 只允许出现在三个文件里：复制按钮放进 `ResultPane.swift` 复用。

## 用户决定（2026-10-10）

- 受众：拿到安装包或开源仓库的任何人能自己引导完成初始化；按 A → B → C 拆分，先做 A。
- 不做配置迁移；报告与向导都要（向导在 B 期）。
- 检查深度：只读体检加连通自检，默认全部实测，含一次合成图模型调用。
- 方案：守护进程提供 `controller.readiness`，命令行与控制台都调用它。
- 能力清单与判定、接口与执行、安全与隐私、控制台测试与验收四节逐节确认。

## 追加：controller id 默认取本机名（用户 2026-10-12 决定）

活体验收时，用户在控制台配置 MQTT，「保存」要等手填 controller id 才能点。用户提出这一项应有默认值，并决定在本批一起改。

- **默认值**：本机的「本地主机名」（`LocalHostName`，经 `SCDynamicStoreCopyLocalHostName` 读取，不查网络）转小写；`[a-z0-9._-]` 以外的字符换成 `-`，连续的 `-` 合成一个，去掉首尾的 `-`，最长 64 个字符；结果为空就没有默认值，仍要手填。不用「电脑名称」（`ComputerName`，常含中文与空格）。
- **取值顺序**：显式填写 → 已有 `mqtt.json` 里的 id → 本机名默认值。重新登记、只改 broker 时不会悄悄换掉 id；否则 Java 端按原 id 发的命令就没人收了。
- **只在第一次登记时预填**：写进 `mqtt.json` 后固定，以后改电脑名不影响。换一台 Mac 时默认值会变：Java 端如果按旧机的 id 发命令，旧机又已停用，就在登记时显式填旧 id。
- **校验**：controller id 是 topic 的一段，也是 `clientId` 的一部分。`imctl enroll` 与控制台保存时只接受 1–64 个 `[A-Za-z0-9._-]` 字符，含 `/`、`+`、`#`、空格等一律拒绝并说明原因。读取已有的 `mqtt.json` 时不校验，旧配置照常工作。
- **EMQX 认证不变**：开了每机认证时，MQTT 用户名仍等于 controller id（`docs/ops/emqx-auth-acl.md`）。
- **控制台说明**：设置页原说明是「保存后到"状态"页重启守护进程」。但首次配置 MQTT 时，常驻是不带 `--mqtt` 装的，重启不会打开 MQTT 模式（活体发现）。改为：首次配置 MQTT 后到「状态」›「守护进程维护」点「安装 / 更新」，以后改设置再点「重启」。
- **体检**：MQTT 未配置时，修复命令改为 `imctl enroll --broker <主机[:端口]>`，文字注明 id 默认取本机名。
- **文档**：README、协议 §2.1、`docs/ops/emqx-auth-acl.md`、`docs/ops/portability.md`（换 Mac 时默认 id 会变）同步修改。
- **验收**：
  - 单测覆盖取值顺序、清洗、校验、表单预填与保存校验、修复命令，每项保证各做一处变异；
  - 活体：新版本装好后，控制台 MQTT 表单显示由本机名得到的 id，用户只填 broker 就能保存；按 MQTT 模式重装后，体检实测 MQTT 发布。门报告不写具体主机名。
