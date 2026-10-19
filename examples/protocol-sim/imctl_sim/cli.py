"""Command line: run the mock, call methods, tail events, or run the full demo.

Broker url: mqtt://[user:pass@]host[:port] (never commit it; use IMCTL_MQTT_URL)
or memory:// to run mock + driver inside this process (no broker needed).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid

from .bus import MemoryBus, open_bus
from .driver import ImctlClient, RpcError, save_qr
from .mock_controller import MockController
from .protocol import loads


def _broker(args) -> str:
    url = args.broker or os.environ.get("IMCTL_MQTT_URL")
    if not url:
        sys.exit("give --broker mqtt://… (or IMCTL_MQTT_URL) or --broker memory://")
    return url


def cmd_mock(args) -> None:
    # `kill -USR1 <pid>` dumps every thread's stack to stderr: the mock is a long-running
    # process on a shared broker and a hang must be diagnosable without a debugger.
    import faulthandler
    import signal
    faulthandler.register(signal.SIGUSR1, all_threads=True)
    bus = open_bus(_broker(args), f"imctl-mock-{args.controller_id}")
    bus.start()
    mock = MockController(bus, controller_id=args.controller_id, corp_id=args.corp_id, api_enabled=not args.no_api)
    mock.start()
    print(f"mock controller {args.controller_id} online; topics im/{args.controller_id}/{{cmd,rsp,evt,state}}, callbacks wecom/{args.corp_id}/evt")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        mock.stop()
        bus.stop()


def cmd_call(args) -> None:
    bus = open_bus(_broker(args), f"imctl-driver-{uuid.uuid4().hex[:6]}")
    bus.start()
    client = ImctlClient(bus, args.controller_id, instance=f"cli-{os.getpid()}")
    try:
        result = client.call(args.method, json.loads(args.params or "{}"), timeout=args.timeout)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except RpcError as e:
        print(json.dumps({"error": {"code": e.code, "message": e.message, "data": e.data}}, ensure_ascii=False, indent=2))
        sys.exit(1)
    finally:
        bus.stop()


def cmd_tail(args) -> None:
    bus = open_bus(_broker(args), f"imctl-tail-{uuid.uuid4().hex[:6]}")
    bus.start()
    client = ImctlClient(bus, args.controller_id, instance=f"tail-{os.getpid()}")
    client.watch_events(lambda e: print(json.dumps(e, ensure_ascii=False)))
    from .bus import Message  # noqa: F401
    from .protocol import callback_topic
    bus.subscribe(callback_topic("+"), lambda m: print(json.dumps(loads(m.payload), ensure_ascii=False)))
    try:
        time.sleep(args.seconds)
    finally:
        bus.stop()


def cmd_demo(args) -> None:
    """The whole WeCom loop end to end. Against the mock, sim.* helpers stand in
    for a customer scanning and typing; against a real imctld those steps are
    skipped (method not found) and a human does them."""
    url = _broker(args)
    bus = open_bus(url, f"imctl-demo-{uuid.uuid4().hex[:6]}")
    bus.start()
    mock = None
    if url.startswith("memory://"):
        mock = MockController(bus, controller_id=args.controller_id)
        mock.start()
    client = ImctlClient(bus, args.controller_id, instance=f"demo-{os.getpid()}")
    client.watch_events()
    out = args.out
    os.makedirs(out, exist_ok=True)
    report = []

    def step(name, fn):
        try:
            value = fn()
            report.append((name, "ok", value))
            print(f"[ok] {name}: {json.dumps(value, ensure_ascii=False)[:300]}")
            return value
        except RpcError as e:
            report.append((name, "error", {"code": e.code, "message": e.message}))
            print(f"[--] {name}: {e.code} {e.message}")
        except TimeoutError as e:
            report.append((name, "timeout", str(e)))
            print(f"[!!] {name}: {e}")
        return None

    describe = step("controller.describe", lambda: client.command("controller.describe")["result"])
    api_enabled = bool(describe and describe.get("wecomApi") == "enabled")
    step("conversation.list", lambda: client.command("conversation.list")["result"])

    seed_group = args.group
    if api_enabled:
        groups = step("group.list{syncNames}", lambda: client.command("group.list", {"syncNames": True})["result"])
        seed_chat_ids = [g["chatId"] for g in (groups or {}).get("groups", []) if not seed_group or g.get("name") == seed_group][:5]
        if seed_chat_ids:
            created = step("group.joinway.create", lambda: client.command("group.joinway.create", {
                "chatIds": seed_chat_ids, "autoCreateRoom": True, "roomBaseName": args.room_base_name, "roomBaseId": 1, "state": args.state,
                "remark": "imctl demo"})["result"])
            if created:
                jw = step("group.joinway.get", lambda: client.command("group.joinway.get", {"configId": created["configId"]})["result"])
                if jw and jw.get("qrCode"):
                    path = save_qr(jw["qrCode"], os.path.join(out, f"joinway-{created['configId']}.png"))
                    print(f"     群活码（扫码进群）二维码: {path}")
        cw = step("contact.way.create", lambda: client.command("contact.way.create", {"scene": 2, "skipVerify": True, "state": args.state, "users": [args.userid],
                                                                                        "conclusionText": "欢迎，稍后发你群二维码"})["result"])
        if cw and cw.get("qrCode"):
            path = save_qr(cw["qrCode"], os.path.join(out, f"contactway-{cw['configId']}.png"))
            print(f"     联系我（扫码加人）二维码: {path}")
        if mock:
            step("sim.callback add_external_contact", lambda: client.call("sim.callback", {"Event": "change_external_contact", "ChangeType": "add_external_contact",
                                                                                          "UserID": args.userid, "ExternalUserID": "wmMOCK000002", "State": args.state, "WelcomeCode": "WC-DEMO"}))
            step("contact.welcome.send", lambda: client.command("contact.welcome.send", {"welcomeCode": "WC-DEMO", "text": "欢迎！点链接进群",
                                                                                         "attachments": [{"msgtype": "link", "link": {"title": "进群", "url": "https://mock.invalid/qr/jw-1.png"}}]})["result"])
    else:
        print("     WeCom API route disabled on this controller: skipping join-way / contact-way / welcome / broadcast (imctl wecom enroll first)")

    target = f"chatId:{mock.conversations['imctl测试群']['chatId']}" if mock else (args.target or "文件传输助手")
    if mock:
        step("sim.inbound", lambda: client.call("sim.inbound", {"target": target, "text": "你们的营业时间？", "sender": "张三"}))
    step("conversation.read", lambda: client.read(target))
    step("message.history", lambda: client.history(20))
    sent = step("message.send", lambda: client.send(target, f"imctl-demo-{int(time.time())}"))
    if sent:
        observed = client.wait_for(lambda e: e["kind"] == "message.observed" and e["payload"].get("commandId") == sent["commandId"], timeout=15)
        report.append(("message.observed origin=controller", "ok" if observed else "missing", observed))
        print(f"[{'ok' if observed else '!!'}] message.observed for our send: {json.dumps(observed, ensure_ascii=False)[:300] if observed else 'not seen'}")
    step("message.send again within 3 s (expect RATE_LIMITED)", lambda: client.send(target, "too fast"))
    if mock:
        step("sim.takeover", lambda: client.call("sim.takeover", {"target": target, "text": "我来接管"}))
        other = client.wait_for(lambda e: e["kind"] == "message.observed" and e["payload"].get("origin") == "other", timeout=5)
        print(f"[{'ok' if other else '!!'}] takeover signal origin=other: {'seen' if other else 'not seen'}")
    if api_enabled:
        b = step("broadcast.create", lambda: client.command("broadcast.create", {"chatIds": [target.split(':', 1)[1]] if target.startswith("chatId:") else [],
                                                                                    "sender": args.userid, "text": "群发测试", "idempotencyKey": str(uuid.uuid4())})["result"])
        if b:
            step("broadcast.confirm", lambda: client.command("broadcast.confirm", {"msgid": b["msgid"]})["result"])
            step("broadcast.get", lambda: client.command("broadcast.get", {"msgid": b["msgid"]})["result"])
    replay = step("event.replay", lambda: client.call("event.replay", {"afterEventId": 0, "limit": 1000}))
    print(f"\nevents seen live: {len(client.events)}; replay reports lastEventId={replay['lastEventId'] if replay else '?'}; report written to {os.path.join(out, 'report.json')}")
    with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as f:
        json.dump([{"step": s, "status": st, "value": v} for s, st, v in report], f, ensure_ascii=False, indent=2)
    if mock:
        mock.stop()
    bus.stop()


def cmd_qr(args) -> None:
    print(save_qr(args.url, args.out))


def main(argv=None) -> None:
    p = argparse.ArgumentParser(prog="imctl_sim", description="imctl protocol simulator and driver")
    p.add_argument("--broker", help="mqtt://[user:pass@]host[:port] | memory:// (default: $IMCTL_MQTT_URL)")
    sub = p.add_subparsers(dest="cmd", required=True)

    m = sub.add_parser("mock", help="run a mock controller on the broker")
    m.add_argument("--controller-id", default="mock-01")
    m.add_argument("--corp-id", default="wwmock")
    m.add_argument("--no-api", action="store_true", help="answer UNSUPPORTED for group.*/contact.*/broadcast.*")
    m.set_defaults(fn=cmd_mock)

    c = sub.add_parser("call", help="publish one JSON-RPC request and print the response")
    c.add_argument("--controller-id", required=True)
    c.add_argument("method")
    c.add_argument("params", nargs="?", default="{}")
    c.add_argument("--timeout", type=float, default=15)
    c.set_defaults(fn=cmd_call)

    t = sub.add_parser("tail", help="print controller events and proxy callbacks")
    t.add_argument("--controller-id", required=True)
    t.add_argument("--seconds", type=float, default=30)
    t.set_defaults(fn=cmd_tail)

    d = sub.add_parser("demo", help="run the whole loop: QR codes, welcome, read/history/send, takeover, broadcast, replay")
    d.add_argument("--controller-id", default="mock-01")
    d.add_argument("--out", default="./out")
    d.add_argument("--group", help="seed group name (real controller) to attach the join-way QR to")
    d.add_argument("--target", help="send target for a real controller (title | chatId:<id>), default 文件传输助手")
    d.add_argument("--userid", default="u1", help="staff userid for contact-way / broadcast")
    d.add_argument("--state", default="imctl-demo")
    d.add_argument("--room-base-name", default="imctl群")
    d.set_defaults(fn=cmd_demo)

    q = sub.add_parser("qr", help="download (or render, for mock URLs) a QR image")
    q.add_argument("--url", required=True)
    q.add_argument("--out", required=True)
    q.set_defaults(fn=cmd_qr)

    args = p.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
