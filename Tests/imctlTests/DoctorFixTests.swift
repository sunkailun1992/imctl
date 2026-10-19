import ArgumentParser
import ControlCore
import Foundation
import Testing
@testable import imctl

final class RecordingExecutor: DoctorFixExecutor {
    var calls: [String] = []
    func open(url: URL) throws { calls.append("open \(url.absoluteString)") }
    func openApp(bundleID: String) throws { calls.append("app \(bundleID)") }
    func runCLI(_ arguments: [String]) throws -> Int32 { calls.append("cli " + arguments.joined(separator: " ")); return 0 }
    func kickstart() throws -> Int32 { calls.append("kickstart"); return 0 }
    func call(_ method: String) throws { calls.append("rpc \(method)") }
}

@Suite("imctl doctor --fix")
struct DoctorFixTests {
    static func cap(_ id: String, _ action: ReadinessAction?, command: String? = nil) -> ReadinessCapability {
        ReadinessCapability(id: id, title: id, required: true, status: .fail, checks: [],
                            fix: ReadinessFix(text: "修 \(id)", command: command, action: action))
    }

    static func report(_ caps: [ReadinessCapability], running: Int? = 0) -> ReadinessReport {
        ReadinessReport(ready: false, nextStep: caps.first?.fix, nextStepCapability: caps.first?.id, capabilities: caps,
                        online: ReadinessOnlineInfo(state: "skipped"), version: "v", generatedMs: 1, runningCommands: running)
    }

    func fixer(answers: [String], running: Int? = 0, restart: (() -> ReadinessRestartAnswer)? = nil,
               out: @escaping (String) -> Void = { _ in }) -> (DoctorFix, RecordingExecutor) {
        var answers = answers
        let executor = RecordingExecutor()
        let fixer = DoctorFix(cli: "imctl", mqttEnrolled: true, ask: { _ in answers.isEmpty ? nil : answers.removeFirst() }, say: out,
                              executor: executor, localReport: { Self.report([], running: running) },
                              restartAnswer: restart ?? { .report(runningCommands: running) })
        return (fixer, executor)
    }

    @Test func eachItemIsAskedInOrderAndNoIsTheDefault() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["", "n"], out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("wecom", ReadinessAction(.openWeCom)), Self.cap("read", ReadinessAction(.setup))]))
        #expect(executor.calls.isEmpty)
        #expect(output.contains { $0.contains("[1/2] wecom") } && output.contains { $0.contains("[2/2] read") })
    }

    @Test func yesRunsTheAction() {
        let (fixer, executor) = fixer(answers: ["y", "y", "y"])
        fixer.run(report: Self.report([Self.cap("wecom", ReadinessAction(.openWeCom)),
                                       Self.cap("media", ReadinessAction(.openSystemSettings, target: "screenRecording")),
                                       Self.cap("mqtt", ReadinessAction(.reinstallDaemon))]))
        #expect(executor.calls == ["app com.tencent.WeWorkMac",
                                   "open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                                   "cli agent install --mqtt"])
    }

    @Test func aDaemonRestartIsSkippedWhileACommandRuns() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["y"], running: 1, out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("daemon", ReadinessAction(.restartDaemon))]))
        #expect(executor.calls.isEmpty && output.contains { $0.contains(ReadinessActionText.busy) })
    }

    /// Review I3b: a daemon that does not answer may be running a long command (the fallback calls it busy).
    @Test func aDaemonThatDoesNotAnswerIsNotRestarted() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["y"], restart: { .noAnswer }, out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("daemon", ReadinessAction(.restartDaemon))]))
        #expect(executor.calls.isEmpty && output.contains { $0.contains(ReadinessActionText.noAnswer) })
    }

    /// Review I3c: the yes may come long after the question; a command that started meanwhile still blocks it.
    @Test func aCommandThatStartsWhileTheQuestionWaitsSkipsTheRestart() {
        var output: [String] = []
        var answers: [ReadinessRestartAnswer] = [.report(runningCommands: 0), .report(runningCommands: 1)]
        let (fixer, executor) = fixer(answers: ["y"], restart: { answers.count > 1 ? answers.removeFirst() : answers[0] },
                                      out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("daemon", ReadinessAction(.restartDaemon))]))
        #expect(executor.calls.isEmpty && output.contains { $0.contains(ReadinessActionText.busy) })
    }

    @Test func navigationOnlyPrintsTheCommand() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: [], out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("mqtt", ReadinessAction(.openSettings, target: "mqtt"), command: "imctl enroll --broker <主机[:端口]>")]))
        #expect(executor.calls.isEmpty && output.contains { $0.contains("$ imctl enroll --broker <主机[:端口]>") })
    }

    @Test func fixesWithoutAKnownActionAreNotOffered() {
        var output: [String] = []
        let (fixer, executor) = fixer(answers: ["y"], out: { output.append($0) })
        fixer.run(report: Self.report([Self.cap("autoAccept", nil), Self.cap("x", ReadinessAction(kind: "somethingNew"))]))
        #expect(executor.calls.isEmpty && output.contains("没有可以自动处理的项目。"))
    }

    @Test func fixNeedsATerminalAndNoJSON() {
        #expect(throws: ValidationError.self) { try DoctorCommand.validateFix(isTerminal: false, json: false) }
        #expect(throws: ValidationError.self) { try DoctorCommand.validateFix(isTerminal: true, json: true) }
        #expect(throws: Never.self) { try DoctorCommand.validateFix(isTerminal: true, json: false) }
    }
}
