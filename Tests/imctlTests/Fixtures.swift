import Foundation

enum Fixtures {
    static func mainWindowPath() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ax-trees/wecom-5.0.10-main-window.json").path
    }
}
