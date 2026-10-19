package com.kellen.imctlconsumer;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Reference consumer for docs/protocol/im-control-protocol.md: it only sends
 * commands and decides replies; it never touches WeCom APIs or the desktop
 * client. Business logic here is deliberately thin so it can be copied into
 * a real service.
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class ConsumerApplication {

    public static void main(String[] args) {
        SpringApplication.run(ConsumerApplication.class, args);
    }
}
