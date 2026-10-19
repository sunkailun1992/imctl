# B13：`message.sendFile`、富消息行与 OSS 取回 — 设计规格（2026-09-22）

状态：用户 2026-09-22 18:01 批准（含 18:01 两条修订）。批次代号 B13。前置：1.0.1（`476e403`，macOS 27.0 上五项授权 ✔，读 / 发路径复验通过）。

## 1. 背景与用户决定（2026-09-22）

- 需求：业务侧给一个 https 地址（图片 / 视频 / PDF / Word …），守护进程下载到本机，经桌面客户端发给会话；同时 `message.history` / `message.observed` 要能分辨图片、视频、文件，并能把它们取回来看。
- 用户决定（按时间）：
  1. 17:33–17:39 手动取证：用 Finder ⌘C → 输入框 ⌘V → 回车，png / mp4 / pdf / docx 四种都能发出，**没有任何确认弹窗**；mp4（23.5 MB）发出为**原生视频消息**（播放键 + 时长）。
  2. 17:43 **批准 ⌘V** 作为 `KeystrokeInjector` 的新按键，用途仅限把守护进程放进剪贴板的文件 URL 贴进输入框；方法定名 `message.sendFile`（不扩 `message.send`）。
  3. 17:46 取回侧先做本机（A），Java 上传版（B）留下一批；只接受 https；MQTT 不给文件内容、只给地址。
  4. 17:53 改为**守护进程把缓存文件上传到 OSS、回签名地址**（大文件不走 base64）；bucket 私有（「令牌加密」），必须签名才能看；OSS 配置进控制台设置页与 CLI，便于以后切地址 / 域名 / 密钥。这条取代了 A 的「本机 media-export 路径」与 B 的「Java 预签名 PUT」。
  5. 18:01 批准规格，并定：**本机消费者（控制台、socket / stdio 智能体）也统一看 OSS 签名地址**，`message.media` 不再返回 base64；发送端来源 `url`（仅 https）或 `ossKey` 二选一确认。
- 密钥处理：AccessKey 只进本机 `oss.json`（0600），经控制台或 `imctl oss set` 输入；不进对话、仓库、日志、wiki。建议专用 RAM 子账号，只授该 bucket 的 `oss:PutObject / GetObject / HeadObject`。

## 2. 客户端事实（企微 5.0.11，macOS 27.0，2026-09-22 取证，换版本须重校）

| 类型 | 贴进输入框后 | 发出后的消息行（AX，`文件传输助手`） | 缓存位置 |
|---|---|---|---|
| 图片 png | 内联缩略图 | 高 356，`AXCell` **无子元素**（图片不在 AX 树，同 B9） | `Caches/Images/<yyyy-MM>/<id>/<原名>`、`<id>_THUMB/`、`<id>_HD/`（原图） |
| 视频 mp4 | 「视频 23.5M」条 | 高 368：时间文本 + `AXImage desc='wwsecurity play action play 40'` + 时长文本 `01:14` | 只有 `Caches/Video_Thumbnail/<yyyy-MM>/<id>/<id>` 封面；本体不落缓存（`Caches/Videos/` 只在收到并播放后才有） |
| pdf | 「文件名 74K」条 | 高 82：`AXImage desc='file pdf emphasized'` + 文件名文本 + 大小文本 `74K` | `Caches/Files/<yyyy-MM>/<id>/<原名>` |
| docx | 「文件名 14K」条 | 高 82：`desc='file word emphasized'` + 文件名 + `14K` | 同上 |

1.0.1 的解析器把 pdf / docx 行当成文本消息（`text` = 文件名），视频 / 图片行为 `media`；图片行因无子元素方向只能 `unknown`。发出后输入框 `AXTextArea` 回到 0 字符。贴上附件后输入框的 AX 形状**未取证**（活体校准项 §11）。

## 3. 范围

做：
- `message.sendFile`（新方法）；`Shortcut.commandV`；`ActionKind.sendFile`；`SendFilePolicy`（来源域名白名单、大小上限）；下载器与 outbox；剪贴板快照 / 恢复；粘贴确认；取证。
- `MessageRowKind` 加 `file` / `video`，行字段 `fileName` / `fileSize` / `fileType` / `duration`；`message.history`、`message.observed` 带出；`MediaIndex` 对这两类也记观察时刻。
- `message.media` 改为：图片、文件、视频封面一律**上传 OSS 回签名地址**，不再返回 base64（所有传输统一）。
- OSS：`oss.json` 设置、V4 签名客户端（PutObject、HeadObject、预签名 GET）、`imctl oss set|status|test`、控制台设置页 OSS 区块、`controller.describe.oss`。
- 控制台：发送页「发文件」行、策略页「文件来源域名」名单、会话页历史行显示文件名 / 大小 / 时长。
- 协议文档、`ProtocolDocTests`、单测、活体、门报告、运维手册。

不做（留下一批或不做）：群发带文件；附带文字说明（业务侧另发 `message.send`）；视频本体抓取；OSS 之外的对象存储；STS 临时凭据；个人微信。

## 4. 协议

### 4.1 `message.sendFile`

参数：`{target, url? | ossKey?, fileName?, idempotencyKey（必填）, issuedAtMs?, ttlMs?}`。`url` 与 `ossKey` 二选一：`url` 必须 `https`、域名在 `policy.json.sendFile.allowedHosts`；`ossKey` 是已配置 bucket 里的对象键，守护进程自己签名下载（bucket 私有）。
结果：`{state, evidence, latencyMs, fileName, bytes, contentType, kind: "image"|"video"|"file"}`。
错误码（新增）：`SOURCE_NOT_ALLOWED`（非 https / 域名不在名单 / 重定向出名单）、`SOURCE_UNSUPPORTED`（扩展名或文件头不在白名单、二者不一致）、`SOURCE_TOO_LARGE`、`SOURCE_UNREACHABLE`（下载失败、超时）、`PASTE_FAILED`（附件没贴进输入框，未按回车，已清空输入框）、`OSS_NOT_CONFIGURED`（用了 `ossKey` 但本机没配）。沿用：`TARGET_NOT_ALLOWED`、`RATE_LIMITED`、过期 / 暂停；崩溃后有 checkpoint 无证据 → `unknown`，同键回放。
事件：`command.state` 照旧；成功后观察者发 `message.observed{kind: image|video|file, fileName?, fileSize?, fileType?, duration?, origin: controller, commandId}`。

### 4.2 消息行

`MessageRowKind`：`message | media | file | video | system`（`media` 继续表示图片 / 表情 / 卡片）。新字段（只在对应类型出现）：`fileName`、`fileSize`（客户端原样文本如 `74K`）、`fileType`（图标描述 `file <type> emphasized` 的 `<type>`：pdf / word / excel / ppt / zip / …，未知原样透传）、`duration`（`01:14`）。`message.history`、`message.observed`、控制台行视图同字段。

### 4.3 `message.media`

参数：`{messageKey, hd?}`（1.0 的 `maxBytes` / `maxPixels` 仍接受但忽略，兼容旧调用方）。
- 图片行：原图（`hd` 默认 true 取 `_HD`，否则展示图）上传 OSS。
- `file` 行：按 `fileName` + `fileSize`（解析 `74K` 为字节，容差 ±5%，多个候选取观察时刻最近者）在 `Caches/Files/<yyyy-MM>/*/` 找到原文件 → 上传 OSS。
- `video` 行：封面（`Video_Thumbnail`）上传 OSS；`Caches/Videos/` 里若有本体（收到并播放过）一并上传，否则 `body: absent`。
- 结果：`{kind, fileName, bytes, contentType, ossKey, url（预签名 GET）, expiresAtMs, width?, height?, duration?, body?: "absent"}`；同一 `messageKey` 已上传过则 `HeadObject` 命中直接复用，不重传（地址重新签）。任何传输都不带 `data`。未配置 OSS → `OSS_NOT_CONFIGURED`。

### 4.4 其它

`controller.describe` 加 `oss: "enabled"|"disabled"`（只报状态，不带任何值）。`RPCMethod` 40 → 41，`tools/list` 42 → 43；`docs/protocol/im-control-protocol.md` 同一提交更新方法、字段、错误码；`java-consumer.md` 写明 MQTT 侧只拿地址。

## 5. OSS

- 设置文件 `~/Library/Application Support/imctl/oss.json`（0600）：`{endpoint, bucket, baseDir, accessKeyId, accessKeySecret, viewExpireSeconds（默认 1800）, maxUploadBytes（默认 52428800）}`。字段名对齐业务侧 `aliyun.oss.*`。`region` 由 endpoint 主机名推出（`oss-cn-hangzhou` → `cn-hangzhou`）。
- 签名：**V4（`OSS4-HMAC-SHA256`）**——新建 bucket 不再保证支持 V1。实现 PutObject（Header 签名）、HeadObject、预签名 GET（Query 签名，过期 = `viewExpireSeconds`）。用 CryptoKit，不引第三方 SDK。
- 对象键：`<baseDir>/<yyyy>/<MM>/<dd>/<messageKey>-<清洗后文件名>`；`Content-Type` 按文件头；bucket 私有，返回的永远是签名 GET 地址。
- 上限 `maxUploadBytes`，超过回 `MEDIA_TOO_LARGE`。
- CLI：`imctl oss set --endpoint --bucket --base-dir --access-key-id --access-key-secret [--view-expire] [--max-upload]`（secret 支持从 stdin 读，不留 shell 历史）、`imctl oss status`（掩码显示 AK 前 4 后 2 位）、`imctl oss test`（上传 1 KB 探针对象 → HEAD → 预签名 GET 拉回 → 删除）。
- 控制台 › 设置：OSS 区块，与 MQTT / 代理区块同样式（写 `oss.json`，0600，不入库，密钥输入框为密码型，「测试」按钮走 `oss test`）。`remoteEdits` 不覆盖 OSS 设置，永远只本机可改。
- 日志：签名 URL、AK 一律不进日志；错误只记 HTTP 状态与 OSS `Code`。

## 6. 策略与安全

- `KeystrokeInjector.Shortcut.commandV`（kVK_ANSI_V = 9，⌘），注释记「用户 2026-09-22 17:43 批准，仅 sendFile 贴附件」；只在 `withFront` 内投递一次；`ForbiddenAPITests` 不变。
- `ActionKind.sendFile`：目标与 `submit` 同一条白名单 / 策略链；来源另过 `SendFilePolicy`。
- `policy.json.sendFile = {allowedHosts: [String], maxBytes: 104857600}`：只 https；域名精确匹配或以 `.` 开头的后缀匹配；**空名单 = 全拒**；重定向每一跳重新检查。CLI `imctl policy hosts --allow <host> | --deny <host>`；`policy.set{allowHosts?, denyHosts?}` 受 `remoteEdits`；控制台策略页列表。`ossKey` 来源不查域名（bucket 本身就是配置项）。
- 类型白名单：扩展名 `png jpg jpeg gif webp mp4 mov pdf doc docx xls xlsx ppt pptx zip txt` **且**文件头一致（图片 / 视频 / pdf / zip 容器 / 纯文本），否则 `SOURCE_UNSUPPORTED`。
- 下载：`URLSession`，流式写 `~/Library/Application Support/imctl/outbox/<key12>-<name>`（目录 0700、文件 0600），`Content-Length` 或已写字节超限即断；超时 120 s；文件名取参数或 URL 末段（百分号解码、去分隔符、≤ 120 字）；成败都删；守护进程启动清孤儿。
- 剪贴板：快照 `NSPasteboard.general` 全部项 → 写入 `[fileURL]` → ⌘V → 确认贴上 → 恢复快照；恢复失败只记日志。已知副作用：粘贴前后几百毫秒内人的复制会被覆盖，写进 `docs/ops/permissions.md`。
- 限速：与 `message.send` 同池（每会话 ≥ 3 s、全局 ≤ 20 / 分），一次 sendFile 计一次发送。

## 7. 执行链与取证

`selectConversation` → 聚焦输入框（`AXFocused`）→ 读前台 `previous` → 置前 → ⌘V → **≤ 3 s 轮询输入框非空**（字符数 > 0 或出现子元素；贴不上则 `clearComposer` + `PASTE_FAILED`，不按回车）→ 落盘 checkpoint → 回车（不可逆点）→ 取证 = 消息表新增一条外发行且 `kind ∈ {media, file, video}` 且输入框回空 → 交还前台。超时：图片 15 s、文件 30 s、视频 30 s + 每 10 MB 加 10 s（上限 180 s）。失败信息带 `details`（贴前 / 贴后字符数、行数变化）。

## 8. 解析器与观察者

- `MessageRowParser`：单元格含描述以 `file ` 开头的 `AXImage` + 文件名文本（+ 可选大小文本 `^\d+(\.\d+)?[KMG]$`）→ `file`；含描述含 `play action play` 的 `AXImage` + 时长文本 `^\d{1,2}:\d{2}(:\d{2})?$` → `video`；其余规则不变。方向沿用按 x 推断（文件名文本 / 播放键位置）；图片行保持 `unknown` 并在协议文档注明是客户端限制。
- 夹具：合成夹具 `Tests/Fixtures/ax-trees/wecom-5.0.11-file-video-rows.json`，用中性文件名（`report.pdf` / `12K` / `01:14`），注释带 2026-09-22 取证来源。
- `WatchEngine` diff 对新类型照常出 `message.observed`，带 §4.2 字段；`MediaIndex.observe` 也记 file / video 行（供 §4.3 的候选筛选）。

## 9. 控制台

发送页：目标沿用勾选 / 下拉，加「文件地址（https）」与「或 ossKey」输入、「发文件」按钮，结果进统一结果面板。策略页：「文件来源域名」增删。会话页：历史行显示 `fileName · fileSize` / `视频 · duration`；图片缩略图与「取回」都改走 `message.media` 的签名地址（`AsyncImage` 加载、可复制、可打开），控制台不再依赖 base64。设置页：§5 的 OSS 区块。

## 10. 测试与门

单测（先写失败）：`SendFilePolicy`（https / 精确与后缀域名 / 空名单全拒 / 大小）；类型判定（扩展名 × 文件头矩阵）；下载器（`URLProtocol` 桩：成功、超限中断、重定向出名单、超时）；文件名清洗；`MessageRowParser` 夹具（file / video / 原有类型回归）；`MediaIndex` 对 file / video 的观察；文件候选匹配（临时目录里同名不同大小、多个候选）；OSS 客户端（V4 签名向量按官方文档示例、对象键、预签名 GET 参数、HEAD 复用）；`oss.json` 0600 与掩码；执行器路由、幂等回放、checkpoint 后 `unknown`、限速；`RPCMethod` / `tools/list` 计数、`ProtocolDocTests`、`ForbiddenAPITests`。
活体（只对 `文件传输助手`）：png / mp4 / pdf / docx 各发一次（`url` 三次 + `ossKey` 一次）；名单外域名被拒；同键回放不重发；`message.media` 取回 pdf 与视频封面到 OSS 并用签名地址拉回；`imctl oss test` 往返；贴上附件后输入框 AX 形状取证（§11）。
门报告 `docs/gates/2026-09-22-b13-sendfile-rich-rows-oss.md`；同步 `docs/ops/permissions.md`（剪贴板）、`docs/protocol/agents-mcp.md` + 技能（新工具与「先读后发」守则）、`docs/protocol/java-consumer.md`、`README.md` 模块表。

## 11. 活体校准项（实现时第一件事）

1. 贴上附件后 `AXTextArea` 的 `AXValue` / `AXNumberOfCharacters` / 子元素长什么样（图片内联 vs 文件条），决定 §7「输入框非空」的判据；若客户端不暴露任何信号，退化为固定 1.0 s 稳定期 + 发后取证，并写进门报告。
2. OSS V4 签名对真实 bucket 的 PUT / HEAD / 预签名 GET 往返。
3. 收到的视频（入站）行形状与 `Caches/Videos/` 落盘条件，需要测试号发一条视频。

## 12. 版本与未闭环

- 版本按 `AI_CODING_GUIDE` §10 递增 patch → 1.0.2（新增方法与设置文件均为兼容性变更；用户若视为功能版可改 1.1.0）。
- 未闭环：群发带文件、附带文字、视频本体、STS；控制台缩略图改走签名地址后的加载延迟由活体观察。
