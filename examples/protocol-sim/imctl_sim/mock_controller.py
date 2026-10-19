"""A mock imctl controller speaking the protocol over a Bus.

It keeps an in-memory client (conversations, messages), an identity bridge,
policy, pause set, rate limit, command records and an event log with a
monotonic eventId, and answers every protocol method the way the Swift
daemon does (docs/protocol/im-control-protocol.md). WeCom API methods return
fake ids and placeholder QR URLs; `sim.*` methods inject peer messages,
takeovers and proxy callbacks so consumers can rehearse the full loop.
"""

from __future__ import annotations

import threading
import uuid
from collections import OrderedDict

from .bus import Bus, Message
from .protocol import (API_METHODS, PROTOCOL, VERSION, assign_keys, callback_topic, dumps, loads, now_ms,
                       parse_target, topics)


class ProtocolError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class MockController:
    MOCK_QR_HOST = "https://mock.invalid/qr/"

    def __init__(self, bus: Bus, controller_id: str = "mock-01", corp_id: str = "wwmock", api_enabled: bool = True,
                 policy: dict | None = None, seed: bool = True) -> None:
        self.bus = bus
        self.controller_id = controller_id
        self.corp_id = corp_id
        self.api_enabled = api_enabled
        self.t = topics(controller_id)
        self.lock = threading.RLock()
        self.events: list[dict] = []
        self.commands: dict[str, dict] = {}
        self.by_key: dict[str, str] = {}
        self.paused: set[str] = set()
        self.policy = policy or {"allowedTitles": ["imctl测试群", "小明·a1b2c3"], "allowedTypes": {"group": False, "customer": False, "internal": False},
                                 "allowedChatIds": [], "allowedExternalUserIds": []}
        self.compiled_allowlist = {"文件传输助手"}
        self.rate_last: dict[str, int] = {}
        self.rate_recent: list[int] = []
        self.conversations: OrderedDict[str, dict] = OrderedDict()
        self.identities: dict[tuple[str, str], str] = {}   # (kind, id) -> title
        self.active: str | None = None
        self.join_ways: dict[str, dict] = {}
        self.contact_ways: dict[str, dict] = {}
        self.broadcasts: dict[str, dict] = {}
        self.callback_seq = 0
        self.seq = 0
        if seed:
            self._seed()

    # ------------------------------------------------------------------ seed

    def _seed(self) -> None:
        self.conversations["文件传输助手"] = {"type": "unknown", "messages": [{"direction": "outbound", "text": "imctl-sim-hello", "sender": None, "timeLabel": "9:18"}]}
        self.conversations["imctl测试群"] = {"type": "group", "chatId": "wrMOCK000001", "memberCount": 3, "messages": [
            {"direction": "inbound", "text": "大家好", "sender": "张三", "timeLabel": "9:18"},
            {"direction": "outbound", "text": "收到", "sender": None, "timeLabel": None},
        ]}
        self.conversations["小明·a1b2c3"] = {"type": "customer", "externalUserId": "wmMOCK000001", "messages": [
            {"direction": "inbound", "text": "在吗", "sender": None, "timeLabel": "10:02"},
        ]}
        self.identities[("group", "wrMOCK000001")] = "imctl测试群"
        self.identities[("customer", "wmMOCK000001")] = "小明·a1b2c3"
        self.active = "文件传输助手"

    # --------------------------------------------------------------- lifecycle

    def start(self) -> None:
        self.bus.subscribe(self.t["cmd"], self._on_command)
        self._publish_state(True)

    def stop(self) -> None:
        self._publish_state(False)

    def _publish_state(self, online: bool) -> None:
        payload = {"online": online, "controllerId": self.controller_id, "version": VERSION, "protocol": PROTOCOL, "tsMs": now_ms(), "pid": 4242}
        self.bus.publish(Message(topic=self.t["state"], payload=dumps(payload), retain=True))

    # ----------------------------------------------------------------- events

    def _emit(self, kind: str, payload: dict) -> dict:
        with self.lock:
            self.seq += 1
            event = {"eventId": self.seq, "tsMs": now_ms(), "kind": kind, "controllerId": self.controller_id, "payload": payload}
            self.events.append(event)
        self.bus.publish(Message(topic=self.t["evt"], payload=dumps(event),
                                 user_properties=[("controller_id", self.controller_id), ("event_id", str(event["eventId"])), ("kind", kind)]))
        return event

    def _command_state(self, record: dict) -> None:
        payload = {"commandId": record["commandId"], "state": record["state"], "method": record["method"]}
        if record.get("idempotencyKey"):
            payload["idempotencyKey"] = record["idempotencyKey"]
        if record.get("error"):
            payload["errorCode"] = record["error"]["code"]
        self._emit("command.state", payload)

    # ----------------------------------------------------------------- inbound

    def _on_command(self, m: Message) -> None:
        try:
            req = loads(m.payload)
        except Exception:
            self._reply(m, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            return
        if not isinstance(req, dict) or "method" not in req:
            self._reply(m, {"jsonrpc": "2.0", "id": req.get("id") if isinstance(req, dict) else None, "error": {"code": -32600, "message": "invalid request"}})
            return
        method, params, id_ = req["method"], req.get("params") or {}, req.get("id")
        try:
            result = self.dispatch(method, params)
            response = {"jsonrpc": "2.0", "id": id_, "result": result}
        except ProtocolError as e:
            response = {"jsonrpc": "2.0", "id": id_, "error": {"code": -32000, "message": e.message, "data": {"code": e.code}}}
        except KeyError as e:
            response = {"jsonrpc": "2.0", "id": id_, "error": {"code": -32601, "message": f"method not found: {e}"}}
        if id_ is None:
            return
        self._reply(m, response)

    def _reply(self, m: Message, response: dict) -> None:
        topic = m.response_topic if m.response_topic and m.response_topic.startswith(self.t["own"]) else self.t["rsp"]
        self.bus.publish(Message(topic=topic, payload=dumps(response), correlation_data=m.correlation_data,
                                 user_properties=[("controller_id", self.controller_id)]))

    # ----------------------------------------------------------------- dispatch

    def dispatch(self, method: str, params: dict) -> dict:
        if method == "event.replay":
            return self._replay(params)
        if method.startswith("sim."):
            return self._sim(method, params)
        handlers = {
            "controller.describe": self._describe, "account.status": self._account_status, "conversation.list": self._conversation_list,
            "conversation.read": self._conversation_read, "message.send": self._message_send, "message.history": self._message_history,
            "command.get": self._command_get, "command.cancel": self._command_cancel, "controller.pause": self._pause, "controller.resume": self._resume,
        }
        if method in API_METHODS:
            handler = self._api
        elif method in handlers:
            handler = handlers[method]
        else:
            raise KeyError(method)
        return self._run(method, params, handler)

    def _run(self, method: str, params: dict, handler) -> dict:
        key = params.get("idempotencyKey")
        if method in ("message.send", "broadcast.create") and not key:
            raise ProtocolError("INVALID_PARAMS", f"{method} requires idempotencyKey")
        with self.lock:
            if key and key in self.by_key:
                return self._view(self.commands[self.by_key[key]])
            record = {"commandId": str(uuid.uuid4()).upper(), "method": method, "state": "accepted", "createdMs": now_ms(), "updatedMs": now_ms(), "params": params}
            if key:
                record["idempotencyKey"] = key
                self.by_key[key] = record["commandId"]
            self.commands[record["commandId"]] = record
        self._command_state(record)
        if method == "message.send":
            ttl, issued = params.get("ttlMs"), params.get("issuedAtMs")
            if ttl is not None and issued is not None and issued + ttl < now_ms():
                return self._finish(record, "expired", error=("EXPIRED", "command expired before execution"))
        if method in ("message.send", "conversation.read") and self.paused:
            return self._finish(record, "failed", error=("PAUSED", "controller paused: " + ",".join(sorted(self.paused))))
        if method == "message.send":
            why = self._rate_admit(params.get("target", ""))
            if why:
                return self._finish(record, "failed", error=("RATE_LIMITED", why))
        record["state"] = "running"
        record["updatedMs"] = now_ms()
        self._command_state(record)
        try:
            if method == "message.send":
                state, result = handler(record, params)
                return self._finish(record, state, result=result)
            if method in API_METHODS:
                return self._finish(record, "succeeded", result=handler(method, params))
            return self._finish(record, "succeeded", result=handler(params))
        except ProtocolError as e:
            return self._finish(record, "failed", error=(e.code, e.message))

    def _finish(self, record: dict, state: str, result=None, error: tuple[str, str] | None = None) -> dict:
        with self.lock:
            record["state"] = state
            record["updatedMs"] = now_ms()
            if result is not None:
                record["result"] = result
            if error:
                record["error"] = {"code": error[0], "message": error[1]}
        self._command_state(record)
        return self._view(record)

    @staticmethod
    def _view(record: dict) -> dict:
        view = {k: v for k, v in record.items() if k != "params"}
        return view

    # ---------------------------------------------------------------- rate limit

    def _rate_admit(self, target: str) -> str | None:
        now = now_ms()
        with self.lock:
            self.rate_recent = [t for t in self.rate_recent if now - t < 60_000]
            last = self.rate_last.get(target)
            if last is not None and now - last < 3000:
                return f'target "{target}" was attempted {now - last} ms ago; minimum interval 3000 ms'
            if len(self.rate_recent) >= 20:
                return f"{len(self.rate_recent)} sends attempted in the last 60 s; limit 20"
            self.rate_last[target] = now
            self.rate_recent.append(now)
        return None

    # ----------------------------------------------------------------- targets

    def _resolve(self, raw: str) -> tuple[str, dict]:
        kind, value = parse_target(raw)
        if kind == "title":
            title = value
        else:
            idkind = "group" if kind == "chatId" else "customer"
            title = self.identities.get((idkind, value))
            if title is None:
                raise ProtocolError("TARGET_NOT_FOUND", f'no conversation for target "{raw}"')
        conv = self.conversations.get(title)
        if conv is None:
            raise ProtocolError("TARGET_NOT_FOUND", f'no conversation for target "{title}"')
        return title, conv

    def _allowed(self, title: str, conv: dict) -> bool:
        if title in self.compiled_allowlist or title in self.policy.get("allowedTitles", []):
            return True
        if conv.get("chatId") in self.policy.get("allowedChatIds", []):
            return True
        if conv.get("externalUserId") in self.policy.get("allowedExternalUserIds", []):
            return True
        return bool(self.policy.get("allowedTypes", {}).get(conv.get("type", "unknown"), False))

    def _ids(self, conv: dict) -> dict:
        out = {}
        if conv.get("chatId"):
            out["chatId"] = conv["chatId"]
        if conv.get("externalUserId"):
            out["externalUserId"] = conv["externalUserId"]
        return out

    # ------------------------------------------------------------- UI methods

    def _describe(self, params: dict) -> dict:
        p = self.policy
        types = "+".join(k for k, v in p.get("allowedTypes", {}).items() if v) or "-"
        return {"platform": "wecom-mock", "client": "mock", "submitStrategy": "enter", "allowlist": ",".join(sorted(self.compiled_allowlist)),
                "policy": f"titles={len(p.get('allowedTitles', []))} types={types} chatIds={len(p.get('allowedChatIds', []))} externalUserIds={len(p.get('allowedExternalUserIds', []))}",
                "targetSyntax": "title | chatId:<id> | externalUserId:<id>", "phase": "1", "version": VERSION, "protocol": PROTOCOL,
                "wecomApi": "enabled" if self.api_enabled else "disabled"}

    def _account_status(self, params: dict) -> dict:
        conv = self.conversations.get(self.active or "", {})
        out = {"windowReachable": "true", "activeTitle": self.active or "", "conversationCount": str(len(self.conversations)),
               "composerPresent": "true", "activeType": conv.get("type", "unknown")}
        if conv.get("memberCount"):
            out["activeMemberCount"] = str(conv["memberCount"])
        return out

    def _conversation_list(self, params: dict) -> list[dict]:
        rows = []
        for i, (title, conv) in enumerate(self.conversations.items()):
            last = conv["messages"][-1] if conv["messages"] else None
            row = {"index": str(i), "selected": "true" if title == self.active else "false", "conversationType": conv.get("type", "unknown"), "title": title}
            if last:
                row["preview"] = (f"{last['sender']}: " if last.get("sender") else "") + last["text"]
                if last.get("timeLabel"):
                    row["timeLabel"] = last["timeLabel"]
            if conv.get("type") == "customer":
                row["markers"] = "微信"
            rows.append(row)
        return rows

    def _conversation_read(self, params: dict) -> dict:
        title, conv = self._resolve(params.get("target", ""))
        if not self._allowed(title, conv):
            raise ProtocolError("TARGET_NOT_ALLOWED", f'target "{title}" is not allowed by the compiled-in allowlist or policy.json')
        if self.active != title:
            old, self.active = self.active, title
            payload = {"activeFrom": old or "", "activeTo": title, "conversationType": conv.get("type", "unknown")}
            payload.update(self._ids(conv))
            self._emit("conversation.activity", payload)
        out = {"active": title, "messageCount": str(len(conv["messages"])), "composerPresent": "true", "conversationType": conv.get("type", "unknown")}
        out.update(self._ids(conv))
        return out

    def _message_history(self, params: dict) -> list[dict]:
        conv = self.conversations.get(self.active or "")
        if conv is None:
            return []
        rows = conv["messages"]
        keys = assign_keys(self.active or "", rows)
        limit = int(params.get("limit") or 50)
        out = []
        for i, (r, k) in enumerate(zip(rows, keys)):
            d = {"index": str(i), "direction": r["direction"], "text": r["text"], "messageKey": k}
            if r.get("timeLabel"):
                d["timeLabel"] = r["timeLabel"]
            if r.get("sender"):
                d["sender"] = r["sender"]
            out.append(d)
        return out[-limit:] if limit > 0 else []

    def _message_send(self, record: dict, params: dict) -> tuple[str, dict]:
        title, conv = self._resolve(params.get("target", ""))
        if not self._allowed(title, conv):
            raise ProtocolError("TARGET_NOT_ALLOWED", f'target "{title}" is not allowed by the compiled-in allowlist or policy.json')
        text = params.get("text", "")
        if not text:
            raise ProtocolError("INVALID_PARAMS", "text is empty")
        if self.active != title:
            old, self.active = self.active, title
            payload = {"activeFrom": old or "", "activeTo": title, "conversationType": conv.get("type", "unknown")}
            payload.update(self._ids(conv))
            self._emit("conversation.activity", payload)
        row = {"direction": "outbound", "text": text, "sender": None, "timeLabel": None}
        conv["messages"].append(row)
        index = len(conv["messages"]) - 1
        self._emit("conversation.activity", {"title": title, "fields": "preview", "preview": text, "timeLabel": "", "badge": "",
                                             "conversationType": conv.get("type", "unknown"), **self._ids(conv)})
        key = assign_keys(title, conv["messages"])[index]
        self._emit("message.observed", {"conversation": title, "direction": "outbound", "timeLabel": "", "text": text, "origin": "controller",
                                        "commandId": record["commandId"], "sender": "", "messageKey": key,
                                        "conversationType": conv.get("type", "unknown"), **self._ids(conv)})
        return "succeeded", {"state": "succeeded", "evidence": f"row #{index} dir=outbound", "latencyMs": 42}

    def _command_get(self, params: dict) -> dict:
        cid = params.get("commandId") or self.by_key.get(params.get("idempotencyKey", ""))
        record = self.commands.get(cid or "")
        if not record:
            raise ProtocolError("INVALID_PARAMS", "no such command")
        return {"id": record["commandId"], "idempotency_key": record.get("idempotencyKey"), "method": record["method"], "state": record["state"],
                "created_ms": record["createdMs"], "updated_ms": record["updatedMs"], "error_code": (record.get("error") or {}).get("code")}

    def _command_cancel(self, params: dict) -> dict:
        cid = params.get("commandId") or self.by_key.get(params.get("idempotencyKey", ""))
        record = self.commands.get(cid or "")
        if not record:
            raise ProtocolError("INVALID_PARAMS", "no such command")
        return {"commandId": record["commandId"], "state": record["state"], "cancelled": "false"}

    def _pause(self, params: dict) -> dict:
        self.paused.add("api")
        self._emit("controller.state", {"paused": sorted(self.paused)})
        return {"paused": sorted(self.paused)}

    def _resume(self, params: dict) -> dict:
        self.paused.discard("api")
        self._emit("controller.state", {"paused": sorted(self.paused)})
        return {"paused": sorted(self.paused)}

    def _replay(self, params: dict) -> dict:
        after = int(params.get("afterEventId") or 0)
        limit = max(1, min(int(params.get("limit") or 200), 1000))
        with self.lock:
            events = [e for e in self.events if e["eventId"] > after][:limit]
            last = self.events[-1]["eventId"] if self.events else 0
        return {"events": [{k: e[k] for k in ("eventId", "tsMs", "kind", "payload")} for e in events], "count": len(events), "lastEventId": last}

    # ------------------------------------------------------------ API methods

    def _api(self, method: str, params: dict) -> dict:
        if not self.api_enabled:
            raise ProtocolError("UNSUPPORTED", "WeCom API route not configured on this controller (imctl wecom enroll)")
        if method == "group.list":
            groups = [{"chatId": c["chatId"], "status": 0, **({"name": t} if params.get("syncNames") else {})}
                      for t, c in self.conversations.items() if c.get("chatId")]
            return {"groups": groups, "nextCursor": ""}
        if method == "group.get":
            for title, conv in self.conversations.items():
                if conv.get("chatId") == params.get("chatId"):
                    self.identities[("group", conv["chatId"])] = title
                    return {"chatId": conv["chatId"], "name": title, "owner": "u1", "members": [{"userid": "u1", "type": 1}, {"userid": "wmMOCK000001", "type": 2, "name": "小明"}], "memberCount": 2}
            raise ProtocolError("WECOM_API", "wecom errcode 40050: invalid chat_id")
        if method == "group.joinway.create":
            cid = f"jw-{len(self.join_ways) + 1}"
            self.join_ways[cid] = {"configId": cid, "chatIds": list(params.get("chatIds") or []), "qrCode": f"{self.MOCK_QR_HOST}{cid}.png",
                                   "state": params.get("state") or "", "remark": params.get("remark") or "", "roomBaseName": params.get("roomBaseName") or "",
                                   "roomBaseId": params.get("roomBaseId") or 0, "autoCreateRoom": bool(params.get("autoCreateRoom")), "scene": 2}
            return {"configId": cid}
        if method == "group.joinway.get":
            jw = self.join_ways.get(params.get("configId", ""))
            if not jw:
                raise ProtocolError("WECOM_API", "wecom errcode 40096: invalid config_id")
            return dict(jw)
        if method == "group.joinway.update":
            jw = self.join_ways.get(params.get("configId", ""))
            if not jw:
                raise ProtocolError("WECOM_API", "wecom errcode 40096: invalid config_id")
            for k in ("chatIds", "remark", "roomBaseName", "roomBaseId", "autoCreateRoom", "state"):
                if k in params:
                    jw[k] = params[k]
            return {"ok": True, "configId": jw["configId"]}
        if method == "group.joinway.delete":
            self.join_ways.pop(params.get("configId", ""), None)
            return {"ok": True, "configId": params.get("configId", "")}
        if method == "contact.way.create":
            cid = f"cw-{len(self.contact_ways) + 1}"
            self.contact_ways[cid] = {"configId": cid, "qrCode": f"{self.MOCK_QR_HOST}{cid}.png", "state": params.get("state") or "", "users": list(params.get("users") or []),
                                      "skipVerify": params.get("skipVerify", True), "scene": params.get("scene", 2), "type": params.get("type", 1),
                                      "remark": params.get("remark") or "", "conclusionText": params.get("conclusionText") or ""}
            return {"configId": cid, "qrCode": self.contact_ways[cid]["qrCode"]}
        if method == "contact.way.list":
            return {"configIds": list(self.contact_ways), "nextCursor": ""}
        if method == "contact.way.get":
            cw = self.contact_ways.get(params.get("configId", ""))
            if not cw:
                raise ProtocolError("WECOM_API", "wecom errcode 40096: invalid config_id")
            return dict(cw)
        if method == "contact.way.update":
            cw = self.contact_ways.get(params.get("configId", ""))
            if not cw:
                raise ProtocolError("WECOM_API", "wecom errcode 40096: invalid config_id")
            for k in ("remark", "skipVerify", "state", "users", "conclusionText"):
                if k in params:
                    cw[k] = params[k]
            return {"ok": True, "configId": cw["configId"]}
        if method == "contact.way.delete":
            self.contact_ways.pop(params.get("configId", ""), None)
            return {"ok": True, "configId": params.get("configId", "")}
        if method == "contact.welcome.send":
            if not params.get("welcomeCode"):
                raise ProtocolError("INVALID_PARAMS", "welcomeCode is required")
            return {"ok": True}
        if method == "contact.remark.set":
            ext, remark = params.get("externalUserId"), params.get("remark")
            if not ext or not remark:
                raise ProtocolError("INVALID_PARAMS", "externalUserId and remark are required")
            old = self.identities.get(("customer", ext))
            if old and old in self.conversations and old != remark:
                self.conversations[remark] = self.conversations.pop(old)
                if self.active == old:
                    self.active = remark
            self.identities[("customer", ext)] = remark
            return {"ok": True, "externalUserId": ext, "title": remark}
        if method == "broadcast.create":
            msgid = f"msg-{len(self.broadcasts) + 1}"
            chat_type = "group" if params.get("chatIds") else "single"
            self.broadcasts[msgid] = {"msgid": msgid, "chatType": chat_type, "targets": list(params.get("chatIds") or params.get("externalUserIds") or []),
                                      "text": params.get("text", ""), "confirmed": False}
            return {"msgid": msgid, "failList": [], "chatType": chat_type}
        if method == "broadcast.confirm":
            b = self.broadcasts.get(params.get("msgid", ""))
            if not b:
                raise ProtocolError("UNSUPPORTED", "action 群发助手 send button unavailable")
            b["confirmed"] = True
            return {"msgid": b["msgid"], "button": "发送", "verified": "true"}
        if method == "broadcast.get":
            b = self.broadcasts.get(params.get("msgid", ""))
            if not b:
                raise ProtocolError("WECOM_API", "wecom errcode 41048: invalid msgid")
            status = 1 if b["confirmed"] else 0
            if params.get("userid"):
                key = "chatId" if b["chatType"] == "group" else "externalUserId"
                return {"msgid": b["msgid"], "results": [{key: t, "userid": params["userid"], "status": status} for t in b["targets"]], "nextCursor": ""}
            return {"msgid": b["msgid"], "tasks": [{"userid": "u1", "status": status}], "nextCursor": ""}
        raise KeyError(method)

    # --------------------------------------------------------- sim-only helpers

    def _sim(self, method: str, params: dict) -> dict:
        if method == "sim.inbound":
            title, conv = self._resolve(params.get("target", ""))
            row = {"direction": "inbound", "text": params.get("text", ""), "sender": params.get("sender") if conv.get("type") == "group" else None, "timeLabel": None}
            conv["messages"].append(row)
            preview = (f"{row['sender']}: " if row["sender"] else "") + row["text"]
            self._emit("conversation.activity", {"title": title, "fields": "preview,badge", "preview": preview, "timeLabel": "", "badge": "1",
                                                 "conversationType": conv.get("type", "unknown"), **self._ids(conv)})
            if self.active == title:
                key = assign_keys(title, conv["messages"])[-1]
                self._emit("message.observed", {"conversation": title, "direction": "inbound", "timeLabel": "", "text": row["text"], "origin": "peer",
                                                "sender": row["sender"] or "", "messageKey": key, "conversationType": conv.get("type", "unknown"), **self._ids(conv)})
            return {"ok": True, "observed": self.active == title}
        if method == "sim.takeover":
            title, conv = self._resolve(params.get("target", ""))
            row = {"direction": "outbound", "text": params.get("text", ""), "sender": None, "timeLabel": None}
            conv["messages"].append(row)
            if self.active == title:
                key = assign_keys(title, conv["messages"])[-1]
                self._emit("message.observed", {"conversation": title, "direction": "outbound", "timeLabel": "", "text": row["text"], "origin": "other",
                                                "sender": "", "messageKey": key, "conversationType": conv.get("type", "unknown"), **self._ids(conv)})
            return {"ok": True, "observed": self.active == title}
        if method == "sim.callback":
            self.callback_seq += 1
            payload = {"ToUserName": self.corp_id, "FromUserName": "sys", "CreateTime": str(now_ms() // 1000), "MsgType": "event"}
            payload.update({k: v for k, v in params.items()})
            event = {"eventId": self.callback_seq, "tsMs": now_ms(), "kind": "wecom.callback", "corpId": self.corp_id, "payload": payload}
            self.bus.publish(Message(topic=callback_topic(self.corp_id), payload=dumps(event),
                                     user_properties=[("event_id", str(self.callback_seq)), ("kind", "wecom.callback"), ("corp_id", self.corp_id)]))
            return {"ok": True, "eventId": self.callback_seq}
        if method == "sim.reset":
            with self.lock:
                self.conversations.clear()
                self.identities.clear()
                self.join_ways.clear()
                self.contact_ways.clear()
                self.broadcasts.clear()
                self.rate_last.clear()
                self.rate_recent.clear()
                self._seed()
            return {"ok": True}
        raise KeyError(method)
