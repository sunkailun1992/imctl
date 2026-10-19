package com.kellen.wecomproxy;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;

import com.kellen.wecomproxy.token.WeComHttp;

/** Scriptable WeCom; records every call (path, token, body) for assertions. */
public class FakeWeComHttp implements WeComHttp {

    public record Call(String path, String token, String body) {
    }

    public final List<Call> calls = new ArrayList<>();
    public int tokenCalls = 0;
    public String tokenBody = "{\"errcode\":0,\"errmsg\":\"ok\",\"access_token\":\"T1\",\"expires_in\":7200}";
    public Function<Call, Response> answer = c -> new Response(200, "{\"errcode\":0,\"errmsg\":\"ok\"}");

    @Override
    public Response getToken(String corpId, String corpSecret) {
        tokenCalls++;
        return new Response(200, tokenBody.replace("T1", "T" + tokenCalls));
    }

    @Override
    public Response post(String path, String accessToken, byte[] body, String contentType) {
        Call c = new Call(path, accessToken, new String(body, StandardCharsets.UTF_8));
        calls.add(c);
        return answer.apply(c);
    }
}
