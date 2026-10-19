import AppKit
import AXKit
import WeComAdapter

/// Read-only, in-process look at the client: what the daemon would see if it
/// were trusted. Needs the console's own Accessibility grant; presses nothing.
struct DiagnosticsReport: Codable, Equatable {
    var consoleTrusted: Bool
    var clientRunning: Bool
    var windowFrame: String?
    var conversationTable: String?
    var messageTable: String?
    var composerPresent: Bool?
    var activeTitle: String?
    var activeType: String?
    var conversationCount: Int?
    var rowHeights: [Int]?
    var windowMenuItems: [String]?
    var error: String?
}

enum Diagnostics {
    static func run(bundleID: String = WeComClient.bundleID) -> DiagnosticsReport {
        let backend = LiveAXBackend()
        var report = DiagnosticsReport(consoleTrusted: backend.isProcessTrusted(prompt: false),
                                       clientRunning: AXApp.runningApplication(bundleID: bundleID) != nil)
        guard report.consoleTrusted, report.clientRunning else { return report }
        do { report = try fill(report, app: try AXApp.byBundleID(bundleID, backend: backend)) }
        catch { report.error = String(describing: error) }
        return report
    }

    /// Fixture-testable part: everything derived from an application element.
    static func fill(_ base: DiagnosticsReport, app: AXElement) throws -> DiagnosticsReport {
        var report = base
        report.windowMenuItems = (try? WeComMenuBar.items(in: app, menu: WeComMenuBar.windowMenuTitle))?
            .map { $0.title + ($0.enabled == false ? " [disabled]" : "") }
        do {
            let window = try WeComWindowLocator.mainWindow(from: app)
            let reader = try WeComReader(window: window)
            let layout = reader.layout
            report.windowFrame = describe(layout.windowFrame)
            report.conversationTable = describe(layout.conversationTableFrame)
            report.messageTable = layout.messageTableFrame.map(describe)
            report.composerPresent = layout.composer != nil
            report.activeTitle = try reader.activeConversationTitle()
            report.activeType = try reader.activeConversationType().rawValue
            let rows = try reader.conversations()
            report.conversationCount = rows.count
            report.rowHeights = Array(Set(rows.map { Int($0.frame.height) })).sorted()
        } catch {
            report.error = String(describing: error)
        }
        return report
    }

    private static func describe(_ r: CGRect) -> String { "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))" }
}
