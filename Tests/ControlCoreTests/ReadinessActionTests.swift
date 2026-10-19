import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness actions")
struct ReadinessActionTests {
    @Test func aFixCarriesItsActionOnTheWire() throws {
        let fix = ReadinessFix(text: "t", command: "imctl setup", action: ReadinessAction(.restartDaemon))
        let json = String(decoding: try JSONEncoder().encode(fix), as: UTF8.self)
        #expect(json.contains(#""action":{"kind":"restartDaemon"}"#))
        #expect(try JSONDecoder().decode(ReadinessFix.self, from: Data(json.utf8)) == fix)
    }

    @Test func anUnknownKindDecodesAndOffersNothing() throws {
        let fix = try JSONDecoder().decode(ReadinessFix.self, from: Data(#"{"text":"x","action":{"kind":"somethingNew"}}"#.utf8))
        let action = try #require(fix.action)
        #expect(action.known == nil && !action.restartsDaemon && !action.navigatesOnly)
        #expect(ReadinessActionText.button(action) == nil && ReadinessActionText.confirmation(action) == nil)
    }

    @Test func onlyTheThreeDaemonKindsRestartAndOnlyThreeKindsNavigate() {
        let restarts = ReadinessAction.Kind.allCases.filter { ReadinessAction($0).restartsDaemon }
        #expect(Set(restarts) == [.setup, .reinstallDaemon, .restartDaemon])
        let navigates = ReadinessAction.Kind.allCases.filter { ReadinessAction($0).navigatesOnly }
        #expect(Set(navigates) == [.openSettings, .openPolicy, .openLogs])
    }

    @Test func everyExecutingKindIsConfirmedAndNavigationIsNot() {
        for kind in ReadinessAction.Kind.allCases {
            let action = ReadinessAction(kind, target: kind == .openSystemSettings ? "screenRecording" : nil)
            #expect(ReadinessActionText.button(action) != nil, "\(kind)")
            let question = ReadinessActionText.confirmation(action)
            #expect((question == nil) == action.navigatesOnly, "\(kind)")
            if action.restartsDaemon { #expect(question?.contains("守护进程会重启") == true, "\(kind)") }
        }
    }

    @Test func systemSettingsOpensOnlyTheThreeFixedPages() {
        #expect(ReadinessActionText.systemSettingsURL("accessibility")?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        #expect(ReadinessActionText.systemSettingsURL("screenRecording")?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        #expect(ReadinessActionText.systemSettingsURL("fullDiskAccess")?.absoluteString.hasSuffix("Privacy_AllFiles") == true)
        #expect(ReadinessActionText.systemSettingsURL("x-apple.systempreferences:anything") == nil)
        #expect(ReadinessActionText.systemSettingsURL(nil) == nil)
    }

    /// A B52 daemon answers without `build`, `runningCommands` or any `action`.
    @Test func aB52ReportDecodes() throws {
        let json = #"{"ready":false,"nextStep":{"text":"打开企业微信并登录","command":"open -b com.tencent.WeWorkMac"},"capabilities":[],"online":{"state":"skipped"},"version":"1.0.15-dev","generatedMs":1}"#
        let report = try JSONDecoder().decode(ReadinessReport.self, from: Data(json.utf8))
        #expect(report.build == nil && report.runningCommands == nil && report.nextStep?.action == nil)
    }

    /// Review I3b: a restart goes ahead only when nothing runs or there is nothing to ask (not running, older than
    /// B53); a daemon that does not answer may be in the middle of a command.
    @Test func aRestartGoesAheadOnlyWhenNothingRunsOrTheDaemonIsNotThere() {
        #expect(ReadinessRestartAnswer.report(runningCommands: 0).refusal == nil)
        #expect(ReadinessRestartAnswer.report(runningCommands: nil).refusal == nil)
        #expect(ReadinessRestartAnswer.report(runningCommands: 2).refusal == ReadinessActionText.busy)
        #expect(ReadinessRestartAnswer.notRunning.refusal == nil)
        #expect(ReadinessRestartAnswer.oldDaemon.refusal == nil)
        #expect(ReadinessRestartAnswer.noAnswer.refusal == ReadinessActionText.noAnswer)
    }
}
