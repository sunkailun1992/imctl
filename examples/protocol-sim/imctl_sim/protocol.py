"""Constants and helpers mirroring docs/protocol/im-control-protocol.md."""

from __future__ import annotations

import hashlib
import json
import time
import uuid

PROTOCOL = "im-control/0.1"
VERSION = "0.1.0-sim"

# Methods (UI route, query, WeCom API route) — keep in sync with the doc.
UI_METHODS = [
    "controller.describe", "account.status", "conversation.list", "conversation.read", "message.send",
    "message.history", "command.get", "command.cancel", "controller.pause", "controller.resume",
]
QUERY_METHODS = ["event.replay"]
API_METHODS = [
    "group.list", "group.get", "group.joinway.create", "group.joinway.get", "group.joinway.update", "group.joinway.delete",
    "contact.way.create", "contact.way.list", "contact.way.get", "contact.way.update", "contact.way.delete",
    "contact.welcome.send", "contact.remark.set", "broadcast.create", "broadcast.confirm", "broadcast.get",
]
# Simulator-only helpers (never implemented by a real controller).
SIM_METHODS = ["sim.inbound", "sim.takeover", "sim.callback", "sim.reset"]

EVENT_KINDS = ["controller.state", "account.changed", "conversation.activity", "message.observed", "command.state"]

ERROR_CODES = [
    "TARGET_NOT_FOUND", "TARGET_AMBIGUOUS", "TARGET_MISMATCH", "TARGET_NOT_ALLOWED", "PAUSED", "EXPIRED", "LOCAL_GUARD",
    "INVALID_PARAMS", "CLIENT_UNAVAILABLE", "INTERNAL", "RATE_LIMITED", "UNSUPPORTED", "WECOM_API", "PROXY_ERROR",
    "UNKNOWN_AFTER_RESTART",
]

IDEMPOTENT_METHODS = {"message.send", "broadcast.create"}


def now_ms() -> int:
    return int(time.time() * 1000)


def topics(controller_id: str, prefix: str = "im") -> dict[str, str]:
    base = f"{prefix}/{controller_id}"
    return {"cmd": f"{base}/cmd", "rsp": f"{base}/rsp", "evt": f"{base}/evt", "state": f"{base}/state", "own": f"{base}/"}


def callback_topic(corp_id: str, prefix: str = "wecom") -> str:
    return f"{prefix}/{corp_id}/evt"


def parse_target(raw: str) -> tuple[str, str]:
    """('chatId'|'externalUserId'|'title', value). An empty id stays a literal title."""
    for kind, pfx in (("chatId", "chatId:"), ("externalUserId", "externalUserId:")):
        if raw.startswith(pfx):
            value = raw[len(pfx):].strip()
            return (kind, value) if value else ("title", raw)
    return ("title", raw)


def message_key(conversation: str, sender: str | None, time_label: str | None, text: str, ordinal: int) -> str:
    material = "\x1f".join([conversation, sender or "", time_label or "", text, str(ordinal)])
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


def assign_keys(conversation: str, rows: list[dict]) -> list[str]:
    seen: dict[str, int] = {}
    keys = []
    for r in rows:
        tup = "\x1f".join([r.get("sender") or "", r.get("timeLabel") or "", r.get("text") or ""])
        ordinal = seen.get(tup, 0)
        seen[tup] = ordinal + 1
        keys.append(message_key(conversation, r.get("sender"), r.get("timeLabel"), r.get("text") or "", ordinal))
    return keys


def request(method: str, params: dict | None = None, id_: str | None = None) -> dict:
    return {"jsonrpc": "2.0", "id": id_ or str(uuid.uuid4()), "method": method, "params": params or {}}


def dumps(obj) -> bytes:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def loads(data: bytes):
    return json.loads(data.decode("utf-8"))
