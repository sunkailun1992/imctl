package com.kellen.imctlconsumer.policy;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Optional;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * Calls an OpenAI-compatible `chat/completions` endpoint (Qwen, DeepSeek,
 * OpenAI …). The system prompt is deliberately short: the consumer, not the
 * model, decides whether to answer at all; the model only writes text.
 */
public class OpenAiCompatibleReplyPolicy implements ReplyPolicy {

    private final String baseUrl;
    private final String apiKey;
    private final String model;
    private final String systemPrompt;
    private final ObjectMapper mapper = new ObjectMapper();
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();

    public OpenAiCompatibleReplyPolicy(String baseUrl, String apiKey, String model, String systemPrompt) {
        this.baseUrl = baseUrl.endsWith("/") ? baseUrl.substring(0, baseUrl.length() - 1) : baseUrl;
        this.apiKey = apiKey;
        this.model = model;
        this.systemPrompt = systemPrompt;
    }

    @Override
    public Optional<String> reply(Context context) {
        try {
            ObjectNode body = mapper.createObjectNode().put("model", model);
            ArrayNode messages = body.putArray("messages");
            messages.addObject().put("role", "system").put("content", systemPrompt);
            for (Turn t : context.history()) {
                String role = "outbound".equals(t.direction()) ? "assistant" : "user";
                String text = t.sender() == null || t.sender().isBlank() ? t.text() : t.sender() + ": " + t.text();
                messages.addObject().put("role", role).put("content", text);
            }
            HttpRequest request = HttpRequest.newBuilder(URI.create(baseUrl + "/chat/completions"))
                    .timeout(Duration.ofSeconds(30)).header("Content-Type", "application/json").header("Authorization", "Bearer " + apiKey)
                    .POST(HttpRequest.BodyPublishers.ofString(mapper.writeValueAsString(body))).build();
            HttpResponse<String> response = http.send(request, HttpResponse.BodyHandlers.ofString());
            if (response.statusCode() / 100 != 2) {
                return Optional.empty();
            }
            JsonNode content = mapper.readTree(response.body()).path("choices").path(0).path("message").path("content");
            return content.isTextual() && !content.asText().isBlank() ? Optional.of(content.asText().strip()) : Optional.empty();
        } catch (Exception e) {
            return Optional.empty();
        }
    }
}
