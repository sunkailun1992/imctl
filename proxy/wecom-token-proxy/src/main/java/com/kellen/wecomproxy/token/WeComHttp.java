package com.kellen.wecomproxy.token;

/** The two HTTP calls the proxy makes to WeCom; faked in tests. */
public interface WeComHttp {

    record Response(int status, String body) {
    }

    /** GET {apiBase}/gettoken?corpid=&corpsecret= */
    Response getToken(String corpId, String corpSecret);

    /** POST {apiBase}/{path}?access_token= with a JSON body. */
    Response post(String path, String accessToken, byte[] body, String contentType);
}
