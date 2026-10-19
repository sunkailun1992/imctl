# B13 `message.sendFile` + rich rows + OSS retrieval — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send a file (image / video / pdf / docx …) fetched from an https URL or an OSS object into a WeCom conversation through the desktop client, recognise file / video rows in history and events, and hand pictures / files / video posters out as OSS signed URLs instead of bytes.

**Architecture:** Same shape as B11/B12: protocol types in `ControlCore`, the fetch/paste/send action in `WeComAdapter` (one new approved key ⌘V in `KeystrokeInjector`, pasteboard behind a protocol), routing in `CommandExecutor` + `RPCDispatcher`, OSS as a new SwiftPM target `OSSClient` behind a `ControlCore.ObjectStore` protocol so the adapter and tests never see Aliyun. Files are downloaded to an owner-only outbox, pasted with ⌘V, sent with the existing Return, and proven by a new outbound `media` / `file` / `video` row.

**Tech Stack:** Swift 6.3.3 (Swift 5 mode), SwiftPM, swift-testing, GRDB, CryptoKit (OSS V4 HMAC-SHA256), URLSession, AppKit (`NSPasteboard`), no new third-party packages.

Spec: `docs/superpowers/specs/2026-09-22-b13-sendfile-rich-rows-oss-design.md` (approved 2026-09-22 18:01).

## Global Constraints

- `AGENTS.md` boundaries stay: no synthetic input outside `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`; the only new key is **⌘V (kVK_ANSI_V = 9, ⌘), user-approved 2026-09-22 17:43, used only to paste the outbox file URL**; `ForbiddenAPITests` must keep passing unchanged.
- Sends only reach the compiled allowlist (`文件传输助手`) + `policy.json`; live tests send **only to `文件传输助手`**.
- Sources: `url` must be `https` and its host must match `policy.json.sendFile.allowedHosts` (empty list = refuse everything; exact host or a `.suffix` rule); `ossKey` needs `oss.json`. Redirects are re-checked per hop. Type allowlist: `png jpg jpeg gif webp mp4 mov pdf doc docx xls xlsx ppt pptx zip txt`, file head must agree. `sendFile.maxBytes` default `104857600`.
- Outbox `~/Library/Application Support/imctl/outbox/` (dir 0700, files 0600), deleted after every attempt and swept at daemon start. OSS settings `~/Library/Application Support/imctl/oss.json` (0600). AccessKey values never appear in code, tests, fixtures, docs, logs, commit messages or the wiki — tests use `TESTAKID0000000001` / `test-secret`; never a string starting with `LTAI`.
- `message.media` returns **signed GET URLs only** on every transport (no base64), `OSS_NOT_CONFIGURED` when `oss.json` is absent; uploads are deduplicated by `HeadObject`; object key `<baseDir>/<yyyy>/<MM>/<dd>/<messageKey>-<sanitized name>`.
- Rate limit: a `message.sendFile` counts as one send in the same pools as `message.send` (per conversation ≥ 3 s, global ≤ 20 / min). Irreversible point = the Return; checkpoint before it; crash after it → `unknown`, same key replays.
- Protocol changes (methods, fields, error codes) update `docs/protocol/im-control-protocol.md` **in the same commit** (`ProtocolDocTests`). `RPCMethod` 40 → 41, `tools/list` 42 → 43, `ActionKind` 14 → 15.
- Version `IMCTLVersion.string` 1.0.1 → 1.0.2 at gate close (Task 15). Commit message prefixes per `AI_CODING_GUIDE.md` §11; every commit ends with the `Co-Authored-By` line from the session reminder.
- Run each task's focused test first (`swift test --filter <Suite>`), the whole `swift test` once at Task 15; `bash scripts/check-secrets.sh` before every commit; never commit `.raw.json`, `--no-redact` output or machine paths.

## File Structure

| Area | Create | Modify |
|---|---|---|
| Protocol | `Sources/ControlCore/Protocol/ObjectStore.swift` | `RPCTypes.swift` (method, params, result, errors), `MediaTypes.swift` (`MediaReference`), `MessageOrigin.swift` (`ControllerSend.kind/fileName`), `Policy/ActionKind.swift`, `Policy/ActionPolicy.swift` |
| Policy | `Sources/ControlCore/Policy/SendFilePolicy.swift` | `SendPolicy.swift`, `PolicyEditing.swift`, `Sources/imctl/Commands/PolicyCommand.swift`, `Sources/imctld/main.swift` (`FilePolicyEditor`) |
| Files | `Sources/ControlCore/Files/FileKind.swift`, `FileNames.swift`, `FileSizeLabel.swift`, `FileFetcher.swift` | `IMCTLPaths.swift` (`outboxDirectory`) |
| Adapter | `Sources/WeComAdapter/Actions/Pasteboard.swift`, `Actions/SendFile.swift` | `Actions/KeystrokeInjector.swift`, `Actions/WeComActions.swift`, `MessageRow.swift`, `WeComReader.swift`, `Watch/WatchSnapshot.swift`, `Watch/WatchDiff.swift`, `Watch/WatchEngine.swift`, `Watch/OriginClassifier.swift`, `Media/WeComMediaStore.swift`, `Handler/WeComCommandHandler.swift`, `Handler/WeComCommandHandler+Media.swift` |
| Store / executor | — | `Store/ControlStore.swift` (`recentSends`), `Executor/CommandHandler.swift`, `Executor/CommandExecutor.swift`, `Sources/MCPTransport/RPCDispatcher.swift` |
| OSS | `Sources/OSSClient/OSSSettings.swift`, `OSSSigner.swift`, `OSSTransport.swift`, `OSSObjectStore.swift`, `Tests/OSSClientTests/*.swift` | `Package.swift` |
| Daemon / CLI | `Sources/imctl/Commands/OSSCommand.swift` | `Sources/imctld/main.swift`, `Sources/imctld/DaemonWatcher.swift`, `Sources/imctl/IMCTL.swift` |
| Console | — | `Model/ConsoleModel.swift`, `Model/RPCService.swift`, `Views/SettingsView.swift`, `Views/SendView.swift`, `Views/PolicyView.swift`, `Views/ConversationsView.swift` |
| Tests | `Tests/ControlCoreTests/SendFilePolicyTests.swift`, `FileKindTests.swift`, `FileFetcherTests.swift`, `Tests/WeComAdapterTests/SendFileTests.swift`, `FileVideoRowTests.swift`, `Tests/Fixtures/ax-trees/wecom-5.0.11-file-video-rows.json`, `Tests/imctlTests/OSSCommandTests.swift` | every `CommandHandler` / `PolicyEditing` conformer in `Tests/` (stubs), `ProtocolTests`, `ProtocolDocTests`, `DispatcherTests`, `CommandExecutorTests`, `ControlStoreTests`, `OriginClassifierTests`, `MessageRowParserTests`, `MediaRouteTests`, `WeComCommandHandlerTests`, `PolicyCommandTests`, `CommandParsingTests`, `ConsoleModelTests`, `IMCTLVersionTests` |
| Docs | `docs/gates/2026-09-22-b13-sendfile-rich-rows-oss.md` | `docs/protocol/im-control-protocol.md`, `java-consumer.md`, `agents-mcp.md`, `docs/agents/skills/imctl/SKILL.md`, `docs/ops/permissions.md`, `README.md`, `scripts/check-secrets.sh` |

Shared names every task uses (defined in Task 1 unless noted): `RPCMethod.messageSendFile`, `SendFileParams`, `SendFileSource`, `SendFileResult`, `MediaReference`, `ObjectStore`, `ControllerSend(kind:fileName:)`, `ActionKind.sendFile`; `SendFilePolicy` (Task 2); `FileKind`, `FileNames`, `FileSizeLabel` (Task 3); `FetchedFile`, `FileFetcher` (Task 4); `KeystrokeInjector.Shortcut.commandV`, `PasteboardHandling` (Task 5); `MessageRowKind.file/.video` (Task 6); `WeComActions.sendFile` (Task 7); `CommandHandler.messageSendFile` / `.messageMedia(messageKey:hd:)` (Task 8 / 10); `OSSSettings`, `OSSSigner`, `OSSObjectStore` (Task 9).

---

### Task 1: Protocol surface — method, params, errors, result types, ObjectStore protocol, ActionKind

**Files:**
- Modify: `Sources/ControlCore/Protocol/RPCTypes.swift`
- Modify: `Sources/ControlCore/Protocol/MediaTypes.swift`
- Modify: `Sources/ControlCore/Protocol/MessageOrigin.swift:18-27`
- Create: `Sources/ControlCore/Protocol/ObjectStore.swift`
- Modify: `Sources/ControlCore/Policy/ActionKind.swift`, `Sources/ControlCore/Policy/ActionPolicy.swift:54`
- Modify: `docs/protocol/im-control-protocol.md` (§6 new method, §10 codes, §12 changelog)
- Test: `Tests/ControlCoreTests/ProtocolTests.swift`, `Tests/MCPTransportTests/ProtocolDocTests.swift`

**Interfaces:**
- Produces: `RPCMethod.messageSendFile` (`"message.sendFile"`, requires idempotency key, not WeCom API); `SendFileParams{target, url?, ossKey?, fileName?, idempotencyKey, ttlMs?, issuedAtMs?}`; `enum SendFileSource { case url(URL); case ossKey(String) }`; `SendFileResult{state, evidence?, reason?, latencyMs?, fileName, bytes: Int64, contentType, kind}`; `ControlError.sourceNotAllowed/.sourceUnsupported/.sourceTooLarge/.sourceUnreachable/.pasteFailed/.ossNotConfigured/.mediaTooLarge/.objectStore` with codes `SOURCE_NOT_ALLOWED SOURCE_UNSUPPORTED SOURCE_TOO_LARGE SOURCE_UNREACHABLE PASTE_FAILED OSS_NOT_CONFIGURED MEDIA_TOO_LARGE OSS_ERROR`; `MediaReference`; `protocol ObjectStore`; `ControllerSend.init(commandId:target:text:tsMs:kind:fileName:)`; `PolicySetParams.allowHosts/denyHosts`; `ActionKind.sendFile` (requires target, forbidden in phase 0).

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ControlCoreTests/ProtocolTests.swift` inside the suite (and change every `RPCMethod.allCases.count == 40` to `41`, every `ActionKind.allCases.count == 14` to `15`, and the `requiresIdempotencyKey` list to `[.messageSend, .messageSendFile, .clientNavigate, .contactRequestAccept, .groupCreate, .groupRename, .messageBroadcast, .contactAdd, .broadcastCreate]`):

```swift
    @Test func sendFileIsAClientMethodWithOneSourceAndItsOwnErrors() throws {
        #expect(RPCMethod(rawValue: "message.sendFile") == .messageSendFile && RPCMethod.messageSendFile.requiresIdempotencyKey && !RPCMethod.messageSendFile.isWeComAPI)
        let p = try JSONDecoder().decode(SendFileParams.self, from: Data(#"{"target":"文件传输助手","url":"https://h.example/a.pdf","idempotencyKey":"f1"}"#.utf8))
        #expect(p.url == "https://h.example/a.pdf" && p.ossKey == nil && p.fileName == nil)
        let r = SendFileResult(state: .succeeded, evidence: "row #2 kind=file", fileName: "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(json.contains("\"kind\":\"file\"") && json.contains("\"bytes\":3"))
        for (e, code) in [(ControlError.sourceNotAllowed("x"), "SOURCE_NOT_ALLOWED"), (.sourceUnsupported("x"), "SOURCE_UNSUPPORTED"), (.sourceTooLarge("x"), "SOURCE_TOO_LARGE"),
                          (.sourceUnreachable("x"), "SOURCE_UNREACHABLE"), (.pasteFailed("x"), "PASTE_FAILED"), (.ossNotConfigured("x"), "OSS_NOT_CONFIGURED"),
                          (.mediaTooLarge("x"), "MEDIA_TOO_LARGE"), (.objectStore("x"), "OSS_ERROR")] {
            #expect(e.code == code && ControlError.allCodes.contains(code))
        }
        #expect(ActionKind.sendFile.requiresTarget && ActionKind.allCases.count == 15)
        #expect(throws: PolicyError.phaseForbids(.sendFile)) { try ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.sendFile], phase: .phase0).authorize(.sendFile, target: "文件传输助手") }
        let send = ControllerSend(commandId: "c", target: "t", text: "", tsMs: 1, kind: "file", fileName: "a.pdf")
        #expect(send.kind == "file" && ControllerSend(commandId: "c", target: "t", text: "hi", tsMs: 1).kind == "text")
        let ref = MediaReference(messageKey: "k", kind: "image", matchedBy: "observed", fileName: "p.png", bytes: 10, contentType: "image/png", ossKey: "imctl/2026/09/22/k-p.png", url: "https://b.example/x?sig", expiresAtMs: 5)
        #expect(String(decoding: try JSONEncoder().encode(ref), as: UTF8.self).contains("\"url\":"))
    }
```

In `Tests/MCPTransportTests/ProtocolDocTests.swift` extend the `samples` array with `.sourceNotAllowed("x"), .sourceUnsupported("x"), .sourceTooLarge("x"), .sourceUnreachable("x"), .pasteFailed("x"), .ossNotConfigured("x"), .mediaTooLarge("x"), .objectStore("x")`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProtocolTests`
Expected: compile errors (`messageSendFile`, `SendFileParams`, `SendFileResult`, `sourceNotAllowed`, `sendFile`, `MediaReference` undefined).

- [ ] **Step 3: Implement**

`Sources/ControlCore/Protocol/RPCTypes.swift` — insert after `case messageSend = "message.send"`:

```swift
    /// B13: fetch an https / OSS source into the outbox, paste it into the composer (⌘V, user-approved 2026-09-22) and send it with Return.
    case messageSendFile = "message.sendFile"
```

In `requiresIdempotencyKey` add `.messageSendFile` right after `.messageSend`. After `SendParams` add:

```swift
/// `message.sendFile`: exactly one of `url` (https, host on policy.json sendFile.allowedHosts) or `ossKey` (object in the configured bucket).
public struct SendFileParams: Codable, Equatable {
    public var target: String
    public var url: String?
    public var ossKey: String?
    public var fileName: String?
    public var idempotencyKey: String
    public var ttlMs: Int?
    public var issuedAtMs: Int64?
    public init(target: String, url: String? = nil, ossKey: String? = nil, fileName: String? = nil, idempotencyKey: String, ttlMs: Int? = nil, issuedAtMs: Int64? = nil) {
        self.target = target; self.url = url; self.ossKey = ossKey; self.fileName = fileName; self.idempotencyKey = idempotencyKey; self.ttlMs = ttlMs; self.issuedAtMs = issuedAtMs
    }
}

/// Where a file to send comes from, after the executor validated the params.
public enum SendFileSource: Equatable {
    case url(URL)
    case ossKey(String)
}

/// `message.sendFile` result: the send outcome plus what was fetched (name as pasted, bytes, sniffed type, image | video | file).
public struct SendFileResult: Codable, Equatable {
    public var state: CommandStateV1
    public var evidence: String?
    public var reason: String?
    public var latencyMs: Int?
    public var fileName: String
    public var bytes: Int64
    public var contentType: String
    public var kind: String
    public init(state: CommandStateV1, evidence: String? = nil, reason: String? = nil, latencyMs: Int? = nil, fileName: String, bytes: Int64, contentType: String, kind: String) {
        self.state = state; self.evidence = evidence; self.reason = reason; self.latencyMs = latencyMs
        self.fileName = fileName; self.bytes = bytes; self.contentType = contentType; self.kind = kind
    }
}
```

`PolicySetParams`: add `public var allowHosts: [String]?` and `public var denyHosts: [String]?` (CodingKeys are synthesized), extend `init` with `allowHosts: [String]? = nil, denyHosts: [String]? = nil` and assign them.

`ControlError`: add the cases after `case proxy(String)`:

```swift
    // B13 message.sendFile / message.media over OSS
    case sourceNotAllowed(String)
    case sourceUnsupported(String)
    case sourceTooLarge(String)
    case sourceUnreachable(String)
    /// The attachment never appeared in the composer; nothing was sent.
    case pasteFailed(String)
    case ossNotConfigured(String)
    case mediaTooLarge(String)
    /// The object store answered with an error (HTTP status + its Code / Message, never a key or a signed URL).
    case objectStore(String)
```

`code` switch: `.sourceNotAllowed → "SOURCE_NOT_ALLOWED"`, `.sourceUnsupported → "SOURCE_UNSUPPORTED"`, `.sourceTooLarge → "SOURCE_TOO_LARGE"`, `.sourceUnreachable → "SOURCE_UNREACHABLE"`, `.pasteFailed → "PASTE_FAILED"`, `.ossNotConfigured → "OSS_NOT_CONFIGURED"`, `.mediaTooLarge → "MEDIA_TOO_LARGE"`, `.objectStore → "OSS_ERROR"`. `message` switch: each returns its associated string. `allCodes`: append `"SOURCE_NOT_ALLOWED", "SOURCE_UNSUPPORTED", "SOURCE_TOO_LARGE", "SOURCE_UNREACHABLE", "PASTE_FAILED", "OSS_NOT_CONFIGURED", "MEDIA_TOO_LARGE", "OSS_ERROR"`.

`Sources/ControlCore/Protocol/MediaTypes.swift` — append:

```swift
/// B13 `message.media` result: the file behind a picture / file / video row, uploaded to the configured object
/// store; callers get a signed GET URL, never bytes (all transports alike).
public struct MediaReference: Codable, Equatable {
    public var messageKey: String
    /// image | file | video
    public var kind: String
    /// assigned | observed | window | name — how the cache file was tied to the row.
    public var matchedBy: String
    public var fileName: String
    public var bytes: Int64
    public var contentType: String
    public var ossKey: String
    public var url: String
    public var expiresAtMs: Int64
    public var width: Int?
    public var height: Int?
    public var duration: String?
    /// video only: `uploaded` when the client had the body cached (played), else `absent`.
    public var body: String?
    public var bodyOssKey: String?
    public var bodyUrl: String?
    public init(messageKey: String, kind: String, matchedBy: String, fileName: String, bytes: Int64, contentType: String, ossKey: String, url: String, expiresAtMs: Int64,
                width: Int? = nil, height: Int? = nil, duration: String? = nil, body: String? = nil, bodyOssKey: String? = nil, bodyUrl: String? = nil) {
        self.messageKey = messageKey; self.kind = kind; self.matchedBy = matchedBy; self.fileName = fileName; self.bytes = bytes; self.contentType = contentType
        self.ossKey = ossKey; self.url = url; self.expiresAtMs = expiresAtMs; self.width = width; self.height = height; self.duration = duration
        self.body = body; self.bodyOssKey = bodyOssKey; self.bodyUrl = bodyUrl
    }
}
```

`Sources/ControlCore/Protocol/ObjectStore.swift` (new):

```swift
import Foundation

/// What the daemon needs from a private object store (Aliyun OSS in `OSSClient`). Bytes never cross the
/// protocol: consumers get signed GET URLs. Implemented by `OSSObjectStore`; faked in tests.
public protocol ObjectStore: AnyObject {
    /// Endpoint host + bucket + base dir + masked key id, for `describe` / logs — never a secret or a signed URL.
    var summary: String { get }
    var baseDir: String { get }
    var maxUploadBytes: Int64 { get }
    var viewExpireSeconds: Int { get }
    func exists(key: String) throws -> Bool
    func put(fileURL: URL, key: String, contentType: String) throws
    func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL
    /// Streams `key` to `destination` (at most `maxBytes`, checked by HEAD first); returns the byte count.
    func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64
    func delete(key: String) throws
}
```

`Sources/ControlCore/Protocol/MessageOrigin.swift` — replace `ControllerSend`:

```swift
public struct ControllerSend: Equatable {
    public var commandId: String
    public var target: String
    public var text: String
    public var tsMs: Int64
    /// `text` (message.send) or `file` (message.sendFile, B13).
    public var kind: String
    /// The name the client shows for a file send; nil for pictures / videos and text.
    public var fileName: String?

    public init(commandId: String, target: String, text: String, tsMs: Int64, kind: String = "text", fileName: String? = nil) {
        self.commandId = commandId; self.target = target; self.text = text; self.tsMs = tsMs; self.kind = kind; self.fileName = fileName
    }
}
```

`ActionKind.swift`: add after `case addContact`:

```swift
    /// B13: put an outbox file URL on the pasteboard, ⌘V into the composer (user-approved 2026-09-22 17:43), then the same Return as `submit`.
    case sendFile
```

and add `.sendFile` to the `return true` list of `requiresTarget`. `ActionPolicy.authorize`: change the phase line to `if phase == .phase0, kind == .submit || kind == .sendFile { throw PolicyError.phaseForbids(kind) }`.

`docs/protocol/im-control-protocol.md`: after §6.42 add

```markdown
### 6.43 `message.sendFile`

参数 `{target, url? | ossKey?, fileName?, idempotencyKey（必填）, ttlMs?, issuedAtMs?}`，`url` 与 `ossKey` 二选一：`url` 必须 `https` 且域名在 `policy.json.sendFile.allowedHosts`（精确或 `.后缀`；空名单 = 全拒；重定向逐跳复查）；`ossKey` 是已配置 bucket（`oss.json`）里的对象键，守护进程自己签名下载。类型白名单 `png jpg jpeg gif webp mp4 mov pdf doc docx xls xlsx ppt pptx zip txt` 且文件头一致；单文件 ≤ `sendFile.maxBytes`（默认 100 MB）。执行：下载到 outbox → 聚焦输入框 → 置前 → ⌘V（用户 2026-09-22 批准的唯一新按键）→ ≤ 3 s 内确认输入框出现附件 → checkpoint → 回车 → 取证 = 新出现的外发 `media` / `file` / `video` 行（图片 15 s、文件 30 s、视频 30 s + 每 10 MB 加 10 s，上限 180 s）→ 交还前台；发完即删 outbox 文件。结果 `{state, evidence?, reason?, latencyMs?, fileName, bytes, contentType, kind:"image"|"video"|"file"}`；限速与 `message.send` 同池；同键回放；崩溃后 `unknown`。活体 2026-09-22（5.0.11 / macOS 27.0）：贴入文件 URL 不弹确认窗，mp4 以原生视频消息发出。
```

§10 error table — add rows:

```markdown
| `SOURCE_NOT_ALLOWED` | `message.sendFile`：非 https、域名不在 `sendFile.allowedHosts`、重定向出名单 | `result.error` |
| `SOURCE_UNSUPPORTED` | 扩展名不在白名单，或文件头与扩展名不符 | `result.error` |
| `SOURCE_TOO_LARGE` | 超过 `sendFile.maxBytes` | `result.error` |
| `SOURCE_UNREACHABLE` | 下载失败 / 超时 / 对象不存在 | `result.error` |
| `PASTE_FAILED` | 附件没有出现在输入框里；未按回车，输入框已清空 | `result.error` |
| `OSS_NOT_CONFIGURED` | 用了 `ossKey` 或 `message.media`，但本机没有 `oss.json`（`imctl oss set`） | 两者 |
| `MEDIA_TOO_LARGE` | `message.media`：缓存文件超过 `oss.json.maxUploadBytes` | JSON-RPC error `data.code` |
| `OSS_ERROR` | 对象存储拒绝或不可达（HTTP 状态 + Code / Message；不含地址与密钥） | 两者 |
```

§12 changelog — add `| 2026-09-22 | B13：`message.sendFile`（https / ossKey → outbox → ⌘V → 回车）；行 `file` / `video`；`message.media` 改为 OSS 签名地址；`policy.json.sendFile`；`oss.json` |`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ProtocolTests|ProtocolDocTests"`
Expected: PASS (the doc test now finds `message.sendFile` and the 8 codes).

- [ ] **Step 5: Commit**

```bash
git add Sources/ControlCore Tests/ControlCoreTests/ProtocolTests.swift Tests/MCPTransportTests/ProtocolDocTests.swift docs/protocol/im-control-protocol.md
git commit -m "feat(protocol): message.sendFile params/result, SendFileSource, ObjectStore protocol, MediaReference, sendFile error codes, ActionKind.sendFile; protocol doc §6.43 + §10 rows"
```

---

### Task 2: `SendFilePolicy` in `policy.json`, `imctl policy hosts`, `policy.set{allowHosts, denyHosts}`

**Files:**
- Create: `Sources/ControlCore/Policy/SendFilePolicy.swift`
- Modify: `Sources/ControlCore/Policy/SendPolicy.swift`, `Sources/ControlCore/Policy/PolicyEditing.swift`
- Modify: `Sources/ControlCore/Executor/CommandExecutor.swift:260-269` (`policySet` branch)
- Modify: `Sources/imctld/main.swift:138-157` (`FilePolicyEditor`), `Tests/ControlCoreTests/CommandExecutorTests.swift:179` (`MemoryPolicyEditor`)
- Modify: `Sources/imctl/Commands/PolicyCommand.swift` (new `PolicyHostsCommand`, list output)
- Modify: `docs/protocol/im-control-protocol.md` §6.35 `policy.set`
- Test: `Tests/ControlCoreTests/SendFilePolicyTests.swift` (new), `Tests/imctlTests/PolicyCommandTests.swift`

**Interfaces:**
- Produces: `SendFilePolicy{allowedHosts: [String], maxBytes: Int64}` with `allows(host:)`, `rejection(for: URL) -> String?`, `allow(_:)`, `deny(_:)`, `summary`; `SendPolicy.sendFile: SendFilePolicy`; `PolicyEditing.apply(allow:deny:contactRequests:gateReads:allowPhones:denyPhones:allowHosts:denyHosts:)`; CLI `imctl policy hosts --allow <host>… --deny <host>… --max-bytes N`.

- [ ] **Step 1: Write the failing tests**

`Tests/ControlCoreTests/SendFilePolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import ControlCore

@Suite("SendFilePolicy (policy.json sendFile)")
struct SendFilePolicyTests {
    @Test func emptyListRefusesEverythingAndOnlyHttpsPasses() throws {
        var p = SendFilePolicy()
        #expect(p.allowedHosts.isEmpty && p.maxBytes == 104_857_600 && !p.allows(host: "h.example"))
        #expect(p.rejection(for: URL(string: "https://h.example/a.pdf")!)?.contains("allowedHosts") == true)
        p.allow("H.Example"); p.allow("h.example")   // normalised, idempotent
        #expect(p.allowedHosts == ["h.example"] && p.allows(host: "h.example") && p.rejection(for: URL(string: "https://h.example/a.pdf")!) == nil)
        #expect(p.rejection(for: URL(string: "http://h.example/a.pdf")!)?.contains("https") == true)
        p.allow(".aliyuncs.com")
        #expect(p.allows(host: "bucket.oss-cn-hangzhou.aliyuncs.com") && !p.allows(host: "aliyuncs.com") && !p.allows(host: "evil-aliyuncs.com"))
        p.deny("h.example")
        #expect(p.allowedHosts == [".aliyuncs.com"] && p.summary == "hosts=1 maxBytes=104857600")
    }

    @Test func sendPolicyRoundTripsAndDefaultsForOldFiles() throws {
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data("{}".utf8))
        #expect(old.sendFile == SendFilePolicy())
        var p = SendPolicy(); p.sendFile.allow("cdn.example"); p.sendFile.maxBytes = 10
        let back = try JSONDecoder().decode(SendPolicy.self, from: try JSONEncoder().encode(p))
        #expect(back.sendFile.allowedHosts == ["cdn.example"] && back.sendFile.maxBytes == 10)
    }
}
```

`Tests/imctlTests/PolicyCommandTests.swift`: change both expected subcommand lists to `["list", "allow", "deny", "requests", "remote", "reads", "phones", "hosts"]` and add:

```swift
    @Test func hostsSubcommandWritesSendFilePolicy() throws {
        let file = tempFile()
        try PolicyHostsCommand.parse(["--file", file, "--allow", "cdn.example", ".aliyuncs.com", "--max-bytes", "1024"]).run()
        var policy = try SendPolicy.load(from: URL(fileURLWithPath: file))
        #expect(policy.sendFile.allowedHosts == ["cdn.example", ".aliyuncs.com"] && policy.sendFile.maxBytes == 1024)
        try PolicyHostsCommand.parse(["--file", file, "--deny", "cdn.example"]).run()
        policy = try SendPolicy.load(from: URL(fileURLWithPath: file))
        #expect(policy.sendFile.allowedHosts == [".aliyuncs.com"])
        #expect(throws: (any Error).self) { try PolicyHostsCommand.parse(["--file", file]).validate() }
    }
```

`Tests/ControlCoreTests/CommandExecutorTests.swift`: in the existing `policy.set` test add a call with `"allowHosts":["cdn.example"]` and assert `MemoryPolicyEditor` received it (extend `MemoryPolicyEditor.apply` to the new signature and store `policy.sendFile.allow(host)` for each). Add to that test: `#expect(editor.policy.sendFile.allowedHosts == ["cdn.example"])`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "SendFilePolicyTests|PolicyCommandTests"`
Expected: compile errors (`SendFilePolicy`, `sendFile`, `PolicyHostsCommand` undefined).

- [ ] **Step 3: Implement**

`Sources/ControlCore/Policy/SendFilePolicy.swift`:

```swift
import Foundation

/// B13: where `message.sendFile` may fetch from. Empty `allowedHosts` (the default) refuses every https
/// source — like titles and phone numbers, opening a host is a person's decision made on this Mac.
/// `ossKey` sources bypass this list: the bucket is itself configuration (`oss.json`).
public struct SendFilePolicy: Codable, Equatable {
    public var allowedHosts: [String]
    /// Hard cap on one downloaded file (bytes).
    public var maxBytes: Int64

    public init(allowedHosts: [String] = [], maxBytes: Int64 = 104_857_600) {
        self.allowedHosts = allowedHosts; self.maxBytes = maxBytes
    }

    enum CodingKeys: String, CodingKey { case allowedHosts, maxBytes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        maxBytes = try c.decodeIfPresent(Int64.self, forKey: .maxBytes) ?? 104_857_600
    }

    public static func normalize(_ host: String) -> String { host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Exact host, or a `.suffix` rule that matches `x.suffix` (never the bare suffix, never `evil-suffix`).
    public func allows(host: String) -> Bool {
        let h = Self.normalize(host)
        guard !h.isEmpty else { return false }
        return allowedHosts.contains { rule in
            let r = Self.normalize(rule)
            if r.hasPrefix(".") { return h.hasSuffix(r) && h.count > r.count }
            return h == r
        }
    }

    /// nil when the URL may be fetched; otherwise the wire message for SOURCE_NOT_ALLOWED.
    public func rejection(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https" else { return "only https sources are accepted (got \(url.scheme ?? "no scheme"))" }
        guard let host = url.host, allows(host: host) else {
            return "host \"\(url.host ?? "-")\" is not in policy.json sendFile.allowedHosts (imctl policy hosts --allow <host>, or the console's 策略 page)"
        }
        return nil
    }

    public mutating func allow(_ host: String) {
        let n = Self.normalize(host)
        guard !n.isEmpty, !allowedHosts.contains(n) else { return }
        allowedHosts.append(n)
    }

    public mutating func deny(_ host: String) {
        let n = Self.normalize(host)
        allowedHosts.removeAll { $0 == n }
    }

    public var summary: String { "hosts=\(allowedHosts.count) maxBytes=\(maxBytes)" }
}
```

`SendPolicy.swift`: add `public var sendFile: SendFilePolicy` after `contactAdd` (doc: `/// B13: https hosts message.sendFile may fetch from and the per-file byte cap.`), add `sendFile: SendFilePolicy = SendFilePolicy()` to `init` (assign it), add `sendFile` to `CodingKeys`, and in `init(from:)`: `sendFile = try c.decodeIfPresent(SendFilePolicy.self, forKey: .sendFile) ?? SendFilePolicy()`.

`PolicyEditing.swift`: replace the `apply` requirement with

```swift
    /// Allows / denies titles, phones and sendFile hosts, replaces `contactRequests` and sets `gateReads` when given; returns the saved policy.
    func apply(allow: [String], deny: [String], contactRequests: ContactRequestPolicy?, gateReads: Bool?,
               allowPhones: [String], denyPhones: [String], allowHosts: [String], denyHosts: [String]) throws -> SendPolicy
```

`CommandExecutor.swift` `policySet` branch: pass `allowHosts: p.allowHosts ?? [], denyHosts: p.denyHosts ?? []`. `FilePolicyEditor.apply` (imctld/main.swift): add the two parameters and `for h in allowHosts { policy.sendFile.allow(h) }; for h in denyHosts { policy.sendFile.deny(h) }` before `save`. `MemoryPolicyEditor` in the tests: same signature, same two loops on its stored policy.

`PolicyCommand.swift`: add `PolicyHostsCommand.self` to `subcommands`, print `hosts (sendFile): \(view.policy.sendFile.allowedHosts.isEmpty ? "-" : view.policy.sendFile.allowedHosts.joined(separator: ", ")) maxBytes=\(view.policy.sendFile.maxBytes)` in `PolicyListCommand.run` after the phones line, and append:

```swift
/// B13: which https hosts `message.sendFile` may download from (policy.json sendFile.allowedHosts; empty = refused).
struct PolicyHostsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hosts", abstract: "Allow / deny https hosts for message.sendFile (exact host or .suffix; empty list = every url refused) and the per-file byte cap.")
    @Option(parsing: .upToNextOption, help: "Host(s) to allow, e.g. cdn.example or .aliyuncs.com") var allow: [String] = []
    @Option(parsing: .upToNextOption, help: "Host(s) to deny.") var deny: [String] = []
    @Option(name: .customLong("max-bytes"), help: "Hard cap on one downloaded file.") var maxBytes: Int64?
    @Option(help: "Policy file path.") var file: String = SendPolicy.defaultURL.path

    func validate() throws {
        if allow.isEmpty, deny.isEmpty, maxBytes == nil { throw ValidationError("pass --allow, --deny or --max-bytes") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: file)
        var policy = try SendPolicy.load(from: url)
        for h in allow { policy.sendFile.allow(h) }
        for h in deny { policy.sendFile.deny(h) }
        if let m = maxBytes { policy.sendFile.maxBytes = max(1, m) }
        try policy.save(to: url)
        print("wrote \(file) (0600): \(policy.sendFile.summary) [\(policy.sendFile.allowedHosts.joined(separator: ", "))]")
        print("imctld reloads the file within one poll")
    }
}
```

Protocol doc §6.35: add `allowHosts?` / `denyHosts?` to the `policy.set` parameter list with one sentence: `sendFile.allowedHosts 的增删（同 remoteEdits 门）`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "SendFilePolicyTests|PolicyCommandTests|CommandExecutorTests|SendPolicyTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ControlCore/Policy Sources/ControlCore/Executor/CommandExecutor.swift Sources/imctld/main.swift Sources/imctl/Commands/PolicyCommand.swift Tests docs/protocol/im-control-protocol.md
git commit -m "feat(policy): sendFile host allowlist + byte cap in policy.json (imctl policy hosts, policy.set allowHosts/denyHosts)"
```

---

### Task 3: File utilities — `FileKind`, `FileNames`, `FileSizeLabel`

**Files:**
- Create: `Sources/ControlCore/Files/FileKind.swift`, `Sources/ControlCore/Files/FileNames.swift`, `Sources/ControlCore/Files/FileSizeLabel.swift`
- Test: `Tests/ControlCoreTests/FileKindTests.swift`

**Interfaces:**
- Produces: `FileKind.Info{kind: String, contentType: String, ext: String}`; `FileKind.info(forFileName:) -> Info?`; `FileKind.signature(of head: [UInt8]) -> String?` (`png jpeg gif webp mp4 mov pdf zip ole`); `FileKind.rejection(fileName:head:) -> String?`; `FileNames.sanitize(_ raw: String, fallback: String) -> String`; `FileNames.name(from url: URL) -> String`; `FileSizeLabel.bytes(_ label: String) -> Int64?`; `FileSizeLabel.matches(size: Int64, label: String) -> Bool`.

- [ ] **Step 1: Write the failing tests**

`Tests/ControlCoreTests/FileKindTests.swift`:

```swift
import Foundation
import Testing
@testable import ControlCore

@Suite("File kind / names / size labels (B13)")
struct FileKindTests {
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0, count: 12)
    static let mp4: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D] + [0, 0, 0, 0]
    static let mov: [UInt8] = [0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20] + [0, 0, 0, 0]
    static let pdf: [UInt8] = Array("%PDF-1.4 rest of head".utf8.prefix(16))
    static let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04] + Array(repeating: 0, count: 12)
    static let ole: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + Array(repeating: 0, count: 8)

    @Test func extensionTableAndSignatures() {
        #expect(FileKind.info(forFileName: "a.PNG") == FileKind.Info(kind: "image", contentType: "image/png", ext: "png"))
        #expect(FileKind.info(forFileName: "report.docx")?.contentType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(FileKind.info(forFileName: "clip.mp4")?.kind == "video" && FileKind.info(forFileName: "x.exe") == nil && FileKind.info(forFileName: "noext") == nil)
        #expect(FileKind.signature(of: Self.png) == "png" && FileKind.signature(of: Self.jpeg) == "jpeg" && FileKind.signature(of: Self.mp4) == "mp4")
        #expect(FileKind.signature(of: Self.mov) == "mov" && FileKind.signature(of: Self.pdf) == "pdf" && FileKind.signature(of: Self.zip) == "zip" && FileKind.signature(of: Self.ole) == "ole")
        #expect(FileKind.signature(of: [1, 2, 3]) == nil)
    }

    @Test func headMustAgreeWithTheExtension() {
        #expect(FileKind.rejection(fileName: "a.png", head: Self.png) == nil)
        #expect(FileKind.rejection(fileName: "a.png", head: Self.jpeg)?.contains("jpeg") == true)
        #expect(FileKind.rejection(fileName: "a.docx", head: Self.zip) == nil && FileKind.rejection(fileName: "a.doc", head: Self.ole) == nil)
        #expect(FileKind.rejection(fileName: "a.doc", head: Self.zip) == nil)     // a .doc that is really OOXML still opens
        #expect(FileKind.rejection(fileName: "a.mov", head: Self.mp4) == nil)     // both are ISO base media
        #expect(FileKind.rejection(fileName: "notes.txt", head: [0x68, 0x69]) == nil)   // text has no signature
        #expect(FileKind.rejection(fileName: "a.exe", head: Self.zip)?.contains("not in the allowlist") == true)
        #expect(FileKind.rejection(fileName: "a.pdf", head: []) != nil)
    }

    @Test func namesAreDecodedSanitisedAndCapped() {
        #expect(FileNames.name(from: URL(string: "https://h.example/dir/%E7%94%B5%E5%AD%90%E5%8F%91%E7%A5%A8-17.31.pdf")!) == "电子发票-17.31.pdf")
        #expect(FileNames.sanitize("../../etc:passwd\u{0}.pdf", fallback: "file.pdf") == "etcpasswd.pdf")
        #expect(FileNames.sanitize("   ", fallback: "file.pdf") == "file.pdf")
        let long = String(repeating: "长", count: 200) + ".docx"
        let capped = FileNames.sanitize(long, fallback: "f.docx")
        #expect(capped.count <= 120 && capped.hasSuffix(".docx"))
        #expect(FileNames.name(from: URL(string: "https://h.example/")!) == "file")
    }

    @Test func sizeLabelsParseAndMatchWithinTolerance() {
        #expect(FileSizeLabel.bytes("74K") == 75_776 && FileSizeLabel.bytes("23.5M") == 24_641_536 && FileSizeLabel.bytes("512B") == 512 && FileSizeLabel.bytes("1.2G") == 1_288_490_188)
        #expect(FileSizeLabel.bytes("hello") == nil && FileSizeLabel.bytes("01:14") == nil)
        #expect(FileSizeLabel.matches(size: 75_543, label: "74K") && FileSizeLabel.matches(size: 24_684_024, label: "23.5M") && FileSizeLabel.matches(size: 14_342, label: "14K"))
        #expect(!FileSizeLabel.matches(size: 90_000, label: "74K") && !FileSizeLabel.matches(size: 100, label: "junk"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FileKindTests`
Expected: compile errors (`FileKind`, `FileNames`, `FileSizeLabel` undefined).

- [ ] **Step 3: Implement**

`Sources/ControlCore/Files/FileKind.swift`:

```swift
import Foundation

/// B13: what `message.sendFile` may fetch and paste. The extension picks the kind and content type; where the
/// format has a signature, the first bytes must agree (a `.png` that starts like a JPEG is refused).
public enum FileKind {
    public struct Info: Equatable {
        /// image | video | file
        public var kind: String
        public var contentType: String
        public var ext: String
        public init(kind: String, contentType: String, ext: String) { self.kind = kind; self.contentType = contentType; self.ext = ext }
    }

    static let table: [String: (kind: String, contentType: String)] = [
        "png": ("image", "image/png"), "jpg": ("image", "image/jpeg"), "jpeg": ("image", "image/jpeg"), "gif": ("image", "image/gif"), "webp": ("image", "image/webp"),
        "mp4": ("video", "video/mp4"), "mov": ("video", "video/quicktime"),
        "pdf": ("file", "application/pdf"), "doc": ("file", "application/msword"),
        "docx": ("file", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        "xls": ("file", "application/vnd.ms-excel"), "xlsx": ("file", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        "ppt": ("file", "application/vnd.ms-powerpoint"), "pptx": ("file", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        "zip": ("file", "application/zip"), "txt": ("file", "text/plain"),
    ]

    /// Signatures each extension accepts; an empty set means "no check" (txt).
    static let accepted: [String: Set<String>] = [
        "png": ["png"], "jpg": ["jpeg"], "jpeg": ["jpeg"], "gif": ["gif"], "webp": ["webp"],
        "mp4": ["mp4", "mov"], "mov": ["mp4", "mov"], "pdf": ["pdf"],
        "doc": ["ole", "zip"], "xls": ["ole", "zip"], "ppt": ["ole", "zip"],
        "docx": ["zip"], "xlsx": ["zip"], "pptx": ["zip"], "zip": ["zip"], "txt": [],
    ]

    public static func info(forFileName name: String) -> Info? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let entry = table[ext] else { return nil }
        return Info(kind: entry.kind, contentType: entry.contentType, ext: ext)
    }

    /// png | jpeg | gif | webp | mp4 | mov | pdf | zip | ole, from the first 16 bytes; nil for anything else.
    public static func signature(of head: [UInt8]) -> String? {
        guard head.count >= 4 else { return nil }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return "ole" }
        guard head.count >= 12 else { return nil }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]), Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] {   // "ftyp"
            let brand = String(decoding: head[8..<12], as: UTF8.self)
            return brand.hasPrefix("qt") ? "mov" : "mp4"
        }
        return nil
    }

    /// nil when accepted; otherwise the SOURCE_UNSUPPORTED message.
    public static func rejection(fileName: String, head: [UInt8]) -> String? {
        guard let info = info(forFileName: fileName) else {
            return "\"\(fileName)\": extension is not in the allowlist (png jpg jpeg gif webp mp4 mov pdf doc docx xls xlsx ppt pptx zip txt)"
        }
        let wanted = accepted[info.ext] ?? []
        guard !wanted.isEmpty else { return nil }
        guard let found = signature(of: head) else { return "\"\(fileName)\": the file head is not a \(wanted.sorted().joined(separator: " / ")) signature" }
        guard wanted.contains(found) else { return "\"\(fileName)\": extension \(info.ext) but the file head says \(found)" }
        return nil
    }
}
```

`Sources/ControlCore/Files/FileNames.swift`:

```swift
import Foundation

/// File names as pasted into the client: the URL's last path component (percent-decoded), no path separators,
/// no control characters, at most 120 characters with the extension kept.
public enum FileNames {
    public static let maxLength = 120

    public static func name(from url: URL) -> String {
        let last = url.lastPathComponent
        let decoded = last.removingPercentEncoding ?? last
        return sanitize(decoded == "/" ? "" : decoded, fallback: "file")
    }

    public static func sanitize(_ raw: String, fallback: String) -> String {
        var s = raw.replacingOccurrences(of: "\\", with: "")
        s = s.split(separator: "/").last.map(String.init) ?? ""
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        guard !s.isEmpty else { return fallback }
        guard s.count > maxLength else { return s }
        let ext = (s as NSString).pathExtension
        let stem = ext.isEmpty ? s : String(s.dropLast(ext.count + 1))
        let room = max(1, maxLength - (ext.isEmpty ? 0 : ext.count + 1))
        return ext.isEmpty ? String(stem.prefix(room)) : String(stem.prefix(room)) + "." + ext
    }
}
```

`Sources/ControlCore/Files/FileSizeLabel.swift`:

```swift
import Foundation

/// The size the client prints on a file chip / row ("74K", "23.5M", live 2026-09-22): binary units, rounded.
public enum FileSizeLabel {
    static let pattern = try? NSRegularExpression(pattern: "^([0-9]+(?:\\.[0-9]+)?)([BKMG])$")
    static let multipliers: [String: Double] = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824]

    public static func bytes(_ label: String) -> Int64? {
        let s = label.trimmingCharacters(in: .whitespaces)
        guard let pattern, let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let numberRange = Range(m.range(at: 1), in: s), let unitRange = Range(m.range(at: 2), in: s),
              let number = Double(s[numberRange]), let unit = multipliers[String(s[unitRange])] else { return nil }
        return Int64((number * unit).rounded())
    }

    /// True when `size` rounds to `label` under the client's rule: within 5 % or within one unit (whichever is larger).
    public static func matches(size: Int64, label: String) -> Bool {
        guard let parsed = bytes(label) else { return false }
        let unitRange = label.uppercased().hasSuffix("K") ? 1024.0 : label.uppercased().hasSuffix("M") ? 1_048_576.0 : label.uppercased().hasSuffix("G") ? 1_073_741_824.0 : 1
        let tolerance = max(Double(parsed) * 0.05, unitRange)
        return abs(Double(size - parsed)) <= tolerance
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FileKindTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ControlCore/Files Tests/ControlCoreTests/FileKindTests.swift
git commit -m "feat(files): extension/signature allowlist, file name sanitiser and size-label parser for message.sendFile"
```

---

### Task 4: `FileFetcher` — https download into the outbox (policy, redirects, size cap, type check) and `ossKey` download

**Files:**
- Create: `Sources/ControlCore/Files/FileFetcher.swift`
- Modify: `Sources/ControlCore/IMCTLPaths.swift` (add `outboxDirectory`)
- Test: `Tests/ControlCoreTests/FileFetcherTests.swift`

**Interfaces:**
- Consumes: `SendFilePolicy.rejection(for:)`, `FileKind`, `FileNames`, `ObjectStore.download(key:to:maxBytes:)`, `ControlError` source cases.
- Produces: `FetchedFile{url: URL, fileName: String, bytes: Int64, kind: String, contentType: String}`; `FileFetcher(outbox: URL)` with `var timeout: TimeInterval = 120`, `var sessionConfiguration: URLSessionConfiguration = .ephemeral`, `func fetch(url: URL, fileName: String?, policy: SendFilePolicy) throws -> FetchedFile`, `func fetch(ossKey: String, fileName: String?, store: ObjectStore, maxBytes: Int64) throws -> FetchedFile`, `func discard(_ file: FetchedFile)`, `func sweep()`; `IMCTLPaths.outboxDirectory`.

- [ ] **Step 1: Write the failing tests**

`Tests/ControlCoreTests/FileFetcherTests.swift`:

```swift
import Foundation
import Testing
@testable import ControlCore

/// Serves scripted responses to the fetcher's URLSession; one static script per test run (tests in this suite are serialized).
final class StubURLProtocol: URLProtocol {
    struct Script { var status: Int; var headers: [String: String]; var body: Data; var redirectTo: URL? }
    nonisolated(unsafe) static var scripts: [String: Script] = [:]
    nonisolated(unsafe) static var requests: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let script = Self.scripts[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        Self.requests.append(url)
        if let target = script.redirectTo {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self); return
        }
        let response = HTTPURLResponse(url: url, statusCode: script.status, httpVersion: nil, headerFields: script.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: script.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("FileFetcher (B13 outbox)", .serialized)
struct FileFetcherTests {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 1, 2, 3, 4])
    static let pdf = Data("%PDF-1.4 tiny".utf8)

    func fetcher() throws -> (FileFetcher, URL) {
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-outbox-\(UUID().uuidString)", isDirectory: true)
        let f = FileFetcher(outbox: outbox)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        f.sessionConfiguration = config
        f.timeout = 5
        StubURLProtocol.scripts = [:]; StubURLProtocol.requests = []
        return (f, outbox)
    }

    var policy: SendFilePolicy { var p = SendFilePolicy(); p.allow("cdn.example"); p.maxBytes = 1000; return p }

    @Test func downloadsIntoAPrivateOutboxAndSniffsTheKind() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/pics/single.png"] = .init(status: 200, headers: ["Content-Length": "20"], body: Self.png, redirectTo: nil)
        let got = try f.fetch(url: URL(string: "https://cdn.example/pics/single.png")!, fileName: nil, policy: policy)
        #expect(got.fileName == "single.png" && got.bytes == 20 && got.kind == "image" && got.contentType == "image/png")
        #expect(got.url.path.hasPrefix(outbox.path) && try Data(contentsOf: got.url) == Self.png)
        let dirMode = try FileManager.default.attributesOfItem(atPath: outbox.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: got.url.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700 && fileMode == 0o600)
        f.discard(got)
        #expect(!FileManager.default.fileExists(atPath: got.url.path))
    }

    @Test func policyRejectsBeforeAnyRequest() throws {
        let (f, _) = try fetcher()
        #expect(throws: ControlError.sourceNotAllowed("host \"other.example\" is not in policy.json sendFile.allowedHosts (imctl policy hosts --allow <host>, or the console's 策略 page)")) {
            try f.fetch(url: URL(string: "https://other.example/a.pdf")!, fileName: nil, policy: policy)
        }
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "http://cdn.example/a.pdf")!, fileName: nil, policy: policy) }
    }

    @Test func redirectOutsideTheAllowlistIsRefusedAndNothingIsKept() throws {
        let (f, outbox) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/a.pdf"] = .init(status: 200, headers: [:], body: Data(), redirectTo: URL(string: "https://evil.example/a.pdf"))
        StubURLProtocol.scripts["https://evil.example/a.pdf"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/a.pdf")!, fileName: nil, policy: policy) }
        #expect(StubURLProtocol.requests.map(\.host) == ["cdn.example"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
    }

    @Test func sizeCapByHeaderAndByStream() throws {
        let (f, _) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/big.pdf"] = .init(status: 200, headers: ["Content-Length": "5000"], body: Data(), redirectTo: nil)
        #expect(throws: ControlError.sourceTooLarge("\"big.pdf\" is 5000 bytes; policy.json sendFile.maxBytes is 1000")) {
            try f.fetch(url: URL(string: "https://cdn.example/big.pdf")!, fileName: nil, policy: policy)
        }
        StubURLProtocol.scripts["https://cdn.example/stream.pdf"] = .init(status: 200, headers: [:], body: Self.pdf + Data(repeating: 0x20, count: 1200), redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/stream.pdf")!, fileName: nil, policy: policy) }
    }

    @Test func typeAndNameRules() throws {
        let (f, _) = try fetcher()
        StubURLProtocol.scripts["https://cdn.example/x.exe"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/x.exe")!, fileName: nil, policy: policy) }
        StubURLProtocol.scripts["https://cdn.example/fake.png"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/fake.png")!, fileName: nil, policy: policy) }
        StubURLProtocol.scripts["https://cdn.example/dl?id=7"] = .init(status: 200, headers: [:], body: Self.pdf, redirectTo: nil)
        let named = try f.fetch(url: URL(string: "https://cdn.example/dl?id=7")!, fileName: "发票.pdf", policy: policy)
        #expect(named.fileName == "发票.pdf" && named.kind == "file" && named.contentType == "application/pdf")
        StubURLProtocol.scripts["https://cdn.example/missing.pdf"] = .init(status: 404, headers: [:], body: Data(), redirectTo: nil)
        #expect(throws: ControlError.self) { try f.fetch(url: URL(string: "https://cdn.example/missing.pdf")!, fileName: nil, policy: policy) }
    }

    @Test func ossKeySourceUsesTheStoreAndSweepClearsLeftovers() throws {
        let (f, outbox) = try fetcher()
        final class Store: ObjectStore {
            var summary = "fake"; var baseDir = "imctl"; var maxUploadBytes: Int64 = 10_000; var viewExpireSeconds = 60
            func exists(key: String) throws -> Bool { true }
            func put(fileURL: URL, key: String, contentType: String) throws {}
            func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL { URL(string: "https://b.example/\(key)")! }
            func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 { try FileFetcherTests.pdf.write(to: destination); return Int64(FileFetcherTests.pdf.count) }
            func delete(key: String) throws {}
        }
        let got = try f.fetch(ossKey: "imctl/2026/09/22/a.pdf", fileName: nil, store: Store(), maxBytes: 1000)
        #expect(got.fileName == "a.pdf" && got.kind == "file" && FileManager.default.fileExists(atPath: got.url.path))
        try Data("stale".utf8).write(to: outbox.appendingPathComponent("stale-old.pdf"))
        f.sweep()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FileFetcherTests`
Expected: compile errors (`FileFetcher`, `FetchedFile` undefined).

- [ ] **Step 3: Implement**

`IMCTLPaths.swift` — add:

```swift
    /// B13: files fetched for `message.sendFile`, owner-only, deleted after every attempt and swept at start.
    public static var outboxDirectory: URL { dataDirectory.appendingPathComponent("outbox", isDirectory: true) }
```

`Sources/ControlCore/Files/FileFetcher.swift`:

```swift
import Foundation

/// A file fetched for `message.sendFile`, sitting in the outbox until the attempt is over.
public struct FetchedFile: Equatable {
    public var url: URL
    public var fileName: String
    public var bytes: Int64
    /// image | video | file
    public var kind: String
    public var contentType: String
    public init(url: URL, fileName: String, bytes: Int64, kind: String, contentType: String) {
        self.url = url; self.fileName = fileName; self.bytes = bytes; self.kind = kind; self.contentType = contentType
    }
}

/// B13: streams an https source (or an OSS object) into the outbox under the policy's host allowlist and byte
/// cap, checking the redirect chain hop by hop and the file head against the extension. Synchronous on purpose
/// (the executor is a serial queue); the session is injectable so tests script responses with a `URLProtocol`.
public final class FileFetcher: NSObject, URLSessionDataDelegate {
    public let outbox: URL
    public var timeout: TimeInterval = 120
    public var sessionConfiguration: URLSessionConfiguration = .ephemeral

    public init(outbox: URL) { self.outbox = outbox }

    // MARK: Sources

    public func fetch(url: URL, fileName: String?, policy: SendFilePolicy) throws -> FetchedFile {
        if let why = policy.rejection(for: url) { throw ControlError.sourceNotAllowed(why) }
        let name = FileNames.sanitize(fileName ?? "", fallback: FileNames.name(from: url))
        guard let info = FileKind.info(forFileName: name) else { throw ControlError.sourceUnsupported(FileKind.rejection(fileName: name, head: []) ?? name) }
        let destination = try prepareDestination(for: url.absoluteString, name: name)
        let job = Job(destination: destination, name: name, maxBytes: policy.maxBytes, policy: policy)
        let session = URLSession(configuration: sessionConfiguration, delegate: job, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        session.dataTask(with: request).resume()
        guard job.done.wait(timeout: .now() + timeout + 5) == .success else {
            job.cancelAndDiscard(); throw ControlError.sourceUnreachable("\"\(name)\": no answer within \(Int(timeout)) s")
        }
        if let error = job.failure { try? FileManager.default.removeItem(at: destination); throw error }
        return try finish(destination: destination, name: name, info: info)
    }

    public func fetch(ossKey: String, fileName: String?, store: ObjectStore, maxBytes: Int64) throws -> FetchedFile {
        let name = FileNames.sanitize(fileName ?? "", fallback: FileNames.sanitize((ossKey as NSString).lastPathComponent, fallback: "file"))
        guard let info = FileKind.info(forFileName: name) else { throw ControlError.sourceUnsupported(FileKind.rejection(fileName: name, head: []) ?? name) }
        let destination = try prepareDestination(for: "oss:" + ossKey, name: name)
        do { _ = try store.download(key: ossKey, to: destination, maxBytes: maxBytes) }
        catch let e as ControlError { try? FileManager.default.removeItem(at: destination); throw e }
        catch { try? FileManager.default.removeItem(at: destination); throw ControlError.sourceUnreachable("ossKey \(ossKey): \(error.localizedDescription)") }
        return try finish(destination: destination, name: name, info: info)
    }

    public func discard(_ file: FetchedFile) { try? FileManager.default.removeItem(at: file.url) }

    /// Daemon start: nothing in the outbox is worth keeping (an attempt that died mid-way is `unknown` anyway).
    public func sweep() {
        for item in (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: Helpers

    private func prepareDestination(for source: String, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outbox.path)
        let stamp = MessageKey.make(conversation: "outbox", sender: nil, timeLabel: nil, text: source, ordinal: 0).prefix(12)
        let destination = outbox.appendingPathComponent("\(stamp)-\(name)")
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return destination
    }

    private func finish(destination: URL, name: String, info: FileKind.Info) throws -> FetchedFile {
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let head = [UInt8]((try? FileHandle(forReadingAtPath: destination.path)?.read(upToCount: 16)) ?? Data())
        if let why = FileKind.rejection(fileName: name, head: head) { try? FileManager.default.removeItem(at: destination); throw ControlError.sourceUnsupported(why) }
        return FetchedFile(url: destination, fileName: name, bytes: size, kind: info.kind, contentType: info.contentType)
    }

    /// One download's delegate: enforces the allowlist on every redirect, the byte cap on the header and on the stream.
    final class Job: NSObject, URLSessionDataDelegate {
        let destination: URL; let name: String; let maxBytes: Int64; let policy: SendFilePolicy
        let done = DispatchSemaphore(value: 0)
        var failure: ControlError?
        private var handle: FileHandle?
        private var received: Int64 = 0

        init(destination: URL, name: String, maxBytes: Int64, policy: SendFilePolicy) {
            self.destination = destination; self.name = name; self.maxBytes = maxBytes; self.policy = policy
            handle = FileHandle(forWritingAtPath: destination.path)
        }

        func cancelAndDiscard() { try? handle?.close(); try? FileManager.default.removeItem(at: destination) }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            if let url = request.url, let why = policy.rejection(for: url) {
                failure = .sourceNotAllowed("redirect refused: " + why); completionHandler(nil); task.cancel(); return
            }
            completionHandler(request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
            guard (200..<300).contains(http.statusCode) else {
                failure = .sourceUnreachable("\"\(name)\": HTTP \(http.statusCode)"); completionHandler(.cancel); return
            }
            if http.expectedContentLength > maxBytes {
                failure = .sourceTooLarge("\"\(name)\" is \(http.expectedContentLength) bytes; policy.json sendFile.maxBytes is \(maxBytes)"); completionHandler(.cancel); return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            received += Int64(data.count)
            if received > maxBytes {
                failure = .sourceTooLarge("\"\(name)\" exceeded policy.json sendFile.maxBytes (\(maxBytes)) while streaming"); dataTask.cancel(); return
            }
            handle?.write(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle?.close()
            if failure == nil, let error, (error as NSError).code != NSURLErrorCancelled {
                failure = .sourceUnreachable("\"\(name)\": \(error.localizedDescription)")
            }
            done.signal()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FileFetcherTests`
Expected: PASS (6 tests). If `willPerformHTTPRedirection` is not delivered by the stub (the URL loading system may follow the redirect itself for `URLProtocol` clients), the redirect test still passes because the second host is refused by `policy.rejection` in the delegate; keep the assertion on `requests.map(\.host) == ["cdn.example"]`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ControlCore/Files/FileFetcher.swift Sources/ControlCore/IMCTLPaths.swift Tests/ControlCoreTests/FileFetcherTests.swift
git commit -m "feat(files): FileFetcher — https download into the 0700 outbox under the host allowlist and byte cap, hop-by-hop redirect check, head/extension check; ossKey download through ObjectStore"
```

---

### Task 5: ⌘V in `KeystrokeInjector`, pasteboard abstraction, `WeComActions.pasteboard` / `pasteTimeout`

**Files:**
- Modify: `Sources/WeComAdapter/Actions/KeystrokeInjector.swift`
- Create: `Sources/WeComAdapter/Actions/Pasteboard.swift`
- Modify: `Sources/WeComAdapter/Actions/WeComActions.swift`
- Test: `Tests/WeComAdapterTests/ContactsNavigationTests.swift` (the existing `Shortcut` test), `Tests/WeComAdapterTests/SendFileTests.swift` (created here with the pasteboard recorder, filled in Task 7)

**Interfaces:**
- Produces: `KeystrokeInjector.Shortcut.commandV` (keyCode 9, flags `[.maskCommand]`); `protocol PasteboardHandling { func snapshot() -> [[String: Data]]; func setFileURL(_ url: URL); func restore(_ snapshot: [[String: Data]]) }`; `GeneralPasteboard: PasteboardHandling` (NSPasteboard.general); `WeComActions.pasteboard: PasteboardHandling` (default `GeneralPasteboard()`), `WeComActions.pasteTimeout: TimeInterval` (default 3).

- [ ] **Step 1: Write the failing tests**

In `Tests/WeComAdapterTests/ContactsNavigationTests.swift`, next to the existing `#expect(KeystrokeInjector.Shortcut.commandDigit(8).keyCode == 28 …)` lines add:

```swift
        // B13 (user 2026-09-22 17:43): ⌘V pastes the outbox file URL into the composer; the only key added since 1.0.0.
        #expect(KeystrokeInjector.Shortcut.commandV.keyCode == 9 && KeystrokeInjector.Shortcut.commandV.flags == [.maskCommand])
```

Create `Tests/WeComAdapterTests/SendFileTests.swift` with the recorder only (the suite body is added in Task 7):

```swift
import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// Records what the send-file action does to the clipboard instead of touching NSPasteboard.
final class RecordingPasteboard: PasteboardHandling {
    var snapshots = 0
    var restored: [[[String: Data]]] = []
    var fileURLs: [URL] = []
    var contents: [[String: Data]] = [["public.utf8-plain-text": Data("the person's clipboard".utf8)]]
    func snapshot() -> [[String: Data]] { snapshots += 1; return contents }
    func setFileURL(_ url: URL) { fileURLs.append(url); contents = [["public.file-url": Data(url.absoluteString.utf8)]] }
    func restore(_ snapshot: [[String: Data]]) { restored.append(snapshot); contents = snapshot }
}

@Suite("Pasteboard abstraction")
struct PasteboardTests {
    @Test func actionsDefaultToTheGeneralPasteboardAndAThreeSecondPasteTimeout() {
        let a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"]))
        #expect(a.pasteboard is GeneralPasteboard && a.pasteTimeout == 3)
        let recorder = RecordingPasteboard()
        let snap = recorder.snapshot()
        recorder.setFileURL(URL(fileURLWithPath: "/tmp/x.pdf"))
        recorder.restore(snap)
        #expect(recorder.contents == snap && recorder.fileURLs.count == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "ContactsNavigationTests|PasteboardTests"`
Expected: compile errors (`commandV`, `PasteboardHandling`, `pasteboard`, `pasteTimeout` undefined).

- [ ] **Step 3: Implement**

`KeystrokeInjector.swift`: extend the file comment with `… plus ⌘V (user decision 2026-09-22 17:43: paste the outbox file URL into the composer for message.sendFile; B13).` and the `Shortcut` enum:

```swift
        /// ⌘V = paste the file URL the daemon put on the pasteboard (message.sendFile; user-approved 2026-09-22 17:43). Never text, never ⌘C / ⌘X.
        case commandV
```

`keyCode`: `case .commandV: return 9` (kVK_ANSI_V); `flags`: add `.commandV` to the `[.maskCommand]` case (`case .commandDigit, .commandN, .commandV: return [.maskCommand]`). The doc comment above `Shortcut` becomes `Keys approved on 2026-09-15 … and ⌘V (2026-09-22). Nothing else.`

`Sources/WeComAdapter/Actions/Pasteboard.swift`:

```swift
import AppKit
import Foundation

/// The clipboard as the file paste needs it: snapshot the person's items, put one file URL on it, put the
/// snapshot back once the client took the paste. Behind a protocol so unit tests record instead of touching
/// `NSPasteboard.general`. Known side effect (docs/ops/permissions.md): a copy the person makes during the
/// few hundred milliseconds between snapshot and restore is overwritten.
public protocol PasteboardHandling {
    func snapshot() -> [[String: Data]]
    func setFileURL(_ url: URL)
    func restore(_ snapshot: [[String: Data]])
}

public final class GeneralPasteboard: PasteboardHandling {
    public init() {}

    public func snapshot() -> [[String: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var out: [String: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type.rawValue] = data } }
            return out
        }
    }

    public func setFileURL(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    public func restore(_ snapshot: [[String: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
```

`WeComActions.swift`: after `postShortcut` add

```swift
    /// B13: the clipboard used to paste a fetched file (`message.sendFile`); snapshot → file URL → ⌘V → restore. Replaced in tests.
    public var pasteboard: PasteboardHandling = GeneralPasteboard()
    /// How long the pasted attachment may take to show up in the composer before the attempt is abandoned without a Return.
    public var pasteTimeout: TimeInterval = 3
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "ContactsNavigationTests|PasteboardTests|ForbiddenAPITests"`
Expected: PASS — `ForbiddenAPITests` still passes because ⌘V is posted through the existing `postShortcut` in the exception file only.

- [ ] **Step 5: Commit**

```bash
git add Sources/WeComAdapter/Actions/KeystrokeInjector.swift Sources/WeComAdapter/Actions/Pasteboard.swift Sources/WeComAdapter/Actions/WeComActions.swift Tests/WeComAdapterTests/ContactsNavigationTests.swift Tests/WeComAdapterTests/SendFileTests.swift
git commit -m "feat(input): ⌘V approved 2026-09-22 for message.sendFile (KeystrokeInjector.Shortcut.commandV); pasteboard snapshot/restore behind PasteboardHandling"
```

---

### Task 6: `file` / `video` rows — parser, fixture, keys, history fields, watcher payloads, origin attribution, `recentSends`

**Files:**
- Modify: `Sources/WeComAdapter/MessageRow.swift` (enum + fields + parser), `Sources/WeComAdapter/WeComReader.swift:56-62` (`chatMessages`)
- Modify: `Sources/WeComAdapter/Watch/WatchSnapshot.swift`, `Watch/WatchDiff.swift:52`, `Watch/WatchEngine.swift:127-143`, `Watch/OriginClassifier.swift`
- Modify: `Sources/ControlCore/Store/ControlStore.swift:155-176` (`recentSends`), `Sources/imctld/DaemonWatcher.swift:110`
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift:131-142` (`messageHistory`)
- Modify: `docs/protocol/im-control-protocol.md` §6.6, §7.4
- Create: `Tests/Fixtures/ax-trees/wecom-5.0.11-file-video-rows.json`, `Tests/WeComAdapterTests/FileVideoRowTests.swift`
- Test: `Tests/WeComAdapterTests/OriginClassifierTests.swift`, `Tests/ControlCoreTests/ControlStoreTests.swift`

**Interfaces:**
- Produces: `MessageRowKind.file`, `.video`; `MessageRow.fileName / fileSize / fileType / duration: String?`; `WatchSnapshot.Message.fileName / fileSize / fileType / duration`; `OriginClassifier.classify(direction:text:conversation:sends:kind:fileName:)` (kind default `"message"`, fileName default nil); `ControlStore.recentSends` includes `message.sendFile` records as `ControllerSend(kind: "file", fileName:)`; `message.history` / `message.observed` rows carry `fileName fileSize fileType duration` and `media` status for file / video rows.

- [ ] **Step 1: Write the failing tests**

Create `Tests/Fixtures/ax-trees/wecom-5.0.11-file-video-rows.json` — a synthetic message table in the exact shape recorded 2026-09-22 (5.0.11, macOS 27.0; neutral names, no real content). Every node needs `actions`, `settable`, `extra`, `children`, `truncated`:

```json
{"role":"AXTable","frame":{"x":311,"y":0,"width":1609,"height":1000},"actions":[],"settable":["AXSelectedRows"],"extra":{},"truncated":false,"children":[
 {"role":"AXRow","subrole":"AXTableRow","frame":{"x":311,"y":28,"width":1609,"height":84},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
  {"role":"AXCell","frame":{"x":311,"y":28,"width":1609,"height":84},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
   {"role":"AXStaticText","value":{"string":"17:03"},"frame":{"x":1099,"y":35,"width":33,"height":18},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXTextArea","value":{"string":"hello from the controller"},"frame":{"x":1651,"y":75,"width":243,"height":22},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]}]}]},
 {"role":"AXRow","subrole":"AXTableRow","frame":{"x":311,"y":112,"width":1609,"height":368},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
  {"role":"AXCell","frame":{"x":311,"y":112,"width":1609,"height":368},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
   {"role":"AXStaticText","value":{"string":"17:38"},"frame":{"x":1099,"y":119,"width":33,"height":18},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXImage","description":"wwsecurity play action play 40","frame":{"x":1792,"y":291,"width":42,"height":42},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXStaticText","value":{"string":"01:14"},"frame":{"x":1863,"y":447,"width":32,"height":18},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]}]}]},
 {"role":"AXRow","subrole":"AXTableRow","frame":{"x":311,"y":480,"width":1609,"height":82},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
  {"role":"AXCell","frame":{"x":311,"y":480,"width":1609,"height":82},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
   {"role":"AXImage","description":"file word emphasized","frame":{"x":1851,"y":499,"width":42,"height":42},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXStaticText","value":{"string":"report.docx"},"frame":{"x":1657,"y":499,"width":169,"height":20},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXStaticText","value":{"string":"14K"},"frame":{"x":1657,"y":525,"width":24,"height":18},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]}]}]},
 {"role":"AXRow","subrole":"AXTableRow","frame":{"x":311,"y":562,"width":1609,"height":82},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
  {"role":"AXCell","frame":{"x":311,"y":562,"width":1609,"height":82},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
   {"role":"AXImage","description":"file pdf emphasized","frame":{"x":390,"y":581,"width":42,"height":42},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXStaticText","value":{"string":"invoice.pdf"},"frame":{"x":445,"y":581,"width":142,"height":20},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]},
   {"role":"AXStaticText","value":{"string":"74K"},"frame":{"x":445,"y":607,"width":24,"height":18},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]}]}]},
 {"role":"AXRow","subrole":"AXTableRow","frame":{"x":311,"y":644,"width":1609,"height":356},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[
  {"role":"AXCell","frame":{"x":311,"y":644,"width":1609,"height":356},"actions":[],"settable":[],"extra":{},"truncated":false,"children":[]}]}
]}
```

(The pdf row is drawn at the left edge so an inbound file row is covered too.)

`Tests/WeComAdapterTests/FileVideoRowTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// Live 2026-09-22 (5.0.11, macOS 27.0, 文件传输助手): a text row, an outbound video (play icon + duration), an
/// outbound docx and an inbound pdf (file icon + name + size), and a picture row whose cell has no children.
@Suite("File / video rows (B13)")
struct FileVideoRowTests {
    func rows() throws -> [MessageRow] {
        let table = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-file-video-rows.json"))
        let fake = FakeAXBackend(root: table)
        return try MessageRowParser().parse(table: fake.rootElement, tableFrame: table.frame?.cgRect ?? .zero)
    }

    @Test func kindsFieldsAndDirections() throws {
        let r = try rows()
        #expect(r.map(\.kind) == [.message, .video, .file, .file, .media])
        #expect(r[1].timeLabel == "17:38" && r[1].duration == "01:14" && r[1].text == nil && r[1].direction == .outbound)
        #expect(r[2].fileName == "report.docx" && r[2].fileSize == "14K" && r[2].fileType == "word" && r[2].text == nil && r[2].direction == .outbound)
        #expect(r[3].fileName == "invoice.pdf" && r[3].fileSize == "74K" && r[3].fileType == "pdf" && r[3].direction == .inbound)
        #expect(r[4].text == nil && r[4].timeLabel == nil && r[4].direction == .unknown)
    }

    @Test func aVideoWithoutItsOwnTimeLabelKeepsTheDurationOutOfTimeLabel() throws {
        let table = AXNode(role: AXRole.table, frame: CGRect(x: 311, y: 0, width: 1609, height: 600), children: [
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 0, width: 1609, height: 360), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 0, width: 1609, height: 360), children: [
                    AXNode(role: AXRole.image, description: "wwsecurity play action play 40", frame: CGRect(x: 400, y: 150, width: 42, height: 42)),
                    AXNode(role: AXRole.staticText, value: .string("00:07"), frame: CGRect(x: 640, y: 320, width: 32, height: 18)),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: table)
        let r = try MessageRowParser().parse(table: fake.rootElement, tableFrame: table.frame?.cgRect ?? .zero)
        #expect(r.count == 1 && r[0].kind == .video && r[0].timeLabel == nil && r[0].duration == "00:07" && r[0].direction == .inbound)
    }

    @Test func keysUseTheFileNameAndHistoryCarriesTheFields() throws {
        let window = GroupFixture.window(messages: [
            GroupFixture.timeRow(y: 64, "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                    AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: 113, width: 42, height: 42)),
                    GroupFixture.text("invoice.pdf", x: 1657, y: 113, w: 142, h: 20),
                    GroupFixture.text("74K", x: 1657, y: 139, w: 24),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: window)
        let reader = try WeComReader(window: fake.rootElement)
        let chat = try reader.chatMessages()
        #expect(chat.count == 1 && chat[0].kind == .file && chat[0].messageKey == MessageKey.make(conversation: GroupFixture.groupTitle, sender: nil, timeLabel: nil, text: "invoice.pdf", ordinal: 0))
        let snapshot = try WatchSnapshot.take(reader)
        #expect(snapshot.messages.first?.fileName == "invoice.pdf" && snapshot.messages.first?.fileSize == "74K" && snapshot.messages.first?.kind == "file")
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-fv-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation], phase: .phase1), checkpoints: cps)
        let hist = try h.messageHistory(limit: 10, scrollback: false)
        #expect(hist.count == 1 && hist[0]["kind"] == "file" && hist[0]["fileName"] == "invoice.pdf" && hist[0]["fileSize"] == "74K" && hist[0]["fileType"] == "pdf" && hist[0]["text"] == nil && hist[0]["media"] == "unmatched")
    }
}
```

`Tests/WeComAdapterTests/OriginClassifierTests.swift` — add:

```swift
    /// B13: a pasted picture / file / video has no text to compare; the oldest unconsumed file send to that conversation is ours.
    @Test func fileSendsAttributeMediaAndFileRowsWithoutText() {
        var c = OriginClassifier()
        let sends = [ControllerSend(commandId: "f1", target: "文件传输助手", text: "", tsMs: 1, kind: "file", fileName: "a.pdf"),
                     ControllerSend(commandId: "f2", target: "文件传输助手", text: "", tsMs: 2, kind: "file", fileName: nil),
                     ControllerSend(commandId: "t1", target: "文件传输助手", text: "hi", tsMs: 3)]
        #expect(c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "file", fileName: "b.pdf").origin == .other)
        let file = c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "file", fileName: "a.pdf")
        #expect(file.origin == .controller && file.commandId == "f1")
        let picture = c.classify(direction: .unknown, text: nil, conversation: "文件传输助手", sends: sends, kind: "media")
        #expect(picture.origin == .controller && picture.commandId == "f2")
        #expect(c.classify(direction: .outbound, text: nil, conversation: "文件传输助手", sends: sends, kind: "video").origin == .other)
        #expect(c.classify(direction: .outbound, text: "hi", conversation: "文件传输助手", sends: sends).commandId == "t1")
    }
```

`Tests/ControlCoreTests/ControlStoreTests.swift` — add:

```swift
    @Test func recentSendsIncludeFileSendsWithTheirName() throws {
        let store = try ControlStore(path: ":memory:")
        let params = #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}"#
        let record = CommandRecord(method: .messageSendFile, paramsJSON: params, idempotencyKey: "f1", nowMs: 10)
        #expect(try store.insertCommand(record))
        try store.updateCommand(id: record.id, state: .succeeded, nowMs: 20, resultJSON: #"{"state":"succeeded","fileName":"a.pdf","bytes":3,"contentType":"application/pdf","kind":"file"}"#, errorCode: nil, errorMessage: nil)
        let sends = try store.recentSends(sinceMs: 0)
        #expect(sends.count == 1 && sends[0].kind == "file" && sends[0].fileName == "a.pdf" && sends[0].target == "文件传输助手" && sends[0].commandId == record.id)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "FileVideoRowTests|OriginClassifierTests|ControlStoreTests"`
Expected: compile errors (`.video`, `fileName`, `kind:` argument) / assertion failures.

- [ ] **Step 3: Implement**

`MessageRow.swift` — enum and struct:

```swift
public enum MessageRowKind: String, Codable {
    case message
    /// A bubble without accessible text — picture, sticker, card: the row's cell has no text children (live 2026-09-15, 5.0.11: a 246 px row).
    case media
    /// A file card (live 2026-09-22, 5.0.11): an `AXImage` described `file <type> emphasized`, the file name and a size label ("74K"), 82 px.
    case file
    /// A native video (live 2026-09-22): an `AXImage` described `… play action play …` and a duration label ("01:14"), ≥ 300 px.
    case video
    case system
    case timeSeparator
    case empty
}
```

Add to `MessageRow` after `senderLabel`:

```swift
    /// file rows: the name and size label the client shows, and the icon's type word (pdf, word, excel, ppt, zip, …).
    public var fileName: String? = nil
    public var fileSize: String? = nil
    public var fileType: String? = nil
    /// video rows: the duration label ("01:14").
    public var duration: String? = nil
```

Replace `MessageRowParser.parse` body (keep `senderName(from:)` and `isCentered`):

```swift
    static let durationPattern = try? NSRegularExpression(pattern: "^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$")
    static func isDuration(_ s: String) -> Bool { durationPattern.map { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } ?? false }
    static func isPlayIcon(_ description: String) -> Bool { description.contains("play action play") }
    /// "file pdf emphasized" → "pdf".
    static func fileType(from description: String) -> String? {
        let parts = description.split(separator: " ")
        guard parts.count >= 2, parts[0] == "file" else { return nil }
        return String(parts[1])
    }

    public func parse(table: AXElement, tableFrame: CGRect, images: [CGRect] = []) throws -> [MessageRow] {
        var rows: [MessageRow] = []
        for (index, row) in try table.children().enumerated() {
            guard try row.role() == AXRole.row else { continue }
            let frame = try row.frame() ?? .zero
            let cell = try row.children().first { try $0.role() == AXRole.cell } ?? row
            var statics: [(String, CGRect)] = []
            var labels: [(String, CGRect)] = []   // clickable sender names (external groups render them as buttons, live 2026-09-15)
            var icons: [(String, CGRect)] = []    // described AXImage children: file icons, the video play button (live 2026-09-22)
            var body: (String, CGRect)?
            for child in try cell.children() {
                let f = try child.frame() ?? .zero
                switch try child.role() {
                case AXRole.textArea:
                    if body == nil { body = (try child.valueString() ?? "", f) }
                case AXRole.staticText:
                    if let v = try child.valueString() { statics.append((v, f)) }
                case AXRole.button:
                    if let t = try child.title(), !t.isEmpty { labels.append((t, f)) }
                case AXRole.image:
                    if let d = try child.axDescription(), !d.isEmpty { icons.append((d, f)) }
                default:
                    continue
                }
            }
            let playIcon = icons.first { Self.isPlayIcon($0.0) }
            let fileIcon = icons.first { Self.fileType(from: $0.0) != nil }
            // A video's duration looks like a time label; the row's own label is the centered one.
            let timeLike = statics.filter { TimeLabel.matches($0.0) }
            let time = timeLike.first { isCentered($0.1, in: tableFrame) } ?? (playIcon == nil ? timeLike.first : nil)
            let nonTime = statics.filter { !TimeLabel.matches($0.0) }
            var kind = MessageRowKind.message
            var anchor: CGRect? = body?.1
            var fileName: String?, fileSize: String?, fileType: String?, duration: String?
            if let playIcon {
                kind = .video
                anchor = playIcon.1
                duration = timeLike.first { !isCentered($0.1, in: tableFrame) && Self.isDuration($0.0) }?.0
                body = nil
            } else if let fileIcon, let name = nonTime.first(where: { FileSizeLabel.bytes($0.0) == nil }) {
                kind = .file
                anchor = name.1
                fileName = name.0
                fileSize = nonTime.first { FileSizeLabel.bytes($0.0) != nil }?.0
                fileType = Self.fileType(from: fileIcon.0)
                body = nil
            } else if let b = body {
                // A centered, short text area is a notice the client renders as a text area (live 2026-09-15: 以上是打招呼的内容 …).
                if isCentered(b.1, in: tableFrame), b.1.width <= tableFrame.width * noticeMaxWidthFraction { kind = .system }
            } else if let first = nonTime.first {
                body = first
                anchor = first.1
                if isCentered(first.1, in: tableFrame) { kind = .system }
            } else if frame.height >= mediaRowMinHeight {
                // A tall row with no text is a picture / sticker; the first one after a time gap carries
                // its own time label in the same row (live 2026-09-16: a 388 px row whose only child was "11:01").
                kind = .media
            } else {
                kind = time == nil ? .empty : .timeSeparator
            }
            if kind == .media {
                anchor = images.filter { $0.minY < frame.maxY && $0.maxY > frame.minY }.max { $0.width * $0.height < $1.width * $1.height }
            }
            // Sender = a static text above the bubble, or a button above it that starts no further right than the bubble
            // (the clickable "名字@微信" of an external group); the WeChat tag is not part of the name.
            let sender = [MessageRowKind.message, .file, .video].contains(kind) ? anchor.flatMap { a in
                nonTime.first { $0.1.maxY <= a.minY && $0.1 != a && $0.0 != fileName } ?? labels.first { $0.1.maxY <= a.minY && $0.1.minX <= a.minX + 20 }
            }.map { Self.senderName(from: $0.0) } : nil
            let directed = [MessageRowKind.message, .media, .file, .video].contains(kind)
            rows.append(MessageRow(
                index: index, kind: kind, text: body?.0, timeLabel: time?.0, bodyFrame: anchor,
                direction: directed ? (anchor.map { direction.infer(body: $0, container: tableFrame) } ?? .unknown) : .unknown,
                senderLabel: sender, frame: frame, handle: row.handle,
                fileName: fileName, fileSize: fileSize, fileType: fileType, duration: duration
            ))
        }
        return rows
    }
```

`MessageRow.swift` needs `import Foundation` for `NSRegularExpression`. `WeComReader.chatMessages`:

```swift
        var rows = try messages().filter { [.message, .media, .file, .video].contains($0.kind) }
        let keys = MessageKey.assign(rows, conversation: conversation, sender: \.senderLabel, timeLabel: \.timeLabel, text: { $0.text ?? $0.fileName ?? "" })
```

`WatchSnapshot.Message`: add `public var fileName: String? = nil`, `fileSize`, `fileType`, `duration` (all `String? = nil`) and fill them in `take` (`fileName: $0.fileName, fileSize: $0.fileSize, fileType: $0.fileType, duration: $0.duration`). `WatchDiff.prependedCount`'s `same`: `a.text == b.text && a.direction == b.direction && a.fileName == b.fileName`.

`OriginClassifier.classify`:

```swift
    public mutating func classify(direction: MessageDirection, text: String?, conversation: String?, sends: [ControllerSend],
                                  kind: String = "message", fileName: String? = nil) -> (origin: MessageOrigin, commandId: String?) {
        if direction == .inbound { return (.peer, nil) }
        let sameConversation: (ControllerSend) -> Bool = { send in
            guard let conversation, !conversation.isEmpty else { return true }
            return send.target == conversation
        }
        let candidates = sends.sorted { $0.tsMs < $1.tsMs }.filter { !consumed.contains($0.commandId) && sameConversation($0) }
        let match: ControllerSend?
        if kind == "message" {
            guard let text, !text.isEmpty else { return direction == .outbound ? (.other, nil) : (.unknown, nil) }
            match = candidates.first { $0.kind == "text" && $0.text == text }
        } else {
            // B13: a pasted picture / file / video carries no text; a file row must also show the name we sent.
            match = candidates.first { $0.kind == "file" && (fileName == nil || $0.fileName == fileName) }
        }
        if let match {
            consumed.insert(match.commandId)
            return (.controller, match.commandId)
        }
        return direction == .outbound ? (.other, nil) : (.unknown, nil)
    }
```

`WatchEngine.draft` `.messageAdded` branch: call `classifier.classify(direction: …, text: message?.text, conversation: snapshot.active, sends: sends, kind: message?.kind ?? "message", fileName: message?.fileName)` and after the `sender` line add:

```swift
            if let v = message?.fileName { payload["fileName"] = v }
            if let v = message?.fileSize { payload["fileSize"] = v }
            if let v = message?.fileType { payload["fileType"] = v }
            if let v = message?.duration { payload["duration"] = v }
```

`ControlStore.recentSends`: change the method filter to `[RPCMethod.messageSend.rawValue, RPCMethod.messageSendFile.rawValue].contains(Column("method"))` and the mapping to:

```swift
        return records.compactMap { record in
            if record.method == RPCMethod.messageSendFile.rawValue {
                guard let params = try? JSONDecoder().decode(SendFileParams.self, from: Data(record.paramsJSON.utf8)) else { return nil }
                let result = record.resultJSON.flatMap { try? JSONDecoder().decode(SendFileResult.self, from: Data($0.utf8)) }
                let name = result?.fileName ?? params.fileName ?? params.url.flatMap { URL(string: $0) }.map(FileNames.name(from:))
                return ControllerSend(commandId: record.id, target: conversationTitle(for: params.target), text: "", tsMs: record.updatedMs, kind: "file", fileName: name)
            }
            guard let params = try? JSONDecoder().decode(SendParams.self, from: Data(record.paramsJSON.utf8)) else { return nil }
            return ControllerSend(commandId: record.id, target: conversationTitle(for: params.target), text: params.text, tsMs: record.updatedMs)
        }
```

`DaemonWatcher.poll`: the media-index line becomes `if draft.kind == .messageObserved, [MessageRowKind.media.rawValue, MessageRowKind.file.rawValue, MessageRowKind.video.rawValue].contains(draft.payload["kind"] ?? ""), let key = draft.payload["messageKey"] { … }`.

`WeComCommandHandler.messageHistory` row mapping — after the sender line:

```swift
                if let v = m.fileName { d["fileName"] = v }
                if let v = m.fileSize { d["fileSize"] = v }
                if let v = m.fileType { d["fileType"] = v }
                if let v = m.duration { d["duration"] = v }
                if let v = m.messageKey {
                    d["messageKey"] = v
                    if [.media, .file, .video].contains(m.kind) { d["media"] = mediaIndex.assignment(for: v) != nil ? "assigned" : (mediaIndex.observation(for: v) != nil ? "observed" : "unmatched") }
                }
```

Protocol doc §6.6: `kind:"message"|"media"|"file"|"video"`, add `fileName? fileSize? fileType? duration?` to the row shape, and a sentence: `file = 文件卡片（图标描述 file <类型> emphasized + 文件名 + 大小，活体 2026-09-22 高 82 px；text 省略，fileName / fileSize / fileType 给出）；video = 原生视频（播放键 + 时长，高 ≥ 300 px；duration 给出）；图片行无子元素时方向为 unknown（客户端限制）。media / file / video 行都带 media: assigned|observed|unmatched`. §7.4 `message.observed`: add the same optional fields and `kind` values.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "FileVideoRowTests|OriginClassifierTests|ControlStoreTests|MessageRowParserTests|WatchDiffTests|WatchEngineTests|WeComCommandHandlerTests|ProtocolDocTests"`
Expected: PASS; the pre-existing parser / watcher suites are unchanged in behaviour (a tall text-less row is still `media`, centered text areas are still `system`).

- [ ] **Step 5: Commit**

```bash
git add Sources/WeComAdapter Sources/ControlCore/Store/ControlStore.swift Sources/imctld/DaemonWatcher.swift Tests/Fixtures/ax-trees/wecom-5.0.11-file-video-rows.json Tests/WeComAdapterTests Tests/ControlCoreTests/ControlStoreTests.swift docs/protocol/im-control-protocol.md
git commit -m "feat(rows): file / video message rows (name, size, type, duration) in history and message.observed; keys by file name; file sends attribute pasted rows as origin controller"
```

---

### Task 7: `WeComActions.sendFile` — paste, confirm, checkpoint, Return, evidence

**Files:**
- Create: `Sources/WeComAdapter/Actions/SendFile.swift`
- Test: `Tests/WeComAdapterTests/SendFileTests.swift` (suite body; the recorder exists since Task 5)

**Interfaces:**
- Consumes: `FetchedFile`, `KeystrokeInjector.Shortcut.commandV`, `PasteboardHandling`, `WeComActions.withFront(app:pid:_:)` (Contacts.swift:67), `postReturnKey`, `setComposer`, `waitUntil`, `SubmitCheckpoint`, `SubmitHooks`, `SubmitOutcome`, `ActionKind.sendFile`.
- Produces: `WeComActions.sendFile(_ file: FetchedFile, reader: WeComReader, checkpoints: CheckpointStore, timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.2, hooks: SubmitHooks = SubmitHooks()) throws -> SubmitOutcome` with `strategy == "paste-enter"`; a paste that never lands returns `state: .failed` with `details["pasteFailed"] == "true"` and no Return posted; `composerSignal(_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/WeComAdapterTests/SendFileTests.swift`:

```swift
@Suite("WeComActions.sendFile on the group fixture")
struct SendFileTests {
    let composerPath = [0, 2, 2, 0]
    let tablePath = GroupFixture.messageTablePath

    struct Harness {
        let fake: FakeAXBackend
        let reader: WeComReader
        let checkpoints: FileCheckpointStore
        let pasteboard: RecordingPasteboard
        var actions: WeComActions
        var shortcuts: [KeystrokeInjector.Shortcut] = []
        var returns = 0
    }

    func harness(landPaste: Bool, appendRow: Bool, rowKind: String = "media") throws -> Harness {
        let fake = GroupFixture.backend()
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-sendfile-\(UUID().uuidString)"))
        let pb = RecordingPasteboard()
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.sendFile, .clearComposer], phase: .phase1), verifyTimeout: 0.3, verifyInterval: 0.02)
        a.pasteboard = pb
        a.pasteTimeout = 0.3
        a.frontmostPid = { 4242 }          // the fake's pid: nothing to bring to front or hand back
        a.restoreFrontmost = { _ in }
        let composer = try #require(fake.handle(atPath: composerPath))
        let table = try #require(fake.handle(atPath: tablePath))
        let box = Box()
        a.postShortcut = { key, _ in
            box.shortcuts.append(key)
            if landPaste { fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("1")) }
        }
        a.postReturnKey = { _, _ in
            box.returns += 1
            fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("0"))
            guard appendRow else { return }
            var rows = GroupFixture.defaultMessages()
            let y: CGFloat = 454
            let cellChildren: [AXNode] = rowKind == "file"
                ? [AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: y + 19, width: 42, height: 42)),
                   GroupFixture.text("a.pdf", x: 1657, y: y + 19, w: 100, h: 20), GroupFixture.text("3B", x: 1657, y: y + 45, w: 24)]
                : []
            rows.append(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: rowKind == "file" ? 82 : 200), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: rowKind == "file" ? 82 : 200), children: cellChildren),
            ]))
            fake.replaceChildren(of: table, with: rows + [AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: 1609, height: 931))])
        }
        var h = Harness(fake: fake, reader: reader, checkpoints: cps, pasteboard: pb, actions: a)
        h.box = box
        return h
    }

    final class Box { var shortcuts: [KeystrokeInjector.Shortcut] = []; var returns = 0 }

    func file(_ name: String = "a.pdf", kind: String = "file") throws -> FetchedFile {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-sf-\(UUID().uuidString)-\(name)")
        try Data("%PDF-1.4".utf8).write(to: url)
        return FetchedFile(url: url, fileName: name, bytes: 8, kind: kind, contentType: "application/pdf")
    }

    @Test func pasteThenReturnProducesANewFileRowAndRestoresTheClipboard() throws {
        var h = try harness(landPaste: true, appendRow: true, rowKind: "file")
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .succeeded && out.strategy == "paste-enter")
        #expect(out.evidence?.contains("kind=file") == true && out.evidence?.contains("dir=outbound") == true)
        #expect(h.box.shortcuts == [.commandV] && h.box.returns == 1)
        #expect(h.pasteboard.snapshots == 1 && h.pasteboard.fileURLs.count == 1 && h.pasteboard.restored.count == 1)
        #expect(h.pasteboard.contents == [["public.utf8-plain-text": Data("the person's clipboard".utf8)]])
        #expect(try h.checkpoints.load(id: out.checkpointID)?.state == .succeeded)
        #expect(out.details["pasteFailed"] == nil && out.details["fileName"] == "a.pdf")
    }

    @Test func aPictureRowIsEvidenceToo() throws {
        var h = try harness(landPaste: true, appendRow: true, rowKind: "media")
        let out = try h.actions.sendFile(try file("p.png", kind: "image"), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .succeeded && out.evidence?.contains("kind=media") == true)
    }

    @Test func pasteThatNeverLandsFailsWithoutAReturnAndClearsTheComposer() throws {
        var h = try harness(landPaste: false, appendRow: true)
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .failed && out.details["pasteFailed"] == "true" && out.reason?.contains("did not appear") == true)
        #expect(h.box.shortcuts == [.commandV] && h.box.returns == 0)
        #expect(h.pasteboard.restored.count == 1)
        #expect(try h.checkpoints.pending().isEmpty)
        #expect(h.fake.recordedSets.contains { $0.attribute == AXAttribute.value && $0.value == .string("") })
    }

    @Test func noRowWithinTimeoutIsFailedWhenTheComposerStillHoldsTheAttachmentElseUnknown() throws {
        var h = try harness(landPaste: true, appendRow: false)
        let composer = try #require(h.fake.handle(atPath: composerPath))
        // Return does not empty the composer in this variant: the chip is still there.
        h.actions.postReturnKey = { _, _ in }
        let stuck = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 0.2, pollInterval: 0.02)
        #expect(stuck.state == .failed && stuck.reason?.contains("still holds") == true)
        #expect(try h.checkpoints.load(id: stuck.checkpointID)?.state == .failed)
        // Composer emptied, no row: unknown, left alone.
        var h2 = try harness(landPaste: true, appendRow: false)
        h2.actions.postReturnKey = { _, _ in h2.fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("0")) }
        _ = composer
        let gone = try h2.actions.sendFile(try file(), reader: h2.reader, checkpoints: h2.checkpoints, timeout: 0.2, pollInterval: 0.02)
        #expect(gone.state == .unknown && (try h2.checkpoints.load(id: gone.checkpointID))?.state == .unknown)
    }

    @Test func guardsBeforeAnythingIsPasted() throws {
        var h = try harness(landPaste: true, appendRow: true)
        let composer = try #require(h.fake.handle(atPath: composerPath))
        h.fake.mutate(composer, attribute: AXAttribute.value, to: .string("human draft"))
        #expect(throws: ActionError.localGuard("composer not empty")) { try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints) }
        #expect(h.pasteboard.snapshots == 0 && h.box.shortcuts.isEmpty)
        var phase0 = try harness(landPaste: true, appendRow: true)
        phase0.actions.policy.phase = .phase0
        #expect(throws: PolicyError.phaseForbids(.sendFile)) { try phase0.actions.sendFile(try file(), reader: phase0.reader, checkpoints: phase0.checkpoints) }
    }
}
```

Add `var box = Box()` to `Harness` (declared with the other stored properties) so the closures and the assertions share one recorder.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SendFileTests`
Expected: compile error `value of type 'WeComActions' has no member 'sendFile'`.

- [ ] **Step 3: Implement**

`Sources/WeComAdapter/Actions/SendFile.swift`:

```swift
import AXKit
import ControlCore
import Foundation

/// B13: paste a fetched file into the composer (⌘V to the client's pid — the key the user approved
/// 2026-09-22 17:43) and send it with the same Return as text. Evidence = a new outbound `media` / `file` /
/// `video` row. Live 2026-09-22 (5.0.11, macOS 27.0): a pasted file URL becomes an inline picture, a
/// "name · size" chip (pdf / docx) or a "视频 · size" chip (mp4, sent as a native video); no dialog appears.
extension WeComActions {
    static let pasteStrategy = "paste-enter"

    /// Composer state as one comparable string: value length / AXNumberOfCharacters / child count. A pasted
    /// attachment changes at least one of them (calibration item §11.1 of the B13 spec; the fake changes the
    /// character count).
    func composerSignal(_ composer: AXElement) -> String {
        let value = (try? composer.valueString())?.count ?? 0
        let chars = (try? composer.string(AXAttribute.numberOfCharacters)) ?? ""
        let children = (try? composer.children().count) ?? 0
        return "\(value)/\(chars)/\(children)"
    }

    public func sendFile(_ file: FetchedFile, reader: WeComReader, checkpoints: CheckpointStore,
                         timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.2, hooks: SubmitHooks = SubmitHooks()) throws -> SubmitOutcome {
        let active = try reader.activeConversationTitle()
        try authorize(.sendFile, title: active)
        guard let composer = reader.layout.composer else { throw WeComError.region("composer") }
        guard reader.layout.messageTable != nil else { throw WeComError.region("messageTable") }
        let current = try composer.valueString() ?? ""
        guard current.isEmpty else { throw ActionError.localGuard("composer not empty") }
        let baselineKeys = Set(try reader.chatMessages().compactMap(\.messageKey))
        let composerBefore = composerSignal(composer)
        var details: [String: String] = ["fileName": file.fileName, "kind": file.kind, "bytes": String(file.bytes), "composerBefore": composerBefore]
        var checkpoint = SubmitCheckpoint(target: active ?? "", text: "file:\(file.fileName)", strategy: Self.pasteStrategy)

        func outcome(_ state: CommandState, reason: String?, evidence: String? = nil, latency: Int? = nil) -> SubmitOutcome {
            SubmitOutcome(state: state, strategy: Self.pasteStrategy, target: active, checkpointID: checkpoint.id, reason: reason,
                          evidence: evidence, latencyMs: latency, composerAfter: (try? composer.valueString())?.count ?? -1, details: details)
        }

        // The client only acts on keys while it is the active application (B9); focus the composer first,
        // remember who was in front, and hand focus back after the bubble check.
        let previous = frontmostPid()
        if (try? composer.isSettable(AXAttribute.focused)) == true { try? composer.setAttribute(AXAttribute.focused, to: .bool(true)) }
        let window = reader.layout.window
        let pid = try window.pid()
        let app = AXApp.byPID(pid, backend: window.backend)
        var restoreAfterConfirm: (() -> Void)?
        defer { restoreAfterConfirm?() }
        if let previous, previous != pid { restoreAfterConfirm = { self.restoreFrontmost(previous) } }

        // ---- paste (reversible) ----
        let clipboard = pasteboard.snapshot()
        pasteboard.setFileURL(file.url)
        let refront = try withFront(app: app, pid: pid) { try postShortcut(.commandV, pid) }
        details["paste"] = "cmd+v -> pid \(pid)\(refront)"
        let landed = try waitUntil(timeout: pasteTimeout) { composerSignal(composer) != composerBefore }
        pasteboard.restore(clipboard)
        details["composerAfterPaste"] = composerSignal(composer)
        guard landed else {
            try? setComposer("", reader: reader)
            details["pasteFailed"] = "true"
            return outcome(.failed, reason: "the attachment did not appear in the composer within \(Int(pasteTimeout)) s (nothing was sent)")
        }

        // verify_target again, immediately before the irreversible step.
        let fresh = try WeComReader(window: window)
        guard try fresh.activeConversationTitle() == active, fresh.layout.composer?.handle == composer.handle else {
            try? setComposer("", reader: reader)
            checkpoint.state = .failed; checkpoint.reason = "target drifted before submit"
            try checkpoints.write(checkpoint)
            return outcome(.failed, reason: checkpoint.reason)
        }
        try checkpoints.write(checkpoint)
        try hooks.beforeIrreversible()
        let started = Date()

        // ---- irreversible point ----
        _ = try withFront(app: app, pid: pid) { try postReturnKey(pid, false) }
        try hooks.afterIrreversible()

        // ---- confirm: a new outbound media / file / video row ----
        let deadline = started.addingTimeInterval(timeout)
        var evidence: String?
        while true {
            if let row = try reader.chatMessages().last(where: { row in
                [.media, .file, .video].contains(row.kind) && row.messageKey.map { !baselineKeys.contains($0) } == true
            }) {
                evidence = "row #\(row.index) kind=\(row.kind.rawValue) dir=\(row.direction.rawValue) time=\(row.timeLabel ?? "-")"
                break
            }
            if Date() >= deadline { break }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)
        let composerAfter = composerSignal(composer)
        details["composerAfter"] = composerAfter

        if let evidence {
            checkpoint.state = .succeeded; checkpoint.evidence = evidence
            try checkpoints.write(checkpoint)
            return outcome(.succeeded, reason: nil, evidence: evidence, latency: latency)
        }
        if composerAfter != composerBefore {
            checkpoint.state = .failed; checkpoint.reason = "no new media / file / video row within \(Int(timeout)) s; composer still holds the attachment"
            try checkpoints.write(checkpoint)
            try? setComposer("", reader: reader)
            return outcome(.failed, reason: checkpoint.reason, latency: latency)
        }
        checkpoint.state = .unknown; checkpoint.reason = "composer emptied but no new media / file / video row was observed"
        try checkpoints.write(checkpoint)
        return outcome(.unknown, reason: checkpoint.reason, latency: latency)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "SendFileTests|SubmitTests|ForbiddenAPITests"`
Expected: PASS (5 new tests; `SubmitTests` unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/WeComAdapter/Actions/SendFile.swift Tests/WeComAdapterTests/SendFileTests.swift
git commit -m "feat(adapter): WeComActions.sendFile — pasteboard file URL, one ⌘V, composer-change confirmation, checkpoint, Return, new media/file/video row as evidence"
```

---

### Task 8: Wire `message.sendFile` — `CommandHandler`, `WeComCommandHandler`, executor (idempotency / pause / TTL / rate), dispatcher + MCP tool, fakes

**Files:**
- Modify: `Sources/ControlCore/Executor/CommandHandler.swift`, `Sources/ControlCore/Executor/CommandExecutor.swift`
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler.swift` (new method + `fileFetcher` / `objectStore` properties)
- Modify: `Sources/MCPTransport/RPCDispatcher.swift:193` (tool descriptor)
- Modify: every `CommandHandler` conformer under `Tests/`: `Tests/ControlCoreTests/CommandExecutorTests.swift` (`FakeHandler`), `Tests/MCPTransportTests/DispatcherTests.swift` (`DispatchFakeHandler`), `Tests/MQTTTransportTests/MQTTBindingTests.swift`, `Tests/imctl-consoleTests/RPCServiceTests.swift`, `Tests/imctl-consoleTests/ConsoleModelTests.swift`
- Modify: `Sources/imctld/main.swift:48` (`enabled:` add `.sendFile`), `Tests/WeComAdapterTests/WeComCommandHandlerTests.swift` (new test)
- Test: `Tests/ControlCoreTests/CommandExecutorTests.swift`, `Tests/MCPTransportTests/DispatcherTests.swift`, `Tests/WeComAdapterTests/WeComCommandHandlerTests.swift`

**Interfaces:**
- Produces: `CommandHandler.messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult`; `WeComCommandHandler.fileFetcher: FileFetcher` (default `FileFetcher(outbox: IMCTLPaths.outboxDirectory)`), `WeComCommandHandler.objectStore: ObjectStore?`; `WeComCommandHandler.sendFileTimeout(kind:bytes:)`; `CommandExecutor.ossEnabled: () -> Bool` (drives `controller.describe.oss`); MCP tool `message.sendFile` (43 tools).

- [ ] **Step 1: Write the failing tests**

Add to every test fake listed above (same body everywhere):

```swift
    var fileSends: [(target: String, source: SendFileSource, fileName: String?)] = []
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        fileSends.append((target, source, fileName))
        try checkpoint(); try afterSubmit()
        return SendFileResult(state: .succeeded, evidence: "row #7 kind=file", latencyMs: 210, fileName: fileName ?? "a.pdf", bytes: 3, contentType: "application/pdf", kind: "file")
    }
```

(`ConsoleModelTests`'s `SwitchingFakeHandler` uses static state; give it `static var fileSends` with the same shape.)

`Tests/ControlCoreTests/CommandExecutorTests.swift` — add:

```swift
    @Test func sendFileRoutesValidatesAndIsRateLimitedLikeASend() throws {
        let (exec, handler, store) = try make()
        let url = #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}"#
        let r = try exec.submit(method: .messageSendFile, paramsJSON: url, idempotencyKey: "f1")
        #expect(r.state == .succeeded && r.resultJSON?.contains("\"kind\":\"file\"") == true && r.checkpointMs != nil)
        #expect(handler.fileSends.count == 1 && handler.fileSends[0].source == .url(URL(string: "https://cdn.example/a.pdf")!))
        #expect(try exec.submit(method: .messageSendFile, paramsJSON: url, idempotencyKey: "f1").id == r.id && handler.fileSends.count == 1)
        // the same conversation within 3 s: the send limiter counts file sends too
        let again = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"文件传输助手","ossKey":"imctl/x.pdf","idempotencyKey":"f2"}"#, idempotencyKey: "f2")
        #expect(again.state == .failed && again.errorCode == "RATE_LIMITED")
        #expect(throws: ControlError.invalidParams("message.sendFile needs exactly one of url / ossKey")) {
            try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"文件传输助手","idempotencyKey":"f3"}"#, idempotencyKey: "f3")
        }
        #expect(throws: ControlError.self) { try exec.submit(method: .messageSendFile, paramsJSON: url, idempotencyKey: nil) }
        let expired = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f4","ttlMs":10,"issuedAtMs":1}"#, idempotencyKey: "f4")
        #expect(expired.state == .expired)
        _ = try exec.submit(method: .controllerPause, paramsJSON: "{}", idempotencyKey: nil)
        let paused = try exec.submit(method: .messageSendFile, paramsJSON: #"{"target":"other","url":"https://cdn.example/b.pdf","idempotencyKey":"f5"}"#, idempotencyKey: "f5")
        #expect(paused.state == .failed && paused.errorCode == "PAUSED")
        exec.ossEnabled = { true }
        let describe = try exec.submit(method: .controllerDescribe, paramsJSON: "{}", idempotencyKey: nil)
        #expect(describe.resultJSON?.contains("\"oss\":\"enabled\"") == true)
        #expect(try store.recentSends(sinceMs: 0).contains { $0.kind == "file" && $0.fileName == "a.pdf" })
    }
```

`Tests/MCPTransportTests/DispatcherTests.swift`: change `arr.count == 42` to `43` and add

```swift
    @Test func sendFileIsAToolAndADirectMethod() throws {
        let (d, handler) = try make()
        let call = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"message.sendFile","arguments":{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}}}"#))
        #expect(call["result"]?.objectValue?["isError"] == .bool(false) && handler.fileSends.count == 1)
        let direct = try parse(d.handle(line: #"{"jsonrpc":"2.0","id":10,"method":"message.sendFile","params":{"target":"文件传输助手","ossKey":"imctl/a.pdf","fileName":"b.pdf","idempotencyKey":"f9"}}"#))
        #expect(direct["result"]?.objectValue?["state"] == .string("succeeded") && handler.fileSends.last?.source == .ossKey("imctl/a.pdf") && handler.fileSends.last?.fileName == "b.pdf")
    }
```

`Tests/WeComAdapterTests/WeComCommandHandlerTests.swift` — add (uses the `harness`-free path: a fake fetcher is not needed because the `ossKey` branch goes through a fake `ObjectStore`, and a refused `url` never reaches the client):

```swift
    @Test func sendFileRefusesDisallowedSourcesBeforeTouchingTheClientAndNeedsOSSForKeys() throws {
        let fake = try Fixtures.mainWindow()
        let h = try handler(fake)
        h.policy.enabled.insert(.sendFile)
        #expect(throws: ControlError.self) {
            try h.messageSendFile(target: "文件传输助手", source: .url(URL(string: "https://nope.example/a.pdf")!), fileName: nil, checkpoint: {}, afterSubmit: {})
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        do {
            _ = try h.messageSendFile(target: "文件传输助手", source: .ossKey("imctl/a.pdf"), fileName: nil, checkpoint: {}, afterSubmit: {})
            Issue.record("expected OSS_NOT_CONFIGURED")
        } catch let e as ControlError { #expect(e.code == "OSS_NOT_CONFIGURED") }
        #expect(WeComCommandHandler.sendFileTimeout(kind: "image", bytes: 1) == 15 && WeComCommandHandler.sendFileTimeout(kind: "file", bytes: 1) == 30)
        #expect(WeComCommandHandler.sendFileTimeout(kind: "video", bytes: 24_684_024) == 50 && WeComCommandHandler.sendFileTimeout(kind: "video", bytes: 300_000_000) == 180)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "CommandExecutorTests|DispatcherTests|WeComCommandHandlerTests"`
Expected: compile errors (`messageSendFile` not in `CommandHandler`, fakes do not conform).

- [ ] **Step 3: Implement**

`CommandHandler.swift` — add after `messageSend`:

```swift
    /// B13: fetch `source` into the outbox (policy-checked), paste it into the target's composer (⌘V) and send it with Return;
    /// `checkpoint` / `afterSubmit` bracket the irreversible step like `messageSend`. Never sends when the paste did not land.
    func messageSendFile(target: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult
```

`CommandExecutor.swift`:

- property: `/// B13: whether an object store (oss.json) is configured; the daemon injects it for controller.describe.` `public var ossEnabled: () -> Bool = { false }`
- TTL expiry block: extend so both param types are checked:

```swift
        if let params = try? decode(SendParams.self, from: paramsJSON), method == .messageSend,
           let ttl = params.ttlMs, let issued = params.issuedAtMs, issued + Int64(ttl) < now() {
            return try transition(record.id, to: .expired, errorCode: ControlError.expired.code, errorMessage: ControlError.expired.message)
        }
        if let params = try? decode(SendFileParams.self, from: paramsJSON), method == .messageSendFile,
           let ttl = params.ttlMs, let issued = params.issuedAtMs, issued + Int64(ttl) < now() {
            return try transition(record.id, to: .expired, errorCode: ControlError.expired.code, errorMessage: ControlError.expired.message)
        }
```

- pause list: add `.messageSendFile` to the array.
- rate limiter: after the existing `.messageSend` block add

```swift
        if method == .messageSendFile, let limiter = rateLimiter,
           let params = try? decode(SendFileParams.self, from: paramsJSON),
           let why = limiter.admit(target: store.conversationTitle(for: params.target), nowMs: now()) {
            let err = ControlError.rateLimited(why)
            return try transition(record.id, to: .failed, errorCode: err.code, errorMessage: err.message)
        }
```

- `execute`: `.controllerDescribe` adds `info["oss"] = ossEnabled() ? "enabled" : "disabled"`; new branch after `.messageSend`:

```swift
        case .messageSendFile:
            let p = try decode(SendFileParams.self, from: paramsJSON)
            let source: SendFileSource
            switch (p.url, p.ossKey) {
            case (let u?, nil):
                guard let url = URL(string: u), url.host != nil else { throw ControlError.invalidParams("message.sendFile url is not an absolute URL") }
                source = .url(url)
            case (nil, let k?):
                let key = k.trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !key.hasPrefix("/"), !key.contains("..") else { throw ControlError.invalidParams("message.sendFile ossKey must be a relative object key") }
                source = .ossKey(key)
            default:
                throw ControlError.invalidParams("message.sendFile needs exactly one of url / ossKey")
            }
            let result = try handler.messageSendFile(
                target: p.target, source: source, fileName: p.fileName,
                checkpoint: { try self.store.updateCommand(id: record.id, state: .running, nowMs: self.now(), checkpointMs: self.now()) },
                afterSubmit: { if self.crashAfterSubmit { try self.exitHook(); throw CrashInjected() } }
            )
            return (result.state, try encode(result))
```

`WeComCommandHandler.swift` — properties next to `mediaIndex`:

```swift
    /// B13: downloads for message.sendFile land here (owner-only outbox, swept at daemon start).
    public var fileFetcher = FileFetcher(outbox: IMCTLPaths.outboxDirectory)
    /// B13: the object store behind message.media and ossKey sources; nil = OSS_NOT_CONFIGURED.
    public var objectStore: ObjectStore?
```

method after `messageSend`:

```swift
    /// B13: policy (target, then source) → fetch → select → paste + Return. The outbox file is deleted whatever happens.
    public func messageSendFile(target rawTarget: String, source: SendFileSource, fileName: String?, checkpoint: () throws -> Void, afterSubmit: () throws -> Void) throws -> SendFileResult {
        try mapErrors {
            let ref = TargetRef.parse(rawTarget)
            let r = try reader()
            let resolved = try resolve(ref, reader: r)
            try policyCheck(.sendFile, resolved: resolved)
            let fetched: FetchedFile
            switch source {
            case .url(let url):
                fetched = try fileFetcher.fetch(url: url, fileName: fileName, policy: currentPolicy.sendPolicy.sendFile)
            case .ossKey(let key):
                guard let store = objectStore else { throw ControlError.ossNotConfigured("message.sendFile{ossKey} needs oss.json on this Mac (imctl oss set, or the console's 设置 page)") }
                fetched = try fileFetcher.fetch(ossKey: key, fileName: fileName, store: store, maxBytes: currentPolicy.sendPolicy.sendFile.maxBytes)
            }
            defer { fileFetcher.discard(fetched) }
            if try r.activeConversationTitle() != resolved.title {
                _ = try actions(for: resolved).selectConversation(resolved.title, reader: r)
            }
            let fresh = try reader()
            let timeout = Self.sendFileTimeout(kind: fetched.kind, bytes: fetched.bytes)
            let outcome = try withoutEscaping(checkpoint, afterSubmit) { before, after in
                try actions(for: resolved).sendFile(fetched, reader: fresh, checkpoints: checkpoints, timeout: timeout,
                                                    hooks: SubmitHooks(beforeIrreversible: before, afterIrreversible: after))
            }
            if outcome.details["pasteFailed"] == "true" { throw ControlError.pasteFailed(outcome.reason ?? "paste failed") }
            let state: CommandStateV1
            switch outcome.state {
            case .succeeded: state = .succeeded
            case .failed: state = .failed
            case .unknown, .pending: state = .unknown
            }
            return SendFileResult(state: state, evidence: outcome.evidence, reason: outcome.reason, latencyMs: outcome.latencyMs,
                                  fileName: fetched.fileName, bytes: fetched.bytes, contentType: fetched.contentType, kind: fetched.kind)
        }
    }

    /// Spec §7: pictures 15 s, files 30 s, videos 30 s + 10 s per 10 MB, capped at 180 s (the client uploads before the bubble appears).
    static func sendFileTimeout(kind: String, bytes: Int64) -> TimeInterval {
        switch kind {
        case "image": return 15
        case "video": return min(180, 30 + Double(bytes / 10_485_760) * 10)
        default: return 30
        }
    }
```

`Sources/imctld/main.swift:48`: add `.sendFile` to the `enabled:` set. `RPCDispatcher.toolDescriptors()` — after the `message.send` entry:

```swift
            ("message.sendFile", "Send a file (image / video / pdf / office / zip / txt) to an allowlisted conversation: the daemon downloads url (https, host on policy.json sendFile.allowedHosts) or ossKey (object in the configured bucket) into its outbox, pastes it into the composer (⌘V) and presses Return; evidence = a new outbound media / file / video row; idempotent per idempotencyKey", schema(["target": target, "url": ("string", "https source; host must be allowed by policy (imctl policy hosts)"), "ossKey": ("string", "Object key in the configured OSS bucket (alternative to url)"), "fileName": ("string", "Name to send as (default: the URL / key's last path component)"), "idempotencyKey": ("string", "Caller-generated unique key"), "ttlMs": ("integer", "Expiry relative to issuedAtMs"), "issuedAtMs": ("integer", "Caller clock, ms since epoch")], required: ["target", "idempotencyKey"])),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "CommandExecutorTests|DispatcherTests|WeComCommandHandlerTests|MQTTBindingTests|RPCServiceTests|ConsoleModelTests|ProtocolDocTests"`
Expected: PASS (43 tools listed; every fake compiles).

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat(sendFile): route message.sendFile through the executor (key, TTL, pause, send limiter), WeComCommandHandler fetch → paste → Return, MCP tool, controller.describe.oss"
```

---

### Task 9: `OSSClient` target — `oss.json`, V4 signer, transport, `OSSObjectStore`

**Files:**
- Modify: `Package.swift` (new library target + test target; add `"OSSClient"` to `imctld`, `imctl`, `imctl-console` dependencies)
- Create: `Sources/OSSClient/OSSSettings.swift`, `Sources/OSSClient/OSSSigner.swift`, `Sources/OSSClient/OSSTransport.swift`, `Sources/OSSClient/OSSObjectStore.swift`
- Create: `Tests/OSSClientTests/OSSSignerTests.swift`, `Tests/OSSClientTests/OSSObjectStoreTests.swift`
- Modify: `scripts/check-secrets.sh` (two patterns)

**Interfaces:**
- Consumes: `ControlCore.ObjectStore`, `ControlError.objectStore/.mediaTooLarge/.sourceTooLarge/.sourceUnreachable`, `IMCTLPaths.dataDirectory`.
- Produces: `OSSSettings{endpoint, bucket, baseDir, accessKeyId, accessKeySecret, viewExpireSeconds = 1800, maxUploadBytes = 52428800}` with `fileName = "oss.json"`, `defaultURL`, `load(from:)`, `save(to:)` (0600), `endpointHost`, `region`, `bucketHost`, `summary`, `static mask(_:)`; `OSSSigner(accessKeyId:accessKeySecret:region:)` with `signedHeaders(method:bucket:key:query:headers:date:)` and `presignedQuery(method:bucket:key:expiresIn:date:)`; `OSSResponse{status, headers, body}`; `protocol OSSTransport { func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse }`; `URLSessionOSSTransport`; `OSSObjectStore(settings:transport:now:) : ObjectStore`.

- [ ] **Step 1: Write the failing tests**

`Tests/OSSClientTests/OSSSignerTests.swift`:

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import OSSClient

@Suite("OSS V4 signer and settings")
struct OSSSignerTests {
    let signer = OSSSigner(accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", region: "cn-hangzhou")
    let date = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21T09:33:20Z

    @Test func stampsEncodingAndCanonicalPieces() {
        let (stamp, day) = OSSSigner.stamps(date)
        #expect(stamp == "20260921T093320Z" && day == "20260921")
        #expect(OSSSigner.encode("imctl/2026/09/22/k-电子发票 (1).pdf", keepSlash: true) == "imctl/2026/09/22/k-%E7%94%B5%E5%AD%90%E5%8F%91%E7%A5%A8%20%281%29.pdf")
        #expect(OSSSigner.encode("a/b", keepSlash: false) == "a%2Fb")
        #expect(OSSSigner.canonicalURI(bucket: "b", key: "x y/z.png") == "/b/x%20y/z.png")
        #expect(OSSSigner.canonicalQuery([("x-oss-expires", "60"), ("x-oss-date", "D"), ("empty", "")]) == "empty&x-oss-date=D&x-oss-expires=60")
        #expect(OSSSigner.canonicalHeaders(["Content-Type": "image/png ", "Host": "h", "x-oss-date": "D", "X-OSS-Content-SHA256": "UNSIGNED-PAYLOAD"]) == "content-type:image/png\nx-oss-content-sha256:UNSIGNED-PAYLOAD\nx-oss-date:D\n")
        let canonical = OSSSigner.canonicalRequest(method: "PUT", bucket: "b", key: "k.png", query: [], headers: ["x-oss-date": "D"], payloadHash: "UNSIGNED-PAYLOAD")
        #expect(canonical == "PUT\n/b/k.png\n\nx-oss-date:D\n\n\nUNSIGNED-PAYLOAD")
        #expect(signer.scope(day: "20260921") == "20260921/cn-hangzhou/oss/aliyun_v4_request")
        let sts = signer.stringToSign(canonicalRequest: canonical, stamp: "20260921T093320Z", day: "20260921")
        #expect(sts.hasPrefix("OSS4-HMAC-SHA256\n20260921T093320Z\n20260921/cn-hangzhou/oss/aliyun_v4_request\n") && sts.split(separator: "\n").last?.count == 64)
    }

    @Test func headerSignatureIsDeterministicAndDependsOnTheSecret() {
        let a = signer.signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)
        let b = signer.signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)
        #expect(a == b && a["x-oss-date"] == "20260921T093320Z" && a["x-oss-content-sha256"] == "UNSIGNED-PAYLOAD")
        let auth = try! #require(a["Authorization"])
        #expect(auth.hasPrefix("OSS4-HMAC-SHA256 Credential=TESTAKID0000000001/20260921/cn-hangzhou/oss/aliyun_v4_request,Signature=") && auth.split(separator: "=").last?.count == 64)
        let other = OSSSigner(accessKeyId: "TESTAKID0000000001", accessKeySecret: "another", region: "cn-hangzhou").signedHeaders(method: "PUT", bucket: "b", key: "k.png", headers: ["Content-Type": "image/png"], date: date)
        #expect(other["Authorization"] != a["Authorization"])
        #expect(!auth.contains("test-secret"))
    }

    @Test func presignedQueryCarriesTheFiveParametersAndNoSecret() {
        let q = signer.presignedQuery(bucket: "b", key: "dir/k.pdf", expiresIn: 1800, date: date)
        let names = q.map(\.0)
        #expect(names == ["x-oss-signature-version", "x-oss-credential", "x-oss-date", "x-oss-expires", "x-oss-signature"])
        #expect(q[0].1 == "OSS4-HMAC-SHA256" && q[1].1 == "TESTAKID0000000001/20260921/cn-hangzhou/oss/aliyun_v4_request" && q[3].1 == "1800" && q[4].1.count == 64)
        #expect(!q.map(\.1).joined().contains("test-secret"))
    }

    @Test func settingsDeriveRegionAndHostSaveOwnerOnlyAndMaskTheKey() throws {
        var s = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret")
        #expect(s.region == "cn-hangzhou" && s.bucketHost == "photos.oss-cn-hangzhou.aliyuncs.com" && s.viewExpireSeconds == 1800 && s.maxUploadBytes == 52_428_800)
        s.endpoint = "https://oss-cn-shanghai-internal.aliyuncs.com"
        #expect(s.region == "cn-shanghai")
        #expect(OSSSettings.mask("TESTAKID0000000001") == "TEST…01" && OSSSettings.mask("ab") == "…")
        #expect(!s.summary.contains("test-secret") && s.summary.contains("bucket=photos"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-\(UUID().uuidString)/oss.json")
        try s.save(to: url)
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        #expect(try OSSSettings.load(from: url) == s)
        #expect(OSSSettings.fileName == "oss.json" && OSSSettings.defaultURL.lastPathComponent == "oss.json")
    }
}
```

`Tests/OSSClientTests/OSSObjectStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ControlCore
@testable import OSSClient

final class ScriptedTransport: OSSTransport {
    var responses: [OSSResponse] = []
    var sent: [(request: URLRequest, upload: URL?, download: URL?)] = []
    var downloadBody = Data("hello".utf8)
    func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse {
        sent.append((request, file, destination))
        if let destination { try downloadBody.write(to: destination) }
        return responses.isEmpty ? OSSResponse(status: 200, headers: [:], body: Data()) : responses.removeFirst()
    }
}

@Suite("OSSObjectStore")
struct OSSObjectStoreTests {
    func store() -> (OSSObjectStore, ScriptedTransport) {
        let settings = OSSSettings(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "b", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", viewExpireSeconds: 60, maxUploadBytes: 100)
        let t = ScriptedTransport()
        return (OSSObjectStore(settings: settings, transport: t, now: { Date(timeIntervalSince1970: 1_790_000_000) }), t)
    }

    @Test func putHeadDeleteAndSignedURL() throws {
        let (s, t) = store()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-put-\(UUID().uuidString).png")
        try Data([1, 2, 3]).write(to: file)
        try s.put(fileURL: file, key: "imctl/2026/09/22/k-a b.png", contentType: "image/png")
        let put = t.sent[0].request
        #expect(put.httpMethod == "PUT" && put.url?.absoluteString == "https://b.oss-cn-hangzhou.aliyuncs.com/imctl/2026/09/22/k-a%20b.png" && t.sent[0].upload == file)
        #expect(put.value(forHTTPHeaderField: "Content-Type") == "image/png" && put.value(forHTTPHeaderField: "Authorization")?.hasPrefix("OSS4-HMAC-SHA256 Credential=TESTAKID0000000001/20260921/cn-hangzhou/oss/aliyun_v4_request,Signature=") == true)
        #expect(put.value(forHTTPHeaderField: "x-oss-content-sha256") == "UNSIGNED-PAYLOAD" && put.value(forHTTPHeaderField: "Host") == "b.oss-cn-hangzhou.aliyuncs.com")
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "3"], body: Data()), OSSResponse(status: 404, headers: [:], body: Data())]
        #expect(try s.exists(key: "k") == true && (try s.exists(key: "k")) == false && t.sent[1].request.httpMethod == "HEAD")
        let url = try s.signedGetURL(key: "imctl/x.pdf", expiresIn: 60)
        #expect(url.absoluteString.hasPrefix("https://b.oss-cn-hangzhou.aliyuncs.com/imctl/x.pdf?x-oss-signature-version=OSS4-HMAC-SHA256&x-oss-credential=") && url.absoluteString.contains("x-oss-expires=60") && url.absoluteString.contains("&x-oss-signature="))
        try s.delete(key: "k")
        #expect(t.sent.last?.request.httpMethod == "DELETE")
        #expect(s.summary.contains("bucket=b") && !s.summary.contains("test-secret") && s.baseDir == "imctl" && s.maxUploadBytes == 100)
    }

    @Test func errorsCarryStatusAndCodeNeverTheKey() throws {
        let (s, t) = store()
        t.responses = [OSSResponse(status: 403, headers: [:], body: Data("<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match.</Message></Error>".utf8))]
        do { _ = try s.exists(key: "k"); Issue.record("expected OSS_ERROR") }
        catch let e as ControlError { #expect(e.code == "OSS_ERROR" && e.message == "HEAD k: HTTP 403 SignatureDoesNotMatch: The request signature we calculated does not match.") }
    }

    @Test func downloadChecksTheSizeFirst() throws {
        let (s, t) = store()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-dl-\(UUID().uuidString).txt")
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "5"], body: Data()), OSSResponse(status: 200, headers: [:], body: Data())]
        #expect(try s.download(key: "k.txt", to: dest, maxBytes: 10) == 5 && (try String(contentsOf: dest, encoding: .utf8)) == "hello")
        t.responses = [OSSResponse(status: 200, headers: ["Content-Length": "5000"], body: Data())]
        #expect(throws: ControlError.self) { try s.download(key: "big", to: dest, maxBytes: 10) }
        t.responses = [OSSResponse(status: 404, headers: [:], body: Data())]
        do { _ = try s.download(key: "gone", to: dest, maxBytes: 10); Issue.record("expected SOURCE_UNREACHABLE") }
        catch let e as ControlError { #expect(e.code == "SOURCE_UNREACHABLE") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "OSSSignerTests|OSSObjectStoreTests"`
Expected: build error — no target `OSSClient` (then, after `Package.swift`, undefined types).

- [ ] **Step 3: Implement**

`Package.swift`: add `.library(name: "OSSClient", targets: ["OSSClient"])` to products, `.target(name: "OSSClient", dependencies: ["ControlCore"])` to targets, `"OSSClient"` to the dependency lists of `imctld`, `imctl` and `imctl-console`, and `.testTarget(name: "OSSClientTests", dependencies: ["OSSClient"])`.

`Sources/OSSClient/OSSSettings.swift`:

```swift
import ControlCore
import Foundation

/// Where pictures / files behind `message.media` are uploaded and where `ossKey` sources come from. Field names
/// mirror the business side's `aliyun.oss.*` block. Stored locally (0600, never committed); the AccessKey pair
/// never appears in logs, `describe` or the console (masked).
public struct OSSSettings: Codable, Equatable {
    public var endpoint: String
    public var bucket: String
    public var baseDir: String
    public var accessKeyId: String
    public var accessKeySecret: String
    public var viewExpireSeconds: Int
    public var maxUploadBytes: Int64

    public init(endpoint: String, bucket: String, baseDir: String, accessKeyId: String, accessKeySecret: String, viewExpireSeconds: Int = 1800, maxUploadBytes: Int64 = 52_428_800) {
        self.endpoint = endpoint; self.bucket = bucket; self.baseDir = baseDir; self.accessKeyId = accessKeyId; self.accessKeySecret = accessKeySecret
        self.viewExpireSeconds = viewExpireSeconds; self.maxUploadBytes = maxUploadBytes
    }

    public static let fileName = "oss.json"
    public static var defaultURL: URL { IMCTLPaths.dataDirectory.appendingPathComponent(fileName) }

    public static func load(from url: URL) throws -> OSSSettings { try JSONDecoder().decode(OSSSettings.self, from: Data(contentsOf: url)) }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public var endpointHost: String? { URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host }
    /// `oss-cn-hangzhou.aliyuncs.com` → `cn-hangzhou`; `oss-cn-shanghai-internal.…` → `cn-shanghai`.
    public var region: String {
        guard let host = endpointHost, let first = host.split(separator: ".").first, first.hasPrefix("oss-") else { return "" }
        var r = String(first.dropFirst(4))
        if r.hasSuffix("-internal") { r.removeLast("-internal".count) }
        return r
    }
    public var bucketHost: String { "\(bucket).\(endpointHost ?? "")" }
    /// For `imctl oss status`, `describe` and logs.
    public var summary: String { "\(endpointHost ?? "-") bucket=\(bucket) baseDir=\(baseDir) ak=\(Self.mask(accessKeyId)) view=\(viewExpireSeconds)s maxUpload=\(maxUploadBytes)" }
    public static func mask(_ id: String) -> String { id.count > 6 ? "\(id.prefix(4))…\(id.suffix(2))" : "…" }
}
```

`Sources/OSSClient/OSSSigner.swift`:

```swift
import CryptoKit
import Foundation

/// Aliyun OSS signature V4 (`OSS4-HMAC-SHA256`): header signing for PUT / HEAD / GET / DELETE and query
/// signing for presigned GET URLs. Pure string functions so the canonical form is unit-testable; the live
/// round trip (`imctl oss test`) is the final judge, and a 403 carries the server's `CanonicalRequest` for comparison.
public struct OSSSigner {
    public var accessKeyId: String
    public var accessKeySecret: String
    public var region: String
    public static let algorithm = "OSS4-HMAC-SHA256"
    public static let unsignedPayload = "UNSIGNED-PAYLOAD"

    public init(accessKeyId: String, accessKeySecret: String, region: String) {
        self.accessKeyId = accessKeyId; self.accessKeySecret = accessKeySecret; self.region = region
    }

    /// `20260921T093320Z` and `20260921` (UTC).
    public static func stamps(_ date: Date) -> (stamp: String, day: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
        return (day + String(format: "T%02d%02d%02dZ", c.hour!, c.minute!, c.second!), day)
    }

    /// RFC 3986: unreserved characters stay; `/` stays only when `keepSlash` (paths).
    public static func encode(_ s: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        if keepSlash { allowed.insert(charactersIn: "/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    public static func canonicalURI(bucket: String, key: String) -> String { "/" + bucket + "/" + encode(key, keepSlash: true) }

    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        items.map { (encode($0.0, keepSlash: false), encode($0.1, keepSlash: false)) }
            .sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { $0.1.isEmpty ? $0.0 : "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// Only `x-oss-*`, `content-type` and `content-md5` are signed: lowercase names, trimmed values, sorted, each line `\n`-terminated.
    public static func canonicalHeaders(_ headers: [String: String]) -> String {
        headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.0.hasPrefix("x-oss-") || $0.0 == "content-type" || $0.0 == "content-md5" }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
    }

    /// Verb, URI, query, canonical headers, additional headers (none), payload hash — joined by `\n`.
    public static func canonicalRequest(method: String, bucket: String, key: String, query: [(String, String)], headers: [String: String], payloadHash: String) -> String {
        [method, canonicalURI(bucket: bucket, key: key), canonicalQuery(query), canonicalHeaders(headers), "", payloadHash].joined(separator: "\n")
    }

    public func scope(day: String) -> String { "\(day)/\(region)/oss/aliyun_v4_request" }

    public func stringToSign(canonicalRequest: String, stamp: String, day: String) -> String {
        [Self.algorithm, stamp, scope(day: day), Self.hex(Data(SHA256.hash(data: Data(canonicalRequest.utf8))))].joined(separator: "\n")
    }

    /// HMAC chain: ("aliyun_v4" + secret) → day → region → "oss" → "aliyun_v4_request" → string to sign.
    public func signature(stringToSign: String, day: String) -> String {
        let dateKey = Self.hmac(key: Data(("aliyun_v4" + accessKeySecret).utf8), data: Data(day.utf8))
        let regionKey = Self.hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = Self.hmac(key: regionKey, data: Data("oss".utf8))
        let signingKey = Self.hmac(key: serviceKey, data: Data("aliyun_v4_request".utf8))
        return Self.hex(Self.hmac(key: signingKey, data: Data(stringToSign.utf8)))
    }

    /// The request's headers plus `x-oss-date`, `x-oss-content-sha256` and `Authorization`.
    public func signedHeaders(method: String, bucket: String, key: String, query: [(String, String)] = [], headers: [String: String], date: Date = Date()) -> [String: String] {
        let (stamp, day) = Self.stamps(date)
        var h = headers
        h["x-oss-date"] = stamp
        h["x-oss-content-sha256"] = Self.unsignedPayload
        let canonical = Self.canonicalRequest(method: method, bucket: bucket, key: key, query: query, headers: h, payloadHash: Self.unsignedPayload)
        let sig = signature(stringToSign: stringToSign(canonicalRequest: canonical, stamp: stamp, day: day), day: day)
        h["Authorization"] = "\(Self.algorithm) Credential=\(accessKeyId)/\(scope(day: day)),Signature=\(sig)"
        return h
    }

    /// Presigned URL parameters in order: signature-version, credential, date, expires, signature. No header is signed.
    public func presignedQuery(method: String = "GET", bucket: String, key: String, expiresIn: Int, date: Date = Date()) -> [(String, String)] {
        let (stamp, day) = Self.stamps(date)
        var query: [(String, String)] = [
            ("x-oss-signature-version", Self.algorithm),
            ("x-oss-credential", "\(accessKeyId)/\(scope(day: day))"),
            ("x-oss-date", stamp),
            ("x-oss-expires", String(expiresIn)),
        ]
        let canonical = Self.canonicalRequest(method: method, bucket: bucket, key: key, query: query, headers: [:], payloadHash: Self.unsignedPayload)
        query.append(("x-oss-signature", signature(stringToSign: stringToSign(canonicalRequest: canonical, stamp: stamp, day: day), day: day)))
        return query
    }

    static func hmac(key: Data, data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
```

`Sources/OSSClient/OSSTransport.swift`:

```swift
import Foundation

public struct OSSResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String], body: Data) { self.status = status; self.headers = headers; self.body = body }
}

/// The little HTTP the object store needs; scripted in tests. `uploading` streams a file as the body
/// (PUT), `downloadingTo` writes the response body to a file (GET); otherwise the body is returned.
public protocol OSSTransport {
    func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse
}

/// Synchronous URLSession transport (the executor is a serial queue; one call is one request).
public final class URLSessionOSSTransport: OSSTransport {
    public let session: URLSession
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private final class Outcome { var data: Data?; var response: URLResponse?; var error: Error?; var file: URL? }

    public func send(_ request: URLRequest, uploading file: URL?, downloadingTo destination: URL?) throws -> OSSResponse {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        if let file {
            session.uploadTask(with: request, fromFile: file) { data, response, error in outcome.data = data; outcome.response = response; outcome.error = error; done.signal() }.resume()
        } else if destination != nil {
            session.downloadTask(with: request) { url, response, error in
                outcome.file = url; outcome.response = response; outcome.error = error
                // The temporary file is deleted when this closure returns: move it first.
                if let url, let destination, error == nil, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true {
                    try? FileManager.default.removeItem(at: destination)
                    do { try FileManager.default.moveItem(at: url, to: destination) } catch { outcome.error = error }
                } else if let url { outcome.data = try? Data(contentsOf: url) }
                done.signal()
            }.resume()
        } else {
            session.dataTask(with: request) { data, response, error in outcome.data = data; outcome.response = response; outcome.error = error; done.signal() }.resume()
        }
        done.wait()
        if let error = outcome.error { throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]) }
        guard let http = outcome.response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k)] = String(describing: v) }
        return OSSResponse(status: http.statusCode, headers: headers, body: outcome.data ?? Data())
    }
}
```

`Sources/OSSClient/OSSObjectStore.swift`:

```swift
import ControlCore
import Foundation

/// `ObjectStore` on Aliyun OSS (virtual-hosted URLs, V4 signatures). Every error becomes `ControlError.objectStore`
/// with the HTTP status and the server's `Code` / `Message` — never the endpoint, a key or a signed URL in logs.
public final class OSSObjectStore: ObjectStore {
    public let settings: OSSSettings
    public let transport: OSSTransport
    public let now: () -> Date
    let signer: OSSSigner

    public init(settings: OSSSettings, transport: OSSTransport = URLSessionOSSTransport(), now: @escaping () -> Date = Date.init) {
        self.settings = settings; self.transport = transport; self.now = now
        signer = OSSSigner(accessKeyId: settings.accessKeyId, accessKeySecret: settings.accessKeySecret, region: settings.region)
    }

    public var summary: String { settings.summary }
    public var baseDir: String { settings.baseDir }
    public var maxUploadBytes: Int64 { settings.maxUploadBytes }
    public var viewExpireSeconds: Int { settings.viewExpireSeconds }

    func url(for key: String, query: [(String, String)] = []) -> URL {
        var s = "https://\(settings.bucketHost)/\(OSSSigner.encode(key, keepSlash: true))"
        if !query.isEmpty { s += "?" + query.map { "\(OSSSigner.encode($0.0, keepSlash: false))=\(OSSSigner.encode($0.1, keepSlash: false))" }.joined(separator: "&") }
        return URL(string: s)!
    }

    func request(_ method: String, key: String, headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url(for: key))
        r.httpMethod = method
        r.timeoutInterval = 120
        for (k, v) in signer.signedHeaders(method: method, bucket: settings.bucket, key: key, headers: headers, date: now()) { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(settings.bucketHost, forHTTPHeaderField: "Host")
        return r
    }

    public func exists(key: String) throws -> Bool {
        let r = try send(request("HEAD", key: key), what: "HEAD \(key)", accept: [200, 404])
        return r.status == 200
    }

    public func put(fileURL: URL, key: String, contentType: String) throws {
        _ = try send(request("PUT", key: key, headers: ["Content-Type": contentType]), what: "PUT \(key)", accept: [200], uploading: fileURL)
    }

    public func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL {
        url(for: key, query: signer.presignedQuery(bucket: settings.bucket, key: key, expiresIn: Int(expiresIn), date: now()))
    }

    public func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 {
        let head = try send(request("HEAD", key: key), what: "HEAD \(key)", accept: [200, 404])
        guard head.status == 200 else { throw ControlError.sourceUnreachable("ossKey \(key): no such object") }
        let length = Int64(head.headers.first { $0.key.lowercased() == "content-length" }?.value ?? "") ?? -1
        if length > maxBytes { throw ControlError.sourceTooLarge("ossKey \(key) is \(length) bytes; the cap is \(maxBytes)") }
        _ = try send(request("GET", key: key), what: "GET \(key)", accept: [200], downloadingTo: destination)
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size > maxBytes { try? FileManager.default.removeItem(at: destination); throw ControlError.sourceTooLarge("ossKey \(key) is \(size) bytes; the cap is \(maxBytes)") }
        return size
    }

    public func delete(key: String) throws {
        _ = try send(request("DELETE", key: key), what: "DELETE \(key)", accept: [200, 204])
    }

    @discardableResult
    func send(_ request: URLRequest, what: String, accept: Set<Int>, uploading: URL? = nil, downloadingTo: URL? = nil) throws -> OSSResponse {
        let response: OSSResponse
        do { response = try transport.send(request, uploading: uploading, downloadingTo: downloadingTo) }
        catch { throw ControlError.objectStore("\(what): \(error.localizedDescription)") }
        guard accept.contains(response.status) else { throw ControlError.objectStore("\(what): HTTP \(response.status)\(Self.detail(response.body))") }
        return response
    }

    /// ` Code: Message` from the XML error body (and nothing else from it).
    static func detail(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        func tag(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        guard let code = tag("Code") else { return "" }
        return " \(code)" + (tag("Message").map { ": \($0)" } ?? "")
    }
}
```

`scripts/check-secrets.sh` — add two patterns to `PATTERNS`: `'LTAI[A-Za-z0-9]{12,}'` and `'accessKeySecret[[:space:]]*[:=][[:space:]]*"?[A-Za-z0-9]{20,}'`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "OSSSignerTests|OSSObjectStoreTests"`
Expected: PASS (7 tests). Then `bash scripts/check-secrets.sh | grep -c OSSClient` → `0`.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/OSSClient Tests/OSSClientTests scripts/check-secrets.sh
git commit -m "feat(oss): OSSClient target — oss.json settings (0600, masked), V4 signer (header + presigned query), URLSession transport, OSSObjectStore (put/head/get/delete/signed URL); secret scanner learns LTAI / accessKeySecret"
```

---

### Task 10: `message.media` → OSS signed URLs for pictures, files and video posters

**Files:**
- Modify: `Sources/WeComAdapter/Media/WeComMediaStore.swift` (file candidates, video body candidates, `candidates(kinds:)` already exists)
- Modify: `Sources/WeComAdapter/Handler/WeComCommandHandler+Media.swift` (new `messageMedia(messageKey:hd:)`, upload helper, file / video resolution)
- Modify: `Sources/ControlCore/Executor/CommandHandler.swift` (`messageMedia` signature), `Sources/MCPTransport/RPCDispatcher.swift` (`media()` + descriptor)
- Modify: the five test fakes from Task 8 (`messageMedia` stub), `Tests/MCPTransportTests/DispatcherTests.swift` (`MediaQueryTests`)
- Modify: `docs/protocol/im-control-protocol.md` §6.39
- Test: `Tests/WeComAdapterTests/MediaRouteTests.swift`

**Interfaces:**
- Consumes: `ObjectStore`, `MediaReference`, `FileSizeLabel`, `FileNames`, `FileKind.info(forFileName:)`, `MessageRowKind.file/.video`, `WeComCommandHandler.objectStore` (Task 8).
- Produces: `CommandHandler.messageMedia(messageKey: String, hd: Bool) throws -> MediaReference`; `WeComMediaStore.fileCandidates(name: String, sizeLabel: String?) -> [MediaCacheFile]`, `WeComMediaStore.videoBodyCandidates(sinceMs:untilMs:) -> [MediaCacheFile]`, `WeComMediaStore.contentType(for: MediaCacheFile, fileName:)`; `WeComCommandHandler.upload(file:messageKey:fileName:contentType:) -> (key: String, url: String, expiresAtMs: Int64)`; `RPCDispatcher.media` params `{messageKey, hd?=true}`.

- [ ] **Step 1: Write the failing tests**

Replace the stub in each fake:

```swift
    func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference {
        guard messageKey == "k-media" else { throw ControlError.mediaNotFound("no observation for \(messageKey)") }
        return MediaReference(messageKey: messageKey, kind: "image", matchedBy: "observed", fileName: "p.png", bytes: 3, contentType: "image/png",
                              ossKey: "imctl/2026/09/22/k-media-p.png", url: "https://b.example/imctl/2026/09/22/k-media-p.png?x-oss-signature=abc", expiresAtMs: 1_790_000_000_000)
    }
```

`Tests/MCPTransportTests/DispatcherTests.swift` `MediaQueryTests`: replace the `base64` assertions — `direct.objectValue?["result"]?.objectValue?["url"]?.stringValue?.hasPrefix("https://b.example/") == true && …["matchedBy"]?.stringValue == "observed"`; the tool call checks `contains("\"ossKey\":\"imctl/2026/09/22/k-media-p.png\"")` instead of `contentType`; keep the "no events, no command" assertions; add `#expect(!text.contains("base64"))` on the tool result text.

`Tests/WeComAdapterTests/MediaRouteTests.swift` — add a fake store and three tests:

```swift
final class RecordingObjectStore: ObjectStore {
    var summary = "fake bucket"; var baseDir = "imctl"; var maxUploadBytes: Int64 = 1_000_000; var viewExpireSeconds = 1800
    var existing: Set<String> = []
    var puts: [(key: String, contentType: String, bytes: Int)] = []
    func exists(key: String) throws -> Bool { existing.contains(key) }
    func put(fileURL: URL, key: String, contentType: String) throws { puts.append((key, contentType, (try? Data(contentsOf: fileURL))?.count ?? -1)); existing.insert(key) }
    func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL { URL(string: "https://b.example/\(OSSSigner_encode(key))?x-oss-signature=sig")! }
    func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 { 0 }
    func delete(key: String) throws {}
    private func OSSSigner_encode(_ k: String) -> String { k.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? k }
}

extension MediaRouteTests {
    /// A container whose current profile holds a picture, a video poster and two files (name + size as the client shows them).
    func containerWithFiles() throws -> URL {
        let t0 = Date(timeIntervalSince1970: 1_789_460_000)
        let root = try container(pictures: [("aaaa", t0, false)])
        let profile = root.appendingPathComponent("Documents/Profiles/D8682F25E08A9B27FB6D096B03712294")
        let files = profile.appendingPathComponent("Caches/Files/2026-09")
        try FileManager.default.createDirectory(at: files.appendingPathComponent("f1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.appendingPathComponent("f2"), withIntermediateDirectories: true)
        try Data(repeating: 0x25, count: 75_543).write(to: files.appendingPathComponent("f1/invoice.pdf"))
        try Data(repeating: 0x50, count: 200).write(to: files.appendingPathComponent("f2/invoice.pdf"))          // same name, wrong size
        let posters = profile.appendingPathComponent("Caches/Video_Thumbnail/2026-09/v1")
        try FileManager.default.createDirectory(at: posters, withIntermediateDirectories: true)
        try (Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 64)).write(to: posters.appendingPathComponent("v1"))
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(30)], ofItemAtPath: posters.appendingPathComponent("v1").path)
        return root
    }

    @Test func fileCandidatesMatchNameAndSizeLabel() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WeComMediaStore(containerData: root)
        let hits = store.fileCandidates(name: "invoice.pdf", sizeLabel: "74K")
        #expect(hits.count == 1 && hits[0].path.hasSuffix("Caches/Files/2026-09/f1/invoice.pdf") && hits[0].kind == "file" && hits[0].size == 75_543)
        #expect(store.fileCandidates(name: "invoice.pdf", sizeLabel: nil).count == 2 && store.fileCandidates(name: "other.pdf", sizeLabel: nil).isEmpty)
    }

    @Test func fileRowsUploadOnceAndReturnASignedURL() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = GroupFixture.window(messages: [
            GroupFixture.timeRow(y: 64, "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                    AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: 113, width: 42, height: 42)),
                    GroupFixture.text("invoice.pdf", x: 1657, y: 113, w: 142, h: 20), GroupFixture.text("74K", x: 1657, y: 139, w: 24),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: window)
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation], phase: .phase1), checkpoints: cps)
        h.mediaStore = WeComMediaStore(containerData: root)
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().first?.messageKey)
        #expect(throws: ControlError.self) { try h.messageMedia(messageKey: key, hd: true) }   // OSS_NOT_CONFIGURED
        let store = RecordingObjectStore()
        h.objectStore = store
        let ref = try h.messageMedia(messageKey: key, hd: true)
        #expect(ref.kind == "file" && ref.fileName == "invoice.pdf" && ref.bytes == 75_543 && ref.contentType == "application/pdf" && ref.matchedBy == "name")
        #expect(ref.ossKey.hasPrefix("imctl/") && ref.ossKey.hasSuffix("/\(key)-invoice.pdf") && ref.url.hasPrefix("https://b.example/") && ref.expiresAtMs > Clock.nowMs())
        #expect(store.puts.count == 1 && store.puts[0].contentType == "application/pdf")
        let again = try h.messageMedia(messageKey: key, hd: true)
        #expect(again.ossKey == ref.ossKey && store.puts.count == 1)   // HEAD hit: no second upload
        #expect(try h.messageHistory(limit: 5, scrollback: false).first?["media"] == "assigned")
        store.maxUploadBytes = 10
        h.mediaIndex.forget(messageKey: key)
        do { _ = try h.messageMedia(messageKey: key, hd: true); Issue.record("expected MEDIA_TOO_LARGE") } catch let e as ControlError { #expect(e.code == "MEDIA_TOO_LARGE") }
    }

    @Test func pictureRowsStillResolveThroughTheIndexAndUploadTheOriginal() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-image-message.json")))
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media2-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation], phase: .phase1), checkpoints: cps)
        h.mediaStore = WeComMediaStore(containerData: root)
        let store = RecordingObjectStore(); h.objectStore = store
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().last?.messageKey)
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "unknown", nowMs: 1_789_460_000_000)
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "image" && ref.contentType == "image/jpeg" && ref.matchedBy == "observed" && store.puts.count == 1 && ref.width == 1 && ref.height == 1)
    }
}
```

(`container(pictures:)` writes a 1×1 JPEG named by id in `Caches/Images/2026-09/<id>/<id>` — see the existing helper; the poster we add is the first candidate in the observation window for a `video` row test in Task 15's live list, not unit-tested here.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "MediaRouteTests|DispatcherTests"`
Expected: compile errors (`fileCandidates`, `messageMedia(messageKey:hd:)`, `objectStore` on fakes).

- [ ] **Step 3: Implement**

`CommandHandler.swift`: replace the `messageMedia` requirement with

```swift
    /// B13: the picture / file / video poster behind a row, uploaded to the configured object store; a signed GET URL comes back, never bytes.
    func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference
```

`WeComMediaStore.swift` — add:

```swift
    /// Files the client cached under `Caches/Files/<yyyy-MM>/<id>/<name>` (live 2026-09-22: the original name and size are kept),
    /// newest first; `sizeLabel` ("74K") narrows same-name files to the one the row shows.
    public func fileCandidates(name: String, sizeLabel: String?) -> [MediaCacheFile] {
        guard let profile = currentProfile() else { return [] }
        let fm = FileManager.default
        let base = containerData.standardizedFileURL.path
        var out: [MediaCacheFile] = []
        let filesDir = profile.appendingPathComponent("Caches/Files", isDirectory: true)
        for month in (try? fm.contentsOfDirectory(at: filesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [] {
            for item in (try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [] {
                let file = item.appendingPathComponent(name)
                guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), v.isRegularFile == true else { continue }
                let size = Int64(v.fileSize ?? 0)
                if let sizeLabel, !FileSizeLabel.matches(size: size, label: sizeLabel) { continue }
                let ms = Int64((v.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
                let rel = String(file.standardizedFileURL.path.dropFirst(base.count + 1))
                out.append(MediaCacheFile(root: Self.rootLabel, path: rel, size: size, modifiedMs: ms, kind: "file", signature: nil))
            }
        }
        return out.sorted { $0.modifiedMs > $1.modifiedMs }
    }

    /// Video bodies the client downloaded (`Caches/Videos`, only after a video was played), in a time window.
    public func videoBodyCandidates(sinceMs: Int64, untilMs: Int64) -> [MediaCacheFile] {
        candidates(sinceMs: sinceMs, untilMs: untilMs, kinds: ["Videos"]).filter { $0.kind == "video" }
    }

    /// Content type from the sniffed signature, else from the file name's extension, else octet-stream.
    public static func contentType(for file: MediaCacheFile, fileName: String) -> String {
        if let sig = file.signature, let type = ["jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic", "mp4": "video/mp4"][sig] { return type }
        return FileKind.info(forFileName: fileName)?.contentType ?? "application/octet-stream"
    }
```

`WeComCommandHandler+Media.swift` — replace `messageMedia` / `messageMediaNow` with:

```swift
    public func messageMedia(messageKey: String, hd: Bool) throws -> MediaReference {
        try mapErrors {
            guard let store = objectStore else { throw ControlError.ossNotConfigured("message.media needs oss.json on this Mac (imctl oss set, or the console's 设置 page)") }
            return try Self.withFileGrantTimeout("message.media") { try self.messageMediaNow(messageKey: messageKey, hd: hd, store: store) }
        }
    }

    func messageMediaNow(messageKey: String, hd: Bool, store: ObjectStore) throws -> MediaReference {
        let rows = try reader().chatMessages()
        let row = rows.first { $0.messageKey == messageKey }
        switch row?.kind {
        case .file?:
            let name = row?.fileName ?? ""
            let (file, matchedBy) = try resolveFile(messageKey: messageKey, name: name, sizeLabel: row?.fileSize)
            let up = try upload(file: file, messageKey: messageKey, fileName: name, contentType: WeComMediaStore.contentType(for: file, fileName: name), store: store)
            return MediaReference(messageKey: messageKey, kind: "file", matchedBy: matchedBy, fileName: name, bytes: file.size, contentType: up.contentType, ossKey: up.key, url: up.url, expiresAtMs: up.expiresAtMs)
        case .video?:
            let (poster, matchedBy) = try resolveMedia(messageKey: messageKey, kinds: ["Video_Thumbnail"])
            let posterName = "\(messageKey)-poster.jpg"
            let up = try upload(file: poster, messageKey: messageKey, fileName: posterName, contentType: WeComMediaStore.contentType(for: poster, fileName: posterName), store: store)
            var ref = MediaReference(messageKey: messageKey, kind: "video", matchedBy: matchedBy, fileName: posterName, bytes: poster.size, contentType: up.contentType, ossKey: up.key, url: up.url, expiresAtMs: up.expiresAtMs, duration: row?.duration, body: "absent")
            let window = mediaIndex.observation(for: messageKey).map { ($0.observedMs - Self.observedWindowBeforeMs, $0.observedMs + 3_600_000) } ?? (poster.modifiedMs - 60_000, poster.modifiedMs + 3_600_000)
            if let body = mediaStore.videoBodyCandidates(sinceMs: window.0, untilMs: window.1).first, body.size <= store.maxUploadBytes {
                let bodyName = "\(messageKey)-video.mp4"
                let bodyUp = try upload(file: body, messageKey: messageKey, fileName: bodyName, contentType: "video/mp4", store: store)
                ref.body = "uploaded"; ref.bodyOssKey = bodyUp.key; ref.bodyUrl = bodyUp.url
            }
            return ref
        default:
            let (file, matchedBy) = try resolveMedia(messageKey: messageKey)
            let chosen = hd ? (mediaStore.hdSibling(of: file) ?? file) : file
            let url = mediaStore.url(of: chosen)
            guard FileManager.default.fileExists(atPath: url.path) else {
                mediaIndex.forget(messageKey: messageKey)
                throw ControlError.mediaNotFound("cache file for \(messageKey) is gone (\(chosen.path)); the client may have cleared it")
            }
            let name = FileNames.sanitize(url.lastPathComponent, fallback: "picture")
            let displayName = FileKind.info(forFileName: name) != nil ? name : name + "." + (chosen.signature == "png" ? "png" : "jpg")
            let up = try upload(file: chosen, messageKey: messageKey, fileName: displayName, contentType: WeComMediaStore.contentType(for: chosen, fileName: displayName), store: store)
            let dims = Self.pixelSize(of: url)
            return MediaReference(messageKey: messageKey, kind: "image", matchedBy: matchedBy, fileName: displayName, bytes: chosen.size, contentType: up.contentType,
                                  ossKey: up.key, url: up.url, expiresAtMs: up.expiresAtMs, width: dims?.width, height: dims?.height)
        }
    }

    /// Object key `<baseDir>/<yyyy>/<MM>/<dd>/<messageKey>-<name>`; a HEAD hit skips the PUT, the URL is signed every time.
    func upload(file: MediaCacheFile, messageKey: String, fileName: String, contentType: String, store: ObjectStore) throws -> (key: String, url: String, expiresAtMs: Int64, contentType: String) {
        guard file.size <= store.maxUploadBytes else { throw ControlError.mediaTooLarge("\(fileName) is \(file.size) bytes; oss.json maxUploadBytes is \(store.maxUploadBytes)") }
        let day = Date(timeIntervalSince1970: Double(file.modifiedMs) / 1000)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        let key = "\(store.baseDir)/\(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))/\(messageKey)-\(FileNames.sanitize(fileName, fallback: "file"))"
        if try !store.exists(key: key) { try store.put(fileURL: mediaStore.url(of: file), key: key, contentType: contentType) }
        let url = try store.signedGetURL(key: key, expiresIn: TimeInterval(store.viewExpireSeconds))
        return (key, url.absoluteString, Clock.nowMs() + Int64(store.viewExpireSeconds) * 1000, contentType)
    }

    /// File rows: an earlier assignment, else the cached file with that name (and size label), the newest one on ties.
    func resolveFile(messageKey: String, name: String, sizeLabel: String?) throws -> (MediaCacheFile, String) {
        if let a = mediaIndex.assignment(for: messageKey) { return (a.file, a.matchedBy) }
        guard !name.isEmpty else { throw ControlError.mediaNotFound("row \(messageKey) shows no file name") }
        let taken = mediaIndex.assignedPaths
        let candidates = mediaStore.fileCandidates(name: name, sizeLabel: sizeLabel).filter { !taken.contains($0.root + ":" + $0.path) }
        let chosen: MediaCacheFile?
        if let o = mediaIndex.observation(for: messageKey) { chosen = candidates.min { abs($0.modifiedMs - o.observedMs) < abs($1.modifiedMs - o.observedMs) } } else { chosen = candidates.first }
        guard let chosen else { throw ControlError.mediaNotFound("no cached file named \"\(name)\"\(sizeLabel.map { " (\($0))" } ?? "") under Caches/Files; open the file in the client once, then ask again") }
        mediaIndex.assign(messageKey: messageKey, file: chosen, matchedBy: "name", nowMs: Clock.nowMs())
        return (chosen, "name")
    }

    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
```

Change `resolveMedia(messageKey:)` to `resolveMedia(messageKey: String, kinds: [String] = WeComMediaStore.cacheKinds)` and pass `kinds:` to both `mediaStore.candidates(…)` calls inside it; the file needs `import ImageIO`. `WeComMediaStore.encode(fileURL:…)` is no longer called — delete it and its `UniformTypeIdentifiers` import if nothing else uses them (`grep -rn "WeComMediaStore.encode" Sources Tests`; the old `MediaRouteTests` encode test is removed).

`RPCDispatcher.media`:

```swift
    /// `{messageKey, hd?=true}` → `MediaReference` as JSON (query, no command record; bytes never leave the Mac — the caller gets a signed URL).
    func media(_ params: [String: JSONValue]) -> Result<JSONValue, ControlError> {
        guard let key = params["messageKey"]?.stringValue, !key.isEmpty else { return .failure(.invalidParams("message.media requires messageKey")) }
        do {
            let content = try executor.serialized { try executor.handler.messageMedia(messageKey: key, hd: params["hd"]?.boolValue ?? true) }
            let data = try JSONEncoder().encode(content)
            return .success(try JSONValue.parse(String(decoding: data, as: UTF8.self)))
        } catch let e as ControlError { return .failure(e) } catch { return .failure(.internalError(String(describing: error))) }
    }
```

Descriptor: `("message.media", "The picture / file / video poster behind a media, file or video row, uploaded once to the configured OSS bucket: ossKey, a signed GET url (expires after oss.json viewExpireSeconds), fileName, bytes, contentType; never bytes. OSS_NOT_CONFIGURED without oss.json; MEDIA_NOT_FOUND when nothing can be tied to the key (open the conversation and ask again)", schema(["messageKey": ("string", "messageKey of a media / file / video row from message.history / message.observed"), "hd": ("boolean", "Prefer the downloaded original picture (default true)")], required: ["messageKey"]))`.

Protocol doc §6.39 — rewrite: parameters `{messageKey, hd?=true}`（1.0 的 `maxBytes` / `maxPixels` 仍接受但忽略）; result `{messageKey, kind:"image"|"file"|"video", matchedBy:"assigned"|"observed"|"window"|"name", fileName, bytes, contentType, ossKey, url, expiresAtMs, width?, height?, duration?, body?:"uploaded"|"absent", bodyOssKey?, bodyUrl?}`; the three resolution rules for pictures stay, add `file` (name + size under `Caches/Files`) and `video` (poster under `Video_Thumbnail`, body only when `Caches/Videos` has it); object key `<baseDir>/<yyyy>/<MM>/<dd>/<messageKey>-<name>`; HEAD before PUT; `OSS_NOT_CONFIGURED` / `MEDIA_TOO_LARGE` / `OSS_ERROR`; `任何传输都不带字节`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "MediaRouteTests|DispatcherTests|WeComCommandHandlerTests|ProtocolDocTests|MQTTBindingTests|RPCServiceTests|ConsoleModelTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests docs/protocol/im-control-protocol.md
git commit -m "feat(media): message.media uploads pictures / files / video posters to OSS once and returns signed URLs (kind, ossKey, url, expiresAtMs); file rows resolved by name + size under Caches/Files"
```

---

### Task 11: `imctl oss set|status|test`, daemon wiring (`--oss-config`, outbox sweep, `ossEnabled`)

**Files:**
- Create: `Sources/imctl/Commands/OSSCommand.swift`
- Modify: `Sources/imctl/IMCTL.swift:10` (register `OSSCommand.self` after `WeComCommand.self`), `Tests/imctlTests/CommandParsingTests.swift:9`
- Modify: `Sources/imctld/main.swift` (option, wiring)
- Create: `Tests/imctlTests/OSSCommandTests.swift`

**Interfaces:**
- Consumes: `OSSSettings`, `OSSObjectStore`, `WeComCommandHandler.objectStore` / `.fileFetcher`, `CommandExecutor.ossEnabled`.
- Produces: `imctl oss set --endpoint --bucket --base-dir --access-key-id [--access-key-secret | --secret-stdin] [--view-expire N] [--max-upload N] [--config PATH]`; `imctl oss status [--json] [--config]`; `imctl oss test [--config]` (1 KB probe object: PUT → HEAD → presigned GET fetched with URLSession → `download` → DELETE; prints each step, never the key or the URL's signature); `imctld run --oss-config <path>` (default `oss.json`).

- [ ] **Step 1: Write the failing tests**

`Tests/imctlTests/CommandParsingTests.swift`: expected root list becomes `[…, "wecom", "oss", "mcp", "setup"]`.

`Tests/imctlTests/OSSCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import imctl
@testable import OSSClient

@Suite("imctl oss")
struct OSSCommandTests {
    @Test func setWritesPrivateSettingsAndStatusMasksTheKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-cli-\(UUID().uuidString)/oss.json").path
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--access-key-secret", "test-secret", "--view-expire", "600", "--max-upload", "1024", "--config", file]).run()
        let s = try OSSSettings.load(from: URL(fileURLWithPath: file))
        #expect(s.bucket == "photos" && s.accessKeySecret == "test-secret" && s.viewExpireSeconds == 600 && s.maxUploadBytes == 1024 && s.region == "cn-hangzhou")
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        let status = try OSSStatusCommand.parse(["--config", file]).collect()
        #expect(status["present"] as? Bool == true && (status["summary"] as? String)?.contains("test-secret") == false && (status["summary"] as? String)?.contains("TEST…01") == true)
        // an empty secret keeps the stored one
        try OSSSetCommand.parse(["--endpoint", "https://oss-cn-hangzhou.aliyuncs.com", "--bucket", "photos", "--base-dir", "imctl", "--access-key-id", "TESTAKID0000000001", "--config", file]).run()
        #expect(try OSSSettings.load(from: URL(fileURLWithPath: file)).accessKeySecret == "test-secret")
        #expect(throws: (any Error).self) { try OSSSetCommand.parse(["--endpoint", "ftp://x", "--bucket", "b", "--base-dir", "d", "--access-key-id", "k", "--access-key-secret", "s"]).validate() }
        #expect(OSSCommand.configuration.subcommands.compactMap { $0.configuration.commandName } == ["set", "status", "test"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "OSSCommandTests|CommandParsingTests"`
Expected: compile errors (`OSSSetCommand` undefined), then the root list mismatch.

- [ ] **Step 3: Implement**

`Sources/imctl/Commands/OSSCommand.swift`:

```swift
import ArgumentParser
import ControlCore
import Foundation
import OSSClient

struct OSSCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "oss",
        abstract: "Object store behind message.media and message.sendFile{ossKey}: write oss.json (0600, never committed), show it masked, run a 1 KB round trip.",
        subcommands: [OSSSetCommand.self, OSSStatusCommand.self, OSSTestCommand.self]
    )
}

struct OSSSetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Write oss.json. An omitted --access-key-secret keeps the stored one; prefer --secret-stdin to keep it out of shell history.")
    @Option(help: "Endpoint, e.g. https://oss-cn-hangzhou.aliyuncs.com (region is derived from it).") var endpoint: String
    @Option(help: "Private bucket name.") var bucket: String
    @Option(name: .customLong("base-dir"), help: "Object key prefix, e.g. imctl.") var baseDir: String
    @Option(name: .customLong("access-key-id"), help: "RAM AccessKeyId (a sub-account limited to this bucket).") var accessKeyId: String
    @Option(name: .customLong("access-key-secret"), help: "AccessKeySecret; omit to keep the stored one.") var accessKeySecret: String?
    @Flag(name: .customLong("secret-stdin"), help: "Read the secret from stdin (first line).") var secretStdin = false
    @Option(name: .customLong("view-expire"), help: "Signed URL lifetime in seconds.") var viewExpire: Int = 1800
    @Option(name: .customLong("max-upload"), help: "Largest file message.media will upload, bytes.") var maxUpload: Int64 = 52_428_800
    @Option(help: "Settings file path.") var config: String = OSSSettings.defaultURL.path

    func validate() throws {
        guard endpoint.hasPrefix("https://") else { throw ValidationError("--endpoint must start with https://") }
        guard !bucket.isEmpty, !baseDir.isEmpty, !accessKeyId.isEmpty else { throw ValidationError("--bucket, --base-dir and --access-key-id are required") }
    }

    func run() throws {
        let url = URL(fileURLWithPath: config)
        var secret = accessKeySecret ?? ""
        if secretStdin { secret = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces) }
        if secret.isEmpty { secret = (try? OSSSettings.load(from: url))?.accessKeySecret ?? "" }
        guard !secret.isEmpty else { throw ValidationError("no secret given and none stored; pass --access-key-secret or --secret-stdin") }
        let settings = OSSSettings(endpoint: endpoint, bucket: bucket, baseDir: baseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")), accessKeyId: accessKeyId,
                                   accessKeySecret: secret, viewExpireSeconds: max(60, viewExpire), maxUploadBytes: max(1, maxUpload))
        guard !settings.region.isEmpty else { throw ValidationError("cannot derive the region from \(endpoint); expected a host like oss-cn-hangzhou.aliyuncs.com") }
        try settings.save(to: url)
        print("saved \(config) (0600): \(settings.summary)")
        print("restart the daemon (状态页 › 重启, or launchctl kickstart) so it picks up oss.json; then `imctl oss test`")
    }
}

struct OSSStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether oss.json exists and its masked summary (never the secret).")
    @Option(help: "Settings file path.") var config: String = OSSSettings.defaultURL.path
    @Flag var json = false

    func collect() throws -> [String: Any] {
        var out: [String: Any] = ["file": config, "present": FileManager.default.fileExists(atPath: config)]
        if out["present"] as? Bool == true {
            let s = try OSSSettings.load(from: URL(fileURLWithPath: config))
            out["summary"] = s.summary; out["region"] = s.region; out["viewExpireSeconds"] = s.viewExpireSeconds; out["maxUploadBytes"] = s.maxUploadBytes
        }
        return out
    }

    func run() throws {
        let out = try collect()
        if json { print(String(decoding: try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)) }
        else { for (k, v) in out.sorted(by: { $0.key < $1.key }) { print("\(k): \(v)") } }
    }
}

struct OSSTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Round trip a 1 KB probe object: PUT → HEAD → presigned GET → download → DELETE. Prints steps and HTTP codes only.")
    @Option(help: "Settings file path.") var config: String = OSSSettings.defaultURL.path

    func run() throws {
        let settings = try OSSSettings.load(from: URL(fileURLWithPath: config))
        let store = OSSObjectStore(settings: settings)
        let key = "\(settings.baseDir)/_probe/\(UUID().uuidString.lowercased()).txt"
        let payload = Data(repeating: 0x61, count: 1024)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-probe-\(UUID().uuidString).txt")
        try payload.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        print("1/5 PUT \(key)"); try store.put(fileURL: temp, key: key, contentType: "text/plain")
        print("2/5 HEAD"); guard try store.exists(key: key) else { throw ValidationError("HEAD after PUT says the object is missing") }
        print("3/5 presigned GET (\(settings.viewExpireSeconds) s)")
        let url = try store.signedGetURL(key: key, expiresIn: 60)
        let fetched = try URLSessionOSSTransport().send(URLRequest(url: url), uploading: nil, downloadingTo: nil)
        guard fetched.status == 200, fetched.body == payload else { throw ValidationError("presigned GET returned HTTP \(fetched.status) / \(fetched.body.count) bytes") }
        print("4/5 download via HEAD + GET")
        let back = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-oss-probe-back-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: back) }
        guard try store.download(key: key, to: back, maxBytes: 4096) == 1024 else { throw ValidationError("download size mismatch") }
        print("5/5 DELETE"); try store.delete(key: key)
        print("ok: \(settings.summary)")
    }
}
```

`IMCTL.swift`: insert `OSSCommand.self` after `WeComCommand.self`.

`Sources/imctld/main.swift`: add the option `@Option(name: .customLong("oss-config"), help: "OSS settings (imctl oss set); when the file exists, message.media uploads there and message.sendFile accepts ossKey.") var ossConfig: String = OSSSettings.defaultURL.path`, `import OSSClient`, and after the wecom block:

```swift
        handler.fileFetcher.sweep()
        if FileManager.default.fileExists(atPath: ossConfig) {
            let oss = try OSSSettings.load(from: URL(fileURLWithPath: ossConfig))
            handler.objectStore = OSSObjectStore(settings: oss)
            executor.ossEnabled = { true }
            log.info("oss: enabled \(oss.summary)")
        } else {
            log.info("oss: disabled (no \(ossConfig)); message.media and message.sendFile{ossKey} answer OSS_NOT_CONFIGURED")
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "OSSCommandTests|CommandParsingTests"` then `swift build`.
Expected: PASS; the daemon builds with the new option.

- [ ] **Step 5: Commit**

```bash
git add Sources/imctl Sources/imctld/main.swift Tests/imctlTests
git commit -m "feat(cli): imctl oss set|status|test; imctld --oss-config wires OSSObjectStore into message.media / sendFile{ossKey}, sweeps the outbox at start"
```

---

### Task 12: Console — OSS settings block, 发文件 section, host allowlist, file / video rows with signed links

**Files:**
- Modify: `Sources/imctl-console/Model/ConsoleModel.swift`, `Sources/imctl-console/Model/RPCService.swift`
- Modify: `Sources/imctl-console/Views/SettingsView.swift`, `Views/SendView.swift`, `Views/PolicyView.swift`, `Views/ConversationsView.swift`
- Test: `Tests/imctl-consoleTests/ConsoleModelTests.swift`, `Tests/imctl-consoleTests/RPCServiceTests.swift`

**Interfaces:**
- Consumes: `OSSSettings`, `SendFilePolicy` via `policy.get`, `message.sendFile`, `message.media` (`url`).
- Produces: `RPCService.sendFileParams(target:url:ossKey:fileName:)`; `ConsoleModel.ossEnrolled`, `StoredSettings.ossEndpoint/ossBucket/ossBaseDir/ossAccessKeyId/hasOSSSecret/ossViewExpireSeconds/ossMaxUploadBytes`, `loadStoredSettings(mqttURL:proxyURL:ossURL:)`, `saveOSS(endpoint:bucket:baseDir:accessKeyId:accessKeySecret:viewExpireSeconds:maxUploadBytes:to:)`, `ossTest()`, `ossTestResult`, `sendFile(target:url:ossKey:fileName:) async -> String`, `allowedHosts`, `policyHosts(allow:deny:)`, `MediaLink{kind, fileName, url, expiresAtMs, duration?}`, `mediaLinks: [String: MediaLink]`, `static link(fromMediaResult:) -> MediaLink?` (replaces `image(fromMediaResult:)`).

- [ ] **Step 1: Write the failing tests**

`Tests/imctl-consoleTests/RPCServiceTests.swift` — add:

```swift
    @Test func sendFileParamsCarryExactlyOneSource() {
        let byURL = RPCService.sendFileParams(target: "文件传输助手", url: "https://cdn.example/a.pdf", ossKey: "", fileName: "")
        #expect(byURL["url"] == .string("https://cdn.example/a.pdf") && byURL["ossKey"] == nil && byURL["fileName"] == nil && byURL["idempotencyKey"]?.stringValue?.hasPrefix("console-") == true)
        let byKey = RPCService.sendFileParams(target: "t", url: "", ossKey: "imctl/a.pdf", fileName: "b.pdf")
        #expect(byKey["ossKey"] == .string("imctl/a.pdf") && byKey["url"] == nil && byKey["fileName"] == .string("b.pdf"))
    }
```

`Tests/imctl-consoleTests/ConsoleModelTests.swift` — replace `mediaResultDecodesToAnImageOrNil` with:

```swift
    @Test func mediaResultDecodesToALinkOrNil() throws {
        let ok = ConsoleModel.link(fromMediaResult: .object(["kind": .string("file"), "fileName": .string("a.pdf"), "url": .string("https://b.example/a.pdf?sig"), "expiresAtMs": .number(5), "duration": .null]))
        #expect(ok?.kind == "file" && ok?.fileName == "a.pdf" && ok?.url == "https://b.example/a.pdf?sig" && ok?.expiresAtMs == 5)
        #expect(ConsoleModel.link(fromMediaResult: .object(["kind": .string("image")])) == nil)
    }
```

and extend `settingsRoundTripKeepsEveryStoredField`:

```swift
        let oss = dir.appendingPathComponent("oss.json")
        model.saveOSS(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "test-secret", viewExpireSeconds: 900, maxUploadBytes: 2048, to: oss)
        let o = model.loadStoredSettings(mqttURL: mqtt, proxyURL: proxy, ossURL: oss)
        #expect(o.ossEndpoint == "https://oss-cn-hangzhou.aliyuncs.com" && o.ossBucket == "photos" && o.ossBaseDir == "imctl" && o.ossAccessKeyId == "TESTAKID0000000001" && o.hasOSSSecret && o.ossViewExpireSeconds == 900 && o.ossMaxUploadBytes == 2048)
        model.saveOSS(endpoint: "https://oss-cn-hangzhou.aliyuncs.com", bucket: "photos", baseDir: "imctl", accessKeyId: "TESTAKID0000000001", accessKeySecret: "", viewExpireSeconds: 900, maxUploadBytes: 2048, to: oss)
        #expect(try OSSSettings.load(from: oss).accessKeySecret == "test-secret")
```

(`import OSSClient` at the top of that test file; the test target already links `imctl-console`, add `"OSSClient"` to its dependencies in `Package.swift`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter "RPCServiceTests|ConsoleModelTests"`
Expected: compile errors (`sendFileParams`, `link(fromMediaResult:)`, `saveOSS`, `ossURL:` undefined).

- [ ] **Step 3: Implement**

`RPCService.swift` — add:

```swift
    static func sendFileParams(target: String, url: String, ossKey: String, fileName: String) -> [String: JSONValue] {
        var p: [String: JSONValue] = ["target": .string(target), "idempotencyKey": .string(idempotencyKey())]
        let u = url.trimmingCharacters(in: .whitespaces), k = ossKey.trimmingCharacters(in: .whitespaces), n = fileName.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { p["url"] = .string(u) } else if !k.isEmpty { p["ossKey"] = .string(k) }
        if !n.isEmpty { p["fileName"] = .string(n) }
        return p
    }
```

`ConsoleModel.swift` — `import OSSClient`; state: `var ossEnrolled = false`, `var ossTestResult = ""`, `var sendFileResult = ""`; in `refreshLocal()` add `ossEnrolled = FileManager.default.fileExists(atPath: OSSSettings.defaultURL.path)`. Replace the media block:

```swift
    /// B13: what message.media returned for a row: a signed URL (pictures are fetched from it for the thumbnail).
    struct MediaLink: Equatable {
        var kind: String; var fileName: String; var url: String; var expiresAtMs: Int64; var duration: String?
    }
    var mediaLinks: [String: MediaLink] = [:]
    var mediaImages: [String: NSImage] = [:]
    var mediaErrors: [String: String] = [:]
    private var mediaLoading: Set<String> = []

    func loadMedia(for key: String) async {
        guard !key.isEmpty, mediaLinks[key] == nil, mediaErrors[key] == nil, !mediaLoading.contains(key) else { return }
        mediaLoading.insert(key); defer { mediaLoading.remove(key) }
        guard let r = await rpc("message.media", ["messageKey": .string(key)], log: false) else { mediaErrors[key] = lastError ?? "message.media failed"; return }
        guard let link = Self.link(fromMediaResult: r) else { mediaErrors[key] = "message.media: 返回里没有 url"; return }
        mediaLinks[key] = link
        if link.kind == "image", let url = URL(string: link.url) {
            let image = await Task.detached { (try? Data(contentsOf: url)).flatMap(NSImage.init(data:)) }.value
            if let image { mediaImages[key] = image } else { mediaErrors[key] = "签名地址拉图失败（可点「打开」在浏览器看）" }
        }
    }

    static func link(fromMediaResult r: JSONValue) -> MediaLink? {
        guard let o = r.objectValue, let url = o["url"]?.stringValue, let kind = o["kind"]?.stringValue else { return nil }
        return MediaLink(kind: kind, fileName: o["fileName"]?.stringValue ?? "", url: url, expiresAtMs: Int64(o["expiresAtMs"]?.numberValue ?? 0), duration: o["duration"]?.stringValue)
    }
```

Add next to `send(target:text:)`:

```swift
    /// B13: message.sendFile from the 发送 page (url or ossKey, optional name).
    func sendFile(target: String, url: String, ossKey: String, fileName: String) async -> String {
        guard let r = await rpc("message.sendFile", RPCService.sendFileParams(target: target, url: url, ossKey: ossKey, fileName: fileName)) else { return log.last?.body ?? "error" }
        return RPCService.pretty(r)
    }

    var allowedHosts: [String] { policyState["sendFile"]?.objectValue?["allowedHosts"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    func policyHosts(allow: String? = nil, deny: String? = nil) async {
        let cli = self.cli
        var args = ["policy", "hosts"]
        if let allow { args += ["--allow", allow] }
        if let deny { args += ["--deny", deny] }
        let result = try? await Task.detached { try cli.run(args) }.value
        append("policy hosts", result?.output ?? "failed", error: (result?.status ?? 1) != 0)
        await loadPolicy()
    }

    func ossTest() async {
        let cli = self.cli
        let result = try? await Task.detached { try cli.run(["oss", "test"]) }.value
        ossTestResult = result?.output ?? "imctl oss test failed to start"
        append("oss test", ossTestResult, error: (result?.status ?? 1) != 0)
    }
```

`StoredSettings`: add `var ossEndpoint = "", ossBucket = "", ossBaseDir = "imctl", ossAccessKeyId = "", hasOSSSecret = false, ossViewExpireSeconds = 1800, ossMaxUploadBytes: Int64 = 52_428_800`. `loadStoredSettings(mqttURL:proxyURL:ossURL: URL = OSSSettings.defaultURL)` fills them from `try? OSSSettings.load(from: ossURL)`. Add:

```swift
    func saveOSS(endpoint: String, bucket: String, baseDir: String, accessKeyId: String, accessKeySecret: String, viewExpireSeconds: Int, maxUploadBytes: Int64, to url: URL = OSSSettings.defaultURL) {
        let existing = try? OSSSettings.load(from: url)
        let keptSecret = accessKeySecret.isEmpty ? (existing?.accessKeySecret ?? "") : accessKeySecret
        do {
            try OSSSettings(endpoint: endpoint, bucket: bucket, baseDir: baseDir.trimmingCharacters(in: CharacterSet(charactersIn: "/")), accessKeyId: accessKeyId, accessKeySecret: keptSecret,
                            viewExpireSeconds: max(60, viewExpireSeconds), maxUploadBytes: max(1, maxUploadBytes)).save(to: url)
            append("oss set", "saved \(url.path) (0600); restart the daemon, then test")
        } catch { append("oss set", String(describing: error), error: true) }
        ossEnrolled = FileManager.default.fileExists(atPath: url.path)
    }
```

`SettingsView.swift` — state `ossEndpoint, ossBucket, ossBaseDir, ossAccessKeyId, ossSecret, ossViewExpire, ossMaxUpload` (strings), filled in `load()` from `stored`; new section before the trailing note:

```swift
            Section("对象存储 OSS（写 oss.json，0600；不入库。message.media 回签名地址、sendFile 可用 ossKey）\(model.ossEnrolled ? " · 已存在，下面是当前值" : "")") {
                TextField("endpoint https://oss-<region>.aliyuncs.com", text: $ossEndpoint)
                TextField("bucket（私有）", text: $ossBucket)
                TextField("base-dir（对象键前缀）", text: $ossBaseDir)
                TextField("AccessKeyId（建议专用 RAM 子账号，只授此 bucket）", text: $ossAccessKeyId)
                SecureField(stored.hasOSSSecret ? "AccessKeySecret：已保存（留空则保留原值）" : "AccessKeySecret", text: $ossSecret)
                TextField("签名地址有效期（秒）", text: $ossViewExpire)
                TextField("单文件上传上限（字节）", text: $ossMaxUpload)
                HStack {
                    Button("保存 OSS 设置") {
                        model.saveOSS(endpoint: ossEndpoint, bucket: ossBucket, baseDir: ossBaseDir, accessKeyId: ossAccessKeyId, accessKeySecret: ossSecret,
                                      viewExpireSeconds: Int(ossViewExpire) ?? 1800, maxUploadBytes: Int64(ossMaxUpload) ?? 52_428_800)
                        load()
                    }
                    .disabled(ossEndpoint.isEmpty || ossBucket.isEmpty || ossAccessKeyId.isEmpty || (ossSecret.isEmpty && !stored.hasOSSSecret))
                    Button("测试往返（1 KB 探针）") { Task { await model.ossTest() } }.disabled(!model.ossEnrolled || model.busy)
                    Button("重新读取") { load() }
                }
                if !model.ossTestResult.isEmpty { ResultPane(title: "imctl oss test", text: model.ossTestResult, minHeight: 80) }
                Text("密钥只进本机 oss.json；改完要在「状态」页重启守护进程。").font(.caption).foregroundStyle(.secondary)
            }
```

`SendView.swift` — state `fileURL = "", ossKey = "", fileName = ""`, `fileResult = ""`; section after the send section:

```swift
            Section("发文件（message.sendFile）— 下载到本机 outbox，⌘V 贴进输入框，回车发出；只收 https（域名在策略页名单）或 ossKey") {
                TextField("https 地址（图片 / 视频 / pdf / office / zip / txt）", text: $fileURL)
                TextField("或 ossKey（配置好的 bucket 里的对象键）", text: $ossKey)
                TextField("文件名（可选，默认取地址末段）", text: $fileName)
                HStack {
                    Button("发文件到 \(target.isEmpty ? "…" : target)") {
                        let t = target, u = fileURL, k = ossKey, n = fileName
                        Task { fileResult = await model.sendFile(target: t, url: u, ossKey: k, fileName: n) }
                    }
                    .disabled(target.isEmpty || (fileURL.isEmpty && ossKey.isEmpty) || model.busy)
                    Text("来源域名：\(model.allowedHosts.isEmpty ? "无（全部拒绝）" : model.allowedHosts.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                Text("视频按大小放宽超时（最多 180 s）；粘贴那几百毫秒会覆盖你的剪贴板并恢复。").font(.caption).foregroundStyle(.orange)
                if !fileResult.isEmpty { ResultPane(title: "message.sendFile 结果", text: fileResult, minHeight: 120) }
            }
```

`PolicyView.swift` — state `host = ""`; section after the send-allowlist section:

```swift
            Section("文件来源域名（policy.json › sendFile.allowedHosts）— message.sendFile 只从这些 https 域名下载；空 = 全部拒绝") {
                ForEach(model.allowedHosts, id: \.self) { h in
                    HStack { Text(h); Spacer(); Button("收回", role: .destructive) { Task { await model.policyHosts(deny: h) } } }
                }
                HStack {
                    TextField("域名（精确 cdn.example，或后缀 .aliyuncs.com）", text: $host)
                    Button("允许") { let h = host; host = ""; Task { await model.policyHosts(allow: h) } }.disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
```

`ConversationsView.swift` — row body:

```swift
                        if ["media", "file", "video"].contains(m["kind"] ?? "") {
                            MediaRowView(messageKey: m["messageKey"] ?? "", kind: m["kind"] ?? "", label: Self.label(for: m), status: m["media"] ?? "")
                        } else {
                            Text(m["text"] ?? "").textSelection(.enabled)
                        }
```

with `static func label(for m: [String: String]) -> String { switch m["kind"] { case "file": return "📎 \(m["fileName"] ?? "文件")\(m["fileSize"].map { " · \($0)" } ?? "")"; case "video": return "🎬 视频\(m["duration"].map { " · \($0)" } ?? "")"; default: return "图片 / 表情 / 卡片" } }` and `MediaRowView`:

```swift
struct MediaRowView: View {
    @Environment(ConsoleModel.self) private var model
    let messageKey: String
    let kind: String
    let label: String
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            if let image = model.mediaImages[messageKey] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 320, maxHeight: 240)
            }
            if let link = model.mediaLinks[messageKey] {
                HStack {
                    Text(link.url).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button("打开") { if let u = URL(string: link.url) { NSWorkspace.shared.open(u) } }.font(.caption)
                    Button("复制地址") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url, forType: .string) }.font(.caption)
                }
            } else if let error = model.mediaErrors[messageKey] {
                Text("[\(error)]").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button("重试") { model.mediaErrors[messageKey] = nil; Task { await model.loadMedia(for: messageKey) } }.font(.caption)
            } else {
                Text("[\(status.isEmpty ? "读取中" : status)]").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: messageKey) { await model.loadMedia(for: messageKey) }
    }
}
```

(`import AppKit` in `ConversationsView.swift`.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "RPCServiceTests|ConsoleModelTests"` then `swift build --product imctl-console`.
Expected: PASS; the console builds.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/imctl-console Tests/imctl-consoleTests
git commit -m "feat(console): OSS settings block with round-trip test, 发文件 (message.sendFile) section, file-source host allowlist, file / video rows with signed links"
```

---

### Task 13: Documentation sync — README, ops, agents, Java contract

**Files:**
- Modify: `README.md:22-28` (module table, CLI list), `docs/ops/permissions.md`, `docs/protocol/agents-mcp.md`, `docs/agents/skills/imctl/SKILL.md`, `docs/protocol/java-consumer.md`
- Test: `swift test --filter ProtocolDocTests` (unchanged; the protocol doc was updated in Tasks 1, 2, 6, 10)

- [ ] **Step 1: Write the edits**

`README.md`: in the `imctl` CLI row add `` `oss` `` after `` `wecom` `` and `` `policy hosts` `` in the policy mention; in the `WeComAdapter` row append `；B13 文件发送（outbox → ⌘V → 回车）与 file / video 行`; add a row after `WeComAPI`:

```markdown
| `OSSClient` | 阿里云 OSS 对象存储（V4 签名，PUT / HEAD / GET / DELETE / 预签名 GET）：`message.media` 把图片 / 文件 / 视频封面传上去回签名地址，`message.sendFile{ossKey}` 从中下载；`oss.json`（0600）、`imctl oss set|status|test`；未配置回 `OSS_NOT_CONFIGURED` | B13 |
```

`docs/ops/permissions.md` — append a section:

```markdown
## 剪贴板（B13 `message.sendFile`）

发文件时守护进程会：快照你当前的剪贴板 → 放入 outbox 文件的 URL → 对企微投一次 ⌘V（用户 2026-09-22 17:43 批准的唯一新按键）→ 确认输入框出现附件 → 恢复快照。中间几百毫秒内你若正好复制了东西，会被恢复覆盖；发送失败也会恢复。剪贴板不需要额外授权。outbox 在 `~/Library/Application Support/imctl/outbox/`（0700），文件发完即删、守护进程启动时清空。
```

`docs/protocol/agents-mcp.md`: rule 1 — replace `（`kind: media` 的行用 `message.media{messageKey}` 取图片，base64）` with `（`kind: media|file|video` 的行用 `message.media{messageKey}` 取 OSS 签名地址；不再有 base64，没配 `oss.json` 时 `OSS_NOT_CONFIGURED`）`; add rule `5. **发文件**：`message.sendFile{target, url|ossKey, fileName?, idempotencyKey}`——只收 https 且域名在 `policy.json.sendFile.allowedHosts`（`imctl policy hosts`），或已配置 bucket 的 `ossKey`；证据 = 新出现的 media / file / video 行；`PASTE_FAILED` 表示没贴进输入框、什么都没发。`; error table rows for `SOURCE_NOT_ALLOWED`, `PASTE_FAILED`, `OSS_NOT_CONFIGURED`.

`docs/agents/skills/imctl/SKILL.md`: table rows — `message.history` mentions `kind: message|media|file|video`, `fileName / fileSize / fileType / duration`; `message.media` → `A signed OSS URL for the picture / file / video poster behind a media, file or video row (`messageKey`, `hd`); never bytes; `OSS_NOT_CONFIGURED` when the Mac has no oss.json`; new row `` `message.sendFile` | Send a file fetched from an https URL (host must be on the Mac's policy list) or an OSS object key; needs `idempotencyKey`; `PASTE_FAILED` = nothing was sent ``; add to "Rules you must keep": `- Files: only https sources on allowlisted hosts or `ossKey`; the daemon pastes with ⌘V and presses Return — say which file you sent and to whom.`

`docs/protocol/java-consumer.md`: in the method list add `` `message.sendFile{target, url|ossKey, fileName?, idempotencyKey}` ``; add a bullet: `- **文件**：`message.sendFile` 只给地址（https，域名要在控制器本机的 `policy.json.sendFile.allowedHosts`）或 `ossKey`；`message.media` 对图片 / 文件 / 视频回 OSS **签名地址**（`url`，`expiresAtMs` 过期后再问一次），MQTT 上永远没有文件内容。`

- [ ] **Step 2: Verify**

Run: `swift test --filter ProtocolDocTests && bash scripts/check-secrets.sh | grep -E "docs/(ops|protocol|agents)|README" || echo clean`
Expected: PASS; `clean`.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/ops/permissions.md docs/protocol/agents-mcp.md docs/agents/skills/imctl/SKILL.md docs/protocol/java-consumer.md
git commit -m "docs: B13 — sendFile / file & video rows / OSS signed URLs in README, permissions (clipboard), agents-mcp, skill, java-consumer"
```

---

### Task 14: Version 1.0.2, the one full `swift test`, secrets scan, install the build

**Files:**
- Modify: `Sources/ControlCore/IMCTLVersion.swift`, `Tests/ControlCoreTests/IMCTLVersionTests.swift`, `packaging/pkg/companion/README-另一台Mac.txt`, `packaging/pkg/companion/install-on-another-mac.command`, `docs/protocol/im-control-protocol.md` (the two `"version": "1.0.1"` examples), `docs/ops/installer.md`

- [ ] **Step 1: Failing test first**

Change `IMCTLVersionTests` expectation to `"1.0.2"`; run `swift test --filter IMCTLVersionTests` → FAIL.

- [ ] **Step 2: Bump**

`IMCTLVersion.swift`: add `/// 1.0.2 (2026-09-22): B13 — message.sendFile, file / video rows, message.media over OSS.` and `string = "1.0.2"`. `sed -i '' 's/1\.0\.1/1.0.2/g'` on the two companion files and the two protocol-doc examples; the companion README build number becomes `git rev-list --count HEAD` + 1 (the number the release commit will have); `docs/ops/installer.md`: add `2026-09-22 晚：`imctl-1.0.2.pkg`（B13）`.

- [ ] **Step 3: The one full run**

```bash
swift build && swift test 2>&1 | grep -E "✘|Test run with" ; bash scripts/check-secrets.sh | grep -v -E "examples/|proxy/" || echo "no new hits"; git status --short
```
Expected: every suite passes (count them: 1.0.1 had 324 / 84; B13 adds ≈ 30 tests); the only secret-scanner hits are the pre-existing `examples/` / `proxy/` placeholders; no `.raw.json` / temp files.

- [ ] **Step 4: Commit and install**

```bash
git add -A Sources Tests packaging docs
git commit -m "release: 1.0.2 — B13 message.sendFile, file / video rows, message.media over OSS signed URLs"
git push origin main
PKG=$(scripts/build-pkg.sh release) && installer -pkg "$PKG" -target CurrentUserHomeDirectory && launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl && sleep 4 && ~/Applications/imctl.app/Contents/MacOS/imctl --version && ~/Applications/imctl.app/Contents/MacOS/imctl setup --check
```
Expected: `1.0.2`, five ✔, daemon log `imctld 1.0.2 running` and `oss: disabled` (until the user enters the key in Task 15).

---

### Task 15: Live calibration and the gate report (user present; sends only to `文件传输助手`)

**Files:**
- Create: `docs/gates/2026-09-22-b13-sendfile-rich-rows-oss.md`
- Possibly modify (calibration): `Sources/WeComAdapter/Actions/SendFile.swift` (`composerSignal` rule), `docs/ops/permissions.md`

- [ ] **Step 1: OSS settings and round trip (user enters the key; it never goes through chat)**

The user runs in their terminal (or the console 设置 page): `~/Applications/imctl.app/Contents/MacOS/imctl oss set --endpoint https://oss-cn-hangzhou.aliyuncs.com --bucket <bucket> --base-dir imctl --access-key-id <RAM AccessKeyId> --secret-stdin` then `launchctl kickstart -k gui/$(id -u)/com.sunkailun.imctl` and `~/Applications/imctl.app/Contents/MacOS/imctl oss test`.
Expected: `1/5 … 5/5 … ok`. On `HTTP 403 SignatureDoesNotMatch`: the error XML OSS returns carries `<CanonicalRequest>` and `<StringToSign>`; temporarily print `response.body` in `OSSObjectStore.send` (never commit that), diff the server's canonical request against `OSSSigner.canonicalRequest(...)` for the same inputs, fix the canonical form (header set, encoding, blank-line layout), add the corrected expectation to `OSSSignerTests`, re-run `imctl oss test`. Record the outcome in the gate.

- [ ] **Step 2: Policy for the source host**

`~/Applications/imctl.app/Contents/MacOS/imctl policy hosts --allow .aliyuncs.com` (the user's OSS host) — this is the user's decision; note it in the gate and the wiki.

- [ ] **Step 3: Composer signal calibration (spec §11.1)**

Through Claude Code's MCP (or `imctl call`): `message.sendFile{target:"文件传输助手", url:"<https png on the allowed host>", idempotencyKey:"b13-live-png-1"}`. Read the daemon log lines `paste` / `composerBefore` / `composerAfterPaste` / `composerAfter` in the result `details`. Expected: `composerAfterPaste != composerBefore` (the fake changed `AXNumberOfCharacters`; live, the value length, the character count or the child count must change). If none changes within 3 s → `PASTE_FAILED` even though the chip is visible: dump the composer subtree (`imctl dump-tree --root main-window --depth 14 --raw --output /tmp-scratch/composer.raw.json` while a file is pasted manually), find the attribute that does change, extend `composerSignal` accordingly, add a unit test for the new attribute, re-run.

- [ ] **Step 4: The four sends and the rejections**

Each once, all to `文件传输助手`, evidence = the result's `evidence` + `message.observed{origin:"controller", commandId}` in `event.replay`:
1. png via `url` (`b13-live-png-1`) → `kind:"image"`, row `kind=media`.
2. pdf via `url` (`b13-live-pdf-1`) → `kind:"file"`, row `kind=file`, `fileName` matches.
3. docx via `ossKey` (`b13-live-docx-1`; upload the docx to the bucket first with `imctl oss test`'s pattern or the OSS console) → `kind:"file"`.
4. mp4 (~24 MB) via `url` (`b13-live-mp4-1`) → `kind:"video"`, row `kind=video`, `duration` present; note the latency.
5. `url` on a host not in the list → `SOURCE_NOT_ALLOWED`, no request, nothing pasted.
6. Replay `b13-live-pdf-1` → same `commandId`, no new row.
7. `message.media` on the pdf row and on the mp4 row → `MediaReference` with `url`; open the url in a browser (user) → the file / poster loads; second call → same `ossKey`, no second PUT (daemon log).
8. `message.history{limit:10}` → the new rows carry `fileName / fileSize / fileType / duration` and `media: assigned`.

- [ ] **Step 5: Gate report**

`docs/gates/2026-09-22-b13-sendfile-rich-rows-oss.md` per `TESTING_SPEC.md`: 条件（macOS 27.0 / 5.0.11 / 1.0.2 build N / OSS region only, bucket name masked as `<bucket>`）, 实现（files, test counts before / after）, 单测（`swift test` numbers, `ForbiddenAPITests`, `check-secrets`）, 活体表（steps 1–8 with latencies, event ids, evidence strings — no signed URLs, no keys）, 结论与未闭环（composer signal rule chosen; anything that needed calibration; inbound video body path still untested; 群发带文件 / 附带文字 / STS out of scope), 待用户（RAM key rotation done?; second Mac).

```bash
git add docs/gates/2026-09-22-b13-sendfile-rich-rows-oss.md Sources Tests docs/ops
git commit -m "docs(gate): B13 live — png/pdf/docx/mp4 to 文件传输助手 via url + ossKey, host rejection, key replay, message.media over OSS, composer-signal calibration"
git push origin main
```

---

### Task 16: Archive the round to LLM-Wiki (user rule: every imctl round)

- [ ] **Step 1:** Invoke the `llm-wiki-archive` skill with `imctl 1.0.2 / B13：message.sendFile、file/video 行、message.media 走 OSS 签名地址（2026-09-22）`: new `queries/2026-09-22-imctl-B13文件发送富消息行与OSS取回记忆.md`, overwrite `topics/macOS企业微信Rust控制器与Java对接.md` 当前口径 (paste key ⌘V approved, sendFile flow, OSS route, client facts from §2 of the spec), `repos/imctl.md` 当前基线 (HEAD, 1.0.2, test counts, `OSSClient` target, `oss.json`, `policy.json.sendFile`), route page, review rows (close "27.0 send path" already closed; open "inbound video body", "second Mac on 1.0.2", "RAM key rotated?"), handoff `handoffs/2026-09-22-imctl-B13后接续交接.md`, overview row, log, `refresh_facts.rb`, `build_index.rb`, both validators 0 failures, commit, push.
- [ ] **Step 2:** Update the auto-memory file `wecom-rust-controller-discussion-only.md` (one paragraph: B13 shipped, key facts, no secrets) and its `MEMORY.md` hook.

---

## Self-review notes (written with the plan)

- Spec coverage: §3 scope → Tasks 1–12; §4.1 → 1, 8; §4.2 → 6; §4.3 → 10; §4.4 → 1, 8, 10; §5 → 9, 11, 12; §6 → 2, 3, 4, 5, 7; §7 → 7, 8; §8 → 6; §9 → 12; §10 → 14, 15; §11 → 15; §12 → 14.
- Names are consistent across tasks: `SendFileSource`, `SendFileResult`, `FetchedFile`, `FileFetcher.fetch(url:fileName:policy:)` / `fetch(ossKey:fileName:store:maxBytes:)`, `WeComActions.sendFile(_:reader:checkpoints:timeout:pollInterval:hooks:)`, `CommandHandler.messageSendFile(target:source:fileName:checkpoint:afterSubmit:)`, `CommandHandler.messageMedia(messageKey:hd:)`, `ObjectStore` (7 members incl. `baseDir`, `maxUploadBytes`, `viewExpireSeconds`, `delete`), `OSSObjectStore(settings:transport:now:)`, `OSSSigner.signedHeaders(method:bucket:key:query:headers:date:)`, `presignedQuery(method:bucket:key:expiresIn:date:)`.
- Known judgement calls left to the live step: the composer "attachment present" signal (§11.1), the exact V4 canonical form (verified by `imctl oss test`), and whether `willPerformHTTPRedirection` fires under a `URLProtocol` stub (the test asserts the outcome, not the callback).
