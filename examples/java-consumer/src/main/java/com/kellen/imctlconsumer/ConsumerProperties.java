package com.kellen.imctlconsumer;

import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "consumer")
public record ConsumerProperties(String mqttUrl, String mqttUsername, String mqttPassword, String instance, String sharedGroup,
                                 String welcomeStates, String groupAllowlist, String customerAllowlist, String joinWayUrl,
                                 String staffUserid, int silenceMinutes, int historyLimit, String aiBaseUrl, String aiApiKey, String aiModel) {

    public Set<String> welcomeStateSet() {
        return split(welcomeStates);
    }

    public Set<String> groupAllowlistSet() {
        return split(groupAllowlist);
    }

    public Set<String> customerAllowlistSet() {
        return split(customerAllowlist);
    }

    static Set<String> split(String csv) {
        if (csv == null || csv.isBlank()) {
            return Set.of();
        }
        return Arrays.stream(csv.split(",")).map(String::trim).filter(s -> !s.isEmpty()).collect(Collectors.toUnmodifiableSet());
    }
}
