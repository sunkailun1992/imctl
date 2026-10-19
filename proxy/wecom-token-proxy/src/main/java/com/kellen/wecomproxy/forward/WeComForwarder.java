package com.kellen.wecomproxy.forward;

import java.util.Set;

import com.kellen.wecomproxy.token.AccessTokenService;
import com.kellen.wecomproxy.token.WeComHttp;
import com.kellen.wecomproxy.util.JsonMini;

/**
 * Forwards one allowlisted call with the cached token injected. When WeCom
 * answers with an invalid/expired-token errcode the token is refreshed and the
 * call retried exactly once; every other answer is returned untouched so imctl
 * sees the platform's own errcode/errmsg.
 */
public class WeComForwarder {

    /** 40014 invalid access_token, 42001 access_token expired, 40001 invalid credential. */
    private static final Set<Integer> TOKEN_ERRORS = Set.of(40014, 42001, 40001);

    private final WeComHttp http;
    private final AccessTokenService tokens;

    public WeComForwarder(WeComHttp http, AccessTokenService tokens) {
        this.http = http;
        this.tokens = tokens;
    }

    public WeComHttp.Response forward(String path, byte[] body, String contentType) {
        WeComHttp.Response r = http.post(path, tokens.current(), body, contentType);
        Integer errcode = r.status() == 200 ? JsonMini.intField(r.body(), "errcode") : null;
        if (errcode != null && TOKEN_ERRORS.contains(errcode)) {
            r = http.post(path, tokens.refresh(), body, contentType);
        }
        return r;
    }
}
