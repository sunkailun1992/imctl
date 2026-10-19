import CoreGraphics
import Foundation
import Testing
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// Records what the send-file action does to the clipboard instead of touching NSPasteboard.
final class RecordingPasteboard: PasteboardHandling {
    var snapshots = 0
    var restored: [[[String: Data]]] = []
    var fileURLs: [URL] = []
    var contents: [[String: Data]] = [["public.utf8-plain-text": Data("the person's clipboard".utf8)]]
    func snapshot() -> [[String: Data]] { snapshots += 1; return contents }
    func setFileURL(_ url: URL) { fileURLs.append(url); contents = [["public.file-url": Data(url.absoluteString.utf8)]] }
    func matchesFileURL(_ url: URL) -> Bool {
        contents == [["public.file-url": Data(url.absoluteString.utf8)]]
    }
    func restore(_ snapshot: [[String: Data]]) { restored.append(snapshot); contents = snapshot }
}

@Suite("Pasteboard abstraction")
struct PasteboardTests {
    @Test func actionsDefaultToTheGeneralPasteboardAndAThreeSecondPasteTimeout() {
        let a = WeComActions(policy: ActionPolicy(allowedTargets: ["文件传输助手"]))
        #expect(a.pasteboard is GeneralPasteboard && a.pasteTimeout == 3)
        let recorder = RecordingPasteboard()
        let snap = recorder.snapshot()
        recorder.setFileURL(URL(fileURLWithPath: "/tmp/x.pdf"))
        recorder.restore(snap)
        #expect(recorder.contents == snap && recorder.fileURLs.count == 1)
    }
}

@Suite("WeComActions.sendFile on the group fixture")
struct SendFileTests {
    let composerPath = [0, 2, 2, 0]
    let tablePath = GroupFixture.messageTablePath

    struct Harness {
        let fake: FakeAXBackend
        let reader: WeComReader
        let checkpoints: FileCheckpointStore
        let pasteboard: RecordingPasteboard
        var actions: WeComActions
        var shortcuts: [KeystrokeInjector.Shortcut] = []
        var returns = 0
        var box = Box()
    }

    func harness(landPaste: Bool, appendRow: Bool, rowKind: String = "media", rowFileName: String = "a.pdf",
                 inbound: Bool = false, unknownDirection: Bool = false,
                 failTableReadAfterReturn: Bool = false) throws -> Harness {
        let fake = GroupFixture.backend()
        let reader = try WeComReader(window: fake.rootElement)
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-sendfile-\(UUID().uuidString)"))
        let pb = RecordingPasteboard()
        var a = WeComActions(policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.sendFile, .clearComposer], phase: .phase1), verifyTimeout: 0.3, verifyInterval: 0.02)
        a.pasteboard = pb
        a.pasteTimeout = 0.3
        a.frontmostPid = { 4242 }          // the fake's pid: nothing to bring to front or hand back
        a.restoreFrontmost = { _ in }
        let composer = try #require(fake.handle(atPath: composerPath))
        let table = try #require(fake.handle(atPath: tablePath))
        let box = Box()
        a.postShortcut = { key, _ in
            box.shortcuts.append(key)
            if landPaste { fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("1")) }
        }
        a.postReturnKey = { _, _ in
            box.returns += 1
            box.armFailure = failTableReadAfterReturn
            fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .string("0"))
            guard appendRow else { return }
            var rows = GroupFixture.defaultMessages()
            let y: CGFloat = 454
            // The table spans x 310…1921, so a chip near its right edge is outbound and one near the left
            // is inbound (`DirectionInference`).
            let iconX: CGFloat = inbound ? 380 : 1851
            let nameX: CGFloat = inbound ? 480 : 1657
            let anchorX: CGFloat = unknownDirection ? 1070 : iconX
            let cellChildren: [AXNode]
            switch rowKind {
            case "file":
                cellChildren = [AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: anchorX, y: y + 19, width: 42, height: 42)),
                                GroupFixture.text(rowFileName, x: unknownDirection ? 1070 : nameX, y: y + 19, w: 100, h: 20),
                                GroupFixture.text("3B", x: unknownDirection ? 1070 : nameX, y: y + 45, w: 24)]
            case "video":
                cellChildren = [AXNode(role: AXRole.image, description: "wwsecurity play action play 40",
                                       frame: CGRect(x: anchorX, y: y + 19, width: 60, height: 60))]
            default:
                cellChildren = [AXNode(role: AXRole.image, frame: CGRect(x: anchorX, y: y + 19, width: 60, height: 60))]
            }
            rows.append(AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: y, width: 1609, height: rowKind == "file" ? 82 : 200), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: y, width: 1609, height: rowKind == "file" ? 82 : 200), children: cellChildren),
            ]))
            fake.replaceChildren(of: table, with: rows + [AXNode(role: "AXColumn", frame: CGRect(x: 311, y: 64, width: 1609, height: 931))])
        }
        // Finding F1: the client is mid-render when the confirm loop polls, so ONE read of the message table
        // after the Return fails. `onRead` runs before the fake's own failure check, so arming the injection
        // from there makes exactly that read throw; every other read clears it again.
        if failTableReadAfterReturn {
            fake.onRead = { element, name in
                fake.injectedFailures["get:\(AXAttribute.children)"] = nil
                guard box.armFailure, !box.failedOnce, element == table, name == AXAttribute.children else { return }
                box.failedOnce = true
                fake.injectedFailures["get:\(AXAttribute.children)"] = .invalidElement
            }
        }
        var h = Harness(fake: fake, reader: reader, checkpoints: cps, pasteboard: pb, actions: a)
        h.box = box
        return h
    }

    final class Box {
        var shortcuts: [KeystrokeInjector.Shortcut] = []
        var returns = 0
        var armFailure = false
        var failedOnce = false
    }

    func file(_ name: String = "a.pdf", kind: String = "file") throws -> FetchedFile {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-sf-\(UUID().uuidString)-\(name)")
        try Data("%PDF-1.4".utf8).write(to: url)
        return FetchedFile(url: url, fileName: name, bytes: 8, kind: kind, contentType: "application/pdf")
    }

    @Test func pasteThenReturnProducesANewFileRowAndRestoresTheClipboard() throws {
        var h = try harness(landPaste: true, appendRow: true, rowKind: "file")
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .succeeded && out.strategy == "paste-enter")
        #expect(out.evidence?.contains("kind=file") == true && out.evidence?.contains("dir=outbound") == true)
        #expect(h.box.shortcuts == [.commandV] && h.box.returns == 1)
        #expect(h.pasteboard.snapshots == 1 && h.pasteboard.fileURLs.count == 1 && h.pasteboard.restored.count == 1)
        #expect(h.pasteboard.contents == [["public.utf8-plain-text": Data("the person's clipboard".utf8)]])
        #expect(try h.checkpoints.load(id: out.checkpointID)?.state == .succeeded)
        #expect(out.details["pasteFailed"] == nil && out.details["fileName"] == "a.pdf")
    }

    @Test func aPictureRowIsEvidenceToo() throws {
        var h = try harness(landPaste: true, appendRow: true, rowKind: "media")
        let out = try h.actions.sendFile(try file("p.png", kind: "image"), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .succeeded && out.evidence?.contains("kind=media") == true
                && out.evidence?.contains("dir=outbound") == true)
    }

    @Test func nativeReplacementObjectStagesOnePictureAndSubmitsOnce() throws {
        var h = try harness(landPaste: false, appendRow: true, rowKind: "media")
        let composer = try #require(h.fake.handle(atPath: composerPath))
        h.actions.postShortcut = { _, _ in
            h.fake.mutate(composer, attribute: AXAttribute.value, to: .string("\u{FFFC}"))
            h.fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .integer(1))
            h.fake.appendChild(to: composer, node: AXNode(role: AXRole.unknown))
        }
        let out = try h.actions.sendFile(try file("p.png", kind: "image"), reader: h.reader,
                                         checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .succeeded && out.evidence?.contains("kind=media") == true)
        #expect(h.box.returns == 1 && h.pasteboard.restored.count == 1)
        #expect(try h.checkpoints.load(id: out.checkpointID)?.state == .succeeded)
    }

    @Test(arguments: ["media", "video"])
    func incomingOrUnplacedMediaCannotConfirmOurSend(rowKind: String) throws {
        for (inbound, unknownDirection) in [(true, false), (false, true)] {
            let h = try harness(landPaste: true, appendRow: true, rowKind: rowKind,
                                inbound: inbound, unknownDirection: unknownDirection)
            let out = try h.actions.sendFile(try file(rowKind == "video" ? "v.mp4" : "p.png",
                                                     kind: rowKind == "media" ? "image" : "video"),
                                             reader: h.reader, checkpoints: h.checkpoints,
                                             timeout: 0.1, pollInterval: 0.02)
            #expect(out.state == .unknown)
            #expect(out.evidence == nil)
        }
    }

    @Test func partialBaselineStopsBeforePasteAndReturn() throws {
        let h = try harness(landPaste: true, appendRow: true, rowKind: "file")
        let body = try #require(h.fake.handle(atPath: tablePath + [0, 0, 0]))
        h.fake.onRead = { handle, attribute in
            guard attribute == AXAttribute.value else { return }
            h.fake.injectedFailures["get:AXValue"] = handle == body
                ? .apiFailure(code: -25201, operation: "get AXValue") : nil
        }
        #expect(throws: ActionError.actionUnavailable("incomplete message baseline")) {
            try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints,
                                   timeout: 0.1, pollInterval: 0.02)
        }
        #expect(h.box.shortcuts.isEmpty && h.box.returns == 0)
        #expect(h.pasteboard.snapshots == 0)
    }

    @Test func outboundWrongAttachmentKindCannotConfirmThisSend() throws {
        let pdf = try harness(landPaste: true, appendRow: true, rowKind: "media")
        let pdfOut = try pdf.actions.sendFile(try file(), reader: pdf.reader, checkpoints: pdf.checkpoints,
                                              timeout: 0.1, pollInterval: 0.02)
        #expect(pdfOut.state == .unknown)

        let video = try harness(landPaste: true, appendRow: true, rowKind: "video")
        let videoOut = try video.actions.sendFile(try file("v.mp4", kind: "video"), reader: video.reader,
                                                  checkpoints: video.checkpoints, timeout: 0.5, pollInterval: 0.02)
        #expect(videoOut.state == .succeeded && videoOut.evidence?.contains("kind=video") == true)
    }

    @Test func switchingConversationAfterReturnCannotConfirmTheOldTarget() throws {
        let h = try harness(landPaste: true, appendRow: true, rowKind: "file")
        let title = try #require(h.reader.layout.activeTitle)
        let hooks = SubmitHooks(afterIrreversible: {
            h.fake.mutate(title.handle, attribute: AXAttribute.value, to: .string("文件传输助手"))
        })
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints,
                                         timeout: 0.1, pollInterval: 0.02, hooks: hooks)
        #expect(out.state == .unknown)
        #expect(out.reason?.contains("active conversation changed") == true)
        #expect(try h.checkpoints.load(id: out.checkpointID)?.state == .unknown)
    }

    @Test func prependedIdenticalMediaCannotLookNew() throws {
        let fake = GroupFixture.backend(messages: [])
        let frame = CGRect(x: 1800, y: 200, width: 60, height: 60)
        let row = MessageRow(index: 0, kind: .media, text: nil, timeLabel: nil, bodyFrame: frame,
                             direction: .outbound, senderLabel: nil, frame: frame, handle: fake.rootHandle)
        let older = MessageRow(index: 0, kind: .media, text: nil, timeLabel: nil, bodyFrame: frame,
                               direction: .outbound, senderLabel: nil, frame: frame, handle: fake.rootHandle)
        #expect(SendEvidence.newRows(baseline: [row], observed: [older, row]).isEmpty)
    }

    @Test func pasteThatNeverLandsFailsWithoutAReturnAndLeavesUnprovenComposerAlone() throws {
        var h = try harness(landPaste: false, appendRow: true)
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .failed && out.details["pasteFailed"] == "true" && out.reason?.contains("did not appear") == true)
        #expect(h.box.shortcuts == [.commandV] && h.box.returns == 0)
        #expect(h.pasteboard.restored.count == 1)
        #expect(try h.checkpoints.pending().isEmpty)
        #expect(h.fake.recordedSets.allSatisfy { $0.attribute != AXAttribute.value })
    }

    @Test func noRowAfterReturnIsUnknownAndDoesNotClearTheAttachment() throws {
        var h = try harness(landPaste: true, appendRow: false)
        // Return does not empty the composer in this variant: the chip is still there.
        h.actions.postReturnKey = { _, _ in }
        let stuck = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 0.2, pollInterval: 0.02)
        #expect(stuck.state == .unknown && stuck.reason?.contains("no new media") == true)
        #expect(try h.checkpoints.load(id: stuck.checkpointID)?.state == .unknown)
        #expect(h.fake.recordedSets.allSatisfy { $0.attribute != AXAttribute.value })
        // Composer emptied, no row: unknown, left alone.
        var h2 = try harness(landPaste: true, appendRow: false)
        let composer2 = try #require(h2.fake.handle(atPath: composerPath))
        h2.actions.postReturnKey = { _, _ in h2.fake.mutate(composer2, attribute: AXAttribute.numberOfCharacters, to: .string("0")) }
        let gone = try h2.actions.sendFile(try file(), reader: h2.reader, checkpoints: h2.checkpoints, timeout: 0.2, pollInterval: 0.02)
        #expect(try gone.state == .unknown && h2.checkpoints.load(id: gone.checkpointID)?.state == .unknown)
    }

    @Test func nativeAttachmentWithoutAnOutboundRowRemainsUnknownAndUntouched() throws {
        var h = try harness(landPaste: false, appendRow: false)
        let composer = try #require(h.fake.handle(atPath: composerPath))
        h.actions.postShortcut = { _, _ in
            h.fake.mutate(composer, attribute: AXAttribute.value, to: .string("\u{FFFC}"))
            h.fake.mutate(composer, attribute: AXAttribute.numberOfCharacters, to: .integer(1))
            h.fake.appendChild(to: composer, node: AXNode(role: AXRole.unknown))
        }
        h.actions.postReturnKey = { _, _ in h.box.returns += 1 }
        let out = try h.actions.sendFile(try file("p.png", kind: "image"), reader: h.reader,
                                         checkpoints: h.checkpoints, timeout: 0.1, pollInterval: 0.02)
        #expect(out.state == .unknown && h.box.returns == 1)
        #expect(try AXElement(handle: composer, backend: h.fake).valueString() == "\u{FFFC}")
        #expect(h.fake.recordedSets.allSatisfy { $0.attribute != AXAttribute.value })
        #expect(try h.checkpoints.load(id: out.checkpointID)?.state == .unknown)
    }

    @Test func guardsBeforeAnythingIsPasted() throws {
        var h = try harness(landPaste: true, appendRow: true)
        let composer = try #require(h.fake.handle(atPath: composerPath))
        h.fake.mutate(composer, attribute: AXAttribute.value, to: .string("human draft"))
        #expect(throws: ActionError.localGuard("composer not empty")) { try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints) }
        #expect(h.pasteboard.snapshots == 0 && h.box.shortcuts.isEmpty)
        var phase0 = try harness(landPaste: true, appendRow: true)
        phase0.actions.policy.phase = .phase0
        #expect(throws: PolicyError.phaseForbids(.sendFile)) { try phase0.actions.sendFile(try file(), reader: phase0.reader, checkpoints: phase0.checkpoints) }
    }

    /// Finding A: a throw from the paste step (⌘V delivery itself, inside `withFront`) must still restore the
    /// person's clipboard exactly once — the bug left the pasted file URL on the clipboard on every throwing path.
    @Test func pasteboardIsRestoredWhenThePasteStepThrows() throws {
        var h = try harness(landPaste: true, appendRow: true)
        h.actions.postShortcut = { _, _ in throw ControlError.internalError("boom") }
        #expect(throws: ControlError.internalError("boom")) {
            try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        }
        #expect(h.pasteboard.restored.count == 1)
        #expect(h.pasteboard.contents == [["public.utf8-plain-text": Data("the person's clipboard".utf8)]])
        #expect(h.box.returns == 0)
    }

    @Test func clipboardReplacementWhileRefocusingNeverPastesTheWrongFile() throws {
        var h = try harness(landPaste: true, appendRow: true)
        let board = h.pasteboard
        let newerClipboard = [["public.utf8-plain-text": Data("new human copy".utf8)]]
        var frontChecks = 0
        h.actions.frontmostPid = {
            frontChecks += 1
            if frontChecks == 2 { board.contents = newerClipboard }
            return 4242
        }
        #expect(throws: ActionError.localGuard("clipboard changed before attachment paste")) {
            try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints)
        }
        #expect(frontChecks >= 2)
        #expect(h.box.shortcuts.isEmpty && h.box.returns == 0)
        #expect(board.contents == newerClipboard && board.restored.isEmpty)
        #expect(try h.checkpoints.pending().isEmpty)
    }

    /// Finding F1: a transient AX error AFTER the irreversible Return used to escape `sendFile`, and the
    /// executor maps `AXKitError` → `CLIENT_UNAVAILABLE` → `failed` — so a consumer would have re-sent a file
    /// that was already on its way. The poll is skipped instead, and the row that appears on the next one
    /// still settles the outcome.
    @Test func anAXErrorOnTheConfirmPollNeverTurnsASentFileIntoFailed() throws {
        let h = try harness(landPaste: true, appendRow: true, rowKind: "file", failTableReadAfterReturn: true)
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(h.box.failedOnce, "the injected AX failure never fired")
        #expect(out.state == .succeeded || out.state == .unknown, "state was \(out.state)")
        #expect(h.box.returns == 1)
    }

    /// Finding F2: evidence is a NEW OUTBOUND row whose name is the one we pasted (§6.43). An inbound file
    /// row with another name arriving right after the Return is somebody else's message, not proof.
    @Test func onlyAnOutboundRowWithThePastedNameCountsAsEvidence() throws {
        let inboundOther = try harness(landPaste: true, appendRow: true, rowKind: "file", rowFileName: "other.pdf", inbound: true)
        let notEvidence = try inboundOther.actions.sendFile(try file(), reader: inboundOther.reader, checkpoints: inboundOther.checkpoints,
                                                            timeout: 0.2, pollInterval: 0.02)
        #expect(notEvidence.state == .unknown && notEvidence.reason?.contains("composer emptied") == true)
        #expect(try inboundOther.checkpoints.load(id: notEvidence.checkpointID)?.state == .unknown)

        // An outbound row is still not evidence when it carries somebody else's file name.
        let outboundOther = try harness(landPaste: true, appendRow: true, rowKind: "file", rowFileName: "other.pdf")
        let wrongName = try outboundOther.actions.sendFile(try file(), reader: outboundOther.reader, checkpoints: outboundOther.checkpoints,
                                                           timeout: 0.2, pollInterval: 0.02)
        #expect(wrongName.state == .unknown)

        // The outbound row with the pasted name is.
        let ours = try harness(landPaste: true, appendRow: true, rowKind: "file", rowFileName: "a.pdf")
        let out = try ours.actions.sendFile(try file(), reader: ours.reader, checkpoints: ours.checkpoints, timeout: 1, pollInterval: 0.02)
        #expect(out.state == .succeeded && out.evidence?.contains("dir=outbound") == true && out.evidence?.contains("kind=file") == true)
    }

    /// `beforeIrreversible` / `afterIrreversible` must bracket the one Return exactly.
    @Test func hooksBracketTheReturn() throws {
        final class Recorder { var events: [String] = [] }
        let recorder = Recorder()
        let hooks = SubmitHooks(
            beforeIrreversible: { recorder.events.append("before") },
            afterIrreversible: { recorder.events.append("after") }
        )
        var h = try harness(landPaste: true, appendRow: true, rowKind: "file")
        let out = try h.actions.sendFile(try file(), reader: h.reader, checkpoints: h.checkpoints, timeout: 1, pollInterval: 0.02, hooks: hooks)
        #expect(out.state == .succeeded)
        #expect(recorder.events == ["before", "after"])
        #expect(h.box.returns == 1)
    }
}
