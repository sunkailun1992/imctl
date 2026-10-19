package com.kellen.imctlconsumer.mqtt;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.hivemq.client.mqtt.datatypes.MqttQos;
import com.hivemq.client.mqtt.mqtt5.Mqtt5AsyncClient;
import com.kellen.imctlconsumer.core.Commands;

/** JSON-RPC over MQTT 5: Response Topic `im/{id}/rsp/{instance}`, Correlation Data = request id. */
public class MqttCommands implements Commands {

    private final Mqtt5AsyncClient client;
    private final String instance;
    private final ObjectMapper mapper;
    private final Map<String, CompletableFuture<JsonNode>> pending = new ConcurrentHashMap<>();
    private final long timeoutSeconds;
    private final Map<String, Boolean> controllers = new ConcurrentHashMap<>();

    public MqttCommands(Mqtt5AsyncClient client, String instance, ObjectMapper mapper, long timeoutSeconds) {
        this.client = client;
        this.instance = instance;
        this.mapper = mapper;
        this.timeoutSeconds = timeoutSeconds;
    }

    public String replyTopic(String controllerId) {
        return "im/" + controllerId + "/rsp/" + instance;
    }

    /** Subscribe once per controller so responses can be matched. */
    public void listen(String controllerId) {
        if (controllers.putIfAbsent(controllerId, Boolean.TRUE) != null) {
            return;
        }
        // Wait for the SUBACK: a command published before the broker routes the reply topic to us would lose its response.
        CompletableFuture<?> subscribed = client.subscribeWith().topicFilter(replyTopic(controllerId)).qos(MqttQos.AT_LEAST_ONCE).callback(publish -> {
            String corr = publish.getCorrelationData().map(buf -> StandardCharsets.UTF_8.decode(buf).toString()).orElse("");
            CompletableFuture<JsonNode> f = pending.remove(corr);
            if (f != null) {
                try {
                    f.complete(mapper.readTree(StandardCharsets.UTF_8.decode(publish.getPayload().orElseThrow()).toString()));
                } catch (Exception e) {
                    f.completeExceptionally(e);
                }
            }
        }).send();
        try {
            subscribed.get(timeoutSeconds, TimeUnit.SECONDS);
        } catch (Exception e) {
            controllers.remove(controllerId);
            throw new IllegalStateException("subscribe to " + replyTopic(controllerId) + " failed: " + e, e);
        }
    }

    /** Any controller whose responses we listen to; API-route commands (welcome, group.get) are controller-agnostic. */
    public String anyController() {
        return controllers.keySet().stream().findFirst().orElse(null);
    }

    @Override
    public JsonNode call(String controllerId, String method, ObjectNode params) {
        String id = UUID.randomUUID().toString();
        ObjectNode request = mapper.createObjectNode().put("jsonrpc", "2.0").put("id", id).put("method", method);
        request.set("params", params);
        CompletableFuture<JsonNode> future = new CompletableFuture<>();
        pending.put(id, future);
        try {
            client.publishWith().topic("im/" + controllerId + "/cmd").qos(MqttQos.AT_LEAST_ONCE)
                    .responseTopic(replyTopic(controllerId)).correlationData(id.getBytes(StandardCharsets.UTF_8))
                    .payload(mapper.writeValueAsBytes(request)).send();
            JsonNode response = future.get(timeoutSeconds, TimeUnit.SECONDS);
            if (response.has("error")) {
                throw new IllegalStateException("json-rpc error " + response.path("error").toString());
            }
            return response.path("result");
        } catch (IllegalStateException e) {
            throw e;
        } catch (Exception e) {
            throw new IllegalStateException("command " + method + " failed: " + e, e);
        } finally {
            pending.remove(id);
        }
    }
}
