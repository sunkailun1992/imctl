import AXKit
import ControlCore
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

/// The handler must actually install B43's passive rounds on an external
/// group.create, while the executor keeps AX evidence and checkpoint semantics.
@Suite("B43 group creation through handler and visual runner")
struct B43GroupCreateHandlerIntegrationTests {
    private final class Trace {
        var captures = 0
        var modelRequests = 0
        var phases: [AIPlannerPhase] = []
        var returns = 0
        var donePresses = 0
        var cancelPresses = 0
    }

    private struct Result {
        let record: CommandRecord
        let trace: Trace
        let createdEvents: Int
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

    private static func run(stopBeforeDone: Bool, createNewGroupEvidence: Bool) throws -> Result {
        let (fake, sheetNode) = try GroupPickerTests.closedSheetFixture()
        let original = try GroupPickerTests.sheetFixture()
        let originalSheet = try #require(try GroupPickerSheet.locate(window: original.rootElement))
        let customer = try #require(originalSheet.customers.first?.name)
        let colleague = try #require(try originalSheet.rows().last?.name)
        let members = [customer, colleague]
        let rowByName = [customer: try GroupPickerTests.rowNode(named: customer),
                         colleague: try GroupPickerTests.rowNode(named: colleague)]
        let trace = Trace()
        var doneHandle: AXElementHandle?
        var cancelHandle: AXElementHandle?
        fake.reactions["set:\(AXAttribute.value)"] = {
            guard case .string(let typed)? = fake.recordedSets.last?.value,
                  let row = rowByName[typed],
                  let sheet = try? GroupPickerSheet.locate(window: fake.rootElement) else { return }
            fake.replaceChildren(of: sheet.outline.handle, with: [row])
        }
        fake.reactions["action:\(AXAction.press)"] = {
            guard let pressed = fake.recordedActions.last?.handle,
                  let sheet = try? GroupPickerSheet.locate(window: fake.rootElement) else { return }
            if pressed == doneHandle {
                trace.donePresses += 1
                if createNewGroupEvidence {
                    try? GroupPickerTests.showCreatedGroup(fake, sheet: sheet,
                        title: "\(customer)、\(colleague)、我",
                        header: "\(customer)、\(colleague)、我(3)")
                } else if let parent = try? sheet.sheet.parent() {
                    fake.removeChild(sheet.sheet.handle, from: parent.handle)
                }
            } else if pressed == cancelHandle {
                trace.cancelPresses += 1
                if let parent = try? sheet.sheet.parent() {
                    fake.removeChild(sheet.sheet.handle, from: parent.handle)
                }
            }
        }

        let settings = try AIPlannerVisionClientTests.settings()
        let checkpoints = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b43-handler-\(UUID().uuidString)"))
        let handler = WeComCommandHandler(rootProvider: { fake.rootElement },
            policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                 enabled: [.openGroupPicker, .createGroup], phase: .phase1),
            checkpoints: checkpoints)
        handler.visualEnabled = { true }
        handler.visualScreenRecordingGranted = { true }
        handler.visualSettingsForCommit = { settings }
        handler.visualSelect = { _, _, _, _, _, _ in
            Issue.record("one exact Done button must not need a model choice")
            return nil
        }
        handler.configureActions = { action in
            action.verifyTimeout = 0.05
            action.verifyInterval = 0.005
            action.groupOpenTimeout = 0.05
            action.frontmostPid = { nil }
            action.openURL = { _ in true }
            action.postShortcut = { shortcut, _ in
                #expect(shortcut == .commandN)
                _ = fake.appendChild(to: fake.rootHandle, node: sheetNode)
                let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
                doneHandle = sheet.doneButton?.handle
                cancelHandle = sheet.cancelButton?.handle
            }
            action.postReturnKey = { _, _ in
                trace.returns += 1
                let sheet = try #require(try GroupPickerSheet.locate(window: fake.rootElement))
                let selectedTable = try #require(sheet.selectedTable?.handle)
                let typed = try #require(try sheet.searchField?.valueString())
                fake.appendChild(to: selectedTable, node: GroupPickerTests.selectedRowNode(
                    named: typed, y: 388 + 36 * CGFloat(trace.returns)))
                if let doneHandle {
                    fake.mutate(doneHandle, attribute: AXAttribute.enabled, to: .bool(true))
                }
            }
        }
        handler.reversibleRunnerFactory = {
            AIPlannerReversibleRunner(beforeRound: { try handler.beginVisualRound() },
                settingsProvider: { settings },
                capture: { _, frame in
                    trace.captures += 1
                    return Self.shot(frame: frame)
                },
                decide: { observation, context, currentSettings in
                    #expect(context.method == .groupCreate)
                    #expect(context.allowedSteps == [.verify, .reobserve, .stop])
                    trace.phases.append(context.phase)
                    let content = stopBeforeDone && trace.phases.count == 1
                        ? #"{"step":"stop"}"# : #"{"step":"verify"}"#
                    let client = AIPlannerStepClient { request in
                        trace.modelRequests += 1
                        #expect(request.url?.host == "dashscope.aliyuncs.com")
                        let requestBody = try #require(request.httpBody)
                        let jsonObject = try JSONSerialization.jsonObject(with: requestBody)
                        let body = try #require(jsonObject as? [String: Any])
                        #expect(body["model"] as? String == "qwen3.7-plus")
                        let messages = try #require(body["messages"] as? [[String: Any]])
                        let parts = try #require(messages.first?["content"] as? [[String: Any]])
                        #expect(parts.count == 2 && parts[1]["image_url"] != nil)
                        return (AIPlannerVisionClientTests.rawResponse(content, provider: .qwen),
                                AIPlannerVisionClientTests.http(request))
                    }
                    return try client.decide(observation: observation,
                                             context: context, settings: currentSettings)
                })
        }

        let store = try ControlStore(path: ":memory:")
        let executor = CommandExecutor(store: store, handler: handler, rateLimiter: nil)
        let key = "b43-handler-\(UUID().uuidString)"
        let params = try String(decoding: JSONEncoder().encode(GroupCreateParams(
            members: members, idempotencyKey: key)), as: UTF8.self)
        let record = try executor.submit(method: .groupCreate, paramsJSON: params,
                                         idempotencyKey: key)
        let createdEvents = try store.events(after: 0, limit: 100)
            .filter { $0.kind == .groupCreated }.count
        return Result(record: record, trace: trace, createdEvents: createdEvents)
    }

    @Test func modelStopBeforeDoneNeverCrossesCheckpoint() throws {
        let result = try Self.run(stopBeforeDone: true, createNewGroupEvidence: true)
        #expect(result.record.state == .failed && result.record.checkpointMs == nil)
        #expect(result.trace.captures == 1 && result.trace.modelRequests == 1
                && result.trace.phases == [.prepare])
        #expect(result.trace.returns == 2 && result.trace.donePresses == 0)
        #expect(result.trace.cancelPresses == 1 && result.createdEvents == 0)
    }

    @Test func verifiedModelRoundsStillNeedNewGroupAXEvidence() throws {
        let success = try Self.run(stopBeforeDone: false, createNewGroupEvidence: true)
        #expect(success.record.state == .succeeded && success.record.checkpointMs != nil)
        #expect(success.trace.captures == 2 && success.trace.modelRequests == 2
                && success.trace.phases == [.prepare, .verify])
        #expect(success.trace.returns == 2 && success.trace.donePresses == 1)
        #expect(success.createdEvents == 1)

        let absent = try Self.run(stopBeforeDone: false, createNewGroupEvidence: false)
        #expect(absent.record.state == .unknown && absent.record.checkpointMs != nil)
        #expect(absent.trace.captures == 1 && absent.trace.modelRequests == 1
                && absent.trace.phases == [.prepare])
        #expect(absent.trace.donePresses == 1 && absent.createdEvents == 0)
    }
}
