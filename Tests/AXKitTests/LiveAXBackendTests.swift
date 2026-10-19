import Foundation
import Testing
@testable import AXKit

let liveEnabled = ProcessInfo.processInfo.environment["IMCTL_LIVE"] == "1"
let liveBundleID = ProcessInfo.processInfo.environment["IMCTL_LIVE_BUNDLE"] ?? "com.apple.finder"

/// Read-only live checks. Never sets attributes or performs actions.
@Suite("LiveAXBackend (IMCTL_LIVE=1)", .enabled(if: liveEnabled))
struct LiveAXBackendTests {
    @Test func trustCheckDoesNotPrompt() {
        let backend = LiveAXBackend()
        _ = backend.isProcessTrusted(prompt: false)
    }

    @Test func applicationElementReadsRoleAndChildren() throws {
        let backend = LiveAXBackend()
        try #require(backend.isProcessTrusted(prompt: false), "grant Accessibility to the test runner first")
        let app = try AXApp.byBundleID(liveBundleID, backend: backend)
        #expect(try app.role() == AXRole.application)
        #expect(try app.pid() > 0)
        let (node, stats) = AXTreeDumper(maxDepth: 2).dumpWithStats(app)
        #expect(node.role == AXRole.application)
        #expect(stats.nodes >= 1)
    }

    @Test func unknownBundleThrows() {
        #expect(throws: AXKitError.applicationNotRunning(bundleID: "com.example.nope")) {
            try AXApp.byBundleID("com.example.nope", backend: LiveAXBackend())
        }
    }
}
