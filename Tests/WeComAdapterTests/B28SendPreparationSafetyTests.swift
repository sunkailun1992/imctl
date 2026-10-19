import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

@Suite("B28 send preparation refuses ambiguous AX evidence")
struct B28SendPreparationSafetyTests {
    private func checkpoints() throws -> FileCheckpointStore {
        try FileCheckpointStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("imctl-b28-\(UUID().uuidString)"))
    }

    private func fakeFile() -> FetchedFile {
        FetchedFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("fixture.pdf"), fileName: "fixture.pdf",
                    bytes: 8, kind: "file", contentType: "application/pdf")
    }

    @Test func outsideEditorCannotDisplaceTheChatComposer() throws {
        let fake = try Fixtures.mainWindow()
        let window = try #require(fake.handle(atPath: [0]))
        fake.appendChild(to: window, node: AXNode(
            role: AXRole.textArea, value: .string(""),
            frame: CGRect(x: 320, y: 110, width: 1580, height: 850),
            settable: [AXAttribute.value]))
        let reader = try WeComReader(window: fake.rootElement)
        #expect(reader.layout.composerAmbiguous == false)
        #expect(reader.layout.composer?.handle == fake.handle(atPath: [0, 33, 6, 0, 2, 0]))
    }

    @Test func twoBottomEditorsRefuseTextAndFileBeforeAnyStaging() throws {
        let fake = GroupFixture.backend()
        fake.appendChild(to: fake.rootHandle, node: AXNode(
            role: AXRole.textArea, value: .string(""),
            frame: CGRect(x: 311, y: 1036, width: 1609, height: 159),
            settable: [AXAttribute.value]))
        let reader = try WeComReader(window: fake.rootElement)
        #expect(reader.layout.composer == nil && reader.layout.composerAmbiguous)
        let cps = try checkpoints()
        let policy = ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                  enabled: [.submit, .sendFile], phase: .phase1)
        var actions = WeComActions(policy: policy)
        let board = RecordingPasteboard()
        actions.pasteboard = board
        actions.postReturnKey = { _, _ in Issue.record("must not submit") }
        actions.postShortcut = { _, _ in Issue.record("must not paste") }
        #expect(throws: ActionError.actionUnavailable("ambiguous composer")) {
            try actions.submit(text: "test", strategy: .enterKey, reader: reader, checkpoints: cps)
        }
        #expect(throws: ActionError.actionUnavailable("ambiguous composer")) {
            try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
        }
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
        #expect(board.snapshots == 0)
        #expect(try cps.pending().isEmpty)
    }

    @Test func humanEditAfterTextReadbackPreventsSubmitAndIsPreserved() throws {
        let fake = try Fixtures.mainWindow()
        let composer = try #require(fake.handle(atPath: [0, 33, 6, 0, 2, 0]))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        var reads = 0
        fake.onRead = { handle, attribute in
            guard handle == composer, attribute == AXAttribute.value else { return }
            reads += 1
            if reads == 3 { fake.mutate(composer, attribute: AXAttribute.value, to: .string("human edit")) }
        }
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                                      enabled: [.submit], phase: .phase1))
        var returns = 0
        actions.postReturnKey = { _, _ in returns += 1 }
        let out = try actions.submit(text: "test", strategy: .enterKey, reader: reader,
                                     checkpoints: cps, timeout: 0.1)
        #expect(out.state == .failed && out.reason == "composer changed before submit" && returns == 0)
        #expect(try AXElement(handle: composer, backend: fake).valueString() == "human edit")
        #expect(fake.recordedSets.filter { $0.handle == composer && $0.attribute == AXAttribute.value }.count == 1)
        #expect(try cps.load(id: out.checkpointID)?.state == .failed)
    }

    @Test func textAppearingDuringFilePasteCannotBeSubmitted() throws {
        let fake = GroupFixture.backend()
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        actions.pasteboard = board
        actions.frontmostPid = { 4242 }
        actions.postShortcut = { _, _ in
            fake.mutate(composer, attribute: AXAttribute.value, to: .string("human draft"))
        }
        var returns = 0
        actions.postReturnKey = { _, _ in returns += 1 }
        #expect(throws: ActionError.localGuard("composer changed while staging attachment")) {
            try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
        }
        #expect(returns == 0 && board.snapshots == 1 && board.restored.count == 1)
        #expect(try AXElement(handle: composer, backend: fake).valueString() == "human draft")
        #expect(try cps.pending().isEmpty)
    }

    @Test func mixedTextAndNativeObjectCannotBeSubmitted() throws {
        let fake = GroupFixture.backend()
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        actions.pasteboard = board
        actions.frontmostPid = { 4242 }
        actions.postShortcut = { _, _ in
            fake.mutate(composer, attribute: AXAttribute.value, to: .string("\u{FFFC}draft"))
            fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .integer(6))
            fake.appendChild(to: composer, node: AXNode(role: AXRole.unknown))
        }
        var returns = 0
        actions.postReturnKey = { _, _ in returns += 1 }
        #expect(throws: ActionError.localGuard("composer changed while staging attachment")) {
            try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
        }
        #expect(returns == 0 && board.restored.count == 1)
        #expect(try cps.pending().isEmpty)
    }

    @Test func multipleObjectsWithEmptyAXValueCannotBeSubmitted() throws {
        for (count, childCount) in [(2, 2), (1, 2)] {
            let fake = GroupFixture.backend()
            let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
            let reader = try WeComReader(window: fake.rootElement)
            let cps = try checkpoints()
            let board = RecordingPasteboard()
            var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                          enabled: [.sendFile], phase: .phase1),
                                       verifyTimeout: 0.1, verifyInterval: 0.01)
            actions.pasteboard = board
            actions.frontmostPid = { 4242 }
            actions.postShortcut = { _, _ in
                fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .integer(count))
                for _ in 0..<childCount { fake.appendChild(to: composer, node: AXNode(role: AXRole.unknown)) }
            }
            var returns = 0
            actions.postReturnKey = { _, _ in returns += 1 }
            #expect(throws: ActionError.localGuard("composer changed while staging attachment")) {
                try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
            }
            #expect(returns == 0 && board.restored.count == 1)
            #expect(try cps.pending().isEmpty)
        }
    }

    @Test func preExistingNativeAttachmentBlocksAnotherPaste() throws {
        let fake = GroupFixture.backend()
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        fake.appendChild(to: composer, node: AXNode(role: AXRole.unknown))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile], phase: .phase1))
        actions.pasteboard = board
        actions.postShortcut = { _, _ in Issue.record("must not paste") }
        #expect(throws: ActionError.localGuard("composer not empty")) {
            try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
        }
        #expect(board.snapshots == 0 && fake.recordedSets.isEmpty)
    }

    @Test func replacementObjectWithoutNativeChildDoesNotSubmit() throws {
        let fake = GroupFixture.backend()
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        actions.pasteboard = board
        actions.pasteTimeout = 0.1
        actions.frontmostPid = { 4242 }
        actions.postShortcut = { _, _ in
            fake.mutate(composer, attribute: AXAttribute.value, to: .string("\u{FFFC}"))
            fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .integer(1))
        }
        var returns = 0
        actions.postReturnKey = { _, _ in returns += 1 }
        let out = try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
        #expect(out.state == .failed && out.details["pasteFailed"] == "true")
        #expect(returns == 0 && board.restored.count == 1)
        #expect(try cps.pending().isEmpty)
    }

    @Test func humanEditAfterFileReturnIsPreservedWhenNoRowAppears() throws {
        let fake = GroupFixture.backend()
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile, .clearComposer], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        actions.pasteboard = board
        actions.frontmostPid = { 4242 }
        actions.postShortcut = { _, _ in fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("1")) }
        actions.postReturnKey = { _, _ in
            fake.mutate(composer, attribute: AXAttribute.value, to: .string("human draft"))
            fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("11"))
        }
        let out = try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps,
                                       timeout: 0.1, pollInterval: 0.02)
        #expect(out.state == .unknown && out.evidence == nil)
        #expect(try AXElement(handle: composer, backend: fake).valueString() == "human draft")
        #expect(try cps.load(id: out.checkpointID)?.state == .unknown)
    }

    @Test func textAppearingAfterPasteSignalStillPreventsReturn() throws {
        let fake = GroupFixture.backend()
        let composer = try #require(fake.handle(atPath: [0, 2, 2, 0]))
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        let board = RecordingPasteboard()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle],
                                                      enabled: [.sendFile], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        actions.pasteboard = board
        actions.frontmostPid = { 4242 }
        actions.postShortcut = { _, _ in
            fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("1"))
        }
        var characterReads = 0
        fake.onRead = { handle, attribute in
            guard handle == composer, attribute == AXAttribute.numberOfCharacters else { return }
            characterReads += 1
            if characterReads == 3 {
                fake.mutate(composer, attribute: AXAttribute.value, to: .string("human draft"))
            }
        }
        var returns = 0
        actions.postReturnKey = { _, _ in returns += 1 }
        let out = try actions.sendFile(fakeFile(), reader: reader, checkpoints: cps)
        #expect(out.state == .failed && out.reason == "attachment staging changed before submit")
        #expect(returns == 0 && board.restored.count == 1)
        #expect(try AXElement(handle: composer, backend: fake).valueString() == "human draft")
        #expect(try cps.load(id: out.checkpointID)?.state == .failed)
    }

    @Test func unreadableMessageRowsAfterReturnRemainUnknown() throws {
        let fake = try Fixtures.mainWindow()
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try checkpoints()
        var actions = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"],
                                                      enabled: [.submit], phase: .phase1),
                                   verifyTimeout: 0.1, verifyInterval: 0.01)
        var returns = 0
        actions.postReturnKey = { _, _ in
            returns += 1
            fake.injectedFailures["get:\(AXAttribute.children)"] = .invalidElement
        }
        let out = try actions.submit(text: "test", strategy: .enterKey, reader: reader,
                                     checkpoints: cps, timeout: 0.1, pollInterval: 0.01)
        #expect(returns == 1 && out.state == .unknown)
        #expect(out.reason == "client evidence unavailable after submit")
        #expect(try cps.load(id: out.checkpointID)?.state == .unknown)
    }
}
