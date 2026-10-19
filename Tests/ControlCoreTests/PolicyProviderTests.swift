import Foundation
import Testing
@testable import ControlCore

@Suite("PolicyProvider")
struct PolicyProviderTests {
    @Test func reloadsOnlyWhenTheFileChangesAndKeepsLastGoodOnParseError() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-pp-\(UUID().uuidString)/policy.json")
        let provider = PolicyProvider(url: url)
        #expect(provider.current().isEmpty && provider.reloadIfChanged() == nil)
        var p = SendPolicy(); p.allow(.title("imctl测试群"))
        try p.save(to: url)
        let changed = try #require(provider.reloadIfChanged())
        #expect(changed.allowedTitles == ["imctl测试群"] && provider.current() == changed)
        #expect(provider.reloadIfChanged() == nil)
        // same size, later mtime: still detected
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(provider.reloadIfChanged() != nil)
        try Data("{broken".utf8).write(to: url)
        #expect(provider.reloadIfChanged() == nil)
        #expect(provider.current().allowedTitles == ["imctl测试群"] && provider.lastError != nil)
    }

    /// B52 readiness reads policy and parse state from the socket queue while the watcher reloads on the
    /// main run loop: both must come from one locked read.
    @Test func snapshotReturnsPolicyAndReadabilityTogether() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-pp-\(UUID().uuidString)/policy.json")
        var p = SendPolicy(); p.allow(.title("imctl测试群"))
        try p.save(to: url)
        let provider = PolicyProvider(url: url)
        #expect(provider.snapshot().readable && provider.snapshot().policy.allowedTitles == ["imctl测试群"])
        try Data("{broken".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        _ = provider.reloadIfChanged()
        let broken = provider.snapshot()
        #expect(!broken.readable && broken.policy.allowedTitles == ["imctl测试群"])
    }

    /// Task 8 review: with no phone list any more, a file that does not parse must not fall back to the
    /// default caps — contact.add stays off until the file parses (a broken file never widens anything).
    @Test func contactAddCapsAreZeroWhileTheFileDoesNotParse() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-pp-\(UUID().uuidString)/policy.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: url)
        let provider = PolicyProvider(url: url)
        let broken = provider.contactAddCaps()
        #expect(broken.adds == 0 && broken.searches == 0)
        var p = SendPolicy(); p.contactAdd.maxAddsPerHour = 5; p.contactAdd.maxSearchesPerHour = 7
        try p.save(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        _ = provider.reloadIfChanged()
        let parsed = provider.contactAddCaps()
        #expect(parsed.adds == 5 && parsed.searches == 7)
    }
}
