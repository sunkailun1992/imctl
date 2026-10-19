import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("message history scroll bar rounds")
struct AIPlannerHistoryIntegrationTests {
    private static let target = "文件传输助手"

    private static func fixture(duplicateBar: Bool = true) throws -> (WeComCommandHandler, FakeAXBackend, AXElementHandle) {
        var tree = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        if !duplicateBar {
            // The recorded client has two coincident scroll bars. Keep one
            // to exercise the newly active single-candidate visual path.
            tree.children[0].children[33].children[6].children[0].children[0].children.removeLast()
        }
        let fake = FakeAXBackend(root: tree)
        let area = try #require(fake.handle(atPath: [0, 33, 6, 0, 0]))
        let selected: AXElementHandle
        if duplicateBar {
            selected = try #require(fake.appendChild(to: area, node: AXNode(
                role: AXRole.scrollBar, value: .number(0),
                frame: CGRect(x: 1904, y: 63, width: 17, height: 892), enabled: false,
                settable: [AXAttribute.value]
            )))
        } else {
            selected = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        }
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-visual-history-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [Self.target], enabled: [.scrollHistory], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandMethod = .messageHistory
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("history round must not use the one-step selector")
            return nil
        }
        handler.configureActions = { action in action.verifyTimeout = 0.05; action.verifyInterval = 0.01 }
        return (handler, fake, selected)
    }

    private static func shot(frame: CGRect) -> WeComWindowScreenshot {
        let context = CGContext(data: nil, width: Int(frame.width), height: Int(frame.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    private static func installRunner(_ handler: WeComCommandHandler, screenshots: @escaping () -> Void,
                                      decide: @escaping (AIPlannerObservation) -> AIPlannerStepDecision) {
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
                beforeRound: { try handler.beginVisualRound() },
                settingsProvider: { try AIPlannerVisionClientTests.settings() },
                capture: { _, frame in screenshots(); return Self.shot(frame: frame) },
                decide: { observation, context, _ in
                    #expect(context.method == .messageHistory)
                    if context.phase == .verify {
                        #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                        #expect(context.lastEvidence == .postconditionPresent)
                        return AIPlannerStepDecision(step: .verify, candidateID: nil)
                    }
                    return decide(observation)
                })
        }
    }

    private static func choose(_ observation: AIPlannerObservation, handle: AXElementHandle) -> AIPlannerStepDecision {
        AIPlannerStepDecision(step: .scroll,
            candidateID: observation.candidates.first(where: { $0.element.handle == handle })?.id)
    }

    private static func prompt(_ context: AIPlannerStepContext,
                               observation: AIPlannerObservation) throws -> String {
        var prompt = ""
        let client = AIPlannerStepClient { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            let parts = try #require(messages.first?["content"] as? [[String: Any]])
            prompt = try #require(parts.first?["text"] as? String)
            let reply = try JSONSerialization.data(withJSONObject: [
                "choices": [["finish_reason": "stop", "message": ["content": "{\"step\":\"stop\"}"]]]
            ])
            let response = try #require(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                        httpVersion: "HTTP/1.1", headerFields: nil))
            return (reply, response)
        }
        #expect(try client.decide(observation: observation, context: context,
                                  settings: AIPlannerVisionClientTests.settings()).step == .stop)
        return prompt
    }

    @Test func promptCarriesTheFixedLatestAndEarliestDestinations() throws {
        let (_, fake, selected) = try Self.fixture(duplicateBar: false)
        let window = try WeComReader(window: fake.rootElement).layout.window
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, expectedTitle: Self.target,
            allowedKinds: [.scroll], eligibleHandles: [selected],
            capture: { _, frame in Self.shot(frame: frame) }
        )
        let latest = try Self.prompt(AIPlannerStepContext(
            method: .messageHistory, allowedSteps: [.scroll, .reobserve, .verify, .stop],
            phase: .locate, lastEvidence: .uniqueHistoryBarVisible,
            goal: .historyScrollBar(destination: .latest)), observation: observation)
        #expect(latest.contains("latest messages at the bottom"))
        #expect(latest.contains("found exactly one visible, writable vertical scroll bar"))
        #expect(latest.contains("choose scroll with candidate_id C0"))
        #expect(latest.contains("narrow or hard-to-read thumb alone is not a contradiction"))
        #expect(!latest.contains("older messages at the top"))

        let verify = try Self.prompt(AIPlannerStepContext(
            method: .messageHistory, allowedSteps: [.verify, .reobserve, .stop],
            phase: .verify, lastEvidence: .postconditionPresent,
            goal: .historyScrollBar(destination: .latest)), observation: observation)
        #expect(verify.contains("same active chat and the chosen AX history scroll bar"))
        #expect(verify.contains("latest messages at the bottom"))
        #expect(verify.contains("independent AX check"))

        let earliest = try Self.prompt(AIPlannerStepContext(
            method: .messageHistory, allowedSteps: [.scroll, .reobserve, .verify, .stop],
            phase: .locate, lastEvidence: .uniqueHistoryBarVisible,
            goal: .historyScrollBar(destination: .earliest)), observation: observation)
        #expect(earliest.contains("older messages at the top"))
        #expect(!earliest.contains("latest messages at the bottom"))
    }

    @Test func latestReobservesAfterFirstSetIsDropped() throws {
        let (handler, fake, selected) = try Self.fixture()
        var screenshots = 0, decisions = 0, writes = 0
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard let last = fake.recordedSets.last, last.handle == selected,
                  last.value == .double(1) else { return }
            writes += 1
            if writes == 1 { fake.mutate(selected, attribute: AXAttribute.value, to: .double(0)) }
        }
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { observation in
            decisions += 1
            return Self.choose(observation, handle: selected)
        })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(writes == 2 && screenshots == 3 && decisions == 2)
        #expect(fake.recordedSets.allSatisfy { $0.handle == selected })
        #expect(try AXElement(handle: selected, backend: fake).value()?.doubleValue == 1)
    }

    @Test func singleBarUsesFreshVisualVerificationAfterScrollingToLatest() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let table = try #require(try WeComReader(window: fake.rootElement).layout.messageTable)
        var messageTableParses = 0
        fake.onRead = { handle, attribute in
            if handle == table.handle && attribute == AXAttribute.children { messageTableParses += 1 }
        }
        var valuesAtCapture: [Double] = []
        var locateDecisions = 0
        Self.installRunner(handler, screenshots: {
            valuesAtCapture.append((try? AXElement(handle: selected, backend: fake).value()?.doubleValue) ?? -1)
        }, decide: { observation in
            locateDecisions += 1
            return Self.choose(observation, handle: selected)
        })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(valuesAtCapture == [0, 1])
        #expect(locateDecisions == 1)
        // The two visual rounds must not parse all loaded messages once per
        // gate/AX postcondition; that cost exhausted the live 60 s deadline.
        #expect(messageTableParses <= 3)
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].handle == selected && fake.recordedSets[0].value == .double(1))
    }

    @Test func changedSelectedConversationDuringInferencePreventsHistoryScroll() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let selectedRow = try #require(try WeComReader(window: fake.rootElement)
            .conversations().first(where: \.selected))
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            fake.mutate(selectedRow.handle, attribute: AXAttribute.selected, to: .bool(false))
            return Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func selectionOnCellStillAllowsVerifiedHistoryScroll() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let row = try #require(try WeComReader(window: fake.rootElement)
            .conversations().first(where: \.selected))
        let cell = try #require(try AXElement(handle: row.handle, backend: fake)
            .children().first(where: { try $0.role() == AXRole.cell }))
        fake.mutate(row.handle, attribute: AXAttribute.selected, to: nil)
        fake.mutate(cell.handle, attribute: AXAttribute.selected, to: .bool(true))
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(fake.recordedSets.count == 1)
    }

    @Test func headerWithoutSelectedRowFallsBackToFullResolver() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let reader = try WeComReader(window: fake.rootElement)
        let table = try #require(reader.layout.messageTable)
        let row = try #require(try reader.conversations().first(where: \.selected))
        let cell = try #require(try AXElement(handle: row.handle, backend: fake)
            .children().first(where: { try $0.role() == AXRole.cell }))
        fake.mutate(row.handle, attribute: AXAttribute.selected, to: nil)
        fake.mutate(cell.handle, attribute: AXAttribute.selected, to: nil)
        var messageTableParses = 0
        fake.onRead = { handle, attribute in
            if handle == table.handle && attribute == AXAttribute.children { messageTableParses += 1 }
        }
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(messageTableParses > 3)
        #expect(fake.recordedSets.count == 1)
    }

    @Test func changedConversationAfterSingleBarScrollRejectsThePostcondition() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let title = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var screenshots = 0
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == selected,
                  fake.recordedSets.last?.value == .double(1) else { return }
            fake.mutate(title.handle, attribute: AXAttribute.value, to: .string("另一个会话"))
        }
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(screenshots == 1)
        #expect(fake.recordedSets.count == 1)
    }

    @Test func singleBarAlreadyAtLatestNeedsNoModelAndNoWrite() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        fake.mutate(selected, attribute: AXAttribute.value, to: .double(1))
        Self.installRunner(handler, screenshots: { Issue.record("latest history must not capture") },
                           decide: { _ in Issue.record("latest history must not call model"); return AIPlannerStepDecision(step: .stop, candidateID: nil) })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func automationKeepsTheSingleBarAXPath() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        handler.desktopCommandOrigin = .automation
        Self.installRunner(handler, screenshots: { Issue.record("watcher must not capture") },
                           decide: { _ in Issue.record("watcher must not call model"); return AIPlannerStepDecision(step: .stop, candidateID: nil) })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].handle == selected && fake.recordedSets[0].value == .double(1))
    }

    @Test func disabledVisionKeepsTheSingleBarAXPath() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        handler.visualEnabled = { false }
        Self.installRunner(handler, screenshots: { Issue.record("disabled vision must not capture") },
                           decide: { _ in Issue.record("disabled vision must not call model"); return AIPlannerStepDecision(step: .stop, candidateID: nil) })
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(fake.recordedSets.count == 1)
        #expect(fake.recordedSets[0].handle == selected && fake.recordedSets[0].value == .double(1))
    }

    @Test func scrollbackReusesChosenBarAndRestoresLatest() throws {
        let (handler, fake, selected) = try Self.fixture()
        var screenshots = 0
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(try handler.messageHistory(limit: 3, scrollback: true).isEmpty)
        #expect(screenshots == 2)
        #expect(fake.recordedSets.filter { $0.value == .double(0) }.count >= 2)
        #expect(fake.recordedSets.allSatisfy { $0.handle == selected })
        #expect(fake.recordedSets.last?.value == .double(1))
    }

    @Test func singleBarScrollbackObservesBeforeAndAfterTheFirstMove() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        var screenshots = 0
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(try handler.messageHistory(limit: 3, scrollback: true).isEmpty)
        #expect(screenshots == 2)
        #expect(fake.recordedSets.first?.handle == selected && fake.recordedSets.first?.value == .double(0))
        #expect(fake.recordedSets.last?.handle == selected && fake.recordedSets.last?.value == .double(1))
    }

    @Test func olderRowsCanRenormalizeTheBarAfterTheTopWrite() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let original = try #require(source.first { $0.role == AXRole.table && ($0.frame?.width ?? 0) > 1000 })
        fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.444))
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == selected,
                  fake.recordedSets.last?.value == .double(0) else { return }
            fake.replaceChildren(of: table, with: [ScrollbackTests.oldRow("older-a"),
                                                   ScrollbackTests.oldRow("older-b")] + original.children)
            fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.121))
        }
        var screenshots = 0
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        let rows = try handler.messageHistory(limit: 3, scrollback: true)
        #expect(rows.count == 2)
        #expect(screenshots == 2)
        #expect(fake.recordedSets.first?.value == .double(0))
        #expect(fake.recordedSets.last?.value == .double(1))
    }

    @Test func renormalizedBarWithoutNewRowsDoesNotVerifyOlderHistory() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.444))
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == selected,
                  fake.recordedSets.last?.value == .double(0) else { return }
            fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.121))
        }
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 3, scrollback: true) }
        #expect(fake.recordedSets.allSatisfy { $0.value == .double(0) })
    }

    @Test func newRowsWithoutTopwardBarMovementDoNotVerifyOlderHistory() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.444))
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == selected,
                  fake.recordedSets.last?.value == .double(0) else { return }
            fake.appendChild(to: table, node: ScrollbackTests.oldRow("new-tail"))
            fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.444))
        }
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 3, scrollback: true) }
        #expect(fake.recordedSets.allSatisfy { $0.value == .double(0) })
    }

    @Test func appendedRowsWithTopwardBarMovementDoNotVerifyOlderHistory() throws {
        let (handler, fake, selected) = try Self.fixture(duplicateBar: false)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.444))
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == selected,
                  fake.recordedSets.last?.value == .double(0) else { return }
            fake.appendChild(to: table, node: ScrollbackTests.oldRow("new-tail"))
            fake.mutate(selected, attribute: AXAttribute.value, to: .double(0.121))
        }
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 3, scrollback: true) }
        #expect(fake.recordedSets.allSatisfy { $0.value == .double(0) })
    }

    @Test func enoughRowsOnSingleBarSkipBothVisualRounds() throws {
        let (handler, fake, _) = try Self.fixture(duplicateBar: false)
        let table = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 0]))
        fake.replaceChildren(of: table, with: [ScrollbackTests.oldRow("visible")])
        Self.installRunner(handler, screenshots: { Issue.record("no screenshot expected") },
                           decide: { _ in
                               Issue.record("no model decision expected")
                               return AIPlannerStepDecision(step: .stop, candidateID: nil)
                           })
        #expect(try handler.messageHistory(limit: 1, scrollback: true).count == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func singleBarModelStopBeforeOlderScrollFailsClosed() throws {
        let (handler, fake, _) = try Self.fixture(duplicateBar: false)
        var screenshots = 0
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { _ in
            AIPlannerStepDecision(step: .stop, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 3, scrollback: true) }
        #expect(screenshots == 1)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func policyRevokedDuringInferencePreventsAnyScroll() throws {
        let (handler, fake, selected) = try Self.fixture()
        var screenshots = 0
        Self.installRunner(handler, screenshots: { screenshots += 1 }, decide: { observation in
            handler.policy.enabled.remove(.scrollHistory)
            return Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(screenshots == 1 && fake.recordedSets.isEmpty)
    }

    @Test func changedConversationPreventsScroll() throws {
        let (handler, fake, selected) = try Self.fixture()
        let title = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            fake.mutate(title.handle, attribute: AXAttribute.value, to: .string("另一个会话"))
            return Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func changedWindowFramePreventsScroll() throws {
        let (handler, fake, selected) = try Self.fixture()
        let window = try WeComReader(window: fake.rootElement).layout.window
        let frame = try #require(try window.frame())
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            fake.mutate(window.handle, attribute: AXAttribute.frame,
                        to: .rect(frame.offsetBy(dx: 20, dy: 0)))
            return Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func changedBarFramePreventsScroll() throws {
        let (handler, fake, selected) = try Self.fixture()
        let bar = AXElement(handle: selected, backend: fake)
        let frame = try #require(try bar.frame())
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            fake.mutate(selected, attribute: AXAttribute.frame,
                        to: .rect(frame.offsetBy(dx: 15, dy: 0)))
            return Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(fake.recordedSets.isEmpty)
    }

    @Test func modelVerifyCannotClaimLatestWithoutAnAXPostcondition() throws {
        let (handler, fake, _) = try Self.fixture()
        var rounds = 0
        Self.installRunner(handler, screenshots: { rounds += 1 }, decide: { _ in
            AIPlannerStepDecision(step: .verify, candidateID: nil)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 30, scrollback: false) }
        #expect(rounds == 4 && fake.recordedSets.isEmpty)
    }

    @Test func policyRevokedAfterFirstScrollPreventsScrollbackContinuationAndRestore() throws {
        let (handler, fake, selected) = try Self.fixture()
        var writes = 0
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard fake.recordedSets.last?.handle == selected else { return }
            writes += 1
            if writes == 2 { handler.policy.enabled.remove(.scrollHistory) }
        }
        Self.installRunner(handler, screenshots: {}, decide: { observation in
            Self.choose(observation, handle: selected)
        })
        #expect(throws: ControlError.self) { try handler.messageHistory(limit: 3, scrollback: true) }
        #expect(writes == 2 && fake.recordedSets.count == 2)
        #expect(fake.recordedSets.allSatisfy { $0.value == .double(0) })
    }

    @Test func coincidentAXBarsAtLatestNeedsNoModelAndNoWrite() throws {
        let fake = try Fixtures.mainWindow()
        let bar = try #require(fake.handle(atPath: [0, 33, 6, 0, 0, 1]))
        fake.mutate(bar, attribute: AXAttribute.value, to: .double(1))
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-fast-history-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [Self.target], enabled: [.scrollHistory], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandMethod = .messageHistory
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in Issue.record("unique AX path uploaded"); return nil }
        handler.reversibleRunnerFactory = { Issue.record("unique AX path entered rounds");
            return AIPlannerReversibleRunner(beforeRound: {}) }
        #expect(try handler.messageHistory(limit: 30, scrollback: false).isEmpty)
        #expect(fake.recordedSets.isEmpty)
    }
}
