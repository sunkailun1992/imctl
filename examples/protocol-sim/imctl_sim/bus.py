"""Transport abstraction: an in-process bus for tests/offline demos and a
paho-mqtt (MQTT 5) bus for a real broker. Only the properties the protocol
uses are modelled: Response Topic, Correlation Data, user properties, retain."""

from __future__ import annotations

import queue
import threading
from dataclasses import dataclass, field
from typing import Callable
from urllib.parse import urlparse


@dataclass
class Message:
    topic: str
    payload: bytes
    qos: int = 1
    retain: bool = False
    response_topic: str | None = None
    correlation_data: bytes | None = None
    user_properties: list[tuple[str, str]] = field(default_factory=list)


Handler = Callable[[Message], None]


def topic_matches(filter_: str, topic: str) -> bool:
    """MQTT wildcard matching; `$share/<group>/` is stripped like a broker does."""
    if filter_.startswith("$share/"):
        filter_ = filter_.split("/", 2)[2]
    f_parts = filter_.split("/")
    t_parts = topic.split("/")
    for i, part in enumerate(f_parts):
        if part == "#":
            return True
        if i >= len(t_parts):
            return False
        if part != "+" and part != t_parts[i]:
            return False
    return len(f_parts) == len(t_parts)


class Bus:
    def start(self) -> None: ...
    def stop(self) -> None: ...
    def publish(self, message: Message) -> None: ...
    def subscribe(self, filter_: str, handler: Handler) -> None: ...


class MemoryBus(Bus):
    """Single-process broker: deliveries happen on one worker thread so the
    mock and the driver behave like they would across a real broker."""

    def __init__(self) -> None:
        self._subs: list[tuple[str, Handler]] = []
        self._retained: dict[str, Message] = {}
        self._queue: queue.Queue[Message | None] = queue.Queue()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.published: list[Message] = []

    def start(self) -> None:
        if self._thread:
            return
        self._thread = threading.Thread(target=self._pump, name="memory-bus", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._thread:
            self._queue.put(None)
            self._thread.join(timeout=2)
            self._thread = None

    def publish(self, message: Message) -> None:
        with self._lock:
            self.published.append(message)
            if message.retain:
                self._retained[message.topic] = message
        self._queue.put(message)

    def subscribe(self, filter_: str, handler: Handler) -> None:
        with self._lock:
            self._subs.append((filter_, handler))
            retained = [m for t, m in self._retained.items() if topic_matches(filter_, t)]
        for m in retained:
            self._queue.put(m)

    def _pump(self) -> None:
        while True:
            m = self._queue.get()
            if m is None:
                return
            with self._lock:
                handlers = [h for f, h in self._subs if topic_matches(f, m.topic)]
            for h in handlers:
                try:
                    h(m)
                except Exception as e:  # a bad handler must not kill the bus
                    print(f"memory-bus: handler error on {m.topic}: {e!r}")


class MqttBus(Bus):
    """paho-mqtt 2.x, MQTT v5, persistent session (clean_start=False)."""

    def __init__(self, url: str, client_id: str, session_expiry: int = 86400) -> None:
        import paho.mqtt.client as mqtt  # imported lazily: tests need no broker
        from paho.mqtt.packettypes import PacketTypes
        from paho.mqtt.properties import Properties

        self._mqtt = mqtt
        self._Properties = Properties
        self._PacketTypes = PacketTypes
        u = urlparse(url)
        if u.scheme not in ("mqtt", "mqtts"):
            raise ValueError("broker url must be mqtt://[user:pass@]host[:port] or mqtts://")
        self._host = u.hostname or "localhost"
        self._port = u.port or (8883 if u.scheme == "mqtts" else 1883)
        self._tls = u.scheme == "mqtts"
        self._client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id, protocol=mqtt.MQTTv5)
        if u.username:
            self._client.username_pw_set(u.username, u.password)
        if self._tls:
            self._client.tls_set()
        self._session_expiry = session_expiry
        self._subs: list[tuple[str, Handler]] = []
        self._connected = threading.Event()
        self._subacks: dict[int, threading.Event] = {}
        self._client.on_message = self._on_message
        self._client.on_connect = self._on_connect
        self._client.on_subscribe = self._on_subscribe

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        for f, _ in self._subs:
            client.subscribe(f, qos=1)
        self._connected.set()

    def _on_subscribe(self, client, userdata, mid, reason_codes, properties=None):
        ev = self._subacks.pop(mid, None)
        if ev:
            ev.set()

    def _on_message(self, client, userdata, msg):
        props = getattr(msg, "properties", None)
        m = Message(
            topic=msg.topic, payload=bytes(msg.payload), qos=msg.qos, retain=bool(msg.retain),
            response_topic=getattr(props, "ResponseTopic", None) if props else None,
            correlation_data=getattr(props, "CorrelationData", None) if props else None,
            user_properties=list(getattr(props, "UserProperty", []) or []) if props else [],
        )
        for f, h in list(self._subs):
            if topic_matches(f, m.topic):
                try:
                    h(m)
                except Exception as e:
                    print(f"mqtt-bus: handler error on {m.topic}: {e!r}")

    def start(self) -> None:
        props = self._Properties(self._PacketTypes.CONNECT)
        props.SessionExpiryInterval = self._session_expiry
        self._client.connect(self._host, self._port, keepalive=30, clean_start=False, properties=props)
        self._client.loop_start()
        # Publishing before CONNACK/SUBACK loses fast replies: wait for the session first.
        if not self._connected.wait(10):
            raise TimeoutError("broker did not acknowledge the connection within 10 s")

    def stop(self) -> None:
        self._client.loop_stop()
        self._client.disconnect()

    def publish(self, message: Message) -> None:
        props = self._Properties(self._PacketTypes.PUBLISH)
        if message.response_topic:
            props.ResponseTopic = message.response_topic
        if message.correlation_data is not None:
            props.CorrelationData = message.correlation_data
        if message.user_properties:
            props.UserProperty = list(message.user_properties)
        self._client.publish(message.topic, message.payload, qos=message.qos, retain=message.retain, properties=props)

    def subscribe(self, filter_: str, handler: Handler) -> None:
        self._subs.append((filter_, handler))
        if self._client.is_connected():
            ev = threading.Event()
            result, mid = self._client.subscribe(filter_, qos=1)
            if mid is not None:
                self._subacks[mid] = ev
                # A command published before the SUBACK could be answered before the
                # broker routes replies to us; block briefly so callers never race.
                ev.wait(5)


def open_bus(url: str, client_id: str) -> Bus:
    if url.startswith("memory://"):
        return MemoryBus()
    return MqttBus(url, client_id)
