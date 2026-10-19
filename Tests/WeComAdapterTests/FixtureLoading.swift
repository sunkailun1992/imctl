import Foundation
@testable import AXKit

enum Fixtures {
    static var root: URL {
        // .../Tests/WeComAdapterTests/FixtureLoading.swift -> Tests/Fixtures/ax-trees
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ax-trees")
    }

    static func mainWindowPath() -> String {
        root.appendingPathComponent("wecom-5.0.10-main-window.json").path
    }

    static func mainWindow() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: mainWindowPath())))
    }
}

extension Fixtures {
    /// Main window while a conversation without a composer (system/notice
    /// account) is active; recorded 2026-09-11 19:1x.
    static func noComposerPath() -> String {
        root.appendingPathComponent("wecom-5.0.10-no-composer.json").path
    }

    static func noComposer() throws -> FakeAXBackend {
        FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: noComposerPath())))
    }
}
