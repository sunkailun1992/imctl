---
name: imctl
description: Drive the user's WeCom (企业微信) desktop client through the local imctl daemon's MCP tools — read conversations and history, send text to allowlisted conversations with an idempotency key, watch events. Use whenever the user asks to read, reply in, or automate WeCom chats on this Mac.
---

# imctl — WeCom control through the local daemon

The `imctl` MCP server (`imctl mcp serve`) forwards every tool call to the running `imctld` daemon,
which drives the WeCom desktop client through Accessibility. One daemon serves the console, the CLI,
Java over MQTT and you — same serial queue, same policy, same event log.

## Workflow

1. **Check the client**: `account.status` (windowReachable, activeTitle) and `controller.describe` (policy summary). When something does not work or the Mac is new, call `controller.readiness` and tell the user its `nextStep`; do not run the fix yourself — installing, restarting or reconfiguring the daemon is the user's call, and never resume a pause you did not set. `fix.action` is a quick-action type for a person to click in the console or `imctl doctor --fix`; relay it, never run it.
2. **Read before writing**: `conversation.list` → `conversation.read {target}` → `message.history {limit: 30}`.
   `conversation.read` opens the conversation in the client (any title by default; if the policy's `gateReads`
   is on and you get `TARGET_NOT_ALLOWED`, walk there with `client.navigate {action: nextConversation|previousConversation, idempotencyKey}`).
3. **Send**: `message.send {target, text, idempotencyKey}`. `target` is the exact conversation title
   (or `chatId:<id>` / `externalUserId:<id>` once the identity bridge knows them).
4. **Confirm**: the result's `state` is `succeeded` only when the outgoing bubble was seen in the client;
   `failed` carries `error.code` / `error.message`; `unknown` means the daemon restarted mid-send — do not resend blindly. A failed or unknown record may carry `diagnosis` (where a visual round ended and how many irreversible points were crossed); it never changes what `unknown` means.
5. **Events**: `event.replay {afterEventId, limit}` — `message.observed {origin: "other"}` means a human
   took over on the phone; stay quiet in that conversation.

## Rules you must keep

- **Idempotency key per intent**: choose a stable key for each message you intend to send (e.g. `reply-<title>-<yyyymmdd>-<n>`).
  Retrying with the same key replays the earlier result and never sends twice; a new key is a new message.
- **Sending only reaches allowlisted conversations**: the compiled-in `文件传输助手` plus `policy.json.allowedTitles`.
  `TARGET_NOT_ALLOWED` is final for you — widening the allowlist is the user's local decision (console 策略 page or `imctl policy allow`).
- Files: only https sources on allowlisted hosts or `ossKey`; the daemon pastes with ⌘V and presses Return — say which file you sent and to whom.
- Add members only to allowlisted groups; try `dryRun: true` first; say who you added to which group.
- Note: this Mac may run with `allowAll` on — then any conversation is sendable (including type `unknown`); still say who you sent to.
- Never call `policy.set` to widen the allowlist on your own; never try to install / restart the daemon or change MQTT / proxy settings from here.
- Keep the user informed: say which conversation you read, what you are about to send, and the key you used.
- `RATE_LIMITED`: ≥ 3 s between sends to one conversation, ≤ 20 sends per minute overall.
- Everything you and other clients (console, Java over MQTT, another agent) submit runs on one serial queue in arrival order; `queuedMs` on the accepted event tells you how long a call waited. Do not fire many calls in parallel expecting parallel execution.

## Useful tools

| Tool | What it does |
|---|---|
| `conversation.list` | Titles, types, badges of the list rows |
| `conversation.read` | Open a conversation; returns `active`, `messageCount`, `conversationType` |
| `message.history` | Explicit normal reads move the current conversation to its newest messages first; `scrollback:true` loads older history. A row with `readError:AX_VALUE_UNAVAILABLE` is incomplete and must not drive a reply. Visible messages of the active conversation (`kind: message|media|file|video`, `direction`, `sender`, `messageKey`; files carry `fileName` / `fileSize` / `fileType`, videos carry `duration`, and media rows carry `mediaType: image|unknown`; media/file/video rows carry `media: assigned|observed|unmatched`). The daemon can use one in-memory WeCom-window frame for an AX-unknown visible media direction after Screen Recording permission is granted; absent or ambiguous evidence remains `unknown`. |
| `message.media` | A signed OSS URL for the picture / file / video poster behind a media, file or video row (`messageKey`, `hd`); never bytes; `OSS_NOT_CONFIGURED` when the Mac has no oss.json |
| `message.send` | Text only; needs `idempotencyKey` |
| `message.broadcast` | Same text to 1…50 targets, one paced send each (`targets`, `text`, `idempotencyKey`); per-target outcomes in the result |
| `message.sendFile` | Send a file fetched from an https URL (host must be on the Mac's policy list) or an OSS object key; needs `idempotencyKey`; `PASTE_FAILED` = nothing was sent; after Return, missing outbound evidence is `unknown` and must not be retried with a new key |
| `client.navigate` | next / previous / nextUnread conversation; needs `idempotencyKey` |
| `contact.list`, `contact.request.list`, `contact.request.accept`, `group.create`, `group.rename` | 通讯录 and groups (policy-gated, see the protocol doc) |
| `contact.add` | Add a customer by phone number (`phone`, `source`, `dryRun`, `idempotencyKey`); any phone number may be searched and added — a sent request cannot be taken back, and whether the person accepts is theirs. Search first (`dryRun: true`), and send a real add only for a number the user asked you to add in this conversation, never on your own initiative; searches and real adds each have an hourly cap on the Mac (`RATE_LIMITED`, final for you); `unknown` with `diagnosis.irreversibleSteps: 1` means 发送 was not pressed — reconcile with the same key and report to a person, never retry with a new key |
| `group.addMembers` | Add members to an existing allowlisted group through the client's 添加群成员 sheet; already-member / notFound / ambiguous come back as `skipped`; `dryRun` selects then cancels; `NOT_A_GROUP` when the target has no member list; needs `idempotencyKey` |
| `event.replay` | Pull events after a cursor |
| `controller.diagnose`, `controller.logs`, `controller.mediaCache`, `controller.permissions`, `controller.readiness` | Daemon-side diagnostics, grants and readiness |

Troubleshooting: `DAEMON_UNREACHABLE` → the daemon is not running (`imctl status`, `imctl agent status`).
