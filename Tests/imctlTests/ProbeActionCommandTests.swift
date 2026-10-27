import Testing
@testable import imctl

@Suite("probe action commands")
struct ProbeActionCommandTests {
    @Test func selectRequiresAllowFlag() {
        #expect(throws: (any Error).self) { try ProbeSelectCommand.parse(["--from-fixture", Fixtures.mainWindowPath()]) }
    }

    @Test func selectFromFixtureVerifies() throws {
        let cmd = try ProbeSelectCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--allow-select", "文件传输助手"])
        let out = try cmd.collect()
        #expect(out.outcome.verified)
        #expect(out.outcome.target == "文件传输助手")
    }

    @Test func composeFromFixtureRoundTrips() throws {
        let cmd = try ProbeComposeCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--allow-compose", "imctl-probe", "--clear"])
        let out = try cmd.collect()
        #expect(out.composed.verified)
        #expect(out.cleared?.verified == true)
        #expect(out.newButtons.isEmpty)
    }

    @Test func watchFromFixtureProducesSummary() throws {
        let cmd = try ProbeWatchCommand.parse(["--from-fixture", Fixtures.mainWindowPath(), "--seconds", "0", "--mode", "poll"])
        let summary = try cmd.runWatch()
        #expect(summary.polls >= 1)
        #expect(summary.events == 0)
    }

    @Test func allProbeSubcommandsRegistered() {
        let sub = ProbeCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(sub == ["conversations", "messages", "watch", "select", "compose", "submit", "menu", "scrollback", "menubar", "contacts", "picker", "rowmenu", "addcustomer", "addmembers", "rail", "ax-timing"])
    }
}
