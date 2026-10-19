package com.kellen.wecomproxy.event;

import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/** Used when no MQTT_URL is configured: events are visible in the log (topic and event id only) and otherwise dropped. */
public class LoggingEventPublisher implements EventPublisher {

    private static final Logger log = LoggerFactory.getLogger(LoggingEventPublisher.class);

    @Override
    public void publish(String topic, byte[] payload, Map<String, String> userProperties) {
        log.warn("MQTT not configured; dropping callback event topic={} event_id={} bytes={}", topic, userProperties.get("event_id"), payload.length);
    }
}
