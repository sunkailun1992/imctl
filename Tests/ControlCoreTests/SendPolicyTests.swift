import Foundation
import Testing
@testable import ControlCore

@Suite("SendPolicy (policy.json)")
struct SendPolicyTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("imctl-policy-\(UUID().uuidString)/policy.json")
    }

    @Test func missingFileIsEmptyPolicyAndSaveIsPrivate() throws {
        let url = tempURL()
        let loaded = try SendPolicy.load(from: url)
        #expect(loaded == SendPolicy() && loaded.isEmpty)
        var p = SendPolicy()
        p.allow(.title("imctl测试群")); p.allow(.type(.group)); p.allow(.chatId("wr1")); p.allow(.externalUserId("wm1"))
        p.allow(.title("imctl测试群"))   // idempotent
        try p.save(to: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        let back = try SendPolicy.load(from: url)
        #expect(back.allowedTitles == ["imctl测试群"] && back.allowedTypes.group && !back.allowedTypes.customer)
        #expect(back.allowedChatIds == ["wr1"] && back.allowedExternalUserIds == ["wm1"])
        #expect(back.summary == "titles=1 types=group chatIds=1 externalUserIds=1 requests=off/off")
        var d = back
        d.deny(.type(.group)); d.deny(.title("imctl测试群")); d.deny(.chatId("nope"))
        #expect(d.allowedTitles.isEmpty && !d.allowedTypes.group && d.allowedChatIds == ["wr1"])
    }

    @Test func malformedFileThrowsInsteadOfAllowing() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try SendPolicy.load(from: url) }
    }

    @Test func unknownTypeIsNeverAllowedByType() {
        var t = AllowedTypes(); t.group = true; t.customer = true; t.internal = true
        #expect(t.allows(.group) && t.allows(.customer) && t.allows(.internal) && !t.allows(.unknown))
    }

    @Test func contactRequestsRoundTripAndDefaultForOldFiles() throws {
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data(#"{"allowedTitles":["a"],"allowedTypes":{"group":false,"customer":false,"internal":false},"allowedChatIds":[],"allowedExternalUserIds":[]}"#.utf8))
        #expect(old.contactRequests == ContactRequestPolicy() && old.summary.hasSuffix("requests=off/off"))
        var p = SendPolicy(); p.contactRequests.autoAccept = .rules; p.contactRequests.groupDefaultMembers = ["同事A"]; p.contactRequests.autoGroup = .perPerson
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SendPolicy.self, from: data)
        #expect(back.contactRequests.autoAccept == .rules && back.contactRequests.groupDefaultMembers == ["同事A"] && back.summary.hasSuffix("requests=rules/perPerson"))
    }

    /// User 2026-09-16: the group name is 客户名 + 群聊 by default and configurable as a template.
    @Test func readGateDefaultsToOpenAndRoundTrips() throws {
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data("{}".utf8))
        #expect(!old.gateReads && !old.remoteEdits)
        var p = SendPolicy(); p.gateReads = true
        let encoded = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SendPolicy.self, from: encoded)
        #expect(back.gateReads && String(decoding: encoded, as: UTF8.self).contains("\"gateReads\":true"))
    }

    @Test func groupNameComesFromTheTemplateWithSuffixFallback() throws {
        var r = ContactRequestPolicy()
        #expect(r.groupName(for: "测试联系人A") == "测试联系人A群聊" && r.groupNameTemplate == "{客户名}群聊")
        r.groupNameTemplate = "{客户名}-售后"
        #expect(r.groupName(for: "测试联系人A") == "测试联系人A-售后")
        r.groupNameTemplate = "客户群"; r.groupNameSuffix = "的群"   // no placeholder: legacy suffix rule
        #expect(r.groupName(for: "测试联系人A") == "测试联系人A的群")
        let decoded = try JSONDecoder().decode(ContactRequestPolicy.self, from: Data(#"{"autoAccept":"off"}"#.utf8))
        #expect(decoded.groupNameTemplate == "{客户名}群聊")
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data(#"{"allowedTitles":["a"]}"#.utf8))
        #expect(!old.remoteEdits && old.allowedTitles == ["a"])
    }

    /// B14 (user 2026-09-22 「全部放开」): absent key decodes false (old files unaffected), round trips,
    /// and the summary gains a trailing `allowAll=true` only when it is on.
    @Test func allowAllDefaultsToFalseAndRoundTrips() throws {
        let old = try JSONDecoder().decode(SendPolicy.self, from: Data("{}".utf8))
        #expect(!old.allowAll)
        var p = SendPolicy(); p.allowAll = true
        let encoded = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SendPolicy.self, from: encoded)
        #expect(back.allowAll && String(decoding: encoded, as: UTF8.self).contains("\"allowAll\":true"))
        #expect(back.summary.hasSuffix("allowAll=true"))
        #expect(SendPolicy().summary == "titles=0 types=- chatIds=0 externalUserIds=0 requests=off/off")
    }
}
