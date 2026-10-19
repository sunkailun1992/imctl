package com.kellen.wecomproxy;

import static org.assertj.core.api.Assertions.assertThat;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;

import com.kellen.wecomproxy.auth.RateLimiter;
import com.kellen.wecomproxy.event.EventSequence;

class RateLimiterAndSequenceTest {

    @Test
    void perTokenWindowOfSixtySeconds() {
        Instant[] now = {Instant.parse("2026-09-14T12:00:00Z")};
        Clock clock = new Clock() {
            @Override public ZoneOffset getZone() { return ZoneOffset.UTC; }
            @Override public Clock withZone(java.time.ZoneId zone) { return this; }
            @Override public Instant instant() { return now[0]; }
        };
        RateLimiter limiter = new RateLimiter(2, clock);
        assertThat(limiter.admit("a")).isTrue();
        assertThat(limiter.admit("a")).isTrue();
        assertThat(limiter.admit("a")).isFalse();
        assertThat(limiter.admit("b")).isTrue();
        now[0] = now[0].plusSeconds(60);
        assertThat(limiter.admit("a")).isTrue();
    }

    @Test
    void sequenceSurvivesRestart() throws Exception {
        Path dir = Files.createTempDirectory("wecom-proxy-seq");
        EventSequence first = new EventSequence(dir);
        assertThat(first.next()).isEqualTo(1);
        assertThat(first.next()).isEqualTo(2);
        EventSequence second = new EventSequence(dir);
        assertThat(second.last()).isEqualTo(2);
        assertThat(second.next()).isEqualTo(3);
    }
}
