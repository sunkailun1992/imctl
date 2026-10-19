import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("contact list picker scroll visual rounds")
struct AIPlannerContactListIntegrationTests {
    private static func fixture(visual: Bool = true, initialBarValue: Double = 0) throws ->
        (handler: WeComCommandHandler, fake: FakeAXBackend, bar: () -> AXElementHandle?) {
        let tree = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
        let sheetNode = try #require(tree.children.first { $0.role == AXRole.sheet })
        let closed = tree.children.filter { $0.role != AXRole.sheet }
        let fake = FakeAXBackend(root: tree)
        fake.replaceChildren(of: fake.rootHandle, with: closed)
        var barHandle: AXElementHandle?
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b38-picker-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                 enabled: [.openGroupPicker], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandMethod = .contactList
        handler.visualEnabled = { visual }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("contact.list must not use the one-step selector")
            return nil
        }
        handler.configureActions = { action in
            action.verifyTimeout = 0.05
            action.verifyInterval = 0.01
            action.frontmostPid = { nil }
            action.postShortcut = { _, _ in
                _ = fake.appendChild(to: fake.rootHandle, node: sheetNode)
                barHandle = try GroupPickerSheet.locate(window: fake.rootElement)?
                    .visibleWritableContactBars().first?.handle
                if let barHandle, initialBarValue != 0 {
                    fake.mutate(barHandle, attribute: AXAttribute.value, to: .double(initialBarValue))
                }
            }
        }
        fake.reactions["action:\(AXAction.press)"] = {
            fake.replaceChildren(of: fake.rootHandle, with: closed)
        }
        return (handler, fake, { barHandle })
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

    private static func runner(_ handler: WeComCommandHandler,
                               capture: @escaping () -> Void = {},
                               decide: @escaping AIPlannerReversibleRunner.Decide) -> AIPlannerReversibleRunner {
        AIPlannerReversibleRunner(maxRounds: 4, maxActions: 2, maxDuration: 6,
            beforeRound: { try handler.beginVisualRound() },
            settingsProvider: { try AIPlannerVisionClientTests.settings() },
            capture: { _, frame in capture(); return shot(frame: frame) },
            decide: decide)
    }

    @Test func promptOffersOnlyTheOwnedPickerBarAndCallerChosenPosition() throws {
        let tree = try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-group-picker-sheet.json"))
        let fake = FakeAXBackend(root: tree)
        let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
        let bar = try #require(try sheet.visibleWritableContactBars().first)
        let observation = try AIPlannerObservation.capture(
            window: fake.rootElement, expectedPID: fake.pid,
            allowedKinds: [.scroll], eligibleHandles: [bar.handle],
            capture: { _, frame in Self.shot(frame: frame) })
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
        let locate = try AIPlannerStepContext(method: .contactList,
            allowedSteps: [.scroll, .reobserve, .verify, .stop],
            phase: .locate, lastEvidence: .uniquePickerContactsBarVisible,
            goal: .pickerContactsScrollBar)
        #expect(try client.decide(observation: observation, context: locate,
                                  settings: AIPlannerVisionClientTests.settings()).step == .stop)
        #expect(prompt.contains("contact rows in this command's open Start Group Chat picker"))
        #expect(prompt.contains("exactly one visible, writable vertical bar"))
        #expect(prompt.contains("caller supplies the fixed first destination"))
        #expect(!prompt.contains("latest messages at the bottom"))
        let verify = try AIPlannerStepContext(method: .contactList,
            allowedSteps: [.verify, .reobserve, .stop],
            phase: .verify, lastEvidence: .postconditionPresent,
            goal: .pickerContactsScrollBar)
        #expect(try client.decide(observation: observation, context: verify,
                                  settings: AIPlannerVisionClientTests.settings()).step == .stop)
        #expect(prompt.contains("independent AX sheet, bar and value check"))
    }

    @Test func firstNeededScrollHasTwoModelRoundsAndLaterPositionsUseAX() throws {
        let (handler, fake, bar) = try Self.fixture()
        var valuesAtCapture: [Double] = []
        var decisions = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, capture: {
                let handle = bar()
                valuesAtCapture.append(handle.flatMap {
                    try? AXElement(handle: $0, backend: fake).value()?.doubleValue
                } ?? -1)
            }, decide: { observation, context, _ in
                decisions += 1
                #expect(context.method == .contactList)
                #expect(observation.candidates.count == 1)
                #expect(observation.candidates.first?.kind == .scroll)
                if context.phase == .verify {
                    #expect(context.lastEvidence == .postconditionPresent)
                    #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                    return AIPlannerStepDecision(step: .verify, candidateID: nil)
                }
                #expect(context.goal.description?.contains("contact rows") == true)
                #expect(context.lastEvidence == .uniquePickerContactsBarVisible)
                return AIPlannerStepDecision(step: .scroll, candidateID: observation.candidates[0].id)
            })
        }
        #expect(try handler.contactList(limit: 50, scope: "customers").count == 1)
        let handle = try #require(bar())
        let writes = fake.recordedSets.filter { $0.handle == handle && $0.attribute == AXAttribute.value }
        #expect(writes.map(\.value) == [.double(0.25), .double(0.5), .double(0.75), .double(1)])
        #expect(valuesAtCapture == [0, 0.25] && decisions == 2)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func alreadyEnoughRowsUsesNoScreenshotAndNoScroll() throws {
        let (handler, fake, bar) = try Self.fixture()
        handler.reversibleRunnerFactory = {
            Issue.record("already enough contacts must not capture")
            return Self.runner(handler, decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(try handler.contactList(limit: 1, scope: "customers").count == 1)
        #expect(fake.recordedSets.filter { $0.handle == bar() }.isEmpty)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func reusedPickerInMiddleReturnsToTopBeforeCollectingEvenForOneRow() throws {
        let (handler, fake, bar) = try Self.fixture(initialBarValue: 0.5)
        var valuesAtCapture: [Double] = []
        handler.reversibleRunnerFactory = {
            Self.runner(handler, capture: {
                valuesAtCapture.append(bar().flatMap {
                    try? AXElement(handle: $0, backend: fake).value()?.doubleValue
                } ?? -1)
            }, decide: { observation, context, _ in
                if context.phase == .verify {
                    return .init(step: .verify, candidateID: nil)
                }
                return .init(step: .scroll, candidateID: observation.candidates.first?.id)
            })
        }
        let contacts = try handler.contactList(limit: 1, scope: "customers")
        #expect(contacts.count == 1)
        #expect(valuesAtCapture == [0.5, 0])
        #expect(fake.recordedSets.filter { $0.handle == bar() && $0.attribute == AXAttribute.value }
            .map(\.value) == [.double(0)])
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func disabledVisualKeepsTheAXScrollPath() throws {
        let (handler, fake, bar) = try Self.fixture(visual: false)
        handler.reversibleRunnerFactory = {
            Issue.record("disabled vision must not capture")
            return Self.runner(handler, decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(try handler.contactList(limit: 50, scope: "customers").count == 1)
        #expect(fake.recordedSets.filter { $0.handle == bar() && $0.attribute == AXAttribute.value }
            .map(\.value) == [.double(0.25), .double(0.5), .double(0.75), .double(1)])
    }

    @Test func automationKeepsTheAXScrollPath() throws {
        let (handler, fake, bar) = try Self.fixture()
        handler.desktopCommandOrigin = .automation
        handler.reversibleRunnerFactory = {
            Issue.record("automation must not upload")
            return Self.runner(handler, decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(try handler.contactList(limit: 50, scope: "customers").count == 1)
        #expect(fake.recordedSets.filter { $0.handle == bar() && $0.attribute == AXAttribute.value }
            .map(\.value) == [.double(0.25), .double(0.5), .double(0.75), .double(1)])
    }

    @Test func modelStopCancelsOwnedSheetWithoutScrolling() throws {
        let (handler, fake, bar) = try Self.fixture()
        var captures = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, capture: { captures += 1 },
                        decide: { _, _, _ in .init(step: .stop, candidateID: nil) })
        }
        #expect(throws: ControlError.self) { try handler.contactList(limit: 50, scope: "customers") }
        #expect(captures == 1)
        #expect(fake.recordedSets.filter { $0.handle == bar() }.isEmpty)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func policyRevocationDuringInferenceCannotScroll() throws {
        let (handler, fake, bar) = try Self.fixture()
        var captures = 0
        handler.reversibleRunnerFactory = {
            Self.runner(handler, capture: { captures += 1 }, decide: { observation, _, _ in
                handler.policy.enabled.remove(.openGroupPicker)
                return .init(step: .scroll, candidateID: observation.candidates.first?.id)
            })
        }
        #expect(throws: ControlError.self) { try handler.contactList(limit: 50, scope: "customers") }
        #expect(captures == 1)
        #expect(fake.recordedSets.filter { $0.handle == bar() }.isEmpty)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }

    @Test func staleBarFrameDuringInferenceCannotScroll() throws {
        let (handler, fake, bar) = try Self.fixture()
        handler.reversibleRunnerFactory = {
            Self.runner(handler, decide: { observation, _, _ in
                if let handle = bar() {
                    fake.mutate(handle, attribute: AXAttribute.frame,
                                to: .rect(CGRect(x: 800, y: 387, width: 17, height: 494)))
                }
                return .init(step: .scroll, candidateID: observation.candidates.first?.id)
            })
        }
        #expect(throws: ControlError.self) { try handler.contactList(limit: 50, scope: "customers") }
        #expect(fake.recordedSets.filter { $0.handle == bar() }.isEmpty)
        #expect(fake.recordedActions.map(\.action) == [AXAction.press])
    }
}
