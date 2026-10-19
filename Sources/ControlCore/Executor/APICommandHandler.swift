/// Platform work behind the official-API methods (`group.*`, `contact.*`,
/// `broadcast.*`). Returns the result JSON; throws `ControlError` for
/// protocol-level failures. Implemented by `WeComAPI`; faked in tests. These
/// methods never touch the desktop client, so the pause reason set does not
/// gate them (`broadcast.confirm` delegates its single AXPress to the adapter
/// and is policy-gated there).
public protocol APICommandHandler {
    func handleAPI(method: RPCMethod, paramsJSON: String) throws -> String
}

/// `broadcast.confirm` is the desktop exception to the API route. Its implementation
/// brackets the actual AX send button with the executor's durable checkpoint hooks.
public protocol CheckpointedBroadcastConfirmHandler: APICommandHandler {
    func broadcastConfirm(paramsJSON: String, checkpoint: () throws -> Void,
                          afterSubmit: () throws -> Void) throws -> String
}
