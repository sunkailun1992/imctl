import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

/// B20: only the reversible target-selection prefix is shared by these four
/// fixed commands. No fake test here reaches a real key poster or client.
@Suite("mutation target visual rounds through handler")
struct AIPlannerMutationTargetIntegrationTests {
    private static let target = "文件传输助手"
    private static let commands: [RPCMethod] = [.messageSend, .messageSendFile, .groupRename, .groupAddMembers]

    private final class RootBox { var root: AXElement? }

    private final class MutableIdentities: IdentityLookup {
        var current = Identity(kind: .group, id: "synthetic-a", title: target, updatedMs: 1)
        func identity(kind: IdentityKind, id: String) throws -> Identity? {
            current.kind == kind && current.id == id ? current : nil
        }
        func identities(title: String) throws -> [Identity] { title == current.title ? [current] : [] }
    }

    private static func handler(parserMiss: Bool, method: RPCMethod,
                                rootBox: RootBox? = nil, identities: IdentityLookup = NoIdentities()) throws
        -> (WeComCommandHandler, FakeAXBackend, AXElementHandle) {
        let fake = try Fixtures.mainWindow()
        if parserMiss {
            let cell = try #require(fake.handle(atPath: [0, 33, 2, 0, 2, 0]))
            let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
            let text = source.children[0].children[33].children[2].children[0].children[2].children[0].children
            fake.replaceChildren(of: cell, with: [
                AXNode(role: AXRole.staticText, value: .string("new badge"),
                       frame: CGRect(x: 100, y: 140, width: 28, height: 20)),
            ] + text)
        }
        let reader = try WeComReader(window: fake.rootElement)
        let header = try #require(reader.layout.activeTitle?.handle)
        fake.mutate(header, attribute: AXAttribute.value, to: .string("同事甲"))
        let composer = try #require(reader.layout.composer?.handle)
        fake.mutate(composer, attribute: AXAttribute.value, to: .string("local draft"))
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-visual-mutation-\(UUID().uuidString)"))
        rootBox?.root = fake.rootElement
        let h = WeComCommandHandler(rootProvider: { rootBox?.root ?? fake.rootElement },
                                    policy: ActionPolicy(allowedTargets: [target],
                                                         enabled: [.selectConversation, .composeText, .clearComposer,
                                                                   .submit, .sendFile, .renameGroup, .addGroupMembers],
                                                         phase: .phase1), checkpoints: checkpoints, identities: identities)
        h.desktopCommandMethod = method
        h.visualEnabled = { true }
        h.visualSelect = { _, _, _, _, _, _ in
            Issue.record("the target round must not use the one-step selector")
            return nil
        }
        h.objectStore = FakeObjectStore()
        h.fileFetcher = FileFetcher(outbox: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-visual-outbox-\(UUID().uuidString)"))
        h.configureActions = { a in
            a.verifyTimeout = 0.02; a.verifyInterval = 0.005
            a.postReturnKey = { _, _ in Issue.record("fake target tests must stop before Return") }
            a.postShortcut = { _, _ in Issue.record("fake target tests must stop before paste") }
        }
        return (h, fake, header)
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

    private static func invoke(_ method: RPCMethod, handler h: WeComCommandHandler) throws {
        switch method {
        case .messageSend:
            _ = try h.messageSend(target: target, text: "fake", checkpoint: {}, afterSubmit: {})
        case .messageSendFile:
            _ = try h.messageSendFile(target: target, source: .ossKey("imctl/fake.pdf"), fileName: "fake.pdf",
                                      checkpoint: {}, afterSubmit: {})
        case .groupRename:
            _ = try h.groupRename(target: target, name: "fake group", checkpoint: { throw CrashInjected() }, afterSubmit: {})
        case .groupAddMembers:
            _ = try h.groupAddMembers(target: target, members: ["fixture member"], dryRun: false,
                                      checkpoint: {}, afterSubmit: {})
        default:
            Issue.record("unsupported target test method")
        }
    }

    private static func runUntilAction(_ method: RPCMethod, handler h: WeComCommandHandler) throws {
        switch method {
        case .messageSend, .messageSendFile:
            #expect(throws: ControlError.localGuard("composer not empty")) { try invoke(method, handler: h) }
        case .groupRename:
            // The fixture's self-chat header can be noneditable; then rename
            // ends as an unverified action before reaching the fake checkpoint.
            do {
                let out = try h.groupRename(target: target, name: "fake group",
                                            checkpoint: { throw CrashInjected() }, afterSubmit: {})
                #expect(out["renamed"] == "false")
            }
            catch is CrashInjected { }
        case .groupAddMembers:
            #expect(throws: ControlError.notAGroup(target)) { try invoke(method, handler: h) }
        default: Issue.record("unsupported target test method")
        }
    }

    @Test func parsedOrMissedTargetUsesTwoVisualRoundsBeforeEachMutation() throws {
        for parserMiss in [false, true] {
            for method in Self.commands {
                let (h, fake, header) = try Self.handler(parserMiss: parserMiss, method: method)
                var rounds = 0, captures = 0, selections = 0
                fake.reactions["set:\(AXAttribute.selectedRows)"] = {
                    selections += 1
                    fake.mutate(header, attribute: AXAttribute.value, to: .string(Self.target))
                }
                h.reversibleRunnerFactory = {
                    AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                              settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                              capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                              decide: { _, context, _ in
                                                  rounds += 1
                                                  #expect(context.method == method)
                                                  return context.phase == .verify
                                                      ? AIPlannerStepDecision(step: .verify, candidateID: nil)
                                                      : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                              })
                }
                try Self.runUntilAction(method, handler: h)
                #expect((selections, rounds, captures) == (1, 2, 2))
                #expect(try h.checkpoints.pending().isEmpty)
            }
        }
    }

    @Test func droppedFirstSelectionGetsOneFreshRoundBeforeAnyMutation() throws {
        let (h, fake, header) = try Self.handler(parserMiss: true, method: .messageSend)
        var selections = 0, captures = 0
        fake.reactions["set:\(AXAttribute.selectedRows)"] = {
            selections += 1
            if selections == 2 { fake.mutate(header, attribute: AXAttribute.value, to: .string(Self.target)) }
        }
        h.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                      decide: { _, context, _ in
                                          context.phase == .verify
                                              ? AIPlannerStepDecision(step: .verify, candidateID: nil)
                                              : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        try Self.runUntilAction(.messageSend, handler: h)
        #expect(selections == 2 && captures == 3)
        #expect(try h.checkpoints.pending().isEmpty)
    }

    @Test func modelStopInSecondRoundPreventsAllFourMutationBodies() throws {
        for method in Self.commands {
            let (h, fake, header) = try Self.handler(parserMiss: false, method: method)
            fake.reactions["set:\(AXAttribute.selectedRows)"] = {
                fake.mutate(header, attribute: AXAttribute.value, to: .string(Self.target))
            }
            var decisions = 0
            h.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                          settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                          capture: { _, frame in Self.shot(frame: frame) },
                                          decide: { _, context, _ in
                                              decisions += 1
                                              return context.phase == .verify
                                                  ? AIPlannerStepDecision(step: .stop, candidateID: nil)
                                                  : AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                          })
            }
            #expect(throws: ControlError.self) { try Self.invoke(method, handler: h) }
            #expect(decisions == 2 && fake.recordedSets.count == 1)
            #expect(try h.checkpoints.pending().isEmpty)
        }
    }

    @Test func revokingMutationPolicyDuringInferenceStopsAllFourBeforeAX() throws {
        for method in Self.commands {
            let (h, fake, _) = try Self.handler(parserMiss: true, method: method)
            let kind: ActionKind = switch method {
            case .messageSend: .submit
            case .messageSendFile: .sendFile
            case .groupRename: .renameGroup
            case .groupAddMembers: .addGroupMembers
            default: .selectConversation
            }
            var captures = 0
            h.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                          settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                          capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                          decide: { _, _, _ in
                                              h.policy.enabled.remove(kind)
                                              return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                          })
            }
            #expect(throws: ControlError.self) { try Self.invoke(method, handler: h) }
            #expect(captures == 1 && fake.recordedSets.isEmpty)
            #expect(try h.checkpoints.pending().isEmpty)
        }
    }

    @Test func pauseOrFullWindowRevocationAfterInferencePreventsTargetSwitch() throws {
        for revokeSettings in [false, true] {
            let (h, fake, _) = try Self.handler(parserMiss: true, method: .messageSend)
            var paused = false
            var settings = try AIPlannerVisionClientTests.settings()
            h.visualCommandGate = { if paused { throw ControlError.paused([.api]) } }
            h.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                          settingsProvider: { settings },
                                          capture: { _, frame in Self.shot(frame: frame) },
                                          decide: { _, _, _ in
                                              if revokeSettings { settings.disable() } else { paused = true }
                                              return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                          })
            }
            #expect(throws: ControlError.self) { try Self.invoke(.messageSend, handler: h) }
            #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
            #expect(try h.checkpoints.pending().isEmpty)
        }
    }

    @Test func changedWindowFrameAfterInferenceNeverWritesSelectedRows() throws {
        let (h, fake, _) = try Self.handler(parserMiss: true, method: .messageSend)
        let window = fake.rootHandle
        let frame = try #require(try fake.rootElement.frame())
        var captures = 0
        h.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, imageFrame in captures += 1; return Self.shot(frame: imageFrame) },
                                      decide: { _, _, _ in
                                          fake.mutate(window, attribute: AXAttribute.frame,
                                                      to: .rect(frame.offsetBy(dx: 12, dy: 0)))
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.self) { try Self.invoke(.messageSend, handler: h) }
        #expect(captures == 1 && fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        #expect(try h.checkpoints.pending().isEmpty)
    }

    @Test func changedWeComPIDAfterInferenceNeverWritesEitherWindow() throws {
        let rootBox = RootBox()
        let (h, original, _) = try Self.handler(parserMiss: true, method: .messageSend, rootBox: rootBox)
        let replacement = FakeAXBackend(root: try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath())), pid: 7331)
        let replacementHeader = try #require(try WeComReader(window: replacement.rootElement).layout.activeTitle?.handle)
        replacement.mutate(replacementHeader, attribute: AXAttribute.value, to: .string("同事甲"))
        var captures = 0
        h.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                      decide: { _, _, _ in
                                          rootBox.root = replacement.rootElement
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.self) { try Self.invoke(.messageSend, handler: h) }
        #expect(captures == 1)
        #expect(original.recordedSets.isEmpty && replacement.recordedSets.isEmpty)
        #expect(original.recordedActions.isEmpty && replacement.recordedActions.isEmpty)
        #expect(try h.checkpoints.pending().isEmpty)
    }

    @Test func changedIdentityBridgeAfterInferenceNeverSelectsTheTarget() throws {
        let identities = MutableIdentities()
        let (h, fake, _) = try Self.handler(parserMiss: true, method: .messageSend, identities: identities)
        var captures = 0
        h.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                      settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                      capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                      decide: { _, _, _ in
                                          identities.current.id = "synthetic-b"
                                          return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                      })
        }
        #expect(throws: ControlError.self) { try Self.invoke(.messageSend, handler: h) }
        #expect(captures == 1 && fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        #expect(try h.checkpoints.pending().isEmpty)
    }

    @Test func duplicateOrVanishedRawRowsNeverSelectOrMutate() throws {
        for duplicate in [true, false] {
            let (h, fake, _) = try Self.handler(parserMiss: true, method: .messageSend)
            let table = try #require(fake.handle(atPath: [0, 33, 2, 0]))
            let source = try AXNode.load(from: URL(fileURLWithPath: Fixtures.mainWindowPath()))
            let original = source.children[0].children[33].children[2].children[0].children[2]
            if duplicate {
                let frame = try #require(original.frame?.cgRect)
                let second = AXNode(role: AXRole.row, subrole: "AXTableRow", frame: frame,
                                    children: [AXNode(role: AXRole.cell, frame: frame, children: [
                                        AXNode(role: AXRole.staticText, value: .string("new badge"),
                                               frame: CGRect(x: frame.minX + 1, y: frame.minY + 4, width: 28, height: 16)),
                                        AXNode(role: AXRole.staticText, value: .string(Self.target),
                                               frame: CGRect(x: frame.minX + 60, y: frame.minY + 4, width: 100, height: 16)),
                                    ])])
                _ = fake.appendChild(to: table, node: second)
            }
            var captures = 0
            h.reversibleRunnerFactory = {
                AIPlannerReversibleRunner(beforeRound: { try h.beginVisualRound() },
                                          settingsProvider: { try AIPlannerVisionClientTests.settings() },
                                          capture: { _, frame in captures += 1; return Self.shot(frame: frame) },
                                          decide: { _, _, _ in
                                              if !duplicate { fake.replaceChildren(of: table, with: []) }
                                              return AIPlannerStepDecision(step: .selectRow, candidateID: "C0")
                                          })
            }
            #expect(throws: ControlError.self) { try Self.invoke(.messageSend, handler: h) }
            #expect(captures == (duplicate ? 0 : 1))
            #expect(fake.recordedSets.isEmpty)
            #expect(try h.checkpoints.pending().isEmpty)
        }
    }

    @Test func disabledFullWindowKeepsParsedRowsOnTheZeroUploadFastPath() throws {
        for method in Self.commands {
            let (h, fake, header) = try Self.handler(parserMiss: false, method: method)
            h.visualEnabled = { false }
            var selections = 0, factories = 0
            fake.reactions["set:\(AXAttribute.selectedRows)"] = {
                selections += 1
                fake.mutate(header, attribute: AXAttribute.value, to: .string(Self.target))
            }
            h.reversibleRunnerFactory = {
                factories += 1
                return AIPlannerReversibleRunner(beforeRound: {},
                                                 capture: { _, _ in Issue.record("disabled visual mode must not capture"); return nil })
            }
            try Self.runUntilAction(method, handler: h)
            #expect(selections == 1 && factories == 0)
            #expect(try h.checkpoints.pending().isEmpty)
        }
    }
}
