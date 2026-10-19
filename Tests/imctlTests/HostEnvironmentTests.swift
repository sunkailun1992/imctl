import Foundation
import Testing
@testable import imctl

@Suite("HostEnvironment")
struct HostEnvironmentTests {
    static func sample() -> HostEnvironment {
        HostEnvironment(
            timestamp: "2026-09-11T05:00:00Z", macOSVersion: "26.6.2", architecture: "arm64",
            accessibilityTrusted: false, clamshellClosed: true, sleepDisabled: true, onACPower: true,
            screenLocked: false, displayAsleep: false, displayCount: 2,
            client: .init(bundleID: "com.tencent.WeWorkMac", version: "5.0.10", pid: 123, hidden: true, active: false),
            process: .init(executablePath: "/tmp/imctl", signingIdentifier: "com.sunkailun.imctl", signingTeam: nil, signed: true)
        )
    }

    @Test func renderListsEveryFieldOnItsOwnLine() {
        let text = Self.sample().render()
        #expect(text.contains("accessibility_trusted: false"))
        #expect(text.contains("clamshell_closed: true"))
        #expect(text.contains("client: com.tencent.WeWorkMac 5.0.10 pid=123 hidden=true active=false"))
        #expect(text.contains("signing: com.sunkailun.imctl (team: -)"))
    }

    @Test func renderShowsUnknownForNilProbes() {
        var env = Self.sample()
        env.clamshellClosed = nil
        env.client = nil
        let text = env.render()
        #expect(text.contains("clamshell_closed: unknown"))
        #expect(text.contains("client: not running"))
    }

    @Test func jsonRoundTrips() throws {
        let env = Self.sample()
        let json = try env.jsonString()
        #expect(json.contains("\"accessibilityTrusted\" : false"))
        let back = try JSONDecoder().decode(HostEnvironment.self, from: Data(json.utf8))
        #expect(back == env)
    }
}
