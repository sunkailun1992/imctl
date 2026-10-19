import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AXKit
@testable import ControlCore
@testable import WeComAdapter

/// B10 step 2: pictures come from the client's cache; a message is tied to a file by observation time or by the
/// time labels around it in the open conversation.
@Suite("Media route (index, store, message.media)", .serialized)
struct MediaRouteTests {
    /// A container with two profiles, the current one named by setting.json, holding pictures at given instants.
    func container(pictures: [(id: String, at: Date, hd: Bool)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-container-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let profiles = root.appendingPathComponent("Documents/Profiles", isDirectory: true)
        let current = "D8682F25E08A9B27FB6D096B03712294", old = "A42E010F7DA34283D3CC292410D16D8E"
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent(old + "/Caches/Images/2024-02"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent(current + "/Caches/Images"), withIntermediateDirectories: true)
        try #"{"CurrentProfile":"\#(current)"}"#.write(to: profiles.appendingPathComponent("setting.json"), atomically: true, encoding: .utf8)
        let jpeg = try Self.jpeg(width: 40, height: 30)
        for p in pictures {
            let month = profiles.appendingPathComponent("\(current)/Caches/Images/2026-09", isDirectory: true)
            for suffix in p.hd ? ["", "_HD"] : [""] {
                let dir = month.appendingPathComponent(p.id + suffix, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent(p.id + suffix)
                try (suffix.isEmpty ? jpeg : try Self.jpeg(width: 400, height: 300)).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: p.at], ofItemAtPath: file.path)
            }
        }
        return root
    }

    static func jpeg(width: Int, height: Int) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func pictureCacheNameCannotOverrideItsVerifiedFormat() throws {
        #expect(try WeComCommandHandler.pictureDisplayName(cacheName: "cache.png", signature: "jpeg") == "cache.jpg")
        #expect(try WeComCommandHandler.pictureDisplayName(cacheName: "cache.jpeg", signature: "jpeg") == "cache.jpeg")
        #expect(try WeComCommandHandler.pictureDisplayName(cacheName: "cache.dat", signature: "heic") == "cache.dat.heic")
        #expect(throws: ControlError.self) { try WeComCommandHandler.pictureDisplayName(cacheName: "cache.mp4", signature: "mp4") }
    }

    /// A file read stuck behind the system prompt must not hold the socket: the caller gets a retryable error.
    @Test func aBlockedFileAccessTurnsIntoARetryableErrorAfterTheGrantTimeout() throws {
        let previous = WeComCommandHandler.fileGrantTimeout
        WeComCommandHandler.fileGrantTimeout = 0.05
        defer { WeComCommandHandler.fileGrantTimeout = previous }
        let release = DispatchSemaphore(value: 0)
        do {
            _ = try WeComCommandHandler.withFileGrantTimeout("test") { release.wait(); return 1 }
            Issue.record("expected a timeout")
        } catch let e as ControlError {
            #expect(e.code == "MEDIA_NOT_FOUND" && e.message.contains("access data from other apps"))
        }
        release.signal()
        #expect(try WeComCommandHandler.withFileGrantTimeout("test") { 42 } == 42)
        #expect(throws: ControlError.self) { try WeComCommandHandler.withFileGrantTimeout("test") { throw ControlError.mediaNotFound("inner") } }
    }

    @Test func timeLabelsBecomeInstants() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 10, minute: 30))!
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))! }
        #expect(MessageTimeLabel.parse("9:32", now: now) == at(2026, 9, 16, 9, 32))
        #expect(MessageTimeLabel.parse("昨天 21:37", now: now) == at(2026, 9, 15, 21, 37))
        #expect(MessageTimeLabel.parse("前天 09:06", now: now) == at(2026, 9, 14, 9, 6))
        #expect(MessageTimeLabel.parse("下午 3:05", now: now) == at(2026, 9, 16, 15, 5))
        #expect(MessageTimeLabel.parse("9月15日 21:37", now: now) == at(2026, 9, 15, 21, 37))
        #expect(MessageTimeLabel.parse("2025年9月15日 21:37", now: now) == at(2025, 9, 15, 21, 37))
        #expect(MessageTimeLabel.parse("12月30日 8:00", now: now) == at(2025, 12, 30, 8, 0))   // in the future → last year
        #expect(MessageTimeLabel.parse("星期一 21:37", now: now) == at(2026, 9, 14, 21, 37))   // 2026-09-16 is a Wednesday
        #expect(MessageTimeLabel.parse("周三 8:00", now: now) == at(2026, 9, 9, 8, 0))        // same weekday → a week ago
        #expect(MessageTimeLabel.parse("刚刚", now: now) == nil && MessageTimeLabel.parse("", now: now) == nil && MessageTimeLabel.parse("abc 12:00", now: now) == nil)
    }

    @Test func indexRemembersObservationsAndAssignmentsAcrossReloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-index-\(UUID().uuidString.prefix(8))/media-index.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = MediaIndex(fileURL: url)
        index.observe(messageKey: "k1", conversation: "c", direction: "inbound", nowMs: 1000)
        index.observe(messageKey: "k1", conversation: "c", direction: "inbound", nowMs: 2000)   // first sighting wins
        index.observe(messageKey: "", conversation: "c", direction: "inbound", nowMs: 3000)
        let file = MediaCacheFile(root: "container", path: "a/b", size: 1, modifiedMs: 900, kind: "image", signature: "jpeg")
        index.assign(messageKey: "k1", file: file, matchedBy: "observed", nowMs: 1100)
        let reloaded = MediaIndex(fileURL: url)
        #expect(reloaded.observation(for: "k1")?.observedMs == 1000 && reloaded.assignment(for: "k1")?.file == file && reloaded.count == (1, 1))
        #expect(reloaded.assignedPaths == ["container:a/b"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        reloaded.forget(messageKey: "k1")
        #expect(MediaIndex(fileURL: url).assignment(for: "k1") == nil)
        let small = MediaIndex(fileURL: nil); small.maxEntries = 2
        for i in 0..<5 { small.observe(messageKey: "o\(i)", conversation: "c", direction: "inbound", nowMs: Int64(i)) }
        #expect(small.count.observations == 2 && small.observation(for: "o4") != nil && small.observation(for: "o0") == nil)
    }

    @Test func storeFindsTheCurrentProfileAndItsPicturesInATimeRange() throws {
        let t0 = Date(timeIntervalSince1970: 1_789_460_000)
        let root = try container(pictures: [("aaaa", t0, true), ("bbbb", t0.addingTimeInterval(60), false), ("cccc", t0.addingTimeInterval(3600), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WeComMediaStore(containerData: root)
        #expect(store.currentProfile()?.lastPathComponent == "D8682F25E08A9B27FB6D096B03712294")
        let since = Int64(t0.timeIntervalSince1970 * 1000)
        let all = store.candidates(sinceMs: since - 1000)
        #expect(all.map { ($0.path as NSString).lastPathComponent } == ["cccc", "bbbb", "aaaa"])   // newest first, no _HD copies
        #expect(all.allSatisfy { $0.kind == "image" && $0.signature == "jpeg" && $0.root == "container" && $0.size > 0 })
        let window = store.candidates(sinceMs: since - 1000, untilMs: since + 120_000)
        #expect(window.map { ($0.path as NSString).lastPathComponent } == ["bbbb", "aaaa"])
        let hd = store.hdSibling(of: all[2])
        #expect(hd?.path.hasSuffix("aaaa_HD/aaaa_HD") == true && store.hdSibling(of: all[1]) == nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Documents/Profiles/setting.json"))
        #expect(store.currentProfile()?.lastPathComponent == "D8682F25E08A9B27FB6D096B03712294")   // newest image cache wins without the setting
    }

    /// The live image fixture: a text row labelled 9:32 followed by a picture row. Without an observation the
    /// picture is found between that label and the end of the day; an observed key is matched by its sighting.
    @Test func messageMediaMatchesByObservationOrByTheSurroundingTimeLabels() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let arrived = cal.date(bySettingHour: 9, minute: 33, second: 10, of: today)!
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [("pic1", arrived, false), ("pic2", observedAt.addingTimeInterval(-4), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        // Live cache shape: JPEG bytes can sit under a `.png` file name. The served name must follow the bytes.
        let second = root.appendingPathComponent("Documents/Profiles/D8682F25E08A9B27FB6D096B03712294/Caches/Images/2026-09/pic2/pic2")
        try FileManager.default.moveItem(at: second, to: second.appendingPathExtension("png"))
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-image-message.json")))
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation, .scrollHistory], phase: .phase1),
                                    checkpoints: cps, strategy: .enterKey, submitTimeout: 0.3)
        h.mediaStore = WeComMediaStore(containerData: root)
        h.mediaIndex = MediaIndex(fileURL: nil)
        let store = RecordingObjectStore()
        h.objectStore = store
        var hist = try h.messageHistory(limit: 10, scrollback: false)
        let key = try #require(hist.last?["messageKey"])
        #expect(hist.last?["kind"] == "media" && hist.last?["media"] == "unmatched" && hist.first?["media"] == nil)
        // window: the 9:32 label above the row brackets the picture that arrived at 9:33
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.matchedBy == "window" && ref.fileName == "pic1.jpg" && ref.contentType == "image/jpeg" && ref.width == 40)
        #expect(ref.url.hasPrefix("https://b.example/") && ref.bytes > 0 && store.puts.count == 1)
        hist = try h.messageHistory(limit: 10, scrollback: false)
        #expect(hist.last?["media"] == "assigned")
        #expect(try h.messageMedia(messageKey: key, hd: false).matchedBy == "window")   // sticky
        #expect(store.puts.count == 1)   // HEAD hit: still no second upload
        // observed: a key seen 4 s after pic2 was written is tied to pic2, not to the already-assigned pic1
        h.mediaIndex.observe(messageKey: "k-observed", conversation: "x", direction: "inbound", nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        let observed = try h.messageMedia(messageKey: "k-observed", hd: false)
        #expect(observed.matchedBy == "observed" && observed.fileName == "pic2.jpg" && observed.contentType == "image/jpeg")
        // nothing left: an observed key with no file in its window, and a key that is not in the open conversation
        h.mediaIndex.observe(messageKey: "k-empty", conversation: "x", direction: "inbound", nowMs: Int64(Date().timeIntervalSince1970 * 1000) - 86_400_000 * 3)
        #expect(throws: ControlError.self) { try h.messageMedia(messageKey: "k-empty", hd: false) }
        do { _ = try h.messageMedia(messageKey: "nope", hd: false); Issue.record("expected MEDIA_NOT_FOUND") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND" && e.message.contains("not in the open conversation")) }
    }

    /// An index written before B13 has no `kind`; those observations were only ever pictures.
    @Test func anObservationWithoutAKindDecodesAsMedia() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-index-\(UUID().uuidString.prefix(8))/media-index.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"assignments":{},"observations":{"k1":{"conversation":"c","direction":"inbound","observedMs":1000}}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let index = MediaIndex(fileURL: url)
        #expect(index.observation(for: "k1")?.kind == "media" && index.observation(for: "k1")?.observedMs == 1000)
        index.observe(messageKey: "k2", conversation: "c", direction: "outbound", kind: "video", nowMs: 2000)
        #expect(MediaIndex(fileURL: url).observation(for: "k2")?.kind == "video")
    }
}

/// B13 fake: records every `put`, serves a deterministic signed URL, never touches the network.
final class RecordingObjectStore: ObjectStore {
    var summary = "fake bucket"; var baseDir = "imctl"; var maxUploadBytes: Int64 = 1_000_000; var viewExpireSeconds = 1800
    var existing: Set<String> = []
    var puts: [(key: String, contentType: String, bytes: Int)] = []
    var downloadData: Data? = nil
    /// A PUT as slow as a big file on a slow link.
    var putDelay: TimeInterval = 0
    func exists(key: String) throws -> Bool { existing.contains(key) }
    func put(fileURL: URL, key: String, contentType: String) throws {
        if putDelay > 0 { Thread.sleep(forTimeInterval: putDelay) }
        puts.append((key, contentType, (try? Data(contentsOf: fileURL))?.count ?? -1)); existing.insert(key)
    }
    func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL { URL(string: "https://b.example/\(OSSSigner_encode(key))?x-oss-signature=sig")! }
    func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64 {
        guard let downloadData else { return 0 }
        try downloadData.write(to: destination)
        return Int64(downloadData.count)
    }
    func delete(key: String) throws {}
    private func OSSSigner_encode(_ k: String) -> String { k.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? k }
}

extension MediaRouteTests {
    /// A historical picture bubble with its own date label, like the row that exposed the key change.
    static func datedPictureRow(_ label: String) -> AXNode {
        let frame = CGRect(x: 311, y: 94, width: 1609, height: 388)
        return AXNode(role: AXRole.row, subrole: "AXTableRow", frame: frame, children: [
            AXNode(role: AXRole.cell, frame: frame, children: [
                GroupFixture.text(label, x: 1050, y: 104, w: 130, h: 20),
            ]),
        ])
    }

    func legacyPictureHandler(files: [(String, Date)], label: String) throws -> (WeComCommandHandler, URL, String, String) {
        let root = try container(pictures: files.map { ($0.0, $0.1, false) })
        let fake = FakeAXBackend(root: GroupFixture.window(messages: [Self.datedPictureRow(label)]))
        let h = try kindHandler(container: root, fake: fake)
        let rows = try WeComReader(window: fake.rootElement).chatMessages()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == .media && row.timeLabel == label)
        let newKey = try #require(row.messageKey)
        let oldLabel = MessageTimeLabel.legacyBareClock(label) ?? label
        let oldKey = MessageKey.make(conversation: GroupFixture.groupTitle, sender: row.senderLabel,
                                     timeLabel: oldLabel, text: row.text ?? row.fileName ?? "", ordinal: 0)
        #expect(newKey != oldKey)
        return (h, root, newKey, oldKey)
    }

    @Test func yesterdayPictureRebindsOnlyItsVerifiedLegacyCacheFile() throws {
        let calendar = Calendar.current
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        let pictureAt = try #require(calendar.date(bySettingHour: 16, minute: 57, second: 0, of: yesterday))
        let (h, root, key, oldKey) = try legacyPictureHandler(files: [("legacy", pictureAt)], label: "昨天 16:36")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = h.mediaStore.candidates(sinceMs: Int64(pictureAt.timeIntervalSince1970 * 1000) - 1_000)
        #expect(files.count == 1)
        let file = try #require(files.first)
        h.mediaIndex.assign(messageKey: oldKey, file: file, matchedBy: "window", nowMs: Clock.nowMs())
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "image" && ref.matchedBy == "window" && ref.messageKey == key && ref.fileName == "legacy.jpg")
        #expect(h.mediaIndex.assignment(for: key)?.file == file)
        #expect(h.mediaIndex.assignment(for: oldKey) == nil)
        #expect(h.mediaIndex.assignedPaths.count == 1)
        let store = try #require(h.objectStore as? RecordingObjectStore)
        #expect(store.puts.count == 1)
        #expect(try h.messageMedia(messageKey: key, hd: false).messageKey == key)
        #expect(store.puts.count == 1)
    }

    @Test func sameDayRawLabelRebindsAssignmentAndObservation() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let pictureAt = try #require(calendar.date(bySettingHour: 9, minute: 25, second: 0, of: today))
        let (h, root, key, oldKey) = try legacyPictureHandler(files: [("same-day", pictureAt)], label: "9:18")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try #require(h.mediaStore.candidates(sinceMs: Int64(pictureAt.timeIntervalSince1970 * 1000) - 1_000).first)
        h.mediaIndex.observe(messageKey: oldKey, conversation: GroupFixture.groupTitle, direction: "unknown", kind: "media",
                             nowMs: Int64(pictureAt.addingTimeInterval(30).timeIntervalSince1970 * 1000))
        h.mediaIndex.assign(messageKey: oldKey, file: file, matchedBy: "observed", nowMs: Clock.nowMs())
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.messageKey == key && ref.kind == "image" && ref.matchedBy == "observed")
        #expect(h.mediaIndex.assignment(for: oldKey) == nil && h.mediaIndex.assignment(for: key)?.file == file)
        #expect(h.mediaIndex.observation(for: oldKey) == nil && h.mediaIndex.observation(for: key)?.conversation == GroupFixture.groupTitle)
    }

    @Test func yesterdayPictureRefusesAmbiguousSecondCacheInsteadOfSubstitutingIt() throws {
        let calendar = Calendar.current
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        let first = try #require(calendar.date(bySettingHour: 16, minute: 57, second: 0, of: yesterday))
        let second = first.addingTimeInterval(60)
        let (h, root, key, oldKey) = try legacyPictureHandler(files: [("legacy", first), ("other", second)], label: "昨天 16:36")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFile = try #require(h.mediaStore.candidates(sinceMs: Int64(first.timeIntervalSince1970 * 1000) - 1_000).first { $0.path.hasSuffix("/legacy") })
        h.mediaIndex.assign(messageKey: oldKey, file: oldFile, matchedBy: "window", nowMs: Clock.nowMs())
        do { _ = try h.messageMedia(messageKey: key, hd: false); Issue.record("expected ambiguous legacy alias") }
        catch let error as ControlError { #expect(error.code == "MEDIA_NOT_FOUND" && error.message.contains("ambiguous")) }
        #expect(h.mediaIndex.assignment(for: oldKey)?.file == oldFile && h.mediaIndex.assignment(for: key) == nil)
        #expect((h.objectStore as? RecordingObjectStore)?.puts.isEmpty == true)
    }

    @Test func yesterdayPictureRefusesTwoBoundLegacyLabelVariants() throws {
        let calendar = Calendar.current
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        let pictureAt = try #require(calendar.date(bySettingHour: 16, minute: 57, second: 0, of: yesterday))
        let (h, root, key, bareKey) = try legacyPictureHandler(files: [("legacy", pictureAt)], label: "昨天 16:36")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try #require(h.mediaStore.candidates(sinceMs: Int64(pictureAt.timeIntervalSince1970 * 1000) - 1_000).first)
        let rawKey = MessageKey.make(conversation: GroupFixture.groupTitle, sender: nil,
                                     timeLabel: "昨天 16:36", text: "", ordinal: 0)
        h.mediaIndex.assign(messageKey: bareKey, file: file, matchedBy: "window", nowMs: Clock.nowMs())
        h.mediaIndex.assign(messageKey: rawKey, file: file, matchedBy: "window", nowMs: Clock.nowMs())
        do { _ = try h.messageMedia(messageKey: key, hd: false); Issue.record("expected two legacy aliases to be rejected") }
        catch let error as ControlError { #expect(error.code == "MEDIA_NOT_FOUND" && error.message.contains("ambiguous")) }
        #expect(h.mediaIndex.assignment(for: bareKey) != nil && h.mediaIndex.assignment(for: rawKey) != nil)
        #expect(h.mediaIndex.assignment(for: key) == nil)
    }

    @Test func yesterdayPictureRefusesLegacyFileWrittenOnAnotherDate() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayFile = try #require(calendar.date(bySettingHour: 0, minute: 10, second: 0, of: today))
        let (h, root, key, oldKey) = try legacyPictureHandler(files: [("wrong-day", todayFile)], label: "昨天 23:50")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = h.mediaStore.candidates(sinceMs: Int64(todayFile.timeIntervalSince1970 * 1000) - 1_000)
        #expect(files.count == 1)
        let file = try #require(files.first)
        h.mediaIndex.assign(messageKey: oldKey, file: file, matchedBy: "window", nowMs: Clock.nowMs())
        do { _ = try h.messageMedia(messageKey: key, hd: false); Issue.record("expected cross-day cache refusal") }
        catch let error as ControlError { #expect(error.code == "MEDIA_NOT_FOUND" && error.message.contains("ambiguous")) }
        #expect(h.mediaIndex.assignment(for: oldKey)?.file == file && h.mediaIndex.assignment(for: key) == nil)
    }

    /// A container whose current profile holds a picture, a video poster and two files (name + size as the client shows them).
    func containerWithFiles() throws -> URL {
        let t0 = Date(timeIntervalSince1970: 1_789_460_000)
        let root = try container(pictures: [("aaaa", t0, false)])
        let profile = root.appendingPathComponent("Documents/Profiles/D8682F25E08A9B27FB6D096B03712294")
        let files = profile.appendingPathComponent("Caches/Files/2026-09")
        try FileManager.default.createDirectory(at: files.appendingPathComponent("f1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: files.appendingPathComponent("f2"), withIntermediateDirectories: true)
        try Data(repeating: 0x25, count: 75_543).write(to: files.appendingPathComponent("f1/invoice.pdf"))
        try Data(repeating: 0x50, count: 200).write(to: files.appendingPathComponent("f2/invoice.pdf"))          // same name, wrong size
        let posters = profile.appendingPathComponent("Caches/Video_Thumbnail/2026-09/v1")
        try FileManager.default.createDirectory(at: posters, withIntermediateDirectories: true)
        try (Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 64)).write(to: posters.appendingPathComponent("v1"))
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(30)], ofItemAtPath: posters.appendingPathComponent("v1").path)
        return root
    }

    @Test func fileCandidatesMatchNameAndSizeLabel() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WeComMediaStore(containerData: root)
        let hits = store.fileCandidates(name: "invoice.pdf", sizeLabel: "74K")
        #expect(hits.count == 1 && hits[0].path.hasSuffix("Caches/Files/2026-09/f1/invoice.pdf") && hits[0].kind == "file" && hits[0].size == 75_543)
        #expect(store.fileCandidates(name: "invoice.pdf", sizeLabel: nil).count == 2 && store.fileCandidates(name: "other.pdf", sizeLabel: nil).isEmpty)
    }

    /// Finding F3: the row's file name comes from the client's AX tree, so it is untrusted input. A name like
    /// `../f1/invoice.pdf` used to be appended to a cache directory as-is and walked straight back out of it,
    /// handing `message.media` a file from a directory it never searched.
    @Test func fileCandidatesRefuseANameThatIsNotAPlainFileName() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WeComMediaStore(containerData: root)
        #expect(!store.fileCandidates(name: "invoice.pdf", sizeLabel: nil).isEmpty)   // the plainly spelled name still resolves
        for bad in ["../f1/invoice.pdf", "../../f1/invoice.pdf", "f1/invoice.pdf", "/invoice.pdf", "..", ""] {
            #expect(store.fileCandidates(name: bad, sizeLabel: nil).isEmpty, "accepted \(bad)")
        }
    }

    /// Finding F4: `message.media` on a key the watcher already observed must not fail CLIENT_UNAVAILABLE just
    /// because the client is mid-render when the row table is read — the observation alone settles the kind
    /// and the cache file. Only a key with neither a row nor an observation still gets the explicit error.
    @Test func anObservedKeyResolvesEvenWhenTheRowTableCannotBeRead() throws {
        let observedAt = Date().addingTimeInterval(-60)
        let root = try container(pictures: [("pic1", observedAt.addingTimeInterval(-3), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { throw AXKitError.invalidElement },
                                    policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation], phase: .phase1),
                                    checkpoints: cps, strategy: .enterKey, submitTimeout: 0.3)
        h.mediaStore = WeComMediaStore(containerData: root)
        h.mediaIndex = MediaIndex(fileURL: nil)
        h.objectStore = RecordingObjectStore()
        h.mediaIndex.observe(messageKey: "k-observed", conversation: "x", direction: "inbound", kind: "media",
                             nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        let ref = try h.messageMedia(messageKey: "k-observed", hd: false)
        #expect(ref.matchedBy == "observed" && ref.fileName == "pic1.jpg" && ref.kind == "image")
        do { _ = try h.messageMedia(messageKey: "nope", hd: false); Issue.record("expected MEDIA_NOT_FOUND") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND" && e.message.contains("no observation")) }
    }

    @Test func fileRowsUploadOnceAndReturnASignedURL() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let window = GroupFixture.window(messages: [
            GroupFixture.timeRow(y: 64, "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                    AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: 113, width: 42, height: 42)),
                    GroupFixture.text("invoice.pdf", x: 1657, y: 113, w: 142, h: 20), GroupFixture.text("74K", x: 1657, y: 139, w: 24),
                ]),
            ]),
        ])
        let fake = FakeAXBackend(root: window)
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation, .scrollHistory], phase: .phase1), checkpoints: cps)
        h.mediaStore = WeComMediaStore(containerData: root)
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().first?.messageKey)
        do { _ = try h.messageMedia(messageKey: key, hd: true); Issue.record("expected OSS_NOT_CONFIGURED") }
        catch let e as ControlError { #expect(e.code == "OSS_NOT_CONFIGURED") }
        let store = RecordingObjectStore()
        h.objectStore = store
        let ref = try h.messageMedia(messageKey: key, hd: true)
        #expect(ref.kind == "file" && ref.fileName == "invoice.pdf" && ref.bytes == 75_543 && ref.contentType == "application/pdf" && ref.matchedBy == "name")
        #expect(ref.ossKey.hasPrefix("imctl/") && ref.ossKey.hasSuffix("/\(key)-invoice.pdf") && ref.url.hasPrefix("https://b.example/") && ref.expiresAtMs > Clock.nowMs())
        #expect(store.puts.count == 1 && store.puts[0].contentType == "application/pdf")
        let again = try h.messageMedia(messageKey: key, hd: true)
        #expect(again.ossKey == ref.ossKey && store.puts.count == 1)   // HEAD hit: no second upload
        #expect(try h.messageHistory(limit: 5, scrollback: false).first?["media"] == "assigned")
        store.maxUploadBytes = 10
        h.mediaIndex.forget(messageKey: key)
        do { _ = try h.messageMedia(messageKey: key, hd: true); Issue.record("expected MEDIA_TOO_LARGE") } catch let e as ControlError { #expect(e.code == "MEDIA_TOO_LARGE") }
    }

    @Test func pictureRowsStillResolveThroughTheIndexAndUploadTheOriginal() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAXBackend(root: try AXNode.load(from: Fixtures.root.appendingPathComponent("wecom-5.0.11-image-message.json")))
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media2-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: ["文件传输助手"], enabled: [.selectConversation], phase: .phase1), checkpoints: cps)
        h.mediaStore = WeComMediaStore(containerData: root)
        let store = RecordingObjectStore(); h.objectStore = store
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().last?.messageKey)
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "unknown", nowMs: 1_789_460_000_000)
        let ref = try h.messageMedia(messageKey: key, hd: false)
        // container(pictures:) writes the non-HD picture at 40×30 (Self.jpeg(width:40, height:30)), not 1×1.
        #expect(ref.kind == "image" && ref.contentType == "image/jpeg" && ref.matchedBy == "observed" && store.puts.count == 1 && ref.width == 40 && ref.height == 30)
    }
}

/// Kind safety (review 2026-09-22): a key's row kind decides which cache is searched at all, so a `video`,
/// `file` or plain text key can never be handed — and permanently assigned — the picture that belongs to a
/// `media` row. Plus the two behaviours the same review asked for: the upload runs outside the file-grant
/// box, and two videos in one hour never share a body.
extension MediaRouteTests {
    /// One cache file under `Caches/<kind>/2026-09/<id>/<id>` with a given head and modification time.
    func cacheFile(in root: URL, kind: String, id: String, bytes: Data, at: Date) throws {
        let dir = root.appendingPathComponent("Documents/Profiles/D8682F25E08A9B27FB6D096B03712294/Caches/\(kind)/2026-09/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(id)
        try bytes.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
    }

    static let posterBytes = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 64)
    /// `ftyp` + brand `isom`: an mp4 to both signature readers.
    static func mp4Bytes(_ padding: Int) -> Data { Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data(repeating: 0, count: padding) }

    func kindHandler(container root: URL, fake: FakeAXBackend) throws -> WeComCommandHandler {
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-kind-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: { fake.rootElement }, policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation], phase: .phase1), checkpoints: cps)
        h.mediaStore = WeComMediaStore(containerData: root)
        h.mediaIndex = MediaIndex(fileURL: nil)
        h.objectStore = RecordingObjectStore()
        return h
    }

    /// (a) A `video` key whose row is not visible must not take the picture in its window — the `media` key still gets it.
    @Test func aVideoKeyNeverConsumesAPicture() throws {
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [("pic1", observedAt.addingTimeInterval(-4), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        let ms = Int64(observedAt.timeIntervalSince1970 * 1000)
        h.mediaIndex.observe(messageKey: "k-video", conversation: "x", direction: "inbound", kind: "video", nowMs: ms)
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: ms)
        do { _ = try h.messageMedia(messageKey: "k-video", hd: false); Issue.record("expected MEDIA_NOT_FOUND for a video key with no poster") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND") }
        #expect(h.mediaIndex.count.assignments == 0)
        #expect(try h.messageMedia(messageKey: "k-media", hd: false).fileName == "pic1.jpg")
    }

    /// (b) A `file` key whose row is not visible is refused before any candidate is looked at.
    @Test func aFileKeyOutsideTheOpenConversationNeverConsumesAPicture() throws {
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [("pic1", observedAt.addingTimeInterval(-4), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        let ms = Int64(observedAt.timeIntervalSince1970 * 1000)
        h.mediaIndex.observe(messageKey: "k-file", conversation: "x", direction: "inbound", kind: "file", nowMs: ms)
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: ms)
        do { _ = try h.messageMedia(messageKey: "k-file", hd: false); Issue.record("expected MEDIA_NOT_FOUND for a file key outside the open conversation") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND" && e.message.contains("open the conversation")) }
        #expect(h.mediaIndex.count.assignments == 0)
        #expect(try h.messageMedia(messageKey: "k-media", hd: false).fileName == "pic1.jpg")
    }

    /// (c) A visible `file` row takes its document even when a picture sits in the same window.
    @Test func aVisibleFileRowTakesItsDocumentAndLeavesThePicture() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAXBackend(root: GroupFixture.window(messages: [
            GroupFixture.timeRow(y: 64, "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                    AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: 113, width: 42, height: 42)),
                    GroupFixture.text("invoice.pdf", x: 1657, y: 113, w: 142, h: 20), GroupFixture.text("74K", x: 1657, y: 139, w: 24),
                ]),
            ]),
        ]))
        let h = try kindHandler(container: root, fake: fake)
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().first?.messageKey)
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "inbound", kind: "file", nowMs: 1_789_460_000_000)
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "file" && ref.matchedBy == "name" && ref.fileName == "invoice.pdf" && ref.bytes == 75_543)
        #expect(h.mediaIndex.assignedPaths.count == 1 && h.mediaIndex.assignedPaths.allSatisfy { $0.contains("Caches/Files/") })
    }

    /// (d) A picture key is never handed a document: `Caches/Files` is not one of its caches.
    @Test func aPictureKeyIsNeverGivenADocument() throws {
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = root.appendingPathComponent("Documents/Profiles/D8682F25E08A9B27FB6D096B03712294/Caches/Files/2026-09/f1", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(repeating: 0x25, count: 2048).write(to: files.appendingPathComponent("invoice.pdf"))
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: Clock.nowMs())
        do { _ = try h.messageMedia(messageKey: "k-media", hd: false); Issue.record("expected MEDIA_NOT_FOUND for a picture key with only a document cached") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND") }
        #expect(h.mediaIndex.count.assignments == 0)
    }

    /// (e) A text row's key is refused by kind, even with a picture inside its time bracket.
    @Test func aTextRowKeyIsRefusedWithItsKind() throws {
        let cal = Calendar.current
        let arrived = cal.date(bySettingHour: 9, minute: 33, second: 10, of: cal.startOfDay(for: Date()))!
        let root = try container(pictures: [("pic1", arrived, false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAXBackend(root: GroupFixture.window(messages: [GroupFixture.messageRow(y: 94, text: "你好", sender: "张三", time: "9:18")]))
        let h = try kindHandler(container: root, fake: fake)
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().first?.messageKey)
        do { _ = try h.messageMedia(messageKey: key, hd: false); Issue.record("expected MEDIA_NOT_FOUND for a text row") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND" && e.message.contains("message row")) }
        #expect(h.mediaIndex.count.assignments == 0)
    }

    /// (f) An assignment a buggy build wrote (a `video` key pointing at a picture) is ignored and forgotten.
    @Test func aStaleAssignmentOnAVideoKeyIsIgnoredAndForgotten() throws {
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [("pic1", observedAt.addingTimeInterval(-4), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        let ms = Int64(observedAt.timeIntervalSince1970 * 1000)
        h.mediaIndex.observe(messageKey: "k-video", conversation: "x", direction: "inbound", kind: "video", nowMs: ms)
        let picture = try #require(WeComMediaStore(containerData: root).candidates(sinceMs: 0).first)
        h.mediaIndex.assign(messageKey: "k-video", file: picture, matchedBy: "observed", nowMs: ms)
        do { _ = try h.messageMedia(messageKey: "k-video", hd: false); Issue.record("expected MEDIA_NOT_FOUND, not the stale picture") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND") }
        #expect(h.mediaIndex.assignment(for: "k-video") == nil)
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: ms)
        #expect(try h.messageMedia(messageKey: "k-media", hd: false).fileName == "pic1.jpg")
    }

    /// The grant box covers the cache work only: a PUT slower than the timeout still finishes, exactly once.
    @Test func aSlowUploadRunsOutsideTheFileGrantBox() throws {
        let previous = WeComCommandHandler.fileGrantTimeout
        WeComCommandHandler.fileGrantTimeout = 0.1
        defer { WeComCommandHandler.fileGrantTimeout = previous }
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [("pic1", observedAt.addingTimeInterval(-4), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        let store = try #require(h.objectStore as? RecordingObjectStore)
        store.putDelay = 0.3
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        let ref = try h.messageMedia(messageKey: "k-media", hd: false)
        #expect(ref.fileName == "pic1.jpg" && store.puts.count == 1)
    }

    /// Video bodies: the one nearest the sighting, and never the same file for two videos in the same hour.
    @Test func twoVideosInTheSameHourGetDifferentBodies() throws {
        let t0 = Date(timeIntervalSince1970: 1_789_460_000)
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try cacheFile(in: root, kind: "Video_Thumbnail", id: "v1", bytes: Self.posterBytes, at: t0.addingTimeInterval(30))
        try cacheFile(in: root, kind: "Video_Thumbnail", id: "v2", bytes: Self.posterBytes, at: t0.addingTimeInterval(45))
        try cacheFile(in: root, kind: "Videos", id: "b1", bytes: Self.mp4Bytes(200), at: t0.addingTimeInterval(40))
        try cacheFile(in: root, kind: "Videos", id: "b2", bytes: Self.mp4Bytes(300), at: t0.addingTimeInterval(1200))
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        let store = try #require(h.objectStore as? RecordingObjectStore)
        let ms = Int64(t0.timeIntervalSince1970 * 1000)
        h.mediaIndex.observe(messageKey: "k-v1", conversation: "x", direction: "inbound", kind: "video", nowMs: ms + 30_000)
        h.mediaIndex.observe(messageKey: "k-v2", conversation: "x", direction: "inbound", kind: "video", nowMs: ms + 50_000)
        let first = try h.messageMedia(messageKey: "k-v1", hd: false)
        let second = try h.messageMedia(messageKey: "k-v2", hd: false)
        #expect(first.kind == "video" && second.kind == "video" && first.contentType == "image/jpeg")
        #expect(first.body == "uploaded" && second.body == "uploaded" && first.bodyOssKey != second.bodyOssKey)
        // b1 is the nearest body to both sightings; the second video must fall back to b2 instead of sharing it
        #expect(h.mediaIndex.assignment(for: "k-v1#body")?.file.path.hasSuffix("b1") == true)
        #expect(h.mediaIndex.assignment(for: "k-v2#body")?.file.path.hasSuffix("b2") == true)
        #expect(store.puts.count == 4 && store.puts.filter { $0.contentType == "video/mp4" }.count == 2)
    }

    /// (g) Critical (review 2026-09-23): the history-bracket stage's candidate pool for a `media` key must
    /// never include `Video_Thumbnail`. Before the fix, `kinds` defaulted to every cache, so a poster written
    /// before the picture (both inside the same bracket) landed at position 0 and the picture row's own
    /// resolution took the poster instead — permanently, since `mediaIndex.assign` is called with `chosen`.
    @Test func aMediaRowInATimeBracketNeverTakesAVideoPoster() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let posterAt = cal.date(bySettingHour: 9, minute: 20, second: 0, of: today)!   // written first
        let pictureAt = cal.date(bySettingHour: 9, minute: 25, second: 0, of: today)!  // written after
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try cacheFile(in: root, kind: "Video_Thumbnail", id: "poster1", bytes: Self.posterBytes, at: posterAt)
        try cacheFile(in: root, kind: "Images", id: "pic1", bytes: try Self.jpeg(width: 40, height: 30), at: pictureAt)
        // a text row labelled 9:18 followed by a media (picture) row, like the live image fixture
        let fake = FakeAXBackend(root: GroupFixture.window(messages: [
            GroupFixture.messageRow(y: 64, text: "早", sender: "张三", time: "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 154, width: 1609, height: 120), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 154, width: 1609, height: 120), children: []),
            ]),
        ]))
        let h = try kindHandler(container: root, fake: fake)
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().last?.messageKey)
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "image" && ref.matchedBy == "window" && ref.fileName == "pic1.jpg" && ref.width == 40)
        // the poster was never touched: the only assignment on record is the picture, in Images
        #expect(h.mediaIndex.assignedPaths.count == 1 && h.mediaIndex.assignedPaths.allSatisfy { $0.contains("Caches/Images/") })
    }

    /// (h) Critical (review 2026-09-23): the observation stage has the same hole whenever the poster sits
    /// nearer the media row's sighting than the picture does.
    @Test func aMediaKeyObservedNearAPosterResolvesThePictureNotThePoster() throws {
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try cacheFile(in: root, kind: "Video_Thumbnail", id: "poster1", bytes: Self.posterBytes, at: observedAt)                       // exactly at the sighting
        try cacheFile(in: root, kind: "Images", id: "pic1", bytes: try Self.jpeg(width: 40, height: 30), at: observedAt.addingTimeInterval(-20))   // 20 s further off
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        let ref = try h.messageMedia(messageKey: "k-media", hd: false)
        #expect(ref.kind == "image" && ref.matchedBy == "observed" && ref.fileName == "pic1.jpg" && ref.width == 40)
        #expect(h.mediaIndex.assignedPaths.count == 1 && h.mediaIndex.assignedPaths.allSatisfy { $0.contains("Caches/Images/") })
    }

    /// (i) A `media` key whose window holds only a poster (no picture-like cache file at all) must not resolve
    /// to anything, and must leave the index untouched.
    @Test func aMediaKeyWithOnlyAPosterInItsWindowIsNotFound() throws {
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try cacheFile(in: root, kind: "Video_Thumbnail", id: "poster1", bytes: Self.posterBytes, at: observedAt)
        let h = try kindHandler(container: root, fake: FakeAXBackend(root: GroupFixture.window()))
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media", nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        do { _ = try h.messageMedia(messageKey: "k-media", hd: false); Issue.record("expected MEDIA_NOT_FOUND for a media key with only a poster in its window") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND") }
        #expect(h.mediaIndex.count.assignments == 0)
    }
}

/// Counts how often the handler asked the client for its element tree. An Accessibility read of the message
/// table costs seconds while the client is busy (live 2026-09-23: ~14 s on 5.0.11), so a key the index already
/// knows must be served without one.
final class RootReadCounter: @unchecked Sendable {
    var count = 0
}

/// The live defect of 2026-09-23 03:07–03:27 (1.0.2): `message.media` read the chat rows over Accessibility
/// *inside* the 8 s file-grant box, so a client slow to answer (~14 s) timed every call out — with a message
/// blaming macOS's grant prompt — even for keys the daemon had already observed or assigned. The index is now
/// self-sufficient for observed rows, and the row read (when one is still needed) happens outside the box.
extension MediaRouteTests {
    func indexHandler(container root: URL, rootProvider: @escaping () throws -> AXElement) throws -> WeComCommandHandler {
        let cps = try FileCheckpointStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-index-\(UUID().uuidString)"))
        let h = WeComCommandHandler(rootProvider: rootProvider,
                                    policy: ActionPolicy(allowedTargets: [GroupFixture.groupTitle], enabled: [.selectConversation], phase: .phase1),
                                    checkpoints: cps, strategy: .enterKey, submitTimeout: 0.3)
        h.mediaStore = WeComMediaStore(containerData: root)
        h.mediaIndex = MediaIndex(fileURL: nil)
        h.objectStore = RecordingObjectStore()
        return h
    }

    /// One file row and one time label, as the client draws them.
    static func fileRowWindow(name: String, size: String) -> AXNode {
        GroupFixture.window(messages: [
            GroupFixture.timeRow(y: 64, "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 94, width: 1609, height: 82), children: [
                    AXNode(role: AXRole.image, description: "file pdf emphasized", frame: CGRect(x: 1851, y: 113, width: 42, height: 42)),
                    GroupFixture.text(name, x: 1657, y: 113, w: 142, h: 20), GroupFixture.text(size, x: 1657, y: 139, w: 24),
                ]),
            ]),
        ])
    }

    /// (i) A `file` key the watcher recorded with its name and size resolves from the cache while the client
    /// cannot be read at all — and a `video` key serves the duration the watcher saw, which no row can supply.
    @Test func anObservedFileKeyResolvesByItsRecordedNameWhileTheClientCannotBeRead() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RootReadCounter()
        let h = try indexHandler(container: root, rootProvider: { counter.count += 1; throw AXKitError.invalidElement })
        h.mediaIndex.observe(messageKey: "k-file", conversation: "x", direction: "inbound", kind: "file",
                             fileName: "invoice.pdf", fileSize: "74K", nowMs: 1_789_460_000_000)
        let ref = try h.messageMedia(messageKey: "k-file", hd: false)
        #expect(ref.kind == "file" && ref.matchedBy == "name" && ref.fileName == "invoice.pdf" && ref.bytes == 75_543)
        #expect(ref.contentType == "application/pdf" && ref.ossKey.hasSuffix("/k-file-invoice.pdf"))
        #expect(counter.count == 0)   // a recorded name settles the row; the client is never asked
        h.mediaIndex.observe(messageKey: "k-video", conversation: "x", direction: "inbound", kind: "video",
                             duration: "01:14", nowMs: 1_789_460_030_000)
        let video = try h.messageMedia(messageKey: "k-video", hd: false)
        #expect(video.kind == "video" && video.duration == "01:14" && video.body == "absent")
        #expect(counter.count == 0)   // the poster sits in the sighting's window: still no read
    }

    @Test func missingSentFileCacheUsesOnlyItsRecordedOriginalSource() throws {
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let h = try indexHandler(container: root, rootProvider: { throw AXKitError.invalidElement })
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-sent-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outbox) }
        h.fileFetcher = FileFetcher(outbox: outbox)
        let store = try #require(h.objectStore as? RecordingObjectStore)
        let bytes = Data("%PDF-1.0".utf8)
        store.downloadData = bytes
        let key = "abcdef0123456789"
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "outbound", kind: "file",
                             fileName: "a.pdf", nowMs: 1_789_460_000_000)
        h.sentAttachmentSource = { requested in
            requested == key ? SentFileSource(source: .ossKey("original/a.pdf"), fileName: "a.pdf", bytes: Int64(bytes.count)) : nil
        }
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "file" && ref.matchedBy == "sent-source" && ref.bytes == Int64(bytes.count))
        #expect(store.puts.count == 1 && store.puts[0].bytes == bytes.count)
        #expect(try h.messageMedia(messageKey: key, hd: false).matchedBy == "sent-source")
        #expect(store.puts.count == 1)
    }

    @Test func outboundVideoCanRecoverItsBodyFromTheExactSentSource() throws {
        let t0 = Date(timeIntervalSince1970: 1_789_460_000)
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        try cacheFile(in: root, kind: "Video_Thumbnail", id: "poster", bytes: Self.posterBytes, at: t0)
        let h = try indexHandler(container: root, rootProvider: { throw AXKitError.invalidElement })
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-video-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outbox) }
        h.fileFetcher = FileFetcher(outbox: outbox)
        let store = try #require(h.objectStore as? RecordingObjectStore)
        let bytes = Self.mp4Bytes(200)
        store.downloadData = bytes
        let key = "0123456789abcdef"
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "outbound", kind: "video", nowMs: Int64(t0.timeIntervalSince1970 * 1000))
        h.sentAttachmentSource = { requested in
            requested == key ? SentFileSource(source: .ossKey("original/movie.mp4"), fileName: "movie.mp4", bytes: Int64(bytes.count)) : nil
        }
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "video" && ref.body == "uploaded" && ref.bodyUrl?.contains("movie.mp4") == true)
        #expect(store.puts.count == 2 && store.puts.contains { $0.contentType == "video/mp4" && $0.bytes == bytes.count })
    }

    /// (ii) A key already tied to a cache file is served from the index alone: the client is never read.
    @Test func anAssignedKeyResolvesWithoutReadingTheClientAtAll() throws {
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RootReadCounter()
        let fake = FakeAXBackend(root: Self.fileRowWindow(name: "invoice.pdf", size: "74K"))
        let h = try indexHandler(container: root, rootProvider: { counter.count += 1; return fake.rootElement })
        let file = try #require(WeComMediaStore(containerData: root).fileCandidates(name: "invoice.pdf", sizeLabel: "74K").first)
        h.mediaIndex.assign(messageKey: "k-assigned", file: file, matchedBy: "name", nowMs: 1_789_460_000_000)
        let ref = try h.messageMedia(messageKey: "k-assigned", hd: false)
        #expect(ref.kind == "file" && ref.matchedBy == "name" && ref.fileName == "invoice.pdf" && ref.bytes == 75_543)
        #expect(counter.count == 0)
    }

    /// (iii) An observed `media` key resolves from the caches with the client unreadable, and without asking it.
    @Test func anObservedMediaKeyResolvesFromTheCachesWithoutAskingTheClient() throws {
        let observedAt = Date().addingTimeInterval(-3000)
        let root = try container(pictures: [("pic1", observedAt.addingTimeInterval(-4), false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RootReadCounter()
        let h = try indexHandler(container: root, rootProvider: { counter.count += 1; throw AXKitError.invalidElement })
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media",
                             nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        let ref = try h.messageMedia(messageKey: "k-media", hd: false)
        #expect(ref.kind == "image" && ref.matchedBy == "observed" && ref.fileName == "pic1.jpg" && counter.count == 0)
    }

    /// (iv) A `file` observation from before the name was recorded still falls back to the visible row — and
    /// that read happens outside the grant box: a client slower than the box still answers.
    @Test func aFileObservationWithoutANameFallsBackToTheRowReadOutsideTheGrantBox() throws {
        let previous = WeComCommandHandler.fileGrantTimeout
        WeComCommandHandler.fileGrantTimeout = 0.15
        defer { WeComCommandHandler.fileGrantTimeout = previous }
        let root = try containerWithFiles()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeAXBackend(root: Self.fileRowWindow(name: "invoice.pdf", size: "74K"))
        let h = try indexHandler(container: root, rootProvider: { Thread.sleep(forTimeInterval: 0.5); return fake.rootElement })
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().first?.messageKey)
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "inbound", kind: "file", nowMs: 1_789_460_000_000)
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "file" && ref.matchedBy == "name" && ref.fileName == "invoice.pdf" && ref.bytes == 75_543)
    }

    /// (v) An index written before 2026-09-23 has no `fileName` / `fileSize` / `duration`; it decodes with nils.
    @Test func anObservationWithoutTheRowFieldsDecodesWithNils() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-index-\(UUID().uuidString.prefix(8))/media-index.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"assignments":{},"observations":{"k1":{"conversation":"c","direction":"inbound","kind":"file","observedMs":1000}}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let o = try #require(MediaIndex(fileURL: url).observation(for: "k1"))
        #expect(o.kind == "file" && o.fileName == nil && o.fileSize == nil && o.duration == nil)
    }

    /// (vi) What the watcher hands `observe` — the observed row's `fileName` / `fileSize` / `duration` — is kept
    /// and survives a restart; the first sighting still wins.
    @Test func observingARowStoresItsNameSizeAndDuration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-index-\(UUID().uuidString.prefix(8))/media-index.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = MediaIndex(fileURL: url)
        index.observe(messageKey: "k-file", conversation: "c", direction: "inbound", kind: "file",
                      fileName: "invoice.pdf", fileSize: "74K", nowMs: 1000)
        index.observe(messageKey: "k-file", conversation: "c", direction: "inbound", kind: "file",
                      fileName: "other.pdf", fileSize: "2M", nowMs: 2000)
        index.observe(messageKey: "k-video", conversation: "c", direction: "inbound", kind: "video", duration: "01:14", nowMs: 1100)
        index.observe(messageKey: "k-media", conversation: "c", direction: "inbound", kind: "media", nowMs: 1200)
        let reloaded = MediaIndex(fileURL: url)
        let file = try #require(reloaded.observation(for: "k-file"))
        #expect(file.fileName == "invoice.pdf" && file.fileSize == "74K" && file.duration == nil && file.observedMs == 1000)
        #expect(reloaded.observation(for: "k-video")?.duration == "01:14")
        #expect(reloaded.observation(for: "k-media")?.fileName == nil)
    }

    /// (vii) Regression of 29ffefc: an observed `media` / `video` key stopped falling back to the history
    /// bracket, because the index path passes no rows and the bracket stage needs them. A thumbnail the client
    /// wrote late (or a sighting that lags the row) therefore ended in MEDIA_NOT_FOUND although the row and its
    /// neighbouring time labels were on screen. The window miss now reads the rows **once**, outside the grant
    /// box, and runs the bracket with them.
    @Test func anObservedMediaKeyWhoseWindowIsEmptyFallsBackToTheVisibleBracket() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let pictureAt = cal.date(bySettingHour: 9, minute: 25, second: 0, of: today)!    // inside the 9:18 bracket
        let observedAt = cal.date(bySettingHour: 9, minute: 35, second: 0, of: today)!   // 10 min past the picture: window empty
        let root = try container(pictures: [("pic1", pictureAt, false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RootReadCounter()
        let fake = FakeAXBackend(root: GroupFixture.window(messages: [
            GroupFixture.messageRow(y: 64, text: "早", sender: "张三", time: "9:18"),
            AXNode(role: AXRole.row, subrole: "AXTableRow", frame: CGRect(x: 311, y: 154, width: 1609, height: 120), children: [
                AXNode(role: AXRole.cell, frame: CGRect(x: 311, y: 154, width: 1609, height: 120), children: []),
            ]),
        ]))
        let h = try indexHandler(container: root, rootProvider: { counter.count += 1; return fake.rootElement })
        let key = try #require(try WeComReader(window: fake.rootElement).chatMessages().last?.messageKey)
        h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "inbound", kind: "media",
                             nowMs: Int64(observedAt.timeIntervalSince1970 * 1000))
        let ref = try h.messageMedia(messageKey: key, hd: false)
        #expect(ref.kind == "image" && ref.matchedBy == "window" && ref.fileName == "pic1.jpg" && ref.width == 40)
        #expect(counter.count == 1)   // exactly one row read, and only after the window came up empty
    }

    /// (viii) The same key with a client that cannot be read at all keeps the window's own error and assigns
    /// nothing: the fallback read is best effort, never a new failure mode.
    @Test func anObservedMediaKeyWhoseWindowIsEmptyKeepsItsErrorWhenTheRowsAreUnreadable() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let root = try container(pictures: [("pic1", cal.date(bySettingHour: 9, minute: 25, second: 0, of: today)!, false)])
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = RootReadCounter()
        let h = try indexHandler(container: root, rootProvider: { counter.count += 1; throw AXKitError.invalidElement })
        h.mediaIndex.observe(messageKey: "k-media", conversation: "x", direction: "inbound", kind: "media",
                             nowMs: Int64(cal.date(bySettingHour: 9, minute: 35, second: 0, of: today)!.timeIntervalSince1970 * 1000))
        do { _ = try h.messageMedia(messageKey: "k-media", hd: false); Issue.record("expected MEDIA_NOT_FOUND") }
        catch let e as ControlError { #expect(e.code == "MEDIA_NOT_FOUND" && e.message.contains("observation window")) }
        #expect(h.mediaIndex.count.assignments == 0 && counter.count == 1)
    }

    /// (ix) Live 2026-09-23 (5.0.11): receiving the same file twice makes the client keep `x.pdf`, `x (1).pdf`,
    /// `x (2).pdf` side by side while every row still shows `x.pdf`. Matching the exact name only, the second
    /// and later rows found the first copy (already assigned → excluded) or nothing at all.
    @Test func duplicateNameCacheCopiesResolveOnePerRow() throws {
        let root = try container(pictures: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Documents/Profiles/D8682F25E08A9B27FB6D096B03712294/Caches/Files/2026-09/f1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = Date(timeIntervalSince1970: 1_789_460_000)
        for (i, name) in ["invoice.pdf", "invoice (1).pdf", "invoice (2).pdf"].enumerated() {
            let file = dir.appendingPathComponent(name)
            try Data(repeating: 0x25, count: 75_543).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(Double(i * 60))], ofItemAtPath: file.path)
        }
        try Data(repeating: 0x25, count: 200).write(to: dir.appendingPathComponent("invoice (3).pdf"))   // a copy of another size
        let store = WeComMediaStore(containerData: root)
        let hits = store.fileCandidates(name: "invoice.pdf", sizeLabel: "74K")
        #expect(hits.map { ($0.path as NSString).lastPathComponent } == ["invoice.pdf", "invoice (2).pdf", "invoice (1).pdf"])   // exact first, copies newest first
        #expect(store.fileCandidates(name: "invoice.pdf", sizeLabel: nil).count == 4)
        let h = try indexHandler(container: root, rootProvider: { throw AXKitError.invalidElement })
        for (i, key) in ["k1", "k2", "k3"].enumerated() {
            h.mediaIndex.observe(messageKey: key, conversation: "x", direction: "inbound", kind: "file",
                                 fileName: "invoice.pdf", fileSize: "74K", nowMs: Int64(t0.timeIntervalSince1970 * 1000) + Int64(i * 60_000))
            #expect(try h.messageMedia(messageKey: key, hd: false).fileName == "invoice.pdf")
        }
        #expect(h.mediaIndex.assignedPaths.count == 3)   // every row got its own copy
    }
}
