import AXKit
import CoreGraphics
import Testing
import WeComAdapter
@testable import imctld

@Suite("daemon watcher availability across WeCom tabs")
struct DaemonWatcherAvailabilityTests {
    private static let missingConversationTable = WeComError.region("conversationTable")

    private static func contactsRoot(includeOutline: Bool = true,
                                     includeSignature: Bool = true,
                                     trusted: Bool = true) -> FakeAXBackend {
        let frame = CGRect(x: 0, y: 30, width: 1_200, height: 800)
        let row = AXNode(role: AXRole.row, frame: CGRect(x: 60, y: 94, width: 250, height: 36),
                         children: [AXNode(role: AXRole.cell, frame: CGRect(x: 60, y: 94, width: 250, height: 36),
                                           children: [AXNode(role: AXRole.textArea,
                                                             value: .string(WeComContactsView.newCustomersTitle),
                                                             frame: CGRect(x: 104, y: 102, width: 70, height: 20))])])
        let signature = AXNode(role: AXRole.row, frame: CGRect(x: 60, y: 132, width: 250, height: 36),
                               children: [AXNode(role: AXRole.cell, children: [
                                   AXNode(role: AXRole.textArea, value: .string("智能机器人"),
                                          frame: CGRect(x: 104, y: 140, width: 70, height: 20)),
                               ])])
        let outline = AXNode(role: AXRole.outline, frame: CGRect(x: 60, y: 90, width: 250, height: 740),
                             settable: [AXAttribute.selectedRows],
                             children: [row] + (includeSignature ? [signature] : []))
        let window = AXNode(role: AXRole.window, frame: frame,
                            children: (includeOutline ? [outline] : [])
                                + (!includeOutline && includeSignature
                                   ? [AXNode(role: AXRole.staticText, value: .string("智能机器人"))] : []))
        return FakeAXBackend(root: AXNode(role: AXRole.application, children: [window]), trusted: trusted)
    }

    /// Live 2026-09-29: another client window in front — e.g. `contact.add`'s 添加客户 panel (same
    /// frame as the main window) or its 发送验证申请 window — is the app's main window, listed first,
    /// while the main window behind it still shows 通讯录. That is the reachable contacts pane.
    @Test(arguments: [CGRect(x: 0, y: 30, width: 1_200, height: 800), CGRect(x: 420, y: 230, width: 360, height: 403)])
    func anotherClientWindowInFrontOfTheContactsPaneKeepsTheClientAvailable(front: CGRect) throws {
        let fake = Self.contactsRoot()
        _ = fake.prependChild(to: fake.rootHandle, node: Self.frontWindow(frame: front))
        #expect(try fake.rootElement.element(AXAttribute.mainWindow)?.frame() == front)
        var tracker = AvailabilityTracker(threshold: 2)
        #expect(tracker.failed(Self.missingConversationTable) == .degraded(count: 1))
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .available)
        #expect(tracker.consecutiveFailures == 0)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    /// A window in front of a main window that is not on 通讯录 changes nothing: the failure counts.
    @Test func anotherClientWindowInFrontOfAnotherPaneStillCountsTheFailure() {
        let fake = Self.contactsRoot(includeOutline: false, includeSignature: false)
        _ = fake.prependChild(to: fake.rootHandle, node: Self.frontWindow(frame: CGRect(x: 0, y: 30, width: 1_200, height: 800)))
        var tracker = AvailabilityTracker(threshold: 2)
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .degraded(count: 1))
    }

    private static func frontWindow(frame: CGRect) -> AXNode {
        AXNode(role: AXRole.window, subrole: "AXStandardWindow", frame: frame, children: [
            AXNode(role: AXRole.textField, value: .string(""), frame: CGRect(x: frame.midX - 100, y: frame.midY, width: 200, height: 30),
                   settable: [AXAttribute.value]),
            AXNode(role: AXRole.button, subrole: "AXCloseButton", frame: CGRect(x: frame.minX + 8, y: frame.minY + 7, width: 12, height: 14),
                   actions: [AXAction.press]),
        ])
    }

    @Test func contactsPaneClearsAccumulatedFailuresWithoutAXMutation() {
        let fake = Self.contactsRoot()
        var tracker = AvailabilityTracker(threshold: 3)
        #expect(tracker.failed(WeComError.region("incomplete message AXValue")) == .degraded(count: 1))
        #expect(tracker.failed(Self.missingConversationTable) == .degraded(count: 2))
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .available)
        #expect(tracker.consecutiveFailures == 0)
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func signatureTextWithoutSelectableOutlineDoesNotMaskFailure() {
        let fake = Self.contactsRoot(includeOutline: false)
        var tracker = AvailabilityTracker(threshold: 2)
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .degraded(count: 1))
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .unavailable(Self.missingConversationTable.description))
        #expect(fake.recordedSets.isEmpty && fake.recordedActions.isEmpty)
    }

    @Test func missingWindowAndTrustFailureStillPauseImmediately() {
        let noWindow = FakeAXBackend(root: AXNode(role: AXRole.application))
        var first = AvailabilityTracker(threshold: 10)
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { noWindow.rootElement },
                                                  tracker: &first) == .unavailable(WeComError.noWindow.description))

        let denied = Self.contactsRoot(trusted: false)
        var second = AvailabilityTracker(threshold: 10)
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { denied.rootElement },
                                                  tracker: &second) == .unavailable(AXKitError.notTrusted.description))

        let invalidFrame = FakeAXBackend(root: AXNode(role: AXRole.application, children: [
            AXNode(role: AXRole.window, frame: .zero, children: [
                AXNode(role: AXRole.staticText, value: .string(WeComContactsView.newCustomersTitle)),
                AXNode(role: AXRole.staticText, value: .string("智能机器人")),
            ]),
        ]))
        var third = AvailabilityTracker(threshold: 10)
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { invalidFrame.rootElement },
                                                  tracker: &third) == .unavailable(WeComError.noWindow.description))
        #expect(noWindow.recordedSets.isEmpty && denied.recordedSets.isEmpty)
    }

    @Test func AXReadFailureAndOtherWatcherErrorsRetainOriginalThreshold() {
        let fake = Self.contactsRoot()
        fake.injectedFailures["get:\(AXAttribute.role)"] = .cannotComplete("get AXRole")
        var tracker = AvailabilityTracker(threshold: 2)
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .degraded(count: 1))
        #expect(DaemonWatcher.availabilityVerdict(after: Self.missingConversationTable,
                                                  rootProvider: { fake.rootElement },
                                                  tracker: &tracker) == .unavailable(AXKitError.cannotComplete("get AXRole").description))

        let complete = Self.contactsRoot()
        var ordinary = AvailabilityTracker(threshold: 2)
        #expect(DaemonWatcher.availabilityVerdict(after: WeComError.region("incomplete message AXValue"),
                                                  rootProvider: { complete.rootElement },
                                                  tracker: &ordinary) == .degraded(count: 1))
    }
}
