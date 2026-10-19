package com.kellen.wecomproxy.mqtt;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Map;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.hivemq.client.mqtt.datatypes.MqttQos;
import com.hivemq.client.mqtt.mqtt5.Mqtt5BlockingClient;
import com.hivemq.client.mqtt.mqtt5.Mqtt5Client;
import com.hivemq.client.mqtt.mqtt5.Mqtt5ClientBuilder;
import com.hivemq.client.mqtt.mqtt5.datatypes.Mqtt5UserProperties;
import com.hivemq.client.mqtt.mqtt5.datatypes.Mqtt5UserPropertiesBuilder;
import com.kellen.wecomproxy.config.MqttProperties;
import com.kellen.wecomproxy.event.EventPublisher;

/** MQTT 5 publisher: persistent session, QoS 1, user properties event_id/kind/corp_id. Reconnects automatically. */
public class HiveMqEventPublisher implements EventPublisher, AutoCloseable {

    private static final Logger log = LoggerFactory.getLogger(HiveMqEventPublisher.class);
    private final Mqtt5BlockingClient client;

    public HiveMqEventPublisher(MqttProperties props) {
        URI uri = URI.create(props.url());
        boolean tls = "mqtts".equals(uri.getScheme());
        Mqtt5ClientBuilder builder = Mqtt5Client.builder()
                .identifier(props.clientId())
                .serverHost(uri.getHost() == null ? "localhost" : uri.getHost())
                .serverPort(uri.getPort() > 0 ? uri.getPort() : (tls ? 8883 : 1883))
                .automaticReconnectWithDefaultConfig();
        if (tls) {
            builder = builder.sslWithDefaultConfig();
        }
        if (props.username() != null && !props.username().isBlank()) {
            builder = builder.simpleAuth().username(props.username())
                    .password((props.password() == null ? "" : props.password()).getBytes(StandardCharsets.UTF_8)).applySimpleAuth();
        }
        this.client = builder.buildBlocking();
        client.connectWith().cleanStart(false).sessionExpiryInterval(86400).send();
        log.info("mqtt connected to {}:{} as {}", uri.getHost(), uri.getPort(), props.clientId());
    }

    @Override
    public void publish(String topic, byte[] payload, Map<String, String> userProperties) {
        Mqtt5UserPropertiesBuilder ups = Mqtt5UserProperties.builder();
        userProperties.forEach(ups::add);
        client.publishWith().topic(topic).qos(MqttQos.AT_LEAST_ONCE).payload(payload).userProperties(ups.build()).send();
    }

    @Override
    public void close() {
        client.disconnect();
    }
}
