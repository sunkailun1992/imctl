import Foundation
import Testing
@testable import WeComAdapter

/// B11's Full Disk Access probe reads a TCC database that only a Full Disk Access holder may open.
/// macOS 27.0 (observed 2026-09-22) no longer has the per-user database, so the probe must also try
/// the system one; both are real files here, no mocks.
@Suite("Permissions probe (Full Disk Access)")
struct PermissionsProbeTests {
    /// A throwaway root holding `Library/Application Support/com.apple.TCC/TCC.db` when `withDatabase`,
    /// readable unless `readable` is false (mode 000 — the tests do not run as root).
    func root(withDatabase: Bool, readable: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-tcc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        if withDatabase {
            let dir = root.appendingPathComponent("Library/Application Support/com.apple.TCC", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = dir.appendingPathComponent("TCC.db")
            try Data("SQLite format 3\0".utf8).write(to: db)
            if !readable { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: db.path) }
        }
        return root
    }

    @Test func yesWhenTheUserDatabaseIsReadable() throws {
        let home = try root(withDatabase: true), system = try root(withDatabase: false)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: system) }
        #expect(WeComCommandHandler.hasFullDiskAccess(home: home, systemRoot: system))
    }

    /// macOS 27.0: `~/Library/Application Support/com.apple.TCC/` is gone; the grant still shows as the
    /// system database being readable.
    @Test func yesWhenOnlyTheSystemDatabaseIsReadable() throws {
        let home = try root(withDatabase: false), system = try root(withDatabase: true)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: system) }
        #expect(WeComCommandHandler.hasFullDiskAccess(home: home, systemRoot: system))
    }

    @Test func noWhenNeitherDatabaseCanBeOpened() throws {
        let home = try root(withDatabase: false), system = try root(withDatabase: true, readable: false)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: system) }
        #expect(!WeComCommandHandler.hasFullDiskAccess(home: home, systemRoot: system))
    }
}
