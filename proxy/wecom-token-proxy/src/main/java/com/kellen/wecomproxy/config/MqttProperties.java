package com.kellen.wecomproxy.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/** Broker for callback events (`{topicPrefix}/{corpId}/evt`); an empty url disables publishing (events are only logged). */
@ConfigurationProperties(prefix = "mqtt")
public record MqttProperties(String url, String username, String password, String clientId, String topicPrefix) {

    public MqttProperties {
        if (clientId == null || clientId.isBlank()) {
            clientId = "wecom-token-proxy";
        }
        if (topicPrefix == null || topicPrefix.isBlank()) {
            topicPrefix = "wecom";
        }
    }

    public boolean enabled() {
        return url != null && !url.isBlank();
    }
}
