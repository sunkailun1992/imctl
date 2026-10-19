import ArgumentParser
import ControlCore
import Foundation
import MCPTransport

struct CallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "call",
        abstract: "Send one JSON-RPC request to the local imctld socket (the same path the console uses) and print the result."
    )

    @Argument(help: "Protocol method, e.g. conversation.list, client.navigate, event.replay") var method: String
    @Option(help: "JSON object with params.") var params: String = "{}"
    @Option(help: "Unix socket served by `imctld run --socket`.") var socket: String = IMCTLPaths.socket.path
    @Option(help: "Seconds to wait for the response.") var timeout: Double = 30

    func run() throws {
        guard let object = try JSONValue.parse(params).objectValue else { throw ValidationError("--params must be a JSON object") }
        do {
            let result = try UnixSocketClient(path: socket, timeout: timeout).call(method, params: object)
            let data = try JSONSerialization.data(withJSONObject: result.any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            print(String(decoding: data, as: UTF8.self))
        } catch let e as UnixSocketClient.RPCError {
            FileHandle.standardError.write(Data("\(e)\n".utf8))
            throw ExitCode(1)
        } catch let e as UnixSocketClient.TransportError {
            throw ValidationError("\(e) (is imctld running with --socket \(socket)?)")
        }
    }
}
