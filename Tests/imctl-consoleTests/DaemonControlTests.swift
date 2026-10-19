import Foundation
import Testing
@testable import ControlCore
@testable import imctl_console

@Suite("DaemonControl")
struct DaemonControlTests {
    @Test func installArgumentsFollowTheCLI() {
        #expect(DaemonControl.installArguments(mqttEnrolled: false, socket: "/s") == ["agent", "install", "--socket", "/s"])
        #expect(DaemonControl.installArguments(mqttEnrolled: true, socket: "/s") == ["agent", "install", "--socket", "/s", "--mqtt"])
        #expect(DaemonControl.installArguments(mqttEnrolled: false).contains(IMCTLPaths.socket.path))
    }

    @Test func statusDecodesAgentStatusJSON() throws {
        let json = #"{"label":"com.sunkailun.imctl","lastExitCode":"0","loaded":true,"logDirectory":"/l","pid":4242,"plist":"/p","plistPresent":true,"state":"running"}"#
        let s = try JSONDecoder().decode(DaemonControl.AgentStatus.self, from: Data(json.utf8))
        #expect(s.loaded && s.state == "running" && s.pid == 4242 && s.plistPresent == true)
        #expect(DaemonControl.kickstartArguments(label: "com.sunkailun.imctl").prefix(2) == ["kickstart", "-k"])
    }
}
