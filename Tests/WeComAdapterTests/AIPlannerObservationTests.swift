import AppKit
import AXKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WeComAdapter

@Suite("AI planner bounded observation")
struct AIPlannerObservationTests {
    static let windowFrame = CGRect(x: 50, y: 30, width: 200, height: 140)

    static func fixture() -> (FakeAXBackend, AXElement) {
        let row = AXNode(role: AXRole.row, title: "测试会话", frame: CGRect(x: 60, y: 50, width: 65, height: 24))
        let table = AXNode(role: AXRole.table, frame: CGRect(x: 55, y: 45, width: 80, height: 90),
                           settable: [AXAttribute.selectedRows], children: [row])
        let button = AXNode(role: AXRole.button, title: "发送", frame: CGRect(x: 180, y: 135, width: 48, height: 22),
                            actions: [AXAction.press])
        let field = AXNode(role: AXRole.textArea, frame: CGRect(x: 137, y: 113, width: 85, height: 20),
                           settable: [AXAttribute.value])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: windowFrame,
                                              children: [table, button, field]))
        return (fake, fake.rootElement)
    }

    static func shot() -> WeComWindowScreenshot {
        let width = 300, height = 200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(windowFrame)
        return WeComWindowScreenshot(image: context.makeImage()!,
                                     windowFrame: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func observation() throws -> AIPlannerObservation {
        let (_, window) = fixture()
        return try AIPlannerObservation.capture(window: window, expectedPID: 4242,
                                                 capture: { _, _ in shot() })
    }

    @Test func discoversOnlyActionableAXElementsAndRevalidates() throws {
        let (fake, window) = Self.fixture()
        let observation = try AIPlannerObservation.capture(window: window, expectedPID: 4242,
                                                            capture: { _, _ in Self.shot() })
        #expect(observation.candidates.count == 3)
        #expect(Set(observation.candidates.map(\.kind)) == Set([.selectRow, .press, .writeText]))
        #expect(observation.candidates.map(\.id) == ["C0", "C1", "C2"])
        let button = try #require(observation.candidates.first { $0.kind == .press })
        #expect(try observation.revalidate(candidateID: button.id, in: window)?.element.handle == button.element.handle)
        #expect(try observation.revalidate(candidateID: "C999", in: window) == nil)
        fake.mutate(button.element.handle, attribute: AXAttribute.frame,
                    to: .rect(CGRect(x: 160, y: 135, width: 48, height: 22)))
        #expect(try observation.revalidate(candidateID: button.id, in: window) == nil)
    }

    @Test func neverCapturesWrongWindowOrPID() throws {
        let (_, window) = Self.fixture()
        var called = false
        do {
            _ = try AIPlannerObservation.capture(window: window, expectedPID: 9999,
                                                  capture: { _, _ in called = true; return Self.shot() })
            Issue.record("Wrong PID was accepted")
        } catch let error as AIPlannerVisionError {
            #expect(error == .staleView)
        }
        #expect(!called)
    }

    @Test func cropsDisplaySizedCaptureBeforeEncoding() throws {
        let observation = try Self.observation()
        let source = try #require(CGImageSourceCreateWithData(observation.imageJPEG as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 200 && image.height == 140)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
        // The red display surround must never enter the uploaded JPEG.
        for (x, y) in [(2, 2), (100, 70), (197, 137)] {
            let i = (y * image.width + x) * 4
            #expect(Int(bytes[i + 1]) > Int(bytes[i]) * 2)
        }
    }

    @Test func rejectsCaptureThatDoesNotContainVerifiedWindow() throws {
        let (fake, window) = Self.fixture()
        let bad = WeComWindowScreenshot(image: Self.shot().image,
                                        windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
        do {
            _ = try AIPlannerObservation.capture(window: window, expectedPID: fake.pid,
                                                  capture: { _, _ in bad })
            Issue.record("Mismatched image geometry was accepted")
        } catch let error as AIPlannerVisionError {
            #expect(error == .captureUnavailable)
        }
    }

    @Test func missingScreenPermissionOrCaptureFailsClosed() throws {
        let (_, window) = Self.fixture()
        do {
            // The injected nil is the same return path as a denied Screen
            // Recording preflight in WeComScreenCapture.capture.
            _ = try AIPlannerObservation.capture(window: window, expectedPID: 4242,
                                                  capture: { _, _ in nil })
            Issue.record("Unavailable screen capture was accepted")
        } catch let error as AIPlannerVisionError {
            #expect(error == .captureUnavailable)
        }
    }

    @Test func excessiveCandidateCountFailsBeforeScreenshot() throws {
        let buttons = (0..<65).map { _ in
            AXNode(role: AXRole.button, frame: CGRect(x: 80, y: 60, width: 30, height: 20),
                   actions: [AXAction.press])
        }
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: Self.windowFrame,
                                               children: buttons))
        var captured = false
        do {
            _ = try AIPlannerObservation.capture(window: fake.rootElement, expectedPID: fake.pid,
                                                  capture: { _, _ in captured = true; return Self.shot() })
            Issue.record("Truncated candidate set was accepted")
        } catch let error as AIPlannerVisionError {
            #expect(error == .invalidCandidates)
        }
        #expect(!captured)
    }

    @Test func eligibleHandleScopeExcludesOtherRowsAndDetectsSameFrameLabelChange() throws {
        let (fake, window) = Self.fixture()
        let button = try #require(fake.element(atPath: [1]))
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: fake.pid, allowedKinds: [.press],
            eligibleHandles: [button.handle], capture: { _, _ in Self.shot() }
        )
        #expect(observation.candidates.count == 1)
        #expect(observation.candidates.first?.element.handle == button.handle)
        let id = try #require(observation.candidates.first?.id)
        #expect(try observation.revalidate(candidateID: id, in: window)?.element.handle == button.handle)
        // The AX object and geometry may be reused for a different control.
        fake.mutate(button.handle, attribute: AXAttribute.title, to: .string("取消"))
        #expect(try observation.revalidate(candidateID: id, in: window) == nil)
    }

    @Test func eligibleScopeCanFindOneTargetPastSixtyFourUnrelatedButtons() throws {
        let buttons = (0..<65).map { index in
            AXNode(role: AXRole.button, title: "button-\(index)",
                   frame: CGRect(x: 80, y: 60, width: 30, height: 20), actions: [AXAction.press])
        }
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: Self.windowFrame,
                                               children: buttons))
        let last = try #require(fake.element(atPath: [64]))
        let observation = try AIPlannerObservation.capture(
            window: fake.rootElement, expectedPID: fake.pid, allowedKinds: [.press],
            eligibleHandles: [last.handle], capture: { _, _ in Self.shot() }
        )
        #expect(observation.candidates.count == 1)
        #expect(observation.candidates.first?.element.handle == last.handle)
    }

    @Test func eligibleRowPastTheWholeWindowNodeLimitStillCapturesAndRevalidates() throws {
        let unrelated = (0..<1_900).map { index in
            AXNode(role: AXRole.staticText, value: .string("unrelated-\(index)"),
                   frame: CGRect(x: 60, y: 60, width: 30, height: 18))
        }
        let row = AXNode(role: AXRole.row, frame: CGRect(x: 60, y: 50, width: 65, height: 24),
                         children: [AXNode(role: AXRole.staticText, value: .string("新的客户"),
                                           frame: CGRect(x: 65, y: 52, width: 50, height: 18))])
        let outline = AXNode(role: AXRole.outline, frame: CGRect(x: 55, y: 45, width: 80, height: 90),
                             settable: [AXAttribute.selectedRows], children: [row])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: Self.windowFrame,
                                               children: unrelated + [outline]))
        let target = try #require(fake.element(atPath: [unrelated.count, 0]))
        let observation = try AIPlannerObservation.capture(
            window: fake.rootElement, expectedPID: fake.pid, allowedKinds: [.selectRow],
            eligibleHandles: [target.handle], capture: { _, _ in Self.shot() }
        )
        #expect(observation.candidates.count == 1)
        #expect(observation.candidates[0].element.handle == target.handle)
        #expect(try observation.revalidate(candidateID: "C0", in: fake.rootElement)?.element.handle == target.handle)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func eligibleHandleFromAnotherWindowFailsBeforeScreenshot() throws {
        let target = AXNode(role: AXRole.button, title: "打开", frame: CGRect(x: 80, y: 60, width: 40, height: 20),
                            actions: [AXAction.press])
        let first = AXNode(role: AXRole.window, frame: Self.windowFrame)
        let second = AXNode(role: AXRole.window, frame: Self.windowFrame, children: [target])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.application, children: [first, second]))
        let window = try #require(fake.element(atPath: [0]))
        let foreign = try #require(fake.element(atPath: [1, 0]))
        var captured = false
        #expect(throws: AIPlannerVisionError.invalidCandidates) {
            try AIPlannerObservation.capture(
                window: window, expectedPID: fake.pid, allowedKinds: [.press],
                eligibleHandles: [foreign.handle], capture: { _, _ in captured = true; return Self.shot() }
            )
        }
        #expect(!captured)
    }

    @Test func textAreaDescriptionFailureKeepsValueBoundToRowChoice() throws {
        let label = AXNode(role: AXRole.textArea, value: .string("新的客户"),
                           frame: CGRect(x: 65, y: 52, width: 50, height: 18))
        let cell = AXNode(role: AXRole.cell, frame: CGRect(x: 60, y: 50, width: 65, height: 24),
                          children: [label])
        let row = AXNode(role: AXRole.row, frame: CGRect(x: 60, y: 50, width: 65, height: 24),
                         children: [cell])
        let outline = AXNode(role: AXRole.outline, frame: CGRect(x: 55, y: 45, width: 80, height: 90),
                             settable: [AXAttribute.selectedRows], children: [row])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: Self.windowFrame,
                                               children: [outline]))
        let rowHandle = try #require(fake.handle(atPath: [0, 0]))
        let labelHandle = try #require(fake.handle(atPath: [0, 0, 0, 0]))
        fake.onRead = { handle, attribute in
            guard attribute == AXAttribute.description else { return }
            if handle == labelHandle {
                fake.injectedFailures["get:\(AXAttribute.description)"] =
                    .apiFailure(code: -25200, operation: "get AXDescription")
            } else {
                fake.injectedFailures.removeValue(forKey: "get:\(AXAttribute.description)")
            }
        }
        let observation = try AIPlannerObservation.capture(
            window: fake.rootElement, expectedPID: fake.pid, allowedKinds: [.selectRow],
            eligibleHandles: [rowHandle], capture: { _, _ in Self.shot() }
        )
        #expect(observation.candidates.count == 1)
        #expect(try observation.revalidate(candidateID: "C0", in: fake.rootElement) != nil)
        fake.mutate(labelHandle, attribute: AXAttribute.value, to: .string("其他客户"))
        #expect(try observation.revalidate(candidateID: "C0", in: fake.rootElement) == nil)
    }

    @Test func disabledWritableScrollBarIsAllowedButDisabledButtonIsNot() throws {
        let bar = AXNode(role: AXRole.scrollBar, value: .number(0.5),
                         frame: CGRect(x: 215, y: 40, width: 12, height: 110), enabled: false,
                         settable: [AXAttribute.value])
        let button = AXNode(role: AXRole.button, title: "发送",
                            frame: CGRect(x: 140, y: 135, width: 48, height: 22),
                            enabled: false, actions: [AXAction.press])
        let fake = FakeAXBackend(root: AXNode(role: AXRole.window, frame: Self.windowFrame,
                                               children: [bar, button]))
        let observation = try AIPlannerObservation.capture(window: fake.rootElement,
                                                            expectedPID: fake.pid,
                                                            capture: { _, _ in Self.shot() })
        #expect(observation.candidates.map(\.kind) == [.scroll])
        let id = try #require(observation.candidates.first?.id)
        fake.mutate(try #require(fake.handle(atPath: [0])), attribute: AXAttribute.value, to: .double(0.6))
        #expect(try observation.revalidate(candidateID: id, in: fake.rootElement) == nil)
    }

    @Test func changedWindowOrConversationTitleRefusesModelChoice() throws {
        let group = GroupFixture.backend()
        let window = group.rootElement
        let frame = try #require(try window.frame())
        let context = try #require(CGContext(data: nil, width: 1920, height: 1200,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(frame)
        let image = try #require(context.makeImage())
        let observation = try AIPlannerObservation.capture(
            window: window, expectedPID: group.pid, expectedTitle: GroupFixture.groupTitle,
            allowedKinds: [.writeText],
            capture: { _, _ in WeComWindowScreenshot(image: image, windowFrame: frame) }
        )
        let id = try #require(observation.candidates.first?.id)
        let title = try #require(try WeComReader(window: window).layout.activeTitle)
        group.mutate(title.handle, attribute: AXAttribute.value, to: .string("其他测试群(3)"))
        do {
            _ = try observation.revalidate(candidateID: id, in: window)
            Issue.record("Changed conversation title was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .staleView) }
        group.mutate(title.handle, attribute: AXAttribute.value, to: .string("\(GroupFixture.groupTitle)(3)"))
        group.mutate(window.handle, attribute: AXAttribute.frame,
                     to: .rect(CGRect(x: 5, y: 0, width: 1920, height: 1200)))
        do {
            _ = try observation.revalidate(candidateID: id, in: window)
            Issue.record("Changed window frame was accepted")
        } catch let error as AIPlannerVisionError { #expect(error == .staleView) }
    }
}
