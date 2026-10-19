package com.kellen.imctlconsumer.core;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/** The command channel to one controller (im/{controller_id}/cmd → rsp). Returns the JSON-RPC `result`; throws on JSON-RPC error/timeout. */
public interface Commands {

    JsonNode call(String controllerId, String method, ObjectNode params);
}
