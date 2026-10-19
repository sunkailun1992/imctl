import AXKit
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

@Suite("command-owned child window capture guard")
struct CommandOwnedChildCaptureTests {
    @Test func captureSelectsChildModeOnlyForOneOwnedOverlay() throws {
        let fake = try GroupPickerTests.sheetFixture()
        let window = fake.rootElement
        let frame = try #require(try window.frame())
        let sheet = try #require(try GroupPickerSheet.locate(window: window))
        let done = try #require(sheet.sheet.descendants(maxDepth: 8, maxNodes: 2000).first {
            (try? $0.role()) == AXRole.button && (try? $0.title()) == "完成"
        })
        var modes: [Bool] = []
        var windowIDs: [CGWindowID?] = []
        let fakeCapture: (pid_t, CGRect, Bool, CGWindowID?) -> WeComWindowScreenshot? = { _, _, includeChild, windowID in
            modes.append(includeChild)
            windowIDs.append(windowID)
            return nil
        }
        _ = CommandOwnedChildCapture.capture(window: window, pid: fake.pid, frame: frame,
                                             captureFrame: fakeCapture)
        _ = CommandOwnedChildCapture.capture(window: window, pid: fake.pid, frame: frame,
            ownedOverlay: (AXRole.sheet, sheet.sheet.handle, done.handle), captureFrame: fakeCapture)
        #expect(modes == [false, true])
        // A window number this command proved (B49: the 添加客户 panel) is handed to the capture as is.
        _ = CommandOwnedChildCapture.capture(window: window, pid: fake.pid, frame: frame, windowID: 71603,
                                             captureFrame: fakeCapture)
        #expect(modes == [false, true, false] && windowIDs == [nil, nil, 71603])

        _ = fake.appendChild(to: fake.rootHandle,
            node: AXNode(role: AXRole.popover, frame: CGRect(x: 500, y: 300, width: 200, height: 200)))
        _ = CommandOwnedChildCapture.capture(window: window, pid: fake.pid, frame: frame,
            ownedOverlay: (AXRole.sheet, sheet.sheet.handle, done.handle), captureFrame: fakeCapture)
        #expect(modes == [false, true, false])
    }

    @Test func groupPickerCanEnterFrameOnlyWithItsOwnDoneButtonAndNoOtherOverlay() throws {
        let fake = try GroupPickerTests.sheetFixture()
        let window = fake.rootElement
        let sheet = try #require(try GroupPickerSheet.locate(window: window))
        let done = try #require(sheet.sheet.descendants(maxDepth: 8, maxNodes: 2000).first {
            (try? $0.role()) == AXRole.button && (try? $0.title()) == "完成"
        })
        #expect(CommandOwnedChildCapture.containsOnlyOwnedOverlay(
            in: window, role: AXRole.sheet, overlayHandle: sheet.sheet.handle,
            candidateHandle: done.handle))
        #expect(!CommandOwnedChildCapture.containsOnlyOwnedOverlay(
            in: window, role: AXRole.popover, overlayHandle: sheet.sheet.handle,
            candidateHandle: done.handle))
        #expect(!CommandOwnedChildCapture.containsOnlyOwnedOverlay(
            in: window, role: AXRole.sheet, overlayHandle: sheet.sheet.handle,
            candidateHandle: window.handle))

        _ = fake.appendChild(to: fake.rootHandle,
            node: AXNode(role: AXRole.popover, frame: CGRect(x: 500, y: 300, width: 200, height: 200)))
        #expect(!CommandOwnedChildCapture.containsOnlyOwnedOverlay(
            in: window, role: AXRole.sheet, overlayHandle: sheet.sheet.handle,
            candidateHandle: done.handle))
    }

    @Test func remarkPopoverMustBeTheOnlyOverlayAndContainItsDoneButton() throws {
        let fake = try ContactsFixture.newCustomers()
        let window = fake.rootElement
        let popover = AXNode(role: AXRole.popover, frame: CGRect(x: 600, y: 300, width: 500, height: 420), children: [
            AXNode(role: AXRole.button, title: WeComAcceptPopover.doneTitle,
                   frame: CGRect(x: 620, y: 660, width: 460, height: 40), actions: [AXAction.press])
        ])
        let handle = try #require(fake.appendChild(to: fake.rootHandle, node: popover))
        let done = try #require(window.descendants(maxDepth: 14, maxNodes: 6000).first {
            (try? $0.role()) == AXRole.button && (try? $0.title()) == WeComAcceptPopover.doneTitle
        })
        #expect(CommandOwnedChildCapture.containsOnlyOwnedOverlay(
            in: window, role: AXRole.popover, overlayHandle: handle,
            candidateHandle: done.handle))
        _ = fake.appendChild(to: fake.rootHandle,
            node: AXNode(role: AXRole.sheet, frame: CGRect(x: 400, y: 300, width: 200, height: 200)))
        #expect(!CommandOwnedChildCapture.containsOnlyOwnedOverlay(
            in: window, role: AXRole.popover, overlayHandle: handle,
            candidateHandle: done.handle))
    }
}
