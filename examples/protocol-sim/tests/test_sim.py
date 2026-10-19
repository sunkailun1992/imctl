"""End-to-end over the in-memory bus: mock controller + driver, no broker.
Run: python3 -m unittest discover -s examples/protocol-sim/tests -t examples/protocol-sim"""

import unittest
import uuid

from imctl_sim.bus import MemoryBus, topic_matches
from imctl_sim.driver import ImctlClient, RpcError
from imctl_sim.mock_controller import MockController
from imctl_sim.protocol import API_METHODS, ERROR_CODES, EVENT_KINDS, UI_METHODS, parse_target


class BusTests(unittest.TestCase):
    def test_wildcards_and_shared_prefix(self):
        self.assertTrue(topic_matches("im/+/evt", "im/mac-01/evt"))
        self.assertTrue(topic_matches("$share/g1/im/+/evt", "im/mac-01/evt"))
        self.assertTrue(topic_matches("im/mac-01/#", "im/mac-01/rsp/x"))
        self.assertFalse(topic_matches("im/+/evt", "im/mac-01/cmd"))
        self.assertFalse(topic_matches("im/mac-01/rsp", "im/mac-01/rsp/x"))


class ProtocolTests(unittest.TestCase):
    def test_constants_match_the_document_sizes(self):
        self.assertEqual(len(UI_METHODS) + len(API_METHODS), 26)
        self.assertEqual(len(EVENT_KINDS), 5)
        self.assertEqual(len(ERROR_CODES), 15)
        self.assertEqual(parse_target("chatId: wr1 "), ("chatId", "wr1"))
        self.assertEqual(parse_target("chatId:"), ("title", "chatId:"))
        self.assertEqual(parse_target("文件传输助手"), ("title", "文件传输助手"))


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.bus = MemoryBus()
        self.bus.start()
        self.mock = MockController(self.bus, controller_id="mock-t")
        self.mock.start()
        self.client = ImctlClient(self.bus, "mock-t", instance="test")
        self.client.watch_events()

    def tearDown(self):
        self.bus.stop()

    def test_describe_and_state(self):
        d = self.client.command("controller.describe")["result"]
        self.assertEqual(d["protocol"], "im-control/0.1")
        self.assertEqual(d["wecomApi"], "enabled")
        self.assertIsNotNone(self.client.wait_for(lambda e: False, timeout=0.05) or self.client.state)
        self.assertTrue(self.client.state["online"])

    def test_send_by_chat_id_produces_the_event_chain_and_is_idempotent(self):
        key = str(uuid.uuid4())
        r = self.client.send("chatId:wrMOCK000001", "你好", key)
        self.assertEqual(r["state"], "succeeded")
        observed = self.client.wait_for(lambda e: e["kind"] == "message.observed" and e["payload"].get("commandId") == r["commandId"])
        self.assertIsNotNone(observed)
        p = observed["payload"]
        self.assertEqual((p["origin"], p["conversationType"], p["chatId"], p["sender"]), ("controller", "group", "wrMOCK000001", ""))
        self.assertEqual(len(p["messageKey"]), 16)
        states = [e["payload"]["state"] for e in self.client.events if e["kind"] == "command.state" and e["payload"]["commandId"] == r["commandId"]]
        self.assertEqual(states, ["accepted", "running", "succeeded"])
        again = self.client.send("chatId:wrMOCK000001", "你好", key)
        self.assertEqual(again["commandId"], r["commandId"])
        with self.assertRaises(RpcError) as ctx:
            self.client.send("chatId:wrMOCK000001", "too fast")
        self.assertEqual(ctx.exception.code, "RATE_LIMITED")

    def test_policy_unknown_target_and_pause(self):
        with self.assertRaises(RpcError) as ctx:
            self.client.send("chatId:nope", "x")
        self.assertEqual(ctx.exception.code, "TARGET_NOT_FOUND")
        self.mock.policy["allowedTitles"] = []
        with self.assertRaises(RpcError) as ctx:
            self.client.send("小明·a1b2c3", "x")
        self.assertEqual(ctx.exception.code, "TARGET_NOT_ALLOWED")
        self.client.command("controller.pause")
        with self.assertRaises(RpcError) as ctx:
            self.client.send("文件传输助手", "x")
        self.assertEqual(ctx.exception.code, "PAUSED")
        self.client.command("controller.resume")
        self.assertEqual(self.client.send("文件传输助手", "x")["state"], "succeeded")
        with self.assertRaises(RpcError) as ctx:
            self.client.call("message.send", {"target": "文件传输助手", "text": "no key"})
        self.assertEqual(ctx.exception.data.get("code"), "INVALID_PARAMS")

    def test_read_history_inbound_and_takeover(self):
        read = self.client.read("chatId:wrMOCK000001")
        self.assertEqual((read["active"], read["conversationType"], read["chatId"]), ("imctl测试群", "group", "wrMOCK000001"))
        self.assertIsNotNone(self.client.wait_for(lambda e: e["kind"] == "conversation.activity" and e["payload"].get("activeTo") == "imctl测试群"))
        hist = self.client.history(10)
        self.assertEqual(hist[0]["sender"], "张三")
        self.assertTrue(all("messageKey" in h for h in hist))
        self.client.call("sim.inbound", {"target": "chatId:wrMOCK000001", "text": "在吗", "sender": "李四"})
        peer = self.client.wait_for(lambda e: e["kind"] == "message.observed" and e["payload"]["origin"] == "peer")
        self.assertEqual(peer["payload"]["sender"], "李四")
        self.client.call("sim.takeover", {"target": "chatId:wrMOCK000001", "text": "我来"})
        self.assertIsNotNone(self.client.wait_for(lambda e: e["kind"] == "message.observed" and e["payload"]["origin"] == "other"))

    def test_join_way_contact_way_welcome_broadcast_and_callback(self):
        jw = self.client.command("group.joinway.create", {"chatIds": ["wrMOCK000001"], "autoCreateRoom": True, "roomBaseName": "imctl群", "roomBaseId": 1, "state": "ch1"})["result"]
        got = self.client.command("group.joinway.get", {"configId": jw["configId"]})["result"]
        self.assertTrue(got["qrCode"].endswith(".png") and got["chatIds"] == ["wrMOCK000001"])
        cw = self.client.command("contact.way.create", {"state": "ch1", "users": ["u1"]})["result"]
        self.assertTrue(cw["qrCode"])
        seen = []
        self.bus.subscribe("wecom/+/evt", lambda m: seen.append(m))
        self.client.call("sim.callback", {"Event": "change_external_contact", "ChangeType": "add_external_contact", "State": "ch1", "WelcomeCode": "WC1", "ExternalUserID": "wm9"})
        import time
        time.sleep(0.1)
        self.assertEqual(len(seen), 1)
        self.assertEqual(self.client.command("contact.welcome.send", {"welcomeCode": "WC1", "text": "hi"})["result"], {"ok": True})
        r = self.client.command("contact.remark.set", {"userid": "u1", "externalUserId": "wmMOCK000001", "remark": "小明·zzz999"})["result"]
        self.assertEqual(r["title"], "小明·zzz999")
        # the title rule no longer matches the renamed conversation; allow it by platform id instead
        self.mock.policy["allowedExternalUserIds"] = ["wmMOCK000001"]
        self.assertEqual(self.client.read("externalUserId:wmMOCK000001")["active"], "小明·zzz999")
        b = self.client.command("broadcast.create", {"chatIds": ["wrMOCK000001"], "sender": "u1", "text": "公告", "idempotencyKey": str(uuid.uuid4())})["result"]
        self.assertEqual(self.client.command("broadcast.confirm", {"msgid": b["msgid"]})["result"]["verified"], "true")
        self.assertEqual(self.client.command("broadcast.get", {"msgid": b["msgid"], "userid": "u1"})["result"]["results"][0]["status"], 1)

    def test_api_disabled_is_unsupported(self):
        self.mock.api_enabled = False
        with self.assertRaises(RpcError) as ctx:
            self.client.command("group.list")
        self.assertEqual(ctx.exception.code, "UNSUPPORTED")

    def test_replay_fills_a_gap(self):
        self.client.send("文件传输助手", "a")
        n = len(self.client.events)
        self.assertGreater(n, 0)
        # forget the tail locally, then reconcile
        self.client.events = self.client.events[:1]
        self.client.last_event_id = 1
        fetched = self.client.reconcile(limit=2)
        self.assertGreaterEqual(fetched, n - 1)
        ids = [e["eventId"] for e in self.client.events]
        self.assertEqual(ids, list(range(1, len(ids) + 1)))
        r = self.client.call("event.replay", {"afterEventId": 0, "limit": 5})
        self.assertEqual((r["count"], r["events"][0]["eventId"]), (5, 1))


if __name__ == "__main__":
    unittest.main()
