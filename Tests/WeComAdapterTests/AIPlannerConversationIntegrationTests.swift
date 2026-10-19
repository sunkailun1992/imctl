import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("conversation read visual rounds through handler")
struct AIPlannerConversationIntegrationTests {
    private static let target = "文件传输助手"

    private static func handlerWithParserMiss() throws -> (WeComCommandHandler, FakeAXBackend) {
        let fake = try Fixtures.mainWindow()
        let cell = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let text = source.children[0].children[33].children[2].children[0].children[2].children[0].children
        fake.replaceChildren(of: cell, with: [
            AXNode(role: AXRole.staticText, value: .string("new badge"),
                   frame: CGRect(x: 100, y: 140, width: 28, height: 20)),
        ] + text)
        let activeTitle = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        fake.mutate(activeTitle.handle, attribute: AXAttribute.value, to: .string("同事甲"))
        let reader = try WeComReader(window: fake.rootElement)
        #expect(try reader.activeConversationTitle() == "同事甲")
        #expect(try reader.conversations().allSatisfy { $0.title != target })
        let checkpoints = try FileCheckpointStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-visual-read-\(UUID().uuidString)"))
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
        return (handler, fake)
    }

    private static func handlerWithParsedRow() throws -> (WeComCommandHandler, FakeAXBackend) {
        let fake = try Fixtures.mainWindow()
        let activeTitle = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        fake.mutate(activeTitle.handle, attribute: AXAttribute.value, to: .string("同事甲"))
        #expect(try WeComReader(window: fake.rootElement).conversations().contains { $0.title == target })
        let checkpoints = try FileCheckpointStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-visual-parsed-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(
            rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: [target], enabled: [.selectConversation], phase: .phase1),
            checkpoints: checkpoints)
        handler.desktopCommandMethod = .conversationRead
        handler.visualEnabled = { true }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("command-owned multi-round selection must not call the one-step selector")
            return nil
        }
        return (handler, fake)
    }

    private static func shot(frame: CGRect) -> WeComWindowScreenshot {
        let width = Int(frame.width), height = Int(frame.height)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return WeComWindowScreenshot(image: context.makeImage()!, windowFrame: frame)
    }

    @Test func parserMissReobservesAfterDroppedSelectionAndReturnsOnlyAXVerifiedResult() throws {
        let (handler, fake) = try Self.handlerWithParserMiss()
        let activeTitle = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var selections = 0, modelRounds = 0, screenshots = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            selections += 1
            if selections == 2 {
                fake.mutate(activeTitle.handle, attribute: AXAttribute.value, to: .string(Self.target))
            }
        }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in screenshots += 1; return Self.shot(frame: frame) },
                                      decide: { _, context, _ in
                                          modelRounds += 1
                                          #expect(context.method == .conversationRead)
                                          return context.phase == .verify
                                              ? AIPlannerStepDecision(step: .verify, candidateID: nil)
                                              : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        let result = try handler.conversationRead(target: Self.target)
        #expect(result["active"] == Self.target)
        #expect(selections == 2 && modelRounds == 3 && screenshots == 3)
    }

    @Test func parsedTargetRowUsesFreshVisualSelectionAndVerification() throws {
        let (handler, fake) = try Self.handlerWithParsedRow()
        let activeTitle = try #require(try WeComReader(window: fake.rootElement).layout.activeTitle)
        var selections = 0, screenshots = 0, modelRounds = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            selections += 1
            fake.mutate(activeTitle.handle, attribute: AXAttribute.value, to: .string(Self.target))
        }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in screenshots += 1; return Self.shot(frame: frame) },
                                      decide: { _, context, _ in
                                          modelRounds += 1
                                          #expect(context.method == .conversationRead)
                                          if context.phase == .verify {
                                              #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                                              return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                          }
                                          #expect(context.phase == .locate)
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        let result = try handler.conversationRead(target: Self.target)
        #expect(result["active"] == Self.target)
        #expect(selections == 1 && screenshots == 2 && modelRounds == 2)
    }

    @Test func readMayChooseVisibleAXRowWithoutAXTitleButStillRequiresTargetHeader() throws {
        let (handler, fake) = try Self.handlerWithParserMiss()
        let cell = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0]))
        let row = try #require(fake.element(atPath: [0, 33, 2, 0, 2]))
        let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
        let originalChildren = source.children[0].children[33].children[2].children[0].children[2].children[0].children
        fake.replaceChildren(of: cell, with: originalChildren.filter { $0.value != .string(Self.target) })
        let initial = try WeComReader(window: fake.rootElement)
        #expect(try initial.conversations().allSatisfy { $0.title != Self.target })
        #expect(!WeComActions.rowTopBandContainsExactTitle(row, title: Self.target))

        let activeTitle = try #require(initial.layout.activeTitle)
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            fake.mutate(activeTitle.handle, attribute: AXAttribute.value, to: .string(Self.target))
        }
        var visibleChoices = 0, requests = 0
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in Self.shot(frame: frame) },
                                      decide: { observation, context, _ in
                                          requests += 1
                                          if context.phase == .verify {
                                              return AIPlannerStepDecision(step: .verify, candidateID: nil)
                                          }
                                          visibleChoices = observation.candidates.count
                                          let chosen = try #require(observation.candidates.first { $0.element.handle == row.handle })
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: chosen.id)
                                      })
        }
        let result = try handler.conversationRead(target: Self.target)
        #expect(result["active"] == Self.target)
        #expect(visibleChoices > 1 && requests == 2)
    }

    @Test func policyRevokedAfterInferencePreventsSelection() throws {
        let (handler, fake) = try Self.handlerWithParserMiss()
        var screenshots = 0
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in screenshots += 1; return Self.shot(frame: frame) },
                                      decide: { _, _, _ in
                                          handler.policy.enabled.remove(.selectConversation)
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.self) { try handler.conversationRead(target: Self.target) }
        #expect(screenshots == 1 && fake.recordedSets.isEmpty)
    }

    @Test func pauseAfterInferencePreventsSelection() throws {
        let (handler, fake) = try Self.handlerWithParserMiss()
        var paused = false
        handler.visualCommandGate = { if paused { throw ControlError.paused([.api]) } }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in Self.shot(frame: frame) },
                                      decide: { _, _, _ in
                                          paused = true
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.paused([.api])) { try handler.conversationRead(target: Self.target) }
        #expect(fake.recordedSets.isEmpty)
    }
}
