import AXKit
import CoreGraphics
import Foundation
import Testing
@testable import WeComAdapter

/// Live 2026-09-28 (5.0.11, macOS 27.0): the 添加客户 panel is a second layer-0 window with exactly the
/// main window's frame `(0, 30, 1920×1170)`, its card drawn in the middle. Geometry alone cannot tell the
/// two apart, so the capture refused (`captureUnavailable`); the window numbers before and after this
/// command's own 添加 press can.
@Suite("WeCom window identity")
struct WeComWindowIdentityTests {
    static let frame = CGRect(x: 0, y: 30, width: 1920, height: 1170)
    static let main = WeComWindowIdentity(id: 53452, layer: 0, bounds: frame, onScreen: true)
    static let strip = WeComWindowIdentity(id: 53456, layer: 0, bounds: CGRect(x: 0, y: 30, width: 1920, height: 44), onScreen: true)
    static let toast = WeComWindowIdentity(id: 53462, layer: 8, bounds: CGRect(x: 910, y: 570, width: 100, height: 30), onScreen: false)
    static let panel = WeComWindowIdentity(id: 71603, layer: 0, bounds: frame, onScreen: true)
    static let popup = WeComWindowIdentity(id: 71604, layer: 101, bounds: CGRect(x: 778, y: 542, width: 358, height: 299), onScreen: false)

    static func candidate(_ w: WeComWindowIdentity, pid: pid_t = 1968) -> WeComScreenCapture.WindowCandidate {
        WeComScreenCapture.WindowCandidate(id: w.id, pid: pid, layer: w.layer, frame: w.bounds)
    }

    @Test func thePanelIsTheSameFrameWindowThatAppearedAfterThePress() {
        let before = [Self.main, Self.strip, Self.toast]
        let after = before + [Self.panel, Self.popup]
        #expect(WeComWindowIdentity.newWindow(matching: Self.frame, before: before, after: after) == 71603)
        #expect(WeComWindowIdentity.existingWindow(matching: Self.frame, in: before) == 53452)
    }

    @Test func anythingButOneNewOnScreenLayerZeroMatchIsNoIdentity() {
        let before = [Self.main, Self.strip]
        #expect(WeComWindowIdentity.newWindow(matching: Self.frame, before: before, after: before) == nil)
        let second = WeComWindowIdentity(id: 71605, layer: 0, bounds: Self.frame, onScreen: true)
        #expect(WeComWindowIdentity.newWindow(matching: Self.frame, before: before, after: before + [Self.panel, second]) == nil)
        let hidden = WeComWindowIdentity(id: 71606, layer: 0, bounds: Self.frame, onScreen: false)
        #expect(WeComWindowIdentity.newWindow(matching: Self.frame, before: before, after: before + [hidden]) == nil)
        let floating = WeComWindowIdentity(id: 71607, layer: 3, bounds: Self.frame, onScreen: true)
        #expect(WeComWindowIdentity.newWindow(matching: Self.frame, before: before, after: before + [floating]) == nil)
        let chat = WeComWindowIdentity(id: 71608, layer: 0, bounds: CGRect(x: 480, y: 215, width: 960, height: 800), onScreen: true)
        #expect(WeComWindowIdentity.newWindow(matching: Self.frame, before: before, after: before + [chat]) == nil)
        #expect(WeComWindowIdentity.existingWindow(matching: Self.frame, in: [Self.main, Self.panel]) == nil)
        #expect(WeComWindowIdentity.existingWindow(matching: Self.frame, in: [Self.strip]) == nil)
    }

    /// A panel capture names the proven panel number; the main-window (invite popover) stage names none
    /// and keeps refusing while the stacked panel is open.
    @Test func onlyThePanelStageNamesAWindowNumber() throws {
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-add-customer.json")))
        let windows = try fake.rootElement.elements(AXAttribute.windows)
        let main = try #require(windows.first { ((try? $0.frame())??.minY ?? 1) == 0 })
        var panel = try #require(try AddCustomerPanel.locate(app: fake.rootElement, mainWindow: main))
        #expect(panel.captureWindowID(forPanelWindow: true) == nil)
        panel.windowID = 71603
        panel.parentWindowID = 53452
        #expect(panel.captureWindowID(forPanelWindow: true) == 71603)
        #expect(panel.captureWindowID(forPanelWindow: false) == nil)
    }

    /// The capture's own choice: without an owned number two same-frame windows stay ambiguous (the
    /// live refusal); with one, only that window — same process, layer 0, same frame — is taken.
    @Test func captureTakesTheOwnedWindowNumberOrRefusesTheAmbiguity() {
        let candidates = [Self.main, Self.strip, Self.toast, Self.panel, Self.popup].map { Self.candidate($0) }
        #expect(WeComScreenCapture.chooseWindow(candidates, pid: 1968, expectedFrame: Self.frame, windowID: nil) == nil)
        #expect(WeComScreenCapture.chooseWindow(candidates, pid: 1968, expectedFrame: Self.frame, windowID: 71603) == 71603)
        #expect(WeComScreenCapture.chooseWindow(candidates, pid: 1968, expectedFrame: Self.frame, windowID: 53452) == 53452)
        #expect(WeComScreenCapture.chooseWindow(candidates, pid: 1968, expectedFrame: Self.frame, windowID: 71604) == nil)
        #expect(WeComScreenCapture.chooseWindow(candidates, pid: 1968, expectedFrame: Self.frame, windowID: 53456) == nil)
        #expect(WeComScreenCapture.chooseWindow(candidates, pid: 1968, expectedFrame: Self.frame, windowID: 99999) == nil)
        let foreign = candidates + [Self.candidate(WeComWindowIdentity(id: 88888, layer: 0, bounds: Self.frame, onScreen: true), pid: 42)]
        #expect(WeComScreenCapture.chooseWindow(foreign, pid: 1968, expectedFrame: Self.frame, windowID: 88888) == nil)
        // One same-frame window, as before any panel opens: unchanged behaviour.
        let alone = [Self.main, Self.strip, Self.toast].map { Self.candidate($0) }
        #expect(WeComScreenCapture.chooseWindow(alone, pid: 1968, expectedFrame: Self.frame, windowID: nil) == 53452)
    }
}
