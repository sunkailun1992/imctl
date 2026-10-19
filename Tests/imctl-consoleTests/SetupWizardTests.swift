import Foundation
import Testing
@testable import ControlCore
@testable import imctl_console

@Suite("Setup wizard")
@MainActor
struct SetupWizardTests {
    static func report(_ statuses: [String: ReadinessStatus], ready: Bool = false) -> ReadinessReport {
        ReadinessReport(ready: ready, nextStep: nil, nextStepCapability: nil,
                        capabilities: statuses.map { ReadinessCapability(id: $0.key, title: $0.key, required: false, status: $0.value, checks: []) },
                        online: ReadinessOnlineInfo(state: "skipped"), version: "v", generatedMs: 1)
    }

    @Test func onlySelectedFeaturesGetASteps() {
        var w = SetupWizard()
        #expect(w.steps == [.install, .wecom, .sendScope, .features, .finish])
        w.selected = [.vision, .agents]
        #expect(w.steps == [.install, .wecom, .sendScope, .features, .configure(.agents), .configure(.vision), .finish])
    }

    @Test func theApplyStepAppearsOnlyAfterASaveThatNeedsARestart() {
        var w = SetupWizard(); w.selected = [.agents, .mqtt]
        w.featureSaved(.agents)
        #expect(!w.steps.contains(.apply))
        w.featureSaved(.mqtt)
        #expect(w.steps.suffix(2) == [.apply, .finish])
        w.applied()
        #expect(!w.steps.contains(.apply))
    }

    @Test func skippingARequiredStepIsRemembered() {
        var w = SetupWizard()
        w.skip(); w.skip(); w.skip()
        #expect(w.skipped == [.install, .wecom] && w.current == .features)
        w.back()
        #expect(w.current == .sendScope)
    }

    @Test func doneIsReadFromTheReport() {
        let fine = Self.report(["daemon": .ok, "read": .ok, "media": .ok, "wecom": .ok, "agents": .ok, "mqtt": .fail, "oss": .disabled])
        #expect(SetupWizard.isDone(.install, report: fine) && SetupWizard.isDone(.wecom, report: fine))
        #expect(SetupWizard.isDone(.configure(.agents), report: fine) && SetupWizard.isDone(.configure(.mqtt), report: fine))
        #expect(!SetupWizard.isDone(.configure(.oss), report: fine))
        #expect(!SetupWizard.isDone(.install, report: Self.report(["daemon": .ok, "read": .fail, "media": .ok])))
        #expect(!SetupWizard.isDone(.install, report: nil) && SetupWizard.isDone(.sendScope, report: nil))
    }

    @Test func configuredFeaturesArePreselected() {
        let r = Self.report(["agents": .ok, "mqtt": .fail, "vision": .disabled, "oss": .disabled, "wecomApi": .ok])
        #expect(SetupWizard.preselected(r) == [.agents, .mqtt, .proxy])
        #expect(SetupWizard.preselected(nil).isEmpty)
    }

    @Test func theWizardOpensByItselfOnlyBeforeItWasEverClosed() {
        #expect(SetupWizard.shouldAutoOpen(report: nil, flagDone: false))
        #expect(!SetupWizard.shouldAutoOpen(report: Self.report([:], ready: true), flagDone: false))
        #expect(!SetupWizard.shouldAutoOpen(report: nil, flagDone: true))
    }

    @Test func closingMarksDoneAndReopeningStartsOver() async {
        let name = "imctl-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        await model.openWizard()
        model.wizard.next(); model.wizard.next()
        model.closeWizard(defaults: defaults)
        #expect(!model.wizardPresented && SetupWizard.flagDone(defaults))
        await model.openWizard()
        #expect(model.wizardPresented && model.wizard.index == 0)
    }

    @Test func aConfirmedReinstallClearsTheApplyStep() async {
        let model = ConsoleModel()
        model.socketPathOverride = "/tmp/imctl-none-\(UUID().uuidString.prefix(8))/s.sock"
        model.performOverride = { _ in }
        model.restartWaitPolls = 0
        model.wizard.selected = [.oss]
        model.wizard.featureSaved(.oss)
        await model.requestAction(ReadinessAction(.reinstallDaemon))
        await model.confirmPendingAction()
        #expect(!model.wizard.needsApply)
    }
}
