package com.kellen.wecomproxy.token;

import java.time.Clock;
import java.time.Instant;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.kellen.wecomproxy.config.WeComProperties;
import com.kellen.wecomproxy.util.JsonMini;

/**
 * Caches the corp access_token and refreshes it 5 minutes before expiry or on
 * demand (invalid/expired token answers from WeCom). Single-flight: concurrent
 * callers share one refresh. The token value itself is never logged.
 */
public class AccessTokenService {

    private static final Logger log = LoggerFactory.getLogger(AccessTokenService.class);
    private static final long EARLY_REFRESH_SECONDS = 300;

    private final WeComHttp http;
    private final WeComProperties props;
    private final Clock clock;
    private String token;
    private Instant expiresAt = Instant.EPOCH;

    public AccessTokenService(WeComHttp http, WeComProperties props, Clock clock) {
        this.http = http;
        this.props = props;
        this.clock = clock;
    }

    public synchronized boolean cached() {
        return token != null && clock.instant().isBefore(expiresAt);
    }

    public synchronized String current() {
        if (!cached()) {
            refresh();
        }
        return token;
    }

    /** Forces a new token; called after WeCom reports 40014/42001 on a forwarded call. */
    public synchronized String refresh() {
        WeComHttp.Response r = http.getToken(props.corpId(), props.corpSecret());
        if (r.status() < 200 || r.status() >= 300) {
            throw new TokenUnavailableException("gettoken HTTP " + r.status());
        }
        Integer errcode = JsonMini.intField(r.body(), "errcode");
        if (errcode != null && errcode != 0) {
            throw new TokenUnavailableException("gettoken errcode " + errcode + ": " + JsonMini.field(r.body(), "errmsg"));
        }
        String value = JsonMini.field(r.body(), "access_token");
        Integer expiresIn = JsonMini.intField(r.body(), "expires_in");
        if (value == null || value.isBlank()) {
            throw new TokenUnavailableException("gettoken returned no access_token");
        }
        token = value;
        long ttl = Math.max(60, (expiresIn == null ? 7200 : expiresIn) - EARLY_REFRESH_SECONDS);
        expiresAt = clock.instant().plusSeconds(ttl);
        log.info("access_token refreshed; valid for {} s", ttl);
        return token;
    }

    public static class TokenUnavailableException extends RuntimeException {
        public TokenUnavailableException(String message) {
            super(message);
        }
    }
}
