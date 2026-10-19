import Foundation

/// Anything that answers one newline-delimited JSON-RPC line: the daemon's
/// own dispatcher, or the `imctl mcp serve` bridge that forwards to it.
public protocol LineHandler: AnyObject {
    func handle(line: String) -> String?
}

/// Reads newline-delimited requests from stdin, writes responses to stdout.
/// Blocks the calling thread; run it on a background thread when the main
/// thread must keep a run loop alive.
public final class StdioServer {
    public let handler: LineHandler
    public var log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    public init(dispatcher: RPCDispatcher) { self.handler = dispatcher }
    public init(handler: LineHandler) { self.handler = handler }

    public func serve() {
        while let line = readLine(strippingNewline: true) {
            if let response = handler.handle(line: line) {
                FileHandle.standardOutput.write(Data((response + "\n").utf8))
            }
        }
        log("stdio: input closed")
    }
}
