import Foundation
import GRDB

/// SQLite persistence for commands, events and pause reasons (GRDB).
/// `idempotency_key` is UNIQUE: the database, not the caller, decides "same key = same command".
public final class ControlStore {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        if path == ":memory:" {
            dbQueue = try DatabaseQueue()
        } else {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            dbQueue = try DatabaseQueue(path: path)
        }
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "commands") { t in
                t.column("id", .text).primaryKey()
                t.column("idempotency_key", .text).unique()
                t.column("method", .text).notNull()
                t.column("params_json", .text).notNull()
                t.column("state", .text).notNull()
                t.column("created_ms", .integer).notNull()
                t.column("updated_ms", .integer).notNull()
                t.column("result_json", .text)
                t.column("error_code", .text)
                t.column("error_message", .text)
                t.column("checkpoint_ms", .integer)
            }
            try db.create(table: "events") { t in
                t.autoIncrementedPrimaryKey("event_id")
                t.column("ts_ms", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payload_json", .text).notNull()
            }
            try db.create(table: "pause_reasons") { t in
                t.column("reason", .text).primaryKey()
                t.column("since_ms", .integer).notNull()
            }
        }
        migrator.registerMigration("v2-kv") { db in
            try db.create(table: "kv") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        migrator.registerMigration("v3-identities") { db in
            try db.create(table: "identities") { t in
                t.column("kind", .text).notNull()
                t.column("id", .text).notNull()
                t.column("title", .text).notNull().indexed()
                t.column("updated_ms", .integer).notNull()
                t.primaryKey(["kind", "id"])
            }
        }
        migrator.registerMigration("v4-diagnosis") { db in
            try db.alter(table: "commands") { t in t.add(column: "diagnosis_json", .text) }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: Key/value (transport cursors etc.)

    public func value(forKey key: String) throws -> String? {
        try dbQueue.read { db in try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) }
    }

    public func setValue(_ value: String, forKey key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO kv(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    // MARK: Commands

    /// Returns false when the idempotency key already exists (nothing inserted).
    @discardableResult
    public func insertCommand(_ record: CommandRecord) throws -> Bool {
        do {
            try dbQueue.write { db in try record.insert(db) }
            return true
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            return false
        }
    }

    public func command(idempotencyKey: String) throws -> CommandRecord? {
        try dbQueue.read { db in
            try CommandRecord.filter(Column("idempotency_key") == idempotencyKey).fetchOne(db)
        }
    }

    public func command(id: String) throws -> CommandRecord? {
        try dbQueue.read { db in try CommandRecord.fetchOne(db, key: id) }
    }

    public func updateCommand(
        id: String, state: CommandStateV1, nowMs: Int64,
        resultJSON: String? = nil, errorCode: String? = nil, errorMessage: String? = nil, checkpointMs: Int64? = nil,
        diagnosisJSON: String? = nil
    ) throws {
        try dbQueue.write { db in
            guard var record = try CommandRecord.fetchOne(db, key: id) else { return }
            record.state = state
            record.updatedMs = nowMs
            if let resultJSON { record.resultJSON = resultJSON }
            if let errorCode { record.errorCode = errorCode }
            if let errorMessage { record.errorMessage = errorMessage }
            if let checkpointMs { record.checkpointMs = checkpointMs }
            if let diagnosisJSON { record.diagnosisJSON = diagnosisJSON }
            try record.update(db)
        }
    }

    public func runningWithCheckpoint() throws -> [CommandRecord] {
        try dbQueue.read { db in
            try CommandRecord
                .filter(Column("state") == CommandStateV1.running.rawValue && Column("checkpoint_ms") != nil)
                .order(Column("created_ms"))
                .fetchAll(db)
        }
    }

    public func recentCommands(limit: Int) throws -> [CommandRecord] {
        try dbQueue.read { db in try CommandRecord.order(Column("created_ms").desc).limit(limit).fetchAll(db) }
    }

    public func commandCounts() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM commands GROUP BY state")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["state"] as String, $0["n"] as Int) })
        }
    }

    /// B53 readiness: commands in any of `states` whose last update is at or after `sinceMs`, all methods.
    public func countCommands(states: [CommandStateV1], sinceMs: Int64 = 0) throws -> Int {
        try dbQueue.read { db in
            try CommandRecord.filter(states.map(\.rawValue).contains(Column("state"))).filter(Column("updated_ms") >= sinceMs).fetchCount(db)
        }
    }

    // MARK: Attribution

    /// `message.send` commands that may have produced an outbound bubble
    /// (`succeeded` or `unknown`) since `sinceMs`, oldest first. The watcher
    /// uses these to attribute observed bubbles (`message.observed.origin`).
    public func countCommands(method: RPCMethod, state: CommandStateV1, sinceMs: Int64) throws -> Int {
        try dbQueue.read { db in
            try CommandRecord.filter(Column("method") == method.rawValue).filter(Column("state") == state.rawValue)
                .filter(Column("updated_ms") >= sinceMs).fetchCount(db)
        }
    }

    /// Like `countCommands` but only records whose params JSON does not contain `excluding` (B12: dry runs are free).
    public func countCommands(method: RPCMethod, state: CommandStateV1, sinceMs: Int64, excludingParams excluding: String) throws -> Int {
        try dbQueue.read { db in
            try CommandRecord.filter(Column("method") == method.rawValue).filter(Column("state") == state.rawValue)
                .filter(Column("updated_ms") >= sinceMs).filter(!Column("params_json").like("%\(excluding)%")).fetchCount(db)
        }
    }

    /// B54: one method's records last updated since `sinceMs` (contact.add's caps decode their params).
    public func commands(method: RPCMethod, updatedSinceMs sinceMs: Int64) throws -> [CommandRecord] {
        try dbQueue.read { db in
            try CommandRecord.filter(Column("method") == method.rawValue).filter(Column("updated_ms") >= sinceMs).fetchAll(db)
        }
    }

    public func recentSends(sinceMs: Int64, limit: Int = 100) throws -> [ControllerSend] {
        let records = try dbQueue.read { db in
            try CommandRecord
                .filter([RPCMethod.messageSend.rawValue, RPCMethod.messageSendFile.rawValue].contains(Column("method")))
                // Finished sends, plus in-flight ones past the irreversible step: the
                // client can show the bubble before the command reaches `succeeded`
                // (2026-09-15 live: the AX notification beat the evidence wait).
                .filter([CommandStateV1.succeeded.rawValue, CommandStateV1.unknown.rawValue].contains(Column("state"))
                        || (Column("state") == CommandStateV1.running.rawValue && Column("checkpoint_ms") != nil))
                .filter(Column("updated_ms") >= sinceMs)
                .order(Column("updated_ms"))
                .limit(limit)
                .fetchAll(db)
        }
        return records.compactMap { record in
            if record.method == RPCMethod.messageSendFile.rawValue {
                guard let params = try? JSONDecoder().decode(SendFileParams.self, from: Data(record.paramsJSON.utf8)) else { return nil }
                let result = record.resultJSON.flatMap { try? JSONDecoder().decode(SendFileResult.self, from: Data($0.utf8)) }
                // An OSS-key-only send still names its file: the key's last path component is what was pasted.
                let name = result?.fileName ?? params.fileName ?? params.url.flatMap { URL(string: $0) }.map(FileNames.name(from:))
                    ?? params.ossKey.map { FileNames.name(from: URL(fileURLWithPath: $0)) }
                return ControllerSend(commandId: record.id, target: conversationTitle(for: params.target), text: "", tsMs: record.updatedMs, kind: "file", fileName: name)
            }
            guard let params = try? JSONDecoder().decode(SendParams.self, from: Data(record.paramsJSON.utf8)) else { return nil }
            // The classifier compares with the title the client shows, so id
            // targets are resolved through the bridge (unknown ids stay as sent).
            return ControllerSend(commandId: record.id, target: conversationTitle(for: params.target), text: params.text, tsMs: record.updatedMs)
        }
    }

    /// Recover only an exact, controller-attributed file or video row. A same-name cache file or a nearby send is
    /// insufficient: those may contain different bytes. The source URL/key stays local to the daemon.
    public func sentAttachmentSource(forMessageKey key: String) throws -> SentFileSource? {
        guard key.count == 16, key.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else { return nil }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT ts_ms, payload_json FROM events WHERE kind = ? AND payload_json LIKE ? ORDER BY event_id DESC LIMIT 8",
                                        arguments: [ControlEventKind.messageObserved.rawValue, "%\(key)%"])
            for row in rows {
                let raw: String = row["payload_json"]
                guard let payload = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
                      payload["messageKey"] == key, let kind = payload["kind"], ["file", "video"].contains(kind),
                      payload["origin"] == "controller", payload["direction"] == "outbound",
                      let commandID = payload["commandId"],
                      let record = try CommandRecord.fetchOne(db, key: commandID),
                      record.method == RPCMethod.messageSendFile.rawValue, record.state == .succeeded,
                      let resultJSON = record.resultJSON,
                      let result = try? JSONDecoder().decode(SendFileResult.self, from: Data(resultJSON.utf8)),
                      result.state == .succeeded, result.kind == kind, result.bytes > 0,
                      let params = try? JSONDecoder().decode(SendFileParams.self, from: Data(record.paramsJSON.utf8)) else { continue }
                // Stay on this GRDB read connection. Calling conversationTitle(for:) here would nest
                // dbQueue.read for an id target and can deadlock its serial queue.
                let targetTitle: String?
                switch TargetRef.parse(params.target) {
                case .title(let title): targetTitle = title
                case .chatId(let id): targetTitle = try String.fetchOne(db, sql: "SELECT title FROM identities WHERE kind = ? AND id = ?", arguments: [IdentityKind.group.rawValue, id])
                case .externalUserId(let id): targetTitle = try String.fetchOne(db, sql: "SELECT title FROM identities WHERE kind = ? AND id = ?", arguments: [IdentityKind.customer.rawValue, id])
                }
                guard payload["conversation"] == targetTitle else { continue }
                let eventMs: Int64 = row["ts_ms"]
                guard abs(eventMs - record.updatedMs) <= 300_000 else { continue }
                let name = result.fileName
                if kind == "file" && payload["fileName"] != name { continue }
                if let label = payload["fileSize"], !FileSizeLabel.matches(size: result.bytes, label: label) { continue }
                if let url = params.url, params.ossKey == nil, let parsed = URL(string: url), parsed.scheme == "https" {
                    return SentFileSource(source: .url(parsed), fileName: name, bytes: result.bytes)
                }
                if let ossKey = params.ossKey, params.url == nil {
                    return SentFileSource(source: .ossKey(ossKey), fileName: name, bytes: result.bytes)
                }
            }
            return nil
        }
    }

    /// `chatId:` / `externalUserId:` → the bridged title; a title is itself.
    public func conversationTitle(for target: String) -> String {
        switch TargetRef.parse(target) {
        case .title(let title): return title
        case .chatId(let id): return ((try? identity(kind: .group, id: id)) ?? nil)?.title ?? target
        case .externalUserId(let id): return ((try? identity(kind: .customer, id: id)) ?? nil)?.title ?? target
        }
    }

    // MARK: Identities (bridge platform ids ↔ client titles)

    public func upsertIdentity(kind: IdentityKind, id: String, title: String, nowMs: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO identities(kind, id, title, updated_ms) VALUES (?, ?, ?, ?)
                ON CONFLICT(kind, id) DO UPDATE SET title = excluded.title, updated_ms = excluded.updated_ms
                """, arguments: [kind.rawValue, id, title, nowMs])
        }
    }

    @discardableResult
    public func deleteIdentity(kind: IdentityKind, id: String) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM identities WHERE kind = ? AND id = ?", arguments: [kind.rawValue, id])
            return db.changesCount > 0
        }
    }

    public func allIdentities() throws -> [Identity] {
        try dbQueue.read { db in try Identity.order(Column("kind"), Column("id")).fetchAll(db) }
    }

    // MARK: Events

    @discardableResult
    public func appendEvent(kind: ControlEventKind, payloadJSON: String, nowMs: Int64) throws -> ControlEvent {
        try dbQueue.write { db in
            var event = ControlEvent(tsMs: nowMs, kind: kind, payloadJSON: payloadJSON)
            try event.insert(db)
            return event
        }
    }

    public func events(after eventId: Int64, limit: Int) throws -> [ControlEvent] {
        try dbQueue.read { db in
            try ControlEvent.filter(Column("event_id") > eventId).order(Column("event_id")).limit(limit).fetchAll(db)
        }
    }

    public func lastEventId() throws -> Int64 {
        try dbQueue.read { db in try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(event_id), 0) FROM events") ?? 0 }
    }

    // MARK: Pause

    public func setPause(_ reason: PauseReason, on: Bool, nowMs: Int64) throws {
        try dbQueue.write { db in
            if on {
                try db.execute(sql: "INSERT OR IGNORE INTO pause_reasons(reason, since_ms) VALUES (?, ?)", arguments: [reason.rawValue, nowMs])
            } else {
                try db.execute(sql: "DELETE FROM pause_reasons WHERE reason = ?", arguments: [reason.rawValue])
            }
        }
    }

    public func pauseReasons() throws -> [PauseReason] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT reason FROM pause_reasons ORDER BY reason").compactMap(PauseReason.init(rawValue:))
        }
    }
}

extension ControlStore: IdentityLookup {
    public func identity(kind: IdentityKind, id: String) throws -> Identity? {
        try dbQueue.read { db in
            try Identity.filter(Column("kind") == kind.rawValue && Column("id") == id).fetchOne(db)
        }
    }

    public func identities(title: String) throws -> [Identity] {
        try dbQueue.read { db in try Identity.filter(Column("title") == title).order(Column("kind")).fetchAll(db) }
    }
}
