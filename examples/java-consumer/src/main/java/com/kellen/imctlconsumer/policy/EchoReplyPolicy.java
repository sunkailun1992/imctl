package com.kellen.imctlconsumer.policy;

import java.util.Optional;

/** Default when no AI endpoint is configured: acknowledges with a fixed prefix so the loop can be proven without a model. */
public class EchoReplyPolicy implements ReplyPolicy {

    private final String prefix;

    public EchoReplyPolicy(String prefix) {
        this.prefix = prefix;
    }

    @Override
    public Optional<String> reply(Context context) {
        if (context.incomingText() == null || context.incomingText().isBlank()) {
            return Optional.empty();
        }
        return Optional.of(prefix + context.incomingText());
    }
}
