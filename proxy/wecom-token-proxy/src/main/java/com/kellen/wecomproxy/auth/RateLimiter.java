package com.kellen.wecomproxy.auth;

import java.time.Clock;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.Map;

/** Per-token sliding window (60 s). Counts attempts, so a misbehaving controller cannot burn the corp's API quota. */
public class RateLimiter {

    private final int limitPerMinute;
    private final Clock clock;
    private final Map<String, Deque<Long>> recent = new HashMap<>();

    public RateLimiter(int limitPerMinute, Clock clock) {
        this.limitPerMinute = limitPerMinute;
        this.clock = clock;
    }

    public synchronized boolean admit(String token) {
        long now = clock.millis();
        Deque<Long> window = recent.computeIfAbsent(token, k -> new ArrayDeque<>());
        while (!window.isEmpty() && now - window.peekFirst() >= 60_000) {
            window.pollFirst();
        }
        if (window.size() >= limitPerMinute) {
            return false;
        }
        window.addLast(now);
        return true;
    }
}
