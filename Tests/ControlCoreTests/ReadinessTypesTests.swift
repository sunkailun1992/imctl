import Foundation
import Testing
@testable import ControlCore

@Suite("Readiness types")
struct ReadinessTypesTests {
    @Test func reportRoundTripsThroughJSON() throws {
        let report = ReadinessReport(
            ready: false,
            nextStep: ReadinessFix(text: "打开企业微信并登录", command: "open -b com.tencent.WeWorkMac"),
            nextStepCapability: "wecom",
            capabilities: [ReadinessCapability(id: "wecom", title: "企业微信", required: true, status: .fail,
                                               checks: [ReadinessCheck(id: "running", status: .fail, detail: "没有运行")],
                                               fix: ReadinessFix(text: "打开企业微信并登录", command: "open -b com.tencent.WeWorkMac"),
                                               warnings: ["w"])],
            online: ReadinessOnlineInfo(state: "running", testedMs: nil, nextRefreshAllowedMs: 60_000),
            version: "1.0.15-dev", generatedMs: 42)
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(ReadinessReport.self, from: data) == report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"status\":\"fail\"") && text.contains("\"state\":\"running\""))
    }

    @Test func probeResultsCarryOnlyACategory() {
        #expect(ReadinessProbeResult.success(latencyMs: 12) == ReadinessProbeResult(ok: true, category: nil, latencyMs: 12))
        #expect(ReadinessProbeResult.failure("timeout", latencyMs: 9).category == "timeout")
        let start = Date(timeIntervalSince1970: 100)
        #expect(ReadinessProbeResult.elapsedMs(since: start, now: Date(timeIntervalSince1970: 100.25)) == 250)
        #expect(ReadinessProbeResult.elapsedMs(since: start, now: Date(timeIntervalSince1970: 99)) == 0)
    }

    @Test func commandsKeepImctlWhenItIsOnPath() {
        #expect(ReadinessCommandText.substitute("imctl setup", cli: "imctl") == "imctl setup")
    }

    @Test func commandsGetTheFullPathOtherwise() {
        let cli = "/Apps/imctl.app/Contents/MacOS/imctl"
        #expect(ReadinessCommandText.substitute("imctl setup", cli: cli) == "\(cli) setup")
        #expect(ReadinessCommandText.substitute("pbpaste | imctl vision set --provider qwen --secret-stdin", cli: cli)
                == "pbpaste | \(cli) vision set --provider qwen --secret-stdin")
        #expect(ReadinessCommandText.substitute("open -b com.tencent.WeWorkMac", cli: cli) == "open -b com.tencent.WeWorkMac")
        #expect(ReadinessCommandText.substitute("imctl setup", cli: "/tmp/my dir/imctl") == "\"/tmp/my dir/imctl\" setup")
    }

    @Test func factsDefaultToAHealthyCore() {
        let f = ReadinessFacts(version: "v")
        #expect(f.accessibilityTrusted && f.clientRunning && f.wecomData == "granted" && f.policy.autoAccept == "off")
        #expect(!f.vision.config.present && !f.mqtt.config.present && !f.agents.claude.registered)
    }
}
