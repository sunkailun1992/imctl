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

    /// B61: one batched round trip reads what the single getters read.
    @Test func batchEqualsSingleOnTheTestApp() throws {
        let backend = LiveAXBackend()
        try #require(backend.isProcessTrusted(prompt: false), "grant Accessibility to the test runner first")
        let app = try AXApp.byBundleID(liveBundleID, backend: backend)
        let names = [AXAttribute.role, AXAttribute.title, AXAttribute.frame, AXAttribute.position, AXAttribute.size, AXAttribute.children]
        for element in [app] + (try app.children()).prefix(5) {
            let snapshot = try element.read(names)
            #expect(try snapshot.role() == element.role())
            #expect(try snapshot.title() == element.title())
            #expect(try snapshot.frame() == element.frame())
            #expect(try snapshot.children().count == element.children().count)
        }
    }

    @Test func unknownBundleThrows() {
        #expect(throws: AXKitError.applicationNotRunning(bundleID: "com.example.nope")) {
            try AXApp.byBundleID("com.example.nope", backend: LiveAXBackend())
        }
    }
}
