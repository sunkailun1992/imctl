package com.kellen.imctlconsumer;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Set;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.kellen.imctlconsumer.core.Commands;
import com.kellen.imctlconsumer.core.Consumer;
import com.kellen.imctlconsumer.core.EventStore;
import com.kellen.imctlconsumer.policy.ReplyPolicy;

class ConsumerTest {

    static class FakeCommands implements Commands {
        record Call(String controllerId, String method, ObjectNode params) {
        }
        final List<Call> calls = new ArrayList<>();
        final ObjectMapper mapper = new ObjectMapper();
        JsonNode replayAnswer;

        @Override
        public JsonNode call(String controllerId, String method, ObjectNode params) {
            calls.add(new Call(controllerId, method, params));
            switch (method) {
                case "event.replay" -> {
                    return replayAnswer != null ? replayAnswer : mapper.createObjectNode().put("count", 0).put("lastEventId", 0).set("events", mapper.createArrayNode());
                }
                case "message.history" -> {
                    ObjectNode r = mapper.createObjectNode();
                    var rows = r.putArray("result");
                    rows.addObject().put("direction", "inbound").put("sender", "张三").put("text", "大家好").put("messageKey", "k0");
                    return r;
                }
                default -> {
                    return mapper.createObjectNode().put("commandId", "C1").put("state", "succeeded");
                }
            }
        }

        List<Call> of(String method) {
            return calls.stream().filter(c -> c.method().equals(method)).toList();
        }
    }

    static class MutableClock extends Clock {
        Instant now = Instant.parse("2026-09-14T12:00:00Z");
        @Override public ZoneOffset getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(java.time.ZoneId zone) { return this; }
        @Override public Instant instant() { return now; }
    }

    final ObjectMapper mapper = new ObjectMapper();
    FakeCommands commands;
    EventStore.Memory store;
    MutableClock clock;
    Consumer consumer;

    @BeforeEach
    void setUp() {
        commands = new FakeCommands();
        store = new EventStore.Memory();
        clock = new MutableClock();
        ReplyPolicy policy = ctx -> ctx.incomingText().contains("静音") ? Optional.empty() : Optional.of("回复：" + ctx.incomingText() + "（历史" + ctx.history().size() + "条）");
        Consumer.Settings settings = new Consumer.Settings(Set.of("ch1"), Set.of("wr1"), Set.of("wm1"), "https://example.invalid/joinway.png", "u1",
                Duration.ofMinutes(30), 20);
        consumer = new Consumer(commands, store, policy, settings, clock, mapper);
    }

    ObjectNode observed(long eventId, String origin, String text, String chatId, String key) {
        ObjectNode e = mapper.createObjectNode().put("eventId", eventId).put("tsMs", 1L).put("kind", "message.observed").put("controllerId", "mac-01");
        ObjectNode p = e.putObject("payload");
        p.put("conversation", "imctl测试群").put("direction", "peer".equals(origin) ? "inbound" : "outbound").put("timeLabel", "").put("text", text)
                .put("origin", origin).put("sender", "张三").put("messageKey", key).put("conversationType", "group");
        if (chatId != null) {
            p.put("chatId", chatId);
        }
        return e;
    }

    @Test
    void peerMessageInAllowlistedGroupGetsAReplyByChatId() {
        List<String> sent = consumer.onControllerEvent(observed(1, "peer", "营业时间？", "wr1", "k1"));
        assertThat(sent).containsExactly("message.send");
        assertThat(commands.of("conversation.read")).hasSize(1);
        FakeCommands.Call send = commands.of("message.send").get(0);
        assertThat(send.params().get("target").asText()).isEqualTo("chatId:wr1");
        assertThat(send.params().get("text").asText()).isEqualTo("回复：营业时间？（历史1条）");
        assertThat(send.params().get("idempotencyKey").asText()).isNotBlank();
        assertThat(send.params().get("ttlMs").asInt()).isEqualTo(30_000);
        // duplicate delivery of the same event, and the same messageKey under a new id, are both ignored
        assertThat(consumer.onControllerEvent(observed(1, "peer", "营业时间？", "wr1", "k1"))).isEmpty();
        assertThat(consumer.onControllerEvent(observed(2, "peer", "营业时间？", "wr1", "k1"))).isEmpty();
        assertThat(commands.of("message.send")).hasSize(1);
    }

    @Test
    void notAllowlistedUnknownAndControllerEchoesAreIgnored() {
        assertThat(consumer.onControllerEvent(observed(1, "peer", "hi", "wr9", "k1"))).isEmpty();
        assertThat(consumer.onControllerEvent(observed(2, "peer", "hi", null, "k2"))).isEmpty();
        assertThat(consumer.onControllerEvent(observed(3, "controller", "hi", "wr1", "k3"))).isEmpty();
        assertThat(consumer.onControllerEvent(observed(4, "unknown", "hi", "wr1", "k4"))).isEmpty();
        assertThat(consumer.onControllerEvent(observed(5, "peer", "请静音", "wr1", "k5"))).isEmpty();
        assertThat(commands.of("message.send")).isEmpty();
    }

    @Test
    void takeoverSilencesTheConversationForTheConfiguredWindow() {
        consumer.onControllerEvent(observed(1, "other", "我来处理", "wr1", "k1"));
        assertThat(consumer.onControllerEvent(observed(2, "peer", "在吗", "wr1", "k2"))).isEmpty();
        clock.now = clock.now.plus(Duration.ofMinutes(31));
        assertThat(consumer.onControllerEvent(observed(3, "peer", "在吗？", "wr1", "k3"))).containsExactly("message.send");
    }

    @Test
    void gapTriggersReplayAndMissedEventsAreHandledInOrder() {
        consumer.onControllerEvent(observed(1, "peer", "one", "wr1", "k1"));
        ObjectNode replay = mapper.createObjectNode().put("count", 2).put("lastEventId", 4);
        var events = replay.putArray("events");
        events.add(observed(2, "peer", "two", "wr1", "k2"));
        events.add(observed(3, "peer", "three", "wr1", "k3"));
        commands.replayAnswer = replay;
        List<String> sent = consumer.onControllerEvent(observed(4, "peer", "four", "wr1", "k4"));
        assertThat(commands.of("event.replay")).hasSize(1);
        assertThat(commands.of("event.replay").get(0).params().get("afterEventId").asLong()).isEqualTo(1);
        assertThat(sent).containsExactly("message.send", "message.send", "message.send");
        // "one" was answered live before the gap; the missed two/three are answered before the live four
        assertThat(commands.of("message.send").stream().map(c -> c.params().get("text").asText()).toList())
                .containsExactly("回复：one（历史1条）", "回复：two（历史1条）", "回复：three（历史1条）", "回复：four（历史1条）");
        assertThat(store.lastContiguousEventId("im:mac-01")).isEqualTo(4);
        assertThat(store.size("im:mac-01")).isEqualTo(4);
    }

    @Test
    void controllerComingBackOnlineReconcilesOnce() {
        consumer.onControllerEvent(observed(1, "peer", "one", "wr1", "k1"));
        consumer.onControllerState("mac-01", mapper.createObjectNode().put("online", false));
        consumer.onControllerState("mac-01", mapper.createObjectNode().put("online", true));
        consumer.onControllerState("mac-01", mapper.createObjectNode().put("online", true));
        assertThat(commands.of("event.replay")).hasSize(1);
    }

    @Test
    void callbackWelcomeOnlyForEnabledChannelsAndGroupCreateFillsTheBridge() {
        ObjectNode add = mapper.createObjectNode().put("eventId", 1).put("tsMs", 1L).put("kind", "wecom.callback").put("corpId", "wwcorp");
        add.putObject("payload").put("Event", "change_external_contact").put("ChangeType", "add_external_contact").put("State", "ch1")
                .put("WelcomeCode", "WC1").put("ExternalUserID", "wmABCDEF123456").put("UserID", "u1");
        assertThat(consumer.onCallbackEvent("mac-01", add)).containsExactly("contact.welcome.send", "contact.remark.set");
        FakeCommands.Call welcome = commands.of("contact.welcome.send").get(0);
        assertThat(welcome.params().get("welcomeCode").asText()).isEqualTo("WC1");
        assertThat(welcome.params().get("attachments").get(0).get("link").get("url").asText()).isEqualTo("https://example.invalid/joinway.png");
        assertThat(commands.of("contact.remark.set").get(0).params().get("remark").asText()).isEqualTo("客户·123456");
        assertThat(consumer.onCallbackEvent("mac-01", add)).isEmpty();   // duplicate eventId
        ObjectNode other = add.deepCopy();
        other.put("eventId", 2);
        ((ObjectNode) other.get("payload")).put("State", "ch-disabled");
        assertThat(consumer.onCallbackEvent("mac-01", other)).isEmpty();
        ObjectNode created = mapper.createObjectNode().put("eventId", 3).put("tsMs", 1L).put("kind", "wecom.callback").put("corpId", "wwcorp");
        created.putObject("payload").put("Event", "change_external_chat").put("ChangeType", "create").put("ChatId", "wr77");
        assertThat(consumer.onCallbackEvent("mac-01", created)).containsExactly("group.get");
        assertThat(commands.of("group.get").get(0).params().get("chatId").asText()).isEqualTo("wr77");
    }
}
