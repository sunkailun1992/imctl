package com.kellen.imctlconsumer.mqtt;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.CommandLineRunner;
import org.springframework.stereotype.Component;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.hivemq.client.mqtt.datatypes.MqttQos;
import com.hivemq.client.mqtt.mqtt5.Mqtt5AsyncClient;
import com.hivemq.client.mqtt.mqtt5.Mqtt5Client;
import com.hivemq.client.mqtt.mqtt5.Mqtt5ClientBuilder;
import com.kellen.imctlconsumer.ConsumerProperties;
import com.kellen.imctlconsumer.core.Consumer;
import com.kellen.imctlconsumer.core.EventStore;
import com.kellen.imctlconsumer.policy.EchoReplyPolicy;
import com.kellen.imctlconsumer.policy.OpenAiCompatibleReplyPolicy;
import com.kellen.imctlconsumer.policy.ReplyPolicy;

/** Connects, shares the event subscription with the other instances, and feeds the consumer. Skipped when IMCTL_MQTT_URL is empty. */
@Component
public class MqttRunner implements CommandLineRunner {

    private static final Logger log = LoggerFactory.getLogger(MqttRunner.class);
    private final ConsumerProperties props;
    private final ObjectMapper mapper = new ObjectMapper();

    public MqttRunner(ConsumerProperties props) {
        this.props = props;
    }

    @Override
    public void run(String... args) throws Exception {
        if (props.mqttUrl() == null || props.mqttUrl().isBlank()) {
            log.warn("IMCTL_MQTT_URL not set: consumer idle (unit tests and offline review only)");
            return;
        }
        URI uri = URI.create(props.mqttUrl());
        boolean tls = "mqtts".equals(uri.getScheme());
        Mqtt5ClientBuilder builder = Mqtt5Client.builder().identifier(props.instance())
                .serverHost(uri.getHost()).serverPort(uri.getPort() > 0 ? uri.getPort() : (tls ? 8883 : 1883)).automaticReconnectWithDefaultConfig();
        if (tls) {
            builder = builder.sslWithDefaultConfig();
        }
        if (props.mqttUsername() != null && !props.mqttUsername().isBlank()) {
            builder = builder.simpleAuth().username(props.mqttUsername())
                    .password((props.mqttPassword() == null ? "" : props.mqttPassword()).getBytes(StandardCharsets.UTF_8)).applySimpleAuth();
        }
        Mqtt5AsyncClient client = builder.buildAsync();
        client.connectWith().cleanStart(false).sessionExpiryInterval(86400).send().get();
        MqttCommands commands = new MqttCommands(client, props.instance(), mapper, 15);
        ReplyPolicy policy = props.aiBaseUrl() == null || props.aiBaseUrl().isBlank()
                ? new EchoReplyPolicy("[imctl consumer] 收到：")
                : new OpenAiCompatibleReplyPolicy(props.aiBaseUrl(), props.aiApiKey(), props.aiModel(),
                        "你是企业微信客服助手，用一两句中文简短回答；不确定就说会转人工。");
        Consumer.Settings settings = new Consumer.Settings(props.welcomeStateSet(), props.groupAllowlistSet(), props.customerAllowlistSet(),
                props.joinWayUrl(), props.staffUserid(), Duration.ofMinutes(Math.max(1, props.silenceMinutes())), Math.max(1, props.historyLimit()));
        Consumer consumer = new Consumer(commands, new EventStore.Memory(), policy, settings, Clock.systemUTC(), mapper);

        String evtFilter = "$share/" + props.sharedGroup() + "/im/+/evt";
        client.subscribeWith().topicFilter(evtFilter).qos(MqttQos.AT_LEAST_ONCE).callback(publish -> {
            try {
                JsonNode event = mapper.readTree(StandardCharsets.UTF_8.decode(publish.getPayload().orElseThrow()).toString());
                String controllerId = event.path("controllerId").asText();
                commands.listen(controllerId);
                consumer.onControllerEvent(event);
            } catch (Exception e) {
                log.warn("event handling failed: {}", e.toString());
            }
        }).send().get();
        client.subscribeWith().topicFilter("im/+/state").qos(MqttQos.AT_LEAST_ONCE).callback(publish -> {
            try {
                String controllerId = publish.getTopic().toString().split("/")[1];
                commands.listen(controllerId);
                consumer.onControllerState(controllerId, mapper.readTree(StandardCharsets.UTF_8.decode(publish.getPayload().orElseThrow()).toString()));
            } catch (Exception e) {
                log.warn("state handling failed: {}", e.toString());
            }
        }).send().get();
        client.subscribeWith().topicFilter("$share/" + props.sharedGroup() + "/wecom/+/evt").qos(MqttQos.AT_LEAST_ONCE).callback(publish -> {
            try {
                JsonNode event = mapper.readTree(StandardCharsets.UTF_8.decode(publish.getPayload().orElseThrow()).toString());
                // API-route commands can go to any enrolled controller; the first one seen is used.
                String controllerId = commands.anyController();
                if (controllerId != null) {
                    consumer.onCallbackEvent(controllerId, event);
                }
            } catch (Exception e) {
                log.warn("callback handling failed: {}", e.toString());
            }
        }).send().get();
        log.info("consumer {} online: {} and wecom/+/evt", props.instance(), evtFilter);
    }
}
