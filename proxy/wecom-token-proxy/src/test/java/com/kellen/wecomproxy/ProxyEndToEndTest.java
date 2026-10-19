package com.kellen.wecomproxy;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.context.annotation.Primary;
import org.springframework.core.env.Environment;

import com.kellen.wecomproxy.crypto.WeComCrypto;
import com.kellen.wecomproxy.event.EventPublisher;
import com.kellen.wecomproxy.token.WeComHttp;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = {
        "wecom.corp-id=wwcorp", "wecom.corp-secret=secret", "wecom.callback-token=tok",
        "wecom.callback-aes-key=" + ProxyEndToEndTest.AES_KEY, "proxy.bearer-tokens=controller-token-1,controller-token-2",
        "proxy.rate-limit-per-minute=100", "proxy.data-dir=target/test-data", "mqtt.url="})
@Import(ProxyEndToEndTest.Fakes.class)
class ProxyEndToEndTest {

    static final String AES_KEY = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ";

    @TestConfiguration
    static class Fakes {
        @Bean
        @Primary
        FakeWeComHttp fakeWeComHttp() {
            return new FakeWeComHttp();
        }

        @Bean
        @Primary
        RecordingPublisher recordingPublisher() {
            return new RecordingPublisher();
        }
    }

    static class RecordingPublisher implements EventPublisher {
        final List<String> topics = new ArrayList<>();
        final List<String> payloads = new ArrayList<>();

        @Override
        public void publish(String topic, byte[] payload, Map<String, String> userProperties) {
            topics.add(topic);
            payloads.add(new String(payload, StandardCharsets.UTF_8));
        }
    }

    @Autowired Environment env;
    @Autowired FakeWeComHttp fake;
    @Autowired RecordingPublisher published;
    @Autowired WeComHttp weComHttp;

    private final HttpClient http = HttpClient.newHttpClient();

    private String base() {
        return "http://localhost:" + env.getProperty("local.server.port");
    }

    private HttpResponse<String> post(String path, String bearer, String body) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(base() + path)).header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body));
        if (bearer != null) {
            b.header("Authorization", "Bearer " + bearer);
        }
        return http.send(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    @Test
    void bearerAllowlistTokenInjectionAndHealth() throws Exception {
        assertThat(weComHttp).isSameAs(fake);
        assertThat(post("/wecom/externalcontact/groupchat/list", null, "{}").statusCode()).isEqualTo(401);
        assertThat(post("/wecom/externalcontact/groupchat/list", "wrong", "{}").statusCode()).isEqualTo(401);
        assertThat(post("/wecom/user/get", "controller-token-1", "{}").statusCode()).isEqualTo(404);
        fake.answer = c -> new WeComHttp.Response(200, "{\"errcode\":0,\"errmsg\":\"ok\",\"group_chat_list\":[]}");
        HttpResponse<String> ok = post("/wecom/externalcontact/groupchat/list", "controller-token-1", "{\"limit\":10}");
        assertThat(ok.statusCode()).isEqualTo(200);
        assertThat(ok.body()).contains("group_chat_list");
        assertThat(fake.calls).hasSize(1);
        assertThat(fake.calls.get(0).path()).isEqualTo("externalcontact/groupchat/list");
        assertThat(fake.calls.get(0).token()).isEqualTo("T1");
        assertThat(fake.calls.get(0).body()).isEqualTo("{\"limit\":10}");
        HttpResponse<String> health = http.send(HttpRequest.newBuilder(URI.create(base() + "/healthz")).GET().build(), HttpResponse.BodyHandlers.ofString());
        assertThat(health.statusCode()).isEqualTo(200);
        assertThat(health.body()).contains("\"tokenCached\":true").contains("\"corpId\":\"wwcorp\"").doesNotContain("secret");
    }

    @Test
    void callbackEndpointsVerifyRelayAndAcknowledge() throws Exception {
        WeComCrypto crypto = new WeComCrypto("tok", AES_KEY, "wwcorp");
        String echo = crypto.encrypt("echo-plain");
        String sig = crypto.signature("1", "n", echo);
        String url = base() + "/wecom/callback?msg_signature=" + sig + "&timestamp=1&nonce=n&echostr=" + java.net.URLEncoder.encode(echo, StandardCharsets.UTF_8);
        HttpResponse<String> verify = http.send(HttpRequest.newBuilder(URI.create(url)).GET().build(), HttpResponse.BodyHandlers.ofString());
        assertThat(verify.statusCode()).isEqualTo(200);
        assertThat(verify.body()).isEqualTo("echo-plain");
        String badUrl = base() + "/wecom/callback?msg_signature=bad&timestamp=1&nonce=n&echostr=" + java.net.URLEncoder.encode(echo, StandardCharsets.UTF_8);
        assertThat(http.send(HttpRequest.newBuilder(URI.create(badUrl)).GET().build(), HttpResponse.BodyHandlers.ofString()).statusCode()).isEqualTo(403);

        String inner = "<xml><ToUserName><![CDATA[wwcorp]]></ToUserName><Event><![CDATA[change_external_chat]]></Event><ChangeType><![CDATA[create]]></ChangeType><ChatId><![CDATA[wr1]]></ChatId></xml>";
        String encrypted = crypto.encrypt(inner);
        String outer = "<xml><ToUserName><![CDATA[wwcorp]]></ToUserName><Encrypt><![CDATA[" + encrypted + "]]></Encrypt></xml>";
        String postUrl = base() + "/wecom/callback?msg_signature=" + crypto.signature("2", "n2", encrypted) + "&timestamp=2&nonce=n2";
        HttpResponse<String> relayed = http.send(HttpRequest.newBuilder(URI.create(postUrl)).header("Content-Type", "text/xml")
                .POST(HttpRequest.BodyPublishers.ofString(outer)).build(), HttpResponse.BodyHandlers.ofString());
        assertThat(relayed.statusCode()).isEqualTo(200);
        assertThat(relayed.body()).isEqualTo("success");
        assertThat(published.topics).containsExactly("wecom/wwcorp/evt");
        assertThat(published.payloads.get(0)).contains("\"ChatId\":\"wr1\"").contains("\"kind\":\"wecom.callback\"");
    }
}
