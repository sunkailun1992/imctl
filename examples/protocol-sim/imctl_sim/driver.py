"""The business side of the protocol: send commands, consume events with
gap reconciliation, download QR codes. Works against the mock and against a
real imctld alike (only the `sim.*` helpers are mock-specific)."""

from __future__ import annotations

import base64
import os
import threading
import time
import urllib.request
from typing import Callable

from .bus import Bus, Message
from .protocol import dumps, loads, request, topics


class RpcError(Exception):
    def __init__(self, code, message, data=None) -> None:
        super().__init__(f"{code}: {message} {data or ''}")
        self.code = code
        self.message = message
        self.data = data or {}


class ImctlClient:
    def __init__(self, bus: Bus, controller_id: str, instance: str = "driver") -> None:
        self.bus = bus
        self.controller_id = controller_id
        self.instance = instance
        self.t = topics(controller_id)
        self.reply_topic = f"{self.t['rsp']}/{instance}"
        self._pending: dict[bytes, tuple[threading.Event, list]] = {}
        self._lock = threading.Lock()
        self.last_event_id = 0
        self.events: list[dict] = []
        self._event_handlers: list[Callable[[dict], None]] = []
        self.state: dict | None = None
        self.bus.subscribe(self.reply_topic, self._on_reply)

    # ------------------------------------------------------------ commands

    def _on_reply(self, m: Message) -> None:
        key = m.correlation_data or b""
        with self._lock:
            slot = self._pending.get(key)
        if slot:
            slot[1].append(loads(m.payload))
            slot[0].set()

    def call(self, method: str, params: dict | None = None, timeout: float = 10.0) -> dict:
        """Returns the JSON-RPC `result` (command record view, or the replay object)."""
        req = request(method, params)
        corr = req["id"].encode("utf-8")
        done, box = threading.Event(), []
        with self._lock:
            self._pending[corr] = (done, box)
        try:
            self.bus.publish(Message(topic=self.t["cmd"], payload=dumps(req), response_topic=self.reply_topic, correlation_data=corr))
            if not done.wait(timeout):
                raise TimeoutError(f"no response to {method} within {timeout}s (is the controller online?)")
        finally:
            with self._lock:
                self._pending.pop(corr, None)
        response = box[0]
        if "error" in response:
            err = response["error"]
            raise RpcError(err.get("code"), err.get("message"), err.get("data"))
        return response["result"]

    def command(self, method: str, params: dict | None = None, timeout: float = 10.0) -> dict:
        """Like `call` but raises when the command record ended in failed/expired."""
        record = self.call(method, params, timeout)
        if record.get("state") in ("failed", "expired"):
            err = record.get("error") or {}
            raise RpcError(err.get("code", record["state"].upper()), err.get("message", ""), {"commandId": record.get("commandId")})
        return record

    # -------------------------------------------------------------- events

    def watch_events(self, handler: Callable[[dict], None] | None = None, shared_group: str | None = None) -> None:
        if handler:
            self._event_handlers.append(handler)
        filter_ = f"$share/{shared_group}/{self.t['evt']}" if shared_group else self.t["evt"]
        self.bus.subscribe(filter_, self._on_event)
        self.bus.subscribe(self.t["state"], self._on_state)

    def _on_state(self, m: Message) -> None:
        was_online = bool(self.state and self.state.get("online"))
        self.state = loads(m.payload)
        if self.state.get("online") and not was_online and self.last_event_id:
            self.reconcile()

    def _on_event(self, m: Message) -> None:
        event = loads(m.payload)
        eid = int(event.get("eventId", 0))
        if eid <= self.last_event_id:
            return  # duplicate delivery (QoS 1)
        if eid > self.last_event_id + 1 and self.last_event_id:
            self._store(event)
            self.reconcile()
            return
        self._store(event)

    def _store(self, event: dict) -> None:
        with self._lock:
            if any(e["eventId"] == event["eventId"] for e in self.events):
                return
            self.events.append(event)
            self.events.sort(key=lambda e: e["eventId"])
            # advance the cursor only over a contiguous prefix
            expected = self.last_event_id + 1
            for e in self.events:
                if e["eventId"] == expected:
                    self.last_event_id = expected
                    expected += 1
        for h in list(self._event_handlers):
            try:
                h(event)
            except Exception as e:
                print(f"driver: event handler error: {e!r}")

    def reconcile(self, limit: int = 500) -> int:
        """Fill gaps with event.replay until caught up; returns how many events were fetched."""
        fetched = 0
        while True:
            r = self.call("event.replay", {"afterEventId": self.last_event_id, "limit": limit})
            for e in r["events"]:
                e = dict(e, controllerId=self.controller_id)
                self._store(e)
                fetched += 1
            # caught up when the page is short or reaches the controller's newest id
            if r["count"] < limit or not r["events"] or r["events"][-1]["eventId"] >= r["lastEventId"]:
                return fetched

    def wait_for(self, predicate: Callable[[dict], bool], timeout: float = 10.0) -> dict | None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                for e in self.events:
                    if predicate(e):
                        return e
            time.sleep(0.02)
        return None

    # ------------------------------------------------------------ helpers

    def send(self, target: str, text: str, key: str | None = None) -> dict:
        import uuid
        return self.command("message.send", {"target": target, "text": text, "idempotencyKey": key or str(uuid.uuid4())})

    def read(self, target: str) -> dict:
        return self.command("conversation.read", {"target": target})["result"]

    def history(self, limit: int = 20, scrollback: bool = False) -> list[dict]:
        return self.command("message.history", {"limit": limit, "scrollback": scrollback})["result"]


def save_qr(url: str, path: str) -> str:
    """Download a QR image URL to `path`. Mock URLs (mock.invalid) are rendered
    locally with `qrcode` when installed, else written as a .txt with the URL."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    if url.startswith("https://mock.invalid/"):
        try:
            import qrcode  # optional
            img = qrcode.make(url)
            img.save(path)
            return path
        except Exception:
            alt = os.path.splitext(path)[0] + ".txt"
            with open(alt, "w", encoding="utf-8") as f:
                f.write(url + "\n")
            return alt
    with urllib.request.urlopen(url, timeout=15) as resp, open(path, "wb") as f:
        f.write(resp.read())
    return path


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")
