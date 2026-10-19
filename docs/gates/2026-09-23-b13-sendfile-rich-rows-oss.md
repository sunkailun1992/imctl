# 批次 B13：`message.sendFile` / file · video 行 / `message.media` 改回 OSS 签名地址（2026-09-23 01:52–04:0x CST）— 通过（活体校准中修了 4 处）

条件：macOS 27.0、企业微信 5.0.11、imctl 1.0.2（01:51 首装 build 104 = 38c6572；02:15 装入 outbox 修复 b7421af；03:05 装入终审修复 21590c2；03:40 装入 29ffefc；04:0x 装入 c1e86d8）。守护进程由 launchd 常驻，`imctl setup --check` 五项 ✔（辅助功能 / 企微数据 / 完全磁盘访问 / 客户端 / launchd）。传输：本机 socket（`imctl call`），MQTT 同时在线（用户 LAN 的 EMQX，事件照常发布）。发送目标只有 `文件传输助手`，共 9 条成功发送（png×2、pdf×4、docx×2〔url + ossKey〕、mp4×1）、2 次失败尝试（域名不在清单、AX 瞬时错误）、1 次同键回放。`oss.json` 由主智能体按用户 2026-09-22 指示写入本机（region `cn-hangzhou`、bucket `<bucket>`、baseDir `media`、AK 掩码 `LTAI…Wh`、view 1800 s、maxUpload 50 MB），凭据只在该 0600 文件里。`policy.json`：`imctl policy hosts --allow .aliyuncs.com`（maxBytes 100 MB）。来源文件是用户提供的四个公开 OSS 地址：png 1,161,729 B、pdf 75,543 B、docx 14,342 B、mp4 24,684,024 B（域名 `*.oss-cn-hangzhou.aliyuncs.com`）。

## 实现
- 规格 `docs/superpowers/specs/2026-09-22-b13-sendfile-rich-rows-oss-design.md`，计划 16 任务，子智能体逐任务实现 + 逐任务 review + 终审（cd112f8..c1e86d8，约 31 提交，85+ 文件）。
- 新增：`message.sendFile{target, url|ossKey, fileName?, idempotencyKey}`（下载到 outbox → 剪贴板放文件 URL → 一次 ⌘V → 输入框变化确认 → checkpoint → 回车 → 新 media / file / video 行取证）；`file` / `video` 行解析（名字、大小、图标类型、时长）进 `message.history` / `message.observed`，归因按文件名；`message.media` 只向 OSS 传一次、回签名 GET 地址（图片 / 文件 / 视频封面 + 视频正文），不再有 base64；`OSSClient` target（`oss.json` 0600 校验、V4 签名〔官方向量〕、带超时的 transport、对象存储）；`imctl oss set|status|test`、`imctl policy hosts`、`imctld --oss-config`；控制台 OSS 设置 / 发文件 / 域名清单 / 文件 · 视频行签名链接（图片行自动取、文件 / 视频行点「取回」）；文档同步；批准的合成按键清单加入 ⌘V（用户 2026-09-22 17:43 决定）。
- 测试数：1.0.1 的 324 → 439（`ForbiddenAPITests` 新增按键清单与 `NSPasteboard` 文件守卫）。

## 单测
- `swift test`：439 tests / 9 targets 全绿（release 提交 414，之后每次修复都跑了一遍全量）；`swift build` 无警告。
- `bash scripts/check-secrets.sh`：11 条既有 warning（`examples/`、旧计划里的路径），无新增；扫描器新学会 `LTAI` / `accessKeySecret`（含 JSON 形）两种模式。

## 活体 / 只读探针
| 时间 | 步骤 | 结果 |
|---|---|---|
| 01:52 | `imctl oss test` | 1/5 PUT → 2/5 HEAD → 3/5 预签名 GET → 4/5 download → 5/5 DELETE，ok（探针对象 `media/_probe/<uuid>.txt` 已删） |
| 01:52 | `imctl policy hosts --allow .aliyuncs.com` | hosts=1，守护进程一轮内热加载 |
| 01:53:05 | png via `url`（`b13-live-png-1`） | succeeded，row #20 kind=media dir=unknown，粘贴→证据 387 ms，1,161,729 B，kind=image |
| 01:53:17 | pdf via `url`（`b13-live-pdf-1`） | succeeded，row #21 kind=file dir=outbound，1634 ms；**缺陷 1**：客户端显示的文件名带 outbox 前缀 `11323a81dec8-…`（b7421af 修） |
| 01:53:31 | docx via `url`（`b13-live-docx-url-1`） | succeeded，row #22 kind=file，666 ms，fileType=word；同缺陷 1 |
| 01:54 | `url` 域名不在清单（example.com，`b13-live-badhost-1`） | failed `SOURCE_NOT_ALLOWED`，无下载、无粘贴 |
| 01:54 | 同键回放 `b13-live-pdf-1` | 同 commandId（5CF82410…），无新行 |
| 01:54:15 | mp4 via `url`（`b13-live-mp4-1`） | failed `CLIENT_UNAVAILABLE: AX API failure -25201 during get AXRole`（1.6 s 内、下载前；见结论 3） |
| 01:55:04 | mp4 重发（`b13-live-mp4-2`） | succeeded，row #23 kind=video dir=outbound duration 01:14，24,684,024 B，粘贴→证据 590 ms，整条 14 s |
| 01:5x | `message.history{limit:6}` | 新行带 fileName / fileSize（74K、14K）/ fileType（pdf、word）/ duration（01:14），`media: observed` |
| 01:5x | `event.replay` 归因 | 37534 media→`unknown`（图片行方向不可推断，见结论 4）；37539 / 37547 file→`other`（缺陷 1 导致名字不匹配）；37570 video→`controller`（3B380E9E） |
| 02:0x | `message.media` pdf 行 / docx 行 | kind=file matchedBy=name，bytes 75,543 / 14,342，ossKey `media/2026/09/22/<messageKey>-<name>`，签名地址 1800 s（curl 未做，浏览器打开待用户） |
| 02:0x | `message.media` png 行 | kind=image matchedBy=observed，1280×1018 JPEG 113,199 B（客户端缓存的是压缩 JPEG，不是 1.16 MB 原图） |
| 02:1x | `message.media` video 行 | kind=video matchedBy=observed，封面 PNG 306,532 B，body=uploaded（本机发出的 mp4 已在 `Caches/Videos`） |
| 02:1x | 二次 `message.media`（pdf / png） | 同 ossKey、新的 expiresAtMs：只传一次成立 |
| 02:15 | 装 b7421af（outbox 改为 `<outbox>/<id>/<name>`） | — |
| 02:16:50 | pdf via `url`（`b13-live-pdf-2`） | succeeded，row #24，文件名 `电子发票-17.31.pdf` 干净，1259 ms；事件 37697 origin=`controller`（61EDB5BE） |
| 02:17:05 | docx via `ossKey`（上一步 media 传上去的 key，`fileName` 覆盖，`b13-live-docx-1`） | succeeded，row #25，686 ms；事件 37702 origin=`controller`（47AE096F） |
| 02:2x | outbox | 发完即删（目录空）；启动清扫 ≥ 1 h 的残留 |
| 03:05 | 装 21590c2（终审修复：回车后 AX 瞬时错误不判 failed、file 行按名字取证、缓存名清洗、`policy.set` 工具 schema、baseDir 校验、transport 错误码、控制台文件 / 视频行改点「取回」） | — |
| 03:06:24 | pdf via `url`（`b13-live-pdf-3`） | succeeded，row #26（按名字取证），1102 ms；事件 37998 origin=`controller` |
| 03:06:43 | png via `url`（`b13-live-png-2`） | succeeded，row #27 kind=media，4595 ms；事件 38005 origin=`unknown` |
| 03:07 / 03:25 | `message.media` 新 pdf 行 | **缺陷 2**：`MEDIA_NOT_FOUND`「等待『访问其他 App 的数据』授权框」——实为 8 s 文件授权框里先读了一遍 AX 行，而客户端 AX 此时一次读取要 14 s（29ffefc 修：索引里有的键不再读 AX；AX 读移出授权框） |
| 03:2x | AX 延迟测量 | `message.history{limit:3}` 6.7–33 s、`conversation.list` 7.7–10.5 s；换到轻的 `imctl测试群` 也是 8 s → 是客户端 AX 服务整体变慢，与会话轻重无关；01:53 时同样调用约 1 s；守护进程重启后不变（见结论 3） |
| 03:40 | 装 29ffefc | `message.media` 已 assign 的 pdf 行 206 ms（不读 AX）；pdf via `url`（`b13-live-pdf-4`）succeeded row #28，2745 ms；新行 `message.media` 31 ms 回 `MEDIA_NOT_FOUND: no cached file named …`——**缺陷 3**：客户端把重名下载存成 `电子发票-17.31 (1).pdf`，行上仍显示原名（c1e86d8 修：接受 `<名> (n)<扩展名>` 副本，按行各取一份）；同时 review 发现 29ffefc 让有观察记录的图片 / 视频键在窗口未命中时不再回退到可见括号（c1e86d8 修：两阶段——先只查索引，窗口未命中再读一次可见行走括号） |
| 04:0x | 装 c1e86d8 后复验 | 见本文末「04:0x 补记」 |

## 结论与未闭环
1. 通过：四类文件、两种来源（https 清单域名 / ossKey）、域名拒绝、幂等回放、file / video 行字段、`message.media` 走 OSS 只传一次、文件 / 视频行归因 `controller`；回车前失败（域名、下载、粘贴不落）都是 `failed` 可换键重试，回车后不再因 AX 瞬时错误判 `failed`。
2. 活体校准修了 4 处（b7421af、21590c2 的 F1–F11、29ffefc、c1e86d8），每处先 RED 后 GREEN，全量 `swift test` 每次都跑。
3. 客户端 AX 变慢 / `-25201` 抖动是 macOS 27.0 升级后的既有现象（09-22 在 1.0.1 下已有 606 次 `watcher degraded`），不是 B13 引入；本轮 mp4 首发因此失败、换键重发成功。今夜 03:2x 起客户端 AX 每次读取 7–30 s（01:53 约 1 s），守护进程重启无改善，换轻会话无改善——待用户重启企业微信后再看；期间发送仍成功，只是慢。
4. 机制成立、效果待验：图片行 `origin: unknown`（客户端限制，方向推不出）；视频行取证只看方向不看名字（解析器拿不到视频名）；超长文件名若被客户端截断会判 `unknown`（安全方向）；inbound 视频的正文只有播放后才有；一个文件收到多次时客户端只保留不同内容的副本，同内容第 3、4 份没有独立缓存文件，`message.media` 对这些行回 `MEDIA_NOT_FOUND`（打开一次文件后再问）。
5. 待用户决定：RAM 子账号 AccessKey 轮换（AK 曾在聊天里出现）；第二台 Mac 装 1.0.2（桌面 `imctl-1.0.2-第二台Mac`）；来源域名清单 `.aliyuncs.com` 是否收窄；控制台「图片行自动取、文件 / 视频行点取回」的口径；tag v1.0.2 是否打。
6. 未做：群发带文件、发文件附带文字、STS 临时凭据、控制台 UI 人工点检（只保证编译无警告 + 模型层单测）、签名地址在浏览器打开（未做 curl 验证，签名算法有官方向量单测 + `imctl oss test` 5/5）。
7. 下一批 B14（用户 2026-09-22 提出）：`group.addMembers`（已建群二次添加成员）、控制台发送 / 群白名单的编辑、类型级规则与「全部放开」开关。

## 04:12 补记：c1e86d8 装入后复验 — 通过

| 步骤 | 结果 |
|---|---|
| `message.media` row #24（pdf-2） | matchedBy=name，取到 `电子发票-17.31.pdf` 本体，18 s（客户端 AX 仍慢，见结论 3） |
| `message.media` row #26（pdf-3） | matchedBy=name，取到客户端另存的 `电子发票-17.31 (1).pdf` 副本（缺陷 3 修复成立），< 1 s |
| `message.media` row #28（pdf-4） | `MEDIA_NOT_FOUND: no cached file named …`：同内容第 3 份客户端没有独立缓存文件，按结论 4 预期；提示「打开一次文件后再问」 |
| `media-index.json` | 9 个 assignment、13 个 observation（含 fileName / fileSize / duration 字段）；旧条目照常解码 |
| 终审 fix 2 re-review | Approved（两阶段信号为显式类型；`(n)` 副本只从清洗后的名字推导） |
