import Testing
@testable import ControlCore

@Suite("IMCTLVersion")
struct IMCTLVersionTests {
    @Test func versionIsTheCurrentPatchRelease() {
        #expect(IMCTLVersion.string == "1.0.18-dev")
    }

    @Test func bundleIdentifierIsStable() {
        #expect(IMCTLVersion.bundleIdentifier == "com.sunkailun.imctl")
    }

    @Test func runtimePathsLiveUnderTheDataDirectory() {
        let root = IMCTLPaths.dataDirectory.path
        #expect(IMCTLPaths.database.path == root + "/imctl.sqlite" && IMCTLPaths.stateFile.path == root + "/state.json")
        #expect(IMCTLPaths.socket.path == root + "/run/imctl.sock" && IMCTLPaths.runDirectory.path == root + "/run")
        #expect(IMCTLPaths.socket.path.utf8.count <= 103)
        #expect(IMCTLPaths.logDirectory.path.hasSuffix("/Library/Logs/imctl"))
    }
}
