import Foundation
import Testing
@testable import ControlCore
@testable import WeComAdapter

@Suite("WeComMediaCacheScanner")
struct MediaCacheTests {
    func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-media-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 2000))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 2000))
        let mp4 = Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D] + [UInt8](repeating: 0, count: 2000))
        for (path, data) in [("Data/u1/Image/2026-09/a.jpg", jpeg), ("Data/u1/Image/2026-09/b.png", png), ("Data/u1/Image/2026-08/c.jpg", jpeg),
                             ("Data/u1/Image/2026-09/noext", png), ("Data/u1/Video/v.mp4", mp4), ("Data/u1/Video/clip.dat", mp4),
                             ("Data/u1/Files/readme.txt", Data(repeating: 0x41, count: 3000)), ("Data/Library/WebKit/skip.jpg", jpeg),
                             ("Data/u1/Image/2026-08/renamed.pic", jpeg), ("Data/u1/Files/store.db", jpeg)] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return root
    }

    @Test func inventoryClassifiesByExtensionThenSignatureAndClustersDirectories() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = WeComMediaCacheScanner(roots: [.init(label: "t", url: root), .init(label: "absent", url: root.appendingPathComponent("nope"))])
        let report = scanner.scan()
        #expect(report.status == "ready" && report.roots == ["t", "absent"] && report.notes.first == "absent: absent" && report.scanned > 8)
        let byPath = Dictionary(uniqueKeysWithValues: report.files.map { ($0.path, $0) })
        #expect(byPath["Data/u1/Image/2026-09/a.jpg"]?.kind == "image" && byPath["Data/u1/Image/2026-09/a.jpg"]?.signature == nil)
        #expect(byPath["Data/u1/Image/2026-09/noext"]?.kind == "image" && byPath["Data/u1/Image/2026-09/noext"]?.signature == "png")
        #expect(byPath["Data/u1/Video/clip.dat"]?.kind == "video" && byPath["Data/u1/Video/clip.dat"]?.signature == "mp4")
        #expect(byPath["Data/u1/Video/v.mp4"]?.kind == "video" && byPath["Data/u1/Files/readme.txt"] == nil && byPath["Data/Library/WebKit/skip.jpg"] == nil)
        #expect(report.files.allSatisfy { $0.root == "t" && $0.size > 1000 && $0.modifiedMs > 0 })
        #expect(byPath["Data/u1/Image/2026-08/renamed.pic"]?.signature == "jpeg" && byPath["Data/u1/Files/store.db"] == nil)   // renamed pictures count, databases never
        #expect(report.directories.first?.path == "Data/u1/Image/2026-09" && report.directories.first?.images == 3)
        #expect(report.directories.map(\.images) == [3, 2])
        #expect(report.trimmed(to: 2).files.count == 2 && report.notes.last?.hasPrefix("signature reads: ") == true)
    }

    @Test func reportNeverBlocksAndCachesTheScan() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = WeComMediaCacheScanner(roots: [.init(label: "t", url: root)])
        let first = scanner.report(limit: 3)
        #expect(first.status == "pending" && first.notes == ["scan started"])
        var ready = first
        for _ in 0..<200 where ready.status != "ready" { Thread.sleep(forTimeInterval: 0.01); ready = scanner.report(limit: 3) }
        #expect(ready.status == "ready" && ready.files.count == 3 && ready.directories.count == 2)
        #expect(scanner.report(limit: 100).files.count == 7)                      // cached, only trimmed
        #expect(scanner.report(limit: 1, refresh: true).status == "pending")       // refresh starts over
    }

    @Test func listingStaysInsideTheRootAndShowsFirstBytes() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = WeComMediaCacheScanner(roots: [.init(label: "t", url: root)])
        let listing = try scanner.list(root: "t", dir: "Data/u1/Image/2026-09")
        #expect(listing.entries?.map(\.name) == ["a.jpg", "b.png", "noext"] && listing.scanned == 3)
        #expect(listing.entries?[0].head?.hasPrefix("ffd8ffe0") == true && listing.entries?[0].signature == "jpeg" && listing.entries?[2].signature == "png")
        let top = try scanner.list(root: nil, dir: "Data")
        #expect(top.entries?.map(\.name) == ["Library", "u1"] && top.entries?.allSatisfy(\.isDirectory) == true)
        #expect(throws: ControlError.self) { try scanner.list(root: "t", dir: "../etc") }
        #expect(throws: ControlError.self) { try scanner.list(root: "t", dir: "/etc") }
        #expect(throws: ControlError.self) { try scanner.list(root: "nope", dir: "Data") }
        #expect(throws: ControlError.self) { try scanner.list(root: "t", dir: "Data/missing") }
    }

    @Test func signaturesCoverTheFormatsTheClientWrites() {
        #expect(WeComMediaCacheScanner.signature(of: [0xFF, 0xD8, 0xFF, 0xE1, 0, 0, 0, 0, 0, 0, 0, 0])?.name == "jpeg")
        #expect(WeComMediaCacheScanner.signature(of: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0, 0, 0, 0, 0, 0])?.name == "gif")
        #expect(WeComMediaCacheScanner.signature(of: Array("RIFF\0\0\0\0WEBPVP8 ".utf8))?.name == "webp")
        let heic = WeComMediaCacheScanner.signature(of: [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])
        #expect(heic?.kind == "image" && heic?.name == "heic")
        #expect(WeComMediaCacheScanner.signature(of: [0, 0, 0, 0]) == nil && WeComMediaCacheScanner.signature(of: Array(repeating: 0x41, count: 16)) == nil)
    }
}
