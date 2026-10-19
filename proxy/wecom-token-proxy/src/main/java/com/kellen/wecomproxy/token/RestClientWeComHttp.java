package com.kellen.wecomproxy.token;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

import org.springframework.http.MediaType;
import org.springframework.web.client.RestClient;

import com.kellen.wecomproxy.config.WeComProperties;

/** RestClient-backed WeCom HTTP; status codes are passed through, never thrown. */
public class RestClientWeComHttp implements WeComHttp {

    private final RestClient client;
    private final String apiBase;

    public RestClientWeComHttp(WeComProperties props) {
        this.apiBase = props.apiBase();
        this.client = RestClient.builder().baseUrl(apiBase).build();
    }

    @Override
    public Response getToken(String corpId, String corpSecret) {
        String url = apiBase + "/gettoken?corpid=" + enc(corpId) + "&corpsecret=" + enc(corpSecret);
        return client.get().uri(url).exchange((req, res) -> new Response(res.getStatusCode().value(), new String(res.getBody().readAllBytes(), StandardCharsets.UTF_8)));
    }

    @Override
    public Response post(String path, String accessToken, byte[] body, String contentType) {
        String url = apiBase + "/" + path + "?access_token=" + enc(accessToken);
        MediaType type = contentType == null ? MediaType.APPLICATION_JSON : MediaType.parseMediaType(contentType);
        return client.post().uri(url).contentType(type).body(body)
                .exchange((req, res) -> new Response(res.getStatusCode().value(), new String(res.getBody().readAllBytes(), StandardCharsets.UTF_8)));
    }

    private static String enc(String s) {
        return URLEncoder.encode(s == null ? "" : s, StandardCharsets.UTF_8);
    }
}
