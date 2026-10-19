package com.kellen.wecomproxy.callback;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.kellen.wecomproxy.crypto.WeComCrypto;
import com.kellen.wecomproxy.event.EventPublisher;
import com.kellen.wecomproxy.event.EventSequence;
import com.kellen.wecomproxy.util.JsonMini;

/**
 * Turns a verified, decrypted callback into one MQTT event on
 * `{prefix}/{corpId}/evt` (docs/protocol/im-control-protocol.md §9). The
 * publish happens before the callback is acknowledged, so WeCom retries
 * when the broker is down instead of the event being lost.
 */
public class CallbackRelay {

    private static final Logger audit = LoggerFactory.getLogger("proxy.audit");
    private final WeComCrypto crypto;
    private final EventSequence sequence;
    private final EventPublisher publisher;
    private final String corpId;
    private final String topicPrefix;

    public CallbackRelay(WeComCrypto crypto, EventSequence sequence, EventPublisher publisher, String corpId, String topicPrefix) {
        this.crypto = crypto;
        this.sequence = sequence;
        this.publisher = publisher;
        this.corpId = corpId;
        this.topicPrefix = topicPrefix;
    }

    public String topic() {
        return topicPrefix + "/" + corpId + "/evt";
    }

    /** GET verification: returns the decrypted echostr, or null when the signature does not match. */
    public String verify(String msgSignature, String timestamp, String nonce, String echostr) {
        if (!crypto.verify(msgSignature, timestamp, nonce, echostr)) {
            return null;
        }
        return crypto.decrypt(echostr);
    }

    /** POST: verify + decrypt + flatten + publish. Returns the event id; throws on signature failure or publish failure. */
    public long relay(String msgSignature, String timestamp, String nonce, String encryptedXml) throws IOException {
        Map<String, String> outer = XmlFlattener.flatten(encryptedXml);
        String encrypted = outer.get("Encrypt");
        if (encrypted == null || !crypto.verify(msgSignature, timestamp, nonce, encrypted)) {
            throw new SecurityException("bad signature");
        }
        Map<String, String> fields = XmlFlattener.flatten(crypto.decrypt(encrypted));
        long eventId = sequence.next();
        long tsMs = System.currentTimeMillis();
        String payload = "{\"eventId\":" + eventId + ",\"tsMs\":" + tsMs + ",\"kind\":\"wecom.callback\",\"corpId\":" + JsonMini.quote(corpId)
                + ",\"payload\":" + JsonMini.object(fields) + "}";
        Map<String, String> props = new LinkedHashMap<>();
        props.put("event_id", Long.toString(eventId));
        props.put("kind", "wecom.callback");
        props.put("corp_id", corpId);
        publisher.publish(topic(), payload.getBytes(StandardCharsets.UTF_8), props);
        audit.info("callback relayed event_id={} event={} change={}", eventId, fields.get("Event"), fields.get("ChangeType"));
        return eventId;
    }
}
