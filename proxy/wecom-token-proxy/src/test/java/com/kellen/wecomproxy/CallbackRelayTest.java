package com.kellen.wecomproxy;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.kellen.wecomproxy.callback.CallbackRelay;
import com.kellen.wecomproxy.callback.XmlFlattener;
import com.kellen.wecomproxy.crypto.WeComCrypto;
import com.kellen.wecomproxy.event.EventPublisher;
import com.kellen.wecomproxy.event.EventSequence;

class CallbackRelayTest {

    static class Recording implements EventPublisher {
        record Published(String topic, String payload, Map<String, String> props) {
        }
        final List<Published> items = new ArrayList<>();
        boolean fail = false;

        @Override
        public void publish(String topic, byte[] payload, Map<String, String> userProperties) {
            if (fail) {
                throw new IllegalStateException("broker down");
            }
            items.add(new Published(topic, new String(payload, StandardCharsets.UTF_8), userProperties));
        }
    }

    @Test
    void verifiedCallbackBecomesOneMqttEventWithPersistentId() throws Exception {
        String key = WeComCryptoTest.randomAesKey();
        WeComCrypto crypto = new WeComCrypto("tok", key, "wwcorp");
        Recording publisher = new Recording();
        CallbackRelay relay = new CallbackRelay(crypto, new EventSequence(Files.createTempDirectory("relay")), publisher, "wwcorp", "wecom");
        String inner = "<xml><ToUserName><![CDATA[wwcorp]]></ToUserName><FromUserName><![CDATA[sys]]></FromUserName><CreateTime>1789300000</CreateTime>"
                + "<MsgType><![CDATA[event]]></MsgType><Event><![CDATA[change_external_contact]]></Event><ChangeType><![CDATA[add_external_contact]]></ChangeType>"
                + "<UserID><![CDATA[u1]]></UserID><ExternalUserID><![CDATA[wm1]]></ExternalUserID><State><![CDATA[ch1]]></State><WelcomeCode><![CDATA[WC1]]></WelcomeCode></xml>";
        String encrypted = crypto.encrypt(inner);
        String outer = "<xml><ToUserName><![CDATA[wwcorp]]></ToUserName><Encrypt><![CDATA[" + encrypted + "]]></Encrypt><AgentID><![CDATA[1000002]]></AgentID></xml>";
        String sig = crypto.signature("1789300000", "n1", encrypted);
        long id = relay.relay(sig, "1789300000", "n1", outer);
        assertThat(id).isEqualTo(1);
        assertThat(publisher.items).hasSize(1);
        Recording.Published p = publisher.items.get(0);
        assertThat(p.topic()).isEqualTo("wecom/wwcorp/evt");
        assertThat(p.props()).containsEntry("event_id", "1").containsEntry("kind", "wecom.callback").containsEntry("corp_id", "wwcorp");
        assertThat(p.payload()).contains("\"eventId\":1").contains("\"kind\":\"wecom.callback\"").contains("\"WelcomeCode\":\"WC1\"").contains("\"State\":\"ch1\"");
        assertThatThrownBy(() -> relay.relay("deadbeef", "1789300000", "n1", outer)).isInstanceOf(SecurityException.class);
        publisher.fail = true;
        assertThatThrownBy(() -> relay.relay(sig, "1789300000", "n1", outer)).isInstanceOf(IllegalStateException.class);
        assertThat(relay.verify(crypto.signature("t", "n", encrypted), "t", "n", encrypted)).isEqualTo(inner);
        assertThat(relay.verify("bad", "t", "n", encrypted)).isNull();
    }

    @Test
    void xmlFlattenerRefusesDoctype() {
        assertThat(XmlFlattener.flatten("<xml><A>1</A><B><C>2</C></B></xml>")).containsEntry("A", "1").containsEntry("B.C", "2");
        assertThatThrownBy(() -> XmlFlattener.flatten("<!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><xml><A>&e;</A></xml>"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
