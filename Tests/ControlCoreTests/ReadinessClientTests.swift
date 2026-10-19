import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness client facts")
struct ReadinessClientTests {
    func app(build: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": build], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// Read from disk every time: an app replaced while the daemon runs must show its new build.
    @Test func theBuildIsReadFromDiskEachTime() throws {
        let url = try app(build: "268")
        #expect(ReadinessClient.bundleBuild(at: url) == "268")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "269"], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        #expect(ReadinessClient.bundleBuild(at: url) == "269")
        #expect(ReadinessClient.bundleBuild(at: url.deletingLastPathComponent()) == nil)
        #expect(ReadinessClient.bundleBuild(at: nil) == nil)
    }

    @Test func theCLIIsLinkedOnlyWhenACandidateResolvesToIt() {
        let cli = "/Apps/imctl.app/Contents/MacOS/imctl"
        #expect(ReadinessClient.cliLinked(cliPath: cli, candidates: ["/usr/local/bin/imctl"], resolve: { _ in cli }))
        #expect(!ReadinessClient.cliLinked(cliPath: cli, candidates: ["/usr/local/bin/imctl"], resolve: { _ in "/Other/imctl" }))
        #expect(!ReadinessClient.cliLinked(cliPath: cli, candidates: ["/usr/local/bin/imctl"], resolve: { _ in nil }))
    }

    @Test func buildsCompareAsNumbers() {
        #expect(ReadinessClient.isOlder("99", than: "268") && !ReadinessClient.isOlder("268", than: "268"))
        #expect(!ReadinessClient.isOlder("x", than: "268"))
    }
}
