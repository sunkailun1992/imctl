package com.kellen.imctlconsumer.core;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Durable, deduplicating event store keyed by (source, eventId). Sources are
 * `im:<controller_id>` and `wecom:<corp_id>`. Replace the memory version with
 * a table whose primary key is (source, event_id) — the semantics stay.
 */
public interface EventStore {

    /** true when stored now, false when this (source, eventId) was already there. */
    boolean saveIfNew(String source, long eventId, String json);

    long lastContiguousEventId(String source);

    void advance(String source, long eventId);

    class Memory implements EventStore {
        private final Map<String, Map<Long, String>> rows = new ConcurrentHashMap<>();
        private final Map<String, Long> cursors = new ConcurrentHashMap<>();

        @Override
        public boolean saveIfNew(String source, long eventId, String json) {
            return rows.computeIfAbsent(source, s -> new ConcurrentHashMap<>()).putIfAbsent(eventId, json) == null;
        }

        @Override
        public long lastContiguousEventId(String source) {
            return cursors.getOrDefault(source, 0L);
        }

        @Override
        public void advance(String source, long eventId) {
            cursors.merge(source, eventId, Math::max);
        }

        public int size(String source) {
            return rows.getOrDefault(source, Map.of()).size();
        }
    }
}
