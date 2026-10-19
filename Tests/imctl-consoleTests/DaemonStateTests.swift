import Foundation
import Testing
@testable import imctl_console

@Suite("DaemonState")
struct DaemonStateTests {
    @Test func decodesOldAndNewStateFiles() throws {
        let old = #"{"active":"","conversations":0,"errors":3,"lastEventId":52,"paused":["system"],"pid":1,"polls":0,"version":"0.1.0-dev"}"#
        let s = try JSONDecoder().decode(DaemonState.self, from: Data(old.utf8))
        #expect(s.pid == 1 && s.pausedReasons == ["system"] && s.trusted == nil && s.socket == nil && s.lastEventId == 52)
        let new = #"{"pid":2,"trusted":true,"socket":"/x/run/imctl.sock","paused":[],"startedMs":1,"policy":"titles=0"}"#
        let n = try JSONDecoder().decode(DaemonState.self, from: Data(new.utf8))
        #expect(n.trusted == true && n.socket == "/x/run/imctl.sock" && n.pausedReasons.isEmpty && n.policy == "titles=0")
        #expect(DaemonState(pid: Int(ProcessInfo.processInfo.processIdentifier)).isAlive)
    }
}
