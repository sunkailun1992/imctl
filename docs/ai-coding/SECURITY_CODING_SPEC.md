# 安全编码规范

本文件只维护 `imctl` 的安全规则。AI 新增或修改动作、策略、执行器、观察、传输、守护进程、CLI 写命令、脚本、夹具、文档和（规划中的）代理 / 消费方代码时，必须先阅读本文件。

## 合成输入与权限面

- 不发全局合成键鼠事件；全部走 AX 属性 / 动作（`AXSelectedRows`、`AXValue`、`AXPress`、`AXScrollBar.AXValue`）。
- 例外只有对企微进程投递的按键（`CGEventPostToPid`），只允许在 `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`。已批准的按键就这些：回车（submit，用户 2026-09-12；选人面板搜索框上的那次，2026-09-15 16:3x）、⌘1–⌘8 / ⌃Tab / ⇧⌃Tab / ⌘N（B7 通讯录导航与发起群聊，用户 2026-09-15）、⌘V（B13 `message.sendFile` 粘贴 outbox 文件 URL，用户 2026-09-22 17:43）。该文件不得含全局 tap、鼠标、PSN 投递或清单之外的按键；再加一个按键要先有用户决定，并在仓库规格及 PR 记录脱敏的授权依据，维护者可另行同步私人 wiki。`ForbiddenAPITests` 会扫描 `Sources/` 并拦截，同时校对该枚举声明的按键集合。
- 权限面限于辅助功能与屏幕录制。B15 已批准并实现：AX 无法判定方向的可见媒体行在本机内存里以企微窗口单帧判断左右，不保存、不上传，证据不足保留 `unknown`。B16 用户 2026-09-24 允许显式添加群成员在 AX 无法可靠定位控件时上传相关控件裁图；该批的真实路径仍优先使用 AX 名称。B17 用户另行批准：**显式固定桌面协议命令**可把当前经核验的企微窗口单帧上传到所选云模型，用于有界多轮规划、AX 候选定位和动作后复核；窗口可能含聊天正文、头像、其他会话预览与个人信息。上传前须确认是企微 PID / 窗口且命令仍在运行，截图只为当前命令生成，禁止后台 watcher、自动轮询和 B15 媒体方向路径上传。守护进程只在显式 `controller.permissions{prompt:true}` 时请求系统授权；`WeComCommandHandler+Permissions.swift` 与 `WeComScreenCapture.swift` 是唯一可使用屏幕录制 API 的文件，`ForbiddenAPITests` 校对。输入监控（`CGRequestListenEventAccess`）及其它 TCC 类别仍禁止。
- 辅助功能授权按进程：终端进程的 trusted 是继承的，launchd 下的 `imctld` 需要用户单独勾选；代码只可请求系统提示（`--prompt-accessibility` / `IMCTL_LAUNCHD=1`），不得尝试绕过。
- 签名 identifier `com.sunkailun.imctl` 保持稳定，否则 TCC 授权丢失；`swift test` 后 `.build/` 二进制变 ad-hoc，常驻只运行稳定副本。

## 目标白名单与策略

- 编译白名单只有 `WeComClient.fileTransferAssistantTitle`；不在代码里硬编码其它目标。
- 放宽只经 `~/Library/Application Support/imctl/policy.json`（`SendPolicy`，0600，`imctl policy allow|deny`），规则只能放宽（标题 / 类型 / `chat_id` / `external_userid`）；`unknown` 类型永远不能被**类型规则**放行；坏文件不视为放行。`allowAll` 是用户明确开启的唯一例外（B14，2026-09-22「全部放开」）：开启后对任何已解析目标放行，含类型 `unknown`；只经本机 `imctl policy all --enable|--disable` 或控制台开关（二次确认），`policy.set` 永远不接受；开启状态有日志（`policy reloaded … allowAll=true`、`controller.describe.policy`）。
- 所有改变客户端状态的原语先 `ActionPolicy.authorize`，且在任何 AX set / action 之前；阶段 0 禁止 `submit`。
- 目标复核：`TARGET_NOT_FOUND`（0 个）/ `TARGET_AMBIGUOUS`（多个）/ `TARGET_MISMATCH`（打开后不符）都不发；标题不是身份，生产只用平台 ID 经身份桥。
- 开发期只对用户自己的测试群（只有本人）与本人微信测试号发消息；任何真实客户 / 客户群等用户明确放开策略，公开报告仅记录脱敏的授权范围，维护者可另行同步私人 wiki。

## 不可逆点与幂等

- `message.send` 必带 `idempotencyKey`；数据库 UNIQUE 判重；同键回放既有结果，不重发。
- submit 前落盘 checkpoint（含目标与文本）；`afterSubmit` 是崩溃注入点；重启后 `running + checkpoint` 一律 `unknown`，绝不重跑；`unknown` 对控制器是终态。
- 输入框非空 = 人正在打字 → `LOCAL_GUARD`，中止；失败清空输入框，`unknown` 保留供人查看。
- 速率硬上限在执行器：每目标 ≥ 3 s、全局 ≤ 20 条/分钟，按尝试计数；Java 策略只能更严。
- 暂停 reason set `{api, local_guard, system}`：Java 只能增删 `api`；`system` 由守护进程按客户端可达性置位；暂停时发送失败 `PAUSED`，读取继续。

## secret 与运行数据

- broker 地址、MQTT 凭据、视觉 API 密钥、企微 corpid / secret / agentid / 回调 Token / EncodingAESKey、代理 Bearer token、Developer ID 证书不得进入代码、测试、夹具、文档、提交信息、wiki。
- `mqtt.json`、`policy.json` 0600；`run/`、`bin/` 目录 0700；socket 父目录必须 0700 否则拒绝绑定。
- B16 三家视觉密钥分别存于本机受限存储，替换 / 删除只经本机设置或从标准输入读取，不放命令行参数、环境输出、日志、SQLite、MQTT、MCP 返回或随包文件。一次性导入已有本机千问密钥时只在本机进程内转移，先核对其地域与官方端点，不打印来源内容；运行期不依赖原应用的密钥文件。密钥配置保存须是 0700 父目录和 0600 文件（或等价的系统凭据存储），状态只报是否存在；提供商切换不复用另一家的密钥。
- 代理参数只进代理主机的环境变量；`application.yml` 只放 `${PLACEHOLDER}`。
- 发现仓库或历史中已有疑似敏感内容，只报告文件与行号（`bash scripts/check-secrets.sh` 为 warning-only），不自动替换或改写历史。
- 本地日志、checkpoint、SQLite 含消息正文：依赖 FileVault，保留期与脱敏策略是运维事项；不复制到仓库 / wiki。

## 日志、探针与文档脱敏

- 探针输出默认脱敏（`AXRedactionPolicy`：保留 `文件传输助手`、UI 文案、时间标签，其余 `«hash»`）；`--no-redact` 只用于本机排障，输出不得进入仓库或 wiki。
- `dump-tree --raw` 输出必须 `.raw.json`（gitignore）；提交的夹具必须脱敏并说明来源。
- 守护进程日志不打印消息正文；事件载荷含正文只进本地 SQLite 与 MQTT（LAN / 用户的 broker）。
- B16/B17 截图与裁图、Base64 请求体、API 请求 / 响应正文、完整请求头和原始错误对象不进日志、探针、门报告、wiki 或协议；日志至多记录提供商、模型的非秘密标识、协议方法、轮次、动作种类、结果码与耗时。配置对象的字符串 / 调试描述不得回显密钥。不得为“完整”报告而保存逐轮截图、AX 全树、模型原文或模型推断的聊天内容。
- 门报告写发送条数与测试文本（如 `imctl-b3-origin-1`），不写真实联系人内容。

## 传输安全

- MQTT 5：每台 Mac 独立凭据与 topic ACL（`im/{id}/cmd|rsp|evt|state`，见 `docs/ops/emqx-auth-acl.md`，配置由用户在 EMQX 完成）；控制器只在自己的子树内发布；Response Topic 不在 `im/<id>/` 子树内改用 `…/rsp`。
- 事件泵按 `event_id` 顺序发布并持久化游标；`event.replay` 是查询，不建命令、不发 `command.state`；限 `limit ≤ 1000`。
- 命令载荷是不可信输入：JSON 解析失败 `-32700`，未知方法 `-32601`，参数错误 `INVALID_PARAMS`；不因载荷内容执行任何非协议动作。
- Unix socket 只在 0700 目录；stdio 模式只给本机智能体 / 测试驱动，生产默认关闭或只读。
- 不在 `MQTTSettings` 之外持凭据；`imctl mqtt call` 只读本地设置文件。

## 代理与回调（`wecom-token-proxy`，规划）

- 代理持 corp secret 与 access_token 缓存；imctl 只带 `Authorization: Bearer <proxy-token>`；路径白名单只放本设计用到的企微接口；限流；审计日志不含正文。
- 回调：GET 验签回显 `echostr`；POST 验签 + AES 解密后转 MQTT `wecom/{corpId}/evt`（QoS 1，`eventId` 单调持久）；验签失败 4xx，不处理；5 s 内应答 `success`。
- 回调正文、企微响应都是不可信输入：校验格式、长度、允许值；不把模型输出或外部文本拼进 URL、topic、SQL。
- 代理 URL、broker 地址、回调地址不由业务输入控制（防 SSRF / 开放重定向）。

## B16 云端视觉定位

- 默认提供商为千问；可在本机改为 Gemini 或 DeepSeek。提供商 / 模型须从支持图像输入的显式名单选择；官方 HTTPS 端点由代码按提供商与地域构造，不能从 MQTT 命令、模型返回或任意配置中接收完整 URL。仅 443 端口、固定路径，不接受 URL 用户信息、查询、片段、自定义域名、IP 字面量或重定向。只用请求内联 Base64 图片，不用公网图片 URL、Files API 或跨提供商自动重试。
- B16 的云端开关独立于 macOS 屏幕录制 TCC；只在本机配置 / 启用，禁用、无密钥、未授权、离线或超时均不上传。B16 路径只由 `group.addMembers` 显式动作触发（例外：B52 显式 `controller.readiness` 用程序绘制的合成图走同一请求形状做连通实测，不截屏、不含本机或企微内容，用户 2026-10-10 决定）；来自 MQTT 的显式操作也必须先经过现有策略授权，拒绝时不截图、不上传。B17 对其它固定桌面协议命令的扩展另受下一节约束。
- AX 能确定唯一控件时直接走 AX。AX 无法定位时，只截已校验 PID 与 AX 窗口的单帧，只取所请求动作的控件带和必要的局部上下文；必须遮去聊天正文、头像和无关区域。无法证明裁图不含这些信息时停止，不退化为整窗上传。裁图在内存中编码，限制像素、字节、单次请求与超时；不落盘、不进入事件或协议。第三方会收到这块裁图，应用无法保证提供商不保留数据，控制台和运维说明须如实告知。
- 截图里的文字和模型响应均不可信。请求使用固定任务说明，不给模型工具调用；响应只接受预先列出的候选 AX 元素 ID，不执行模型提出的 URL、坐标点击、按键、发送文本、策略或后续步骤。返回候选必须唯一，复核当前企微 PID、窗口、会话、候选 AX 角色 / 动作 / 几何与快照一致，并由 `ActionPolicy`、`CommandExecutor`、checkpoint / 幂等机制继续执行。不能映射到可操作 AX 元素、元素变化、响应含糊或 AX 动作无结果证据时失败关闭；不加入合成鼠标。
- 云端视觉只协助显式动作定位，不判断该不该回复、回复内容或消息方向；B15 方向仍在本机内存判断。一次失败不向第二家转发同一裁图，不在后台自动重试；已发生不可逆动作而证据不足时沿用 `unknown`，绝不重发。

## B17 固定桌面命令的有界 AI 执行

- 协议方法和调用方参数保持固定。模型只在命令处理器内部选择预定义的下一观察或 AX 候选，不生成新 RPC、目标、收件人、成员、手机号、正文、附件来源、策略变更或幂等键。每个方法有单独的允许动作集合与终止条件；没有对应执行器分支的方法不得被通用代理接管。`message.broadcast` 只能通过各子命令原有的策略与幂等路径执行，API / 管理 / 后台 watcher 不因本批接入截图。
- B17 整窗视觉当前只支持千问与 Gemini，默认千问；DeepSeek 的配置和密钥替换入口保留，但不支持整窗规划，选中时不能发送整窗。B17 全窗上传须同时通过屏幕录制 TCC、B16 云端总开关 `cloudEnabled`、本机整窗许可 `fullWindowEnabled`；旧设置文件缺少 `fullWindowEnabled` 按 false 处理。`imctl vision full-window --enable|--disable` 只在本机更改整窗许可，控制台设置和状态页显示它；仅开启 `cloudEnabled` 仍只覆盖原有 B16 受限裁图。启用整窗许可后，显式固定**读取**命令也可能向第三方发送整个企微窗口，不再沿用 B16“普通读取不上传”的限制；控制台、安装和协议说明必须标明这项数据传输。调用方不能通过 MQTT 指定密钥、端点或强行开启云端。禁用 / 无密钥 / 无授权时沿现有可验证 AX 路径执行或明确失败，不声称模型参与。
- 每一轮：先做当前命令应有的暂停 / 目标 / 策略检查；复核企微进程、单个窗口的 PID / frame / 会话 / 前台状态；仅截该窗口单帧，在内存中内联给固定官方 HTTPS 端点；由模型从本轮生成的 AX 候选 ID 与方法允许的动作中选一个；行动前再次验证 AX 角色、动作、frame、窗口与目标；行动后从新 AX 状态观察。任一处变化或歧义都停止，不把模型输出中的文字当企微操作指令，也不执行任意坐标、全局点击、扩展按键或未列入候选的 AX 元素。模型只给决策建议，事实由客户端观察与既有解析器证明。
- 控制每命令轮次、单次请求/整命令时间、截图字节与像素、并发和调用频率。每轮图像、模型输出与 AX 候选仅保存在本进程当前调用内；不落盘、不进 SQLite、MQTT、MCP、日志或 wiki。远端收到全窗单帧，imctl 不保证远端零留存。超时、无候选、响应无效、API 错误与证据不足时停止；不跨提供商重试，也不因为 MQTT 响应超时换幂等键。
- 任何不可逆动作仍在 `CommandExecutor` 与 `ActionPolicy` 后、checkpoint 后执行，速率与本机白名单照旧。模型不能自行二次发送或在 `unknown` 后重跑；按下确认 / 回车后若没有可靠证据，保留 `unknown`，业务侧通过事件、命令记录和历史对账。`succeeded` 只说明协议指定的客户端证据已出现，不能由模型文字、HTTP 200 或“看起来成功”代替。

## 输入信任

- AX 文本（标题、正文、发送者、标记）、会话表几何都是客户端给的：只用于解析与复核，不拼进命令、路径或 topic；同名会话按 `TARGET_AMBIGUOUS` 拒绝。
- 会话类型推断只在有证据时给出；没有证据 `unknown`；标记词与 `@` 规则需活体校准，校准前不放开类型规则。
- `policy.json`、`mqtt.json`、夹具 JSON 解析失败一律失败关闭（不放行、不连接、测试失败），不回退到宽松默认。

## AI 边界

- 回复内容与是否回复仍由 Java / 调用方决定。B16 是添加群成员的单按钮候选；B17 扩到显式固定桌面命令的有界多轮执行，可用于这些命令明确请求的读取，但不得进入后台每条消息的观察路径。模型不能成为命令源、目标白名单、策略或发送内容的依据。
- 方向 `unknown`、来源 `unknown`、类型 `unknown` 的消息不驱动自动回复；`origin: other` 是接管信号，按会话静默由 Java 决定。
- 模型提出的适配器 / 策略变更必须走规格、测试与人的决定；生产 Mac 上不做自主"自修复"。

## 测试要求

- 策略测试覆盖：默认拒绝、启用后仍需允许、阶段 0 禁 submit、类型 `unknown` 不放行、`policy.json` 只放宽。
- 执行器测试覆盖：无键拒绝、同键不重跑、过期、暂停、速率、崩溃后 `unknown` 且不重跑。
- 处理器 / 动作测试覆盖：策略拒绝前无 AX set / action；目标缺失 / 同名 / 不符；人留草稿；证据匹配。
- 传输测试覆盖：Response Topic 守卫、事件顺序与游标、`event.replay` 不建命令、JSON `0/1`。
- 守卫测试：`ForbiddenAPITests` 扫描 `Sources/`。
- B16 追加 fake 测试：策略拒绝前零截图 / 零上传 / 零 AX 写；裁图外像素不能进入请求；密钥替换与切换不回显；只向官方端点发一次内联图片，重定向与任意地址拒绝；伪造候选、多个候选、窗口 / 会话过期、超时和无 AX 动作一律不操作；正常 MQTT 读取 / 观察对云端传输调用数为零。三家协议测试只用合成图片与假密钥。
- B17 追加每个已实现桌面方法的 fake 测试矩阵：授权前零上传 / 零 AX 写；显式读取与后台 watcher 分流；只截经核验的企微窗口而非整屏或其它进程；模型输出只可选当前方法的候选 ID / 动作；每轮行动前后复核；轮次、时间、体积和并发边界；失败、UI 变化、模型无把握不猜；不可逆前 checkpoint、已提交后 `unknown` 不重试；MQTT 同键重放、Response Topic、Correlation Data、事件顺序与 `command.get` 对账。测试只用合成窗口、fake AX、fake API、假密钥；B17 活体另门控，不把 fake 当第三方真实请求证明。
- 活体测试：只对白名单 / 策略允许的测试目标；发送条数与内容写进门报告；`IMCTL_LIVE` 门控的套件 CI 不跑。
