package com.kellen.imctlconsumer.core;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.kellen.imctlconsumer.policy.ReplyPolicy;

/**
 * The business side of the loop in protocol §11: dedupe events, fill gaps,
 * answer allowlisted peers through the reply policy, go silent on takeover,
 * and welcome scanned contacts within the 20 s window. It only ever sends
 * commands; every safety limit (allowlist, rate, policy) also exists on the
 * controller, so a bug here cannot widen what the Mac will do.
 */
public class Consumer {

    private static final Logger log = LoggerFactory.getLogger(Consumer.class);

    public record Settings(Set<String> welcomeStates, Set<String> groupAllowlist, Set<String> customerAllowlist, String joinWayUrl,
                           String staffUserid, Duration silence, int historyLimit) {
    }

    private final Commands commands;
    private final EventStore store;
    private final Reconciler reconciler;
    private final ReplyPolicy policy;
    private final Settings settings;
    private final Clock clock;
    private final ObjectMapper mapper;
    private final Map<String, Instant> silencedUntil = new ConcurrentHashMap<>();
    private final Map<String, Boolean> seenKeys = new LinkedHashMap<>(1024, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<String, Boolean> eldest) {
            return size() > 10_000;
        }
    };
    private final Map<String, Boolean> controllerOnline = new ConcurrentHashMap<>();

    public Consumer(Commands commands, EventStore store, ReplyPolicy policy, Settings settings, Clock clock, ObjectMapper mapper) {
        this.commands = commands;
        this.store = store;
        this.reconciler = new Reconciler(commands, store, mapper);
        this.policy = policy;
        this.settings = settings;
        this.clock = clock;
        this.mapper = mapper;
    }

    // ----------------------------------------------------------- controller events

    /** Entry point for `im/{controller_id}/evt` payloads. Returns the commands it decided to send (method names), for tests and audit. */
    public List<String> onControllerEvent(JsonNode event) {
        String controllerId = event.path("controllerId").asText();
        long eventId = event.path("eventId").asLong();
        String source = "im:" + controllerId;
        if (!store.saveIfNew(source, eventId, event.toString())) {
            return List.of();
        }
        List<String> sent = new ArrayList<>();
        for (JsonNode missed : reconciler.onLiveEvent(controllerId, eventId)) {
            sent.addAll(handle(controllerId, missed));
        }
        sent.addAll(handle(controllerId, event));
        return sent;
    }

    /** `im/{controller_id}/state`: a controller coming back online triggers one reconciliation. */
    public List<String> onControllerState(String controllerId, JsonNode state) {
        boolean online = state.path("online").asBoolean(false);
        Boolean was = controllerOnline.put(controllerId, online);
        List<String> sent = new ArrayList<>();
        if (online && (was == null || !was) && store.lastContiguousEventId("im:" + controllerId) > 0) {
            for (JsonNode missed : reconciler.replay(controllerId)) {
                sent.addAll(handle(controllerId, missed));
            }
        }
        return sent;
    }

    private List<String> handle(String controllerId, JsonNode event) {
        String kind = event.path("kind").asText();
        JsonNode p = event.path("payload");
        if (!"message.observed".equals(kind)) {
            return List.of();
        }
        String conversation = p.path("conversation").asText();
        String origin = p.path("origin").asText();
        String key = p.path("messageKey").asText("");
        if ("other".equals(origin)) {
            silencedUntil.put(conversation, clock.instant().plus(settings.silence()));
            log.info("takeover on {}: silent for {}", conversation, settings.silence());
            return List.of();
        }
        if (!"peer".equals(origin)) {
            return List.of();   // controller echoes, unknown direction
        }
        if (!key.isEmpty()) {
            synchronized (seenKeys) {
                if (seenKeys.put(key, Boolean.TRUE) != null) {
                    return List.of();   // seen live and via history/replay
                }
            }
        }
        Instant until = silencedUntil.get(conversation);
        if (until != null && clock.instant().isBefore(until)) {
            return List.of();
        }
        String target = target(p);
        if (target == null) {
            return List.of();   // not allowlisted, or the bridge has no id: never address by title
        }
        List<ReplyPolicy.Turn> history = history(controllerId, target);
        ReplyPolicy.Context ctx = new ReplyPolicy.Context(controllerId, conversation, p.path("conversationType").asText(), p.path("chatId").asText(null),
                p.path("externalUserId").asText(null), p.path("sender").asText(""), p.path("text").asText(""), history);
        Optional<String> reply = policy.reply(ctx);
        if (reply.isEmpty()) {
            return List.of();
        }
        ObjectNode params = mapper.createObjectNode().put("target", target).put("text", reply.get())
                .put("idempotencyKey", UUID.randomUUID().toString()).put("ttlMs", 30_000).put("issuedAtMs", clock.millis());
        JsonNode record = commands.call(controllerId, "message.send", params);
        log.info("reply to {} -> {} ({})", target, record.path("state").asText(), record.path("error").path("code").asText(""));
        return List.of("message.send");
    }

    /** `chatId:` / `externalUserId:` when the bridge knows the conversation and the allowlist includes it; else null. */
    private String target(JsonNode p) {
        String chatId = p.path("chatId").asText(null);
        String ext = p.path("externalUserId").asText(null);
        if (chatId != null && settings.groupAllowlist().contains(chatId)) {
            return "chatId:" + chatId;
        }
        if (ext != null && settings.customerAllowlist().contains(ext)) {
            return "externalUserId:" + ext;
        }
        return null;
    }

    private List<ReplyPolicy.Turn> history(String controllerId, String target) {
        List<ReplyPolicy.Turn> turns = new ArrayList<>();
        try {
            commands.call(controllerId, "conversation.read", mapper.createObjectNode().put("target", target));
            JsonNode rows = commands.call(controllerId, "message.history", mapper.createObjectNode().put("limit", settings.historyLimit())).path("result");
            for (JsonNode r : rows) {
                turns.add(new ReplyPolicy.Turn(r.path("direction").asText(), r.path("sender").asText(null), r.path("text").asText("")));
            }
        } catch (RuntimeException e) {
            log.warn("history for {} unavailable: {}", target, e.toString());
        }
        return turns;
    }

    // -------------------------------------------------------------- callback events

    /** Entry point for `wecom/{corp_id}/evt` payloads relayed by the proxy. */
    public List<String> onCallbackEvent(String controllerId, JsonNode event) {
        String corpId = event.path("corpId").asText();
        if (!store.saveIfNew("wecom:" + corpId, event.path("eventId").asLong(), event.toString())) {
            return List.of();
        }
        JsonNode p = event.path("payload");
        String eventName = p.path("Event").asText();
        String change = p.path("ChangeType").asText();
        if ("change_external_contact".equals(eventName) && "add_external_contact".equals(change)) {
            String state = p.path("State").asText("");
            String welcomeCode = p.path("WelcomeCode").asText("");
            if (welcomeCode.isEmpty() || !settings.welcomeStates().contains(state)) {
                return List.of();
            }
            ObjectNode params = mapper.createObjectNode().put("welcomeCode", welcomeCode).put("text", "您好，欢迎！点下面的链接进群。");
            if (settings.joinWayUrl() != null && !settings.joinWayUrl().isBlank()) {
                ArrayNode attachments = params.putArray("attachments");
                ObjectNode link = attachments.addObject().put("msgtype", "link");
                link.putObject("link").put("title", "扫码进群").put("url", settings.joinWayUrl());
            }
            commands.call(controllerId, "contact.welcome.send", params);
            List<String> sent = new ArrayList<>(List.of("contact.welcome.send"));
            String ext = p.path("ExternalUserID").asText("");
            if (!ext.isEmpty() && settings.staffUserid() != null && !settings.staffUserid().isBlank()) {
                String shortCode = ext.length() >= 6 ? ext.substring(ext.length() - 6) : ext;
                commands.call(controllerId, "contact.remark.set", mapper.createObjectNode().put("userid", settings.staffUserid())
                        .put("externalUserId", ext).put("remark", "客户·" + shortCode));
                sent.add("contact.remark.set");
            }
            return sent;
        }
        if ("change_external_chat".equals(eventName) && ("create".equals(change) || "update".equals(change))) {
            String chatId = p.path("ChatId").asText("");
            if (!chatId.isEmpty()) {
                commands.call(controllerId, "group.get", mapper.createObjectNode().put("chatId", chatId));
                return List.of("group.get");
            }
        }
        return List.of();
    }
}
