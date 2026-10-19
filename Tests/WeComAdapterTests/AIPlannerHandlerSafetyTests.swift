import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("visual conversation handler safety")
struct AIPlannerHandlerSafetyTests {
    private static let target = "文件传输助手"

    private static func handler() throws -> (WeComCommandHandler, FakeAXBackend, AXElementHandle) {
        let fake = try Fixtures.mainWindow()
        let activeTitle = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle?.handle)
        fake.mutate(activeTitle, attribute: AXAttribute.value, to: .string("同事甲"))
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-visual-handler-safety-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [target], enabled: [.selectConversation], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandMethod = .conversationRead
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("multi-round handler must not call the one-step selector")
            return nil
        }
        return (handler, fake, activeTitle)
    }

    private static func shot(frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(origin: .zero, size: frame.size))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    @Test func readNavigationCommandBudgetDoesNotChangeMutationBudget() throws {
        let (handler, _, _) = try Self.handler()
        handler.maxReadNavigationVisualDuration = 0
        handler.desktopCommandMethod = .messageHistory
        #expect(throws: AIPlannerVisionError.timeout) { try handler.beginVisualRound() }
        handler.desktopCommandMethod = .contactRequestList
        #expect(throws: AIPlannerVisionError.timeout) { try handler.beginVisualRound() }
        handler.desktopCommandMethod = .contactRequestAccept
        try handler.beginVisualRound()
        handler.desktopCommandMethod = .messageSend
        try handler.beginVisualRound()
    }

    @Test func duplicateTitleOutsideViewportStopsBeforeCaptureOrSelection() throws {
        let (handler, fake, _) = try Self.handler()
        let table = try #require(fake.handle(atPath: [0, 33, 2, 0]))
        let row = try #require(fake.element(atPath: [0, 33, 2, 0, 2]))
        let originalFrame = try #require(try row.frame())
        let offscreen = originalFrame.offsetBy(dx: 0, dy: 5000)
        let duplicate = AXNode(role: AXRole.row, frame: offscreen, children: [
            AXNode(role: AXRole.cell, frame: offscreen, children: [
                AXNode(role: AXRole.staticText, value: .string("badge"),
                       frame: CGRect(x: offscreen.minX + 1, y: offscreen.minY + 4, width: 28, height: 16)),
                AXNode(role: AXRole.staticText, value: .string(Self.target),
                       frame: CGRect(x: offscreen.minX + 60, y: offscreen.minY + 4, width: 100, height: 16)),
            ]),
        ])
        _ = fake.appendChild(to: table, node: duplicate)
        let parsed = try WeComReader(window: fake.rootElement).conversations().filter { $0.title == Self.target }
        #expect(parsed.count == 1)
        var factories = 0
        handler.reversibleRunnerFactory = {
            factories += 1
            return AIPlannerReversibleRunner(beforeRound: {},
                                             capture: { _, _ in Issue.record("duplicate must not capture"); return nil })
        }
        #expect(throws: ControlError.targetAmbiguous(Self.target)) {
            try handler.conversationRead(target: Self.target)
        }
        #expect(factories == 0 && fake.recordedSets.isEmpty)
    }

    @Test func parsedOffscreenTargetUsesDirectAXWithoutVisualCapture() throws {
        let (handler, fake, activeTitle) = try Self.handler()
        let row = try #require(fake.element(atPath: [0, 33, 2, 0, 2]))
        let originalFrame = try #require(try row.frame())
        fake.mutate(row.handle, attribute: AXAttribute.frame,
                    to: .rect(originalFrame.offsetBy(dx: 0, dy: 5000)))
        #expect(try WeComReader(window: fake.rootElement).conversations().contains { $0.title == Self.target })
        var factories = 0
        handler.reversibleRunnerFactory = {
            factories += 1
            return AIPlannerReversibleRunner(beforeRound: {},
                                             capture: { _, _ in Issue.record("offscreen row must not capture"); return nil })
        }
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(activeTitle, attribute: AXAttribute.value, to: .string(Self.target))
        }
        let result = try handler.conversationRead(target: Self.target)
        #expect(result["active"] == Self.target)
        #expect(factories == 0)
        #expect(fake.recordedSets.filter { $0.attribute == AXAttribute.selectedRows }.count == 1)
    }

    @Test func windowFrameDriftAfterSelectionStopsBeforeVisualPostcondition() throws {
        let (handler, fake, activeTitle) = try Self.handler()
        let window = fake.rootHandle
        let frame = try #require(try fake.rootElement.frame())
        var selections = 0, captures = 0, decisions = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            selections += 1
            fake.mutate(activeTitle, attribute: AXAttribute.value, to: .string(Self.target))
            fake.mutate(window, attribute: AXAttribute.frame,
                        to: .rect(frame.offsetBy(dx: 12, dy: 0)))
        }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, shotFrame in captures += 1; return Self.shot(frame: shotFrame) },
                                      decide: { _, _, _ in
                                          decisions += 1
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.self) { try handler.conversationRead(target: Self.target) }
        #expect(selections == 1 && captures == 1 && decisions == 1)
    }

    /// B54: every visual stop or vision error that ends a handler command notes where it ended, and every
    /// runner reports its rounds. The counts pin today's sites: a new site must take the same path.
    @Test func everyVisualEndInTheHandlerIsRecorded() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/WeComAdapter/Handler/WeComCommandHandler.swift")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        // The line itself and the next non-blank line.
        func site(_ i: Int) -> String {
            lines[i] + "\n" + (lines[(i + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "")
        }
        var catches = 0, outcomes = 0
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.contains(" as AIPlannerVisionError {") {
                catches += 1
                #expect(site(i).contains("visualEnded(") || site(i).contains("markVisualEnd("), "line \(i + 1)")
            } else if trimmed.hasPrefix("case .stopped") || trimmed.hasPrefix("case .unverified")
                        || line.contains("outcome == .verified else {") {
                outcomes += 1
                #expect(site(i).contains("visualEnded(") || site(i).contains("markVisualEnd("), "line \(i + 1)")
            }
        }
        // 22 rethrows + the selector wrapper + mapErrors; 7 guards + 6 stopped + 4 unverified.
        #expect(catches == 24 && outcomes == 17)
        #expect(!lines.contains { $0.contains("try runner.") })
        #expect(lines.filter { $0.contains("try self.recording(runner).") }.count == 13)
        // Review I1: every visual step names itself before its first model request, so an end before that
        // request is reported at this step, never at an earlier step's round.
        let entries = lines.indices.filter {
            lines[$0].contains("actions.visualObserve") && lines[$0].contains("= {")
                || lines[$0].contains("func ") && lines[$0].contains("WithVisualRounds(")
        }
        #expect(entries.count == 13)
        for (i, line) in lines.enumerated() where line.contains("let runner = ") {
            let entry = try #require(entries.last { $0 < i }, "line \(i + 1)")
            #expect(lines[entry...i].contains { $0.contains("beginVisualStep(") }, "line \(i + 1)")
        }
    }

    /// Review I3b: a stop or a vision error from the one-step selector is noted at the selector's own step;
    /// the action then turns either into its own error.
    @Test func aSelectorStopOrErrorIsNotedAtItsStep() throws {
        let (handler, fake, _) = try Self.handler()
        var answer: () throws -> AIPlannerCandidate? = { nil }
        handler.visualSelect = { _, _, _, _, _, _ in try answer() }
        let select = try #require(handler.actions(for: nil).visualSelect)
        answer = {
            // What the daemon's selector reports for its one model request.
            handler.noteVisualRound(AIPlannerRoundRecord(method: .conversationRead, goal: "sendButton", phase: .choose,
                                                         round: 1, outcome: "stop", latencyMs: 5))
            return nil
        }
        #expect(try select(fake.rootElement, .control(.sendButton), [.press], nil, [], {}) == nil)
        #expect(handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "sendButton", phase: "choose", round: 1, outcome: "stop"))
        handler.desktopCommandVisualEnd = nil  // the next command
        answer = { throw AIPlannerVisionError.staleView }
        #expect(throws: AIPlannerVisionError.staleView) {
            try select(fake.rootElement, .control(.sendButton), [.press], nil, [], {})
        }
        #expect(handler.desktopCommandVisualEnd
                == CommandDiagnosis.Visual(goal: "sendButton", phase: "choose", round: 0, outcome: "staleView"))
    }
}
