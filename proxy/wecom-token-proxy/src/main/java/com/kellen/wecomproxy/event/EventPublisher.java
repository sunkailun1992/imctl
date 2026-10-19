package com.kellen.wecomproxy.event;

import java.util.Map;

/** Publishes one callback event (QoS 1) with MQTT 5 user properties; throws when it cannot, so the callback is not acknowledged. */
public interface EventPublisher {

    void publish(String topic, byte[] payload, Map<String, String> userProperties);
}
