import Foundation
import Testing
@testable import ControlCore
@testable import MCPTransport

@Suite("MCP handshake probe")
struct MCPHandshakeProbeTests {
    static let good = """
    {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"imctl","version":"x"}}}
    {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"controller.describe"},{"name":"controller.readiness"}]}}
    """

    func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-mcp-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func verifyNeedsTheServerNameAndTheReadinessTool() {
        #expect(MCPHandshakeProbe.verify(Self.good))
        #expect(!MCPHandshakeProbe.verify(Self.good.replacingOccurrences(of: "controller.readiness", with: "controller.other")))
        #expect(!MCPHandshakeProbe.verify(Self.good.replacingOccurrences(of: "\"imctl\"", with: "\"other\"")))
        #expect(!MCPHandshakeProbe.verify(""))
    }

    @Test func aWorkingServerPasses() throws {
        let url = try script("cat >/dev/null\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"serverInfo\":{\"name\":\"imctl\"}}}' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"controller.readiness\"}]}}'")
        #expect(MCPHandshakeProbe.run(executable: url, timeout: 5).ok)
    }

    /// A child that exits before reading must not take the daemon down with SIGPIPE.
    @Test func writingToAClosedPipeThrowsInsteadOfKillingTheProcess() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        #expect(throws: (any Error).self) { try MCPHandshakeProbe.writeRequests(to: pipe.fileHandleForWriting) }
    }

    @Test func aServerThatExitsAtOnceFailsCleanly() throws {
        #expect(!MCPHandshakeProbe.run(executable: try script("exit 0"), timeout: 2).ok)
    }

    @Test func failuresAreCategorised() throws {
        #expect(MCPHandshakeProbe.run(executable: URL(fileURLWithPath: "/nonexistent/imctl"), timeout: 1).category == "launch")
        #expect(MCPHandshakeProbe.run(executable: try script("cat"), timeout: 5).category == "protocol")
        #expect(MCPHandshakeProbe.run(executable: try script("sleep 5"), timeout: 0.5).category == "timeout")
    }
}
