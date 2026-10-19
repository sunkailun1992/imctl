package com.kellen.imctlconsumer.core;

import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * Keeps `lastEventId` per controller and fills gaps with `event.replay`
 * (protocol §8). Returns the events that were missed so the consumer can
 * process them in order.
 */
public class Reconciler {

    public static final int REPLAY_LIMIT = 500;
    private final Commands commands;
    private final EventStore store;
    private final ObjectMapper mapper;

    public Reconciler(Commands commands, EventStore store, ObjectMapper mapper) {
        this.commands = commands;
        this.store = store;
        this.mapper = mapper;
    }

    /** Called for a live event after it was stored. Detects a hole and replays; returns missed events (already stored) in id order. */
    public List<JsonNode> onLiveEvent(String controllerId, long eventId) {
        String source = "im:" + controllerId;
        long last = store.lastContiguousEventId(source);
        if (eventId <= last) {
            return List.of();
        }
        if (eventId == last + 1 || last == 0) {
            store.advance(source, eventId);
            return List.of();
        }
        List<JsonNode> missed = replay(controllerId);
        // the live event itself is already stored; move the cursor over it when the replay closed the hole up to it
        if (store.lastContiguousEventId(source) + 1 == eventId) {
            store.advance(source, eventId);
        }
        return missed;
    }

    /** Loops event.replay from the cursor until caught up; used on gaps, on reconnect and when the controller comes back online. */
    public List<JsonNode> replay(String controllerId) {
        String source = "im:" + controllerId;
        List<JsonNode> missed = new ArrayList<>();
        int guard = 0;
        while (guard++ < 1000) {
            long cursor = store.lastContiguousEventId(source);
            ObjectNode params = mapper.createObjectNode().put("afterEventId", cursor).put("limit", REPLAY_LIMIT);
            JsonNode r = commands.call(controllerId, "event.replay", params);
            JsonNode events = r.path("events");
            long newest = r.path("lastEventId").asLong();
            for (JsonNode e : events) {
                long id = e.path("eventId").asLong();
                if (store.saveIfNew(source, id, e.toString())) {
                    missed.add(e);
                }
                if (id == store.lastContiguousEventId(source) + 1) {
                    store.advance(source, id);
                }
            }
            if (events.size() < REPLAY_LIMIT || events.isEmpty() || store.lastContiguousEventId(source) >= newest) {
                break;
            }
        }
        return missed;
    }
}
