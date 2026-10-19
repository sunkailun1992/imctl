package com.kellen.imctlconsumer.policy;

import java.util.List;
import java.util.Optional;

/** Decides the reply text for a conversation; the only place an AI model enters the loop. */
public interface ReplyPolicy {

    record Turn(String direction, String sender, String text) {
    }

    record Context(String controllerId, String conversationTitle, String conversationType, String chatId, String externalUserId,
                   String incomingSender, String incomingText, List<Turn> history) {
    }

    /** Empty = stay silent. */
    Optional<String> reply(Context context);
}
