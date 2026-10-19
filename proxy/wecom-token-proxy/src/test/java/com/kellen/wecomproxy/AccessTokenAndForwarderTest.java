package com.kellen.wecomproxy;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;

import org.junit.jupiter.api.Test;

import com.kellen.wecomproxy.config.WeComProperties;
import com.kellen.wecomproxy.forward.PathAllowlist;
import com.kellen.wecomproxy.forward.WeComForwarder;
import com.kellen.wecomproxy.token.AccessTokenService;
import com.kellen.wecomproxy.token.WeComHttp;

class AccessTokenAndForwarderTest {

    static class MutableClock extends Clock {
        Instant now = Instant.parse("2026-09-14T12:00:00Z");

        @Override public ZoneOffset getZone() { return ZoneOffset.UTC; }
        @Override public Clock withZone(java.time.ZoneId zone) { return this; }
        @Override public Instant instant() { return now; }
    }

    final WeComProperties props = new WeComProperties("wwcorp", "secret", 1000002L, "tok", null, null);

    @Test
    void tokenIsCachedUntilFiveMinutesBeforeExpiry() {
        FakeWeComHttp http = new FakeWeComHttp();
        MutableClock clock = new MutableClock();
        AccessTokenService tokens = new AccessTokenService(http, props, clock);
        assertThat(tokens.cached()).isFalse();
        assertThat(tokens.current()).isEqualTo("T1");
        assertThat(tokens.current()).isEqualTo("T1");
        assertThat(http.tokenCalls).isEqualTo(1);
        clock.now = clock.now.plus(Duration.ofSeconds(7200 - 300 + 1));
        assertThat(tokens.current()).isEqualTo("T2");
        assertThat(http.tokenCalls).isEqualTo(2);
    }

    @Test
    void gettokenErrorsAreSurfacedNotSwallowed() {
        FakeWeComHttp http = new FakeWeComHttp();
        http.tokenBody = "{\"errcode\":40013,\"errmsg\":\"invalid corpid\"}";
        AccessTokenService tokens = new AccessTokenService(http, props, new MutableClock());
        assertThatThrownBy(tokens::current).isInstanceOf(AccessTokenService.TokenUnavailableException.class).hasMessageContaining("40013");
    }

    @Test
    void forwarderInjectsTokenAndRetriesOnceOnExpiredToken() {
        FakeWeComHttp http = new FakeWeComHttp();
        AccessTokenService tokens = new AccessTokenService(http, props, new MutableClock());
        WeComForwarder fwd = new WeComForwarder(http, tokens);
        http.answer = c -> c.token().equals("T1")
                ? new WeComHttp.Response(200, "{\"errcode\":42001,\"errmsg\":\"access_token expired\"}")
                : new WeComHttp.Response(200, "{\"errcode\":0,\"errmsg\":\"ok\",\"config_id\":\"cfg1\"}");
        WeComHttp.Response r = fwd.forward("externalcontact/groupchat/add_join_way", "{\"scene\":2}".getBytes(), "application/json");
        assertThat(r.status()).isEqualTo(200);
        assertThat(r.body()).contains("cfg1");
        assertThat(http.calls).hasSize(2);
        assertThat(http.calls.get(0).token()).isEqualTo("T1");
        assertThat(http.calls.get(1).token()).isEqualTo("T2");
        assertThat(http.calls.get(1).body()).isEqualTo("{\"scene\":2}");
        // other errcodes pass through untouched, no retry
        http.answer = c -> new WeComHttp.Response(200, "{\"errcode\":40096,\"errmsg\":\"invalid config_id\"}");
        assertThat(fwd.forward("externalcontact/groupchat/get_join_way", new byte[0], null).body()).contains("40096");
        assertThat(http.calls).hasSize(3);
    }

    @Test
    void allowlistNormalisesAndRejectsTraversal() {
        PathAllowlist list = new PathAllowlist(java.util.Set.of("externalcontact/remark"));
        assertThat(list.allows("/externalcontact/remark/")).isTrue();
        assertThat(list.allows("externalcontact/../user/get")).isFalse();
        assertThat(list.allows("externalcontact/remark?x=1")).isFalse();
        assertThat(list.allows("user/get")).isFalse();
        assertThat(PathAllowlist.normalize("//a//b")).isEmpty();
    }
}
