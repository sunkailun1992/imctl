package com.kellen.wecomproxy.config;

import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

import org.springframework.boot.context.properties.ConfigurationProperties;

/** Proxy-side policy: which controllers may call (bearer tokens), which interfaces they may reach, how fast. */
@ConfigurationProperties(prefix = "proxy")
public record ProxyProperties(String bearerTokens, String allowedPaths, int rateLimitPerMinute, String dataDir) {

    /** The 16 interfaces imctl uses plus media upload; see docs/protocol/wecom-token-proxy.md. */
    public static final List<String> DEFAULT_ALLOWED_PATHS = List.of(
            "externalcontact/groupchat/list", "externalcontact/groupchat/get",
            "externalcontact/groupchat/add_join_way", "externalcontact/groupchat/get_join_way",
            "externalcontact/groupchat/update_join_way", "externalcontact/groupchat/del_join_way",
            "externalcontact/add_contact_way", "externalcontact/list_contact_way", "externalcontact/get_contact_way",
            "externalcontact/update_contact_way", "externalcontact/del_contact_way", "externalcontact/send_welcome_msg",
            "externalcontact/remark", "externalcontact/add_msg_template", "externalcontact/get_groupmsg_task",
            "externalcontact/get_groupmsg_send_result", "media/upload");

    public Set<String> tokenSet() {
        return split(bearerTokens);
    }

    public Set<String> allowedPathSet() {
        Set<String> configured = split(allowedPaths);
        return configured.isEmpty() ? Set.copyOf(DEFAULT_ALLOWED_PATHS) : configured;
    }

    public int effectiveRateLimit() {
        return rateLimitPerMinute > 0 ? rateLimitPerMinute : 120;
    }

    private static Set<String> split(String csv) {
        if (csv == null || csv.isBlank()) {
            return Set.of();
        }
        return Arrays.stream(csv.split(",")).map(String::trim).filter(s -> !s.isEmpty()).collect(Collectors.toUnmodifiableSet());
    }
}
