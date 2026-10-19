package com.kellen.wecomproxy.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/** WeCom self-built app parameters; all secrets arrive through environment variables. */
@ConfigurationProperties(prefix = "wecom")
public record WeComProperties(String corpId, String corpSecret, long agentId, String callbackToken, String callbackAesKey,
                              String apiBase) {

    public WeComProperties {
        if (apiBase == null || apiBase.isBlank()) {
            apiBase = "https://qyapi.weixin.qq.com/cgi-bin";
        }
        apiBase = apiBase.endsWith("/") ? apiBase.substring(0, apiBase.length() - 1) : apiBase;
    }
}
