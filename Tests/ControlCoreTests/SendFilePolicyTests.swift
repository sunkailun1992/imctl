import Foundation
import Testing
@testable import ControlCore

@Suite("SendFilePolicy (policy.json sendFile)")
struct SendFilePolicyTests {
    @Test func emptyListRefusesEverythingAndOnlyHttpsPasses() throws {
        var p = SendFilePolicy()
        #expect(p.allowedHosts.isEmpty && p.maxBytes == 104_857_600 && !p.allows(host: "h.example"))
        #expect(p.rejection(for: URL(string: "https://h.example/a.pdf")!)?.contains("allowedHosts") == true)
        p.allow("H.Example"); p.allow("h.example")   // normalised, idempotent
        #expect(p.allowedHosts == ["h.example"] && p.allows(host: "h.example") && p.rejection(for: URL(string: "https://h.example/a.pdf")!) == nil)
        #expect(p.rejection(for: URL(string: "http://h.example/a.pdf")!)?.contains("https") == true)
        p.allow(".aliyuncs.com")
        #expect(p.allows(host: "bucket.oss-cn-hangzhou.aliyuncs.com") && !p.allows(host: "aliyuncs.com") && !p.allows(host: "evil-aliyuncs.com"))
        p.deny("h.example")
        #expect(p.allowedHosts == [".aliyuncs.com"] && p.summary == "hosts=1 maxBytes=104857600")
    }

    @Test func sendPolicyRoundTripsAndDefaultsForOldFiles() throws {
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data("{}".utf8))
        #expect(old.sendFile == SendFilePolicy())
        var p = SendPolicy(); p.sendFile.allow("cdn.example"); p.sendFile.maxBytes = 10
        let back = try JSONDecoder().decode(SendPolicy.self, from: try JSONEncoder().encode(p))
        #expect(back.sendFile.allowedHosts == ["cdn.example"] && back.sendFile.maxBytes == 10)
    }

    @Test func allowAndDenyNormaliseTheStoredEntriesToo() throws {
        // A person hand-edits policy.json with browser-bar casing; the CLI must still recognise and revoke it.
        var p = try JSONDecoder().decode(SendFilePolicy.self, from: Data(#"{"allowedHosts":["CDN.Example"," .Aliyuncs.COM "]}"#.utf8))
        #expect(p.allows(host: "cdn.example"))
        p.allow("cdn.example")
        #expect(p.allowedHosts.count == 2)          // recognised as already present, not appended
        p.deny("cdn.example")
        #expect(p.allowedHosts == [" .Aliyuncs.COM "] && !p.allows(host: "cdn.example"))
        p.deny(".aliyuncs.com")
        #expect(p.allowedHosts.isEmpty)
    }
}
