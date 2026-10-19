package com.kellen.wecomproxy;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Token-injecting proxy for imctl: holds the WeCom corp secret, injects
 * access_token into allowlisted forwarded calls, and relays WeCom callbacks to
 * MQTT. It carries no business logic and never logs request or callback bodies.
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class WeComTokenProxyApplication {

    public static void main(String[] args) {
        SpringApplication.run(WeComTokenProxyApplication.class, args);
    }
}
