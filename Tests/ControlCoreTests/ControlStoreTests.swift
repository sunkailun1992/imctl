import Foundation
import SQLite3
import Testing
@testable import ControlCore

@Suite("ControlStore (GRDB, in-memory)")
struct ControlStoreTests {
    @Test func idempotencyKeyIsUniqueAndLookups() throws {
        let store = try ControlStore(path: ":memory:")
        let a = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "k1", nowMs: 1)
        #expect(try store.insertCommand(a))
        let dup = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "k1", nowMs: 2)
        #expect(try store.insertCommand(dup) == false)
        #expect(try store.command(idempotencyKey: "k1")?.id == a.id)
        #expect(try store.command(id: a.id)?.state == .accepted)
        #expect(try store.insertCommand(CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: 3)))
        #expect(try store.insertCommand(CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: 4)))
    }

    @Test func updateAndCheckpointQuery() throws {
        let store = try ControlStore(path: ":memory:")
        let a = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "k1", nowMs: 1)
        try store.insertCommand(a)
        try store.updateCommand(id: a.id, state: .running, nowMs: 2, checkpointMs: 2)
        #expect(try store.runningWithCheckpoint().map(\.id) == [a.id])
        try store.updateCommand(id: a.id, state: .succeeded, nowMs: 3, resultJSON: #"{"evidence":"row #6"}"#)
        #expect(try store.runningWithCheckpoint().isEmpty)
        let r = try #require(try store.command(id: a.id))
        #expect(r.state == .succeeded && r.resultJSON?.contains("row #6") == true && r.checkpointMs == 2)
        #expect(try store.commandCounts()["succeeded"] == 1)
    }

    @Test func recentSendsReturnsSucceededAndUnknownSendsOnly() throws {
        let store = try ControlStore(path: ":memory:")
        let a = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"a","idempotencyKey":"k1"}"#, idempotencyKey: "k1", nowMs: 10)
        try store.insertCommand(a); try store.updateCommand(id: a.id, state: .succeeded, nowMs: 20)
        let b = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"b","idempotencyKey":"k2"}"#, idempotencyKey: "k2", nowMs: 30)
        try store.insertCommand(b); try store.updateCommand(id: b.id, state: .failed, nowMs: 40)
        let u = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"u","idempotencyKey":"k3"}"#, idempotencyKey: "k3", nowMs: 50)
        try store.insertCommand(u); try store.updateCommand(id: u.id, state: .unknown, nowMs: 60)
        let c = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: 70)
        try store.insertCommand(c); try store.updateCommand(id: c.id, state: .succeeded, nowMs: 80)
        let sends = try store.recentSends(sinceMs: 0)
        #expect(sends.map(\.text) == ["a", "u"] && sends.first?.commandId == a.id && sends.first?.target == "文件传输助手" && sends.first?.tsMs == 20)
        #expect(try store.recentSends(sinceMs: 21).map(\.text) == ["u"])
        #expect(try store.recentSends(sinceMs: 0, limit: 1).map(\.text) == ["a"])
    }

    @Test func eventsAreMonotonicWithCursor() throws {
        let store = try ControlStore(path: ":memory:")
        let e1 = try store.appendEvent(kind: .commandState, payloadJSON: "{}", nowMs: 1)
        let e2 = try store.appendEvent(kind: .conversationActivity, payloadJSON: "{}", nowMs: 2)
        #expect(e1.eventId == 1 && e2.eventId == 2)
        #expect(try store.events(after: 1, limit: 10).map(\.kind) == [.conversationActivity])
        #expect(try store.lastEventId() == 2)
    }

    @Test func pauseReasonsAreASet() throws {
        let store = try ControlStore(path: ":memory:")
        try store.setPause(.api, on: true, nowMs: 1)
        try store.setPause(.api, on: true, nowMs: 2)
        try store.setPause(.system, on: true, nowMs: 3)
        #expect(try store.pauseReasons() == [.api, .system])
        try store.setPause(.api, on: false, nowMs: 4)
        #expect(try store.pauseReasons() == [.system])
    }

    @Test func keyValueRoundTrip() throws {
        let store = try ControlStore(path: ":memory:")
        #expect(try store.value(forKey: "mqtt.cursor") == nil)
        try store.setValue("7", forKey: "mqtt.cursor")
        try store.setValue("9", forKey: "mqtt.cursor")
        #expect(try store.value(forKey: "mqtt.cursor") == "9")
    }


    @Test func identitiesBridgeIdsAndTitlesBothWays() throws {
        let store = try ControlStore(path: ":memory:")
        try store.upsertIdentity(kind: .group, id: "wr1", title: "imctl测试群", nowMs: 1)
        try store.upsertIdentity(kind: .customer, id: "wm1", title: "小明·a1b2c3", nowMs: 2)
        try store.upsertIdentity(kind: .group, id: "wr1", title: "imctl测试群2", nowMs: 3)   // rename = upsert
        #expect(try store.identity(kind: .group, id: "wr1")?.title == "imctl测试群2")
        #expect(try store.identity(kind: .group, id: "wm1") == nil)
        #expect(try store.identities(title: "小明·a1b2c3").map(\.id) == ["wm1"])
        #expect(try store.identities(title: "imctl测试群").isEmpty)
        #expect(try store.allIdentities().map(\.id) == ["wm1", "wr1"])
        #expect(try store.identity(kind: .customer, id: "wm1")?.conversationType == .customer)
        let removed = try store.deleteIdentity(kind: .group, id: "wr1")
        let removedAgain = try store.deleteIdentity(kind: .group, id: "wr1")
        #expect(removed && !removedAgain)
        #expect(try NoIdentities().identity(kind: .group, id: "wr1") == nil)
        #expect(try NoIdentities().identities(title: "x").isEmpty)
    }

    @Test func recentSendsResolveIdTargetsThroughTheBridge() throws {
        let store = try ControlStore(path: ":memory:")
        try store.upsertIdentity(kind: .group, id: "wr1", title: "imctl测试群", nowMs: 1)
        let byId = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"chatId:wr1","text":"a","idempotencyKey":"k1"}"#, idempotencyKey: "k1", nowMs: 10)
        let unknown = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"externalUserId:nobody","text":"b","idempotencyKey":"k2"}"#, idempotencyKey: "k2", nowMs: 11)
        for r in [byId, unknown] {
            _ = try store.insertCommand(r)
            try store.updateCommand(id: r.id, state: .succeeded, nowMs: 20)
        }
        #expect(try store.recentSends(sinceMs: 0).map(\.target) == ["imctl测试群", "externalUserId:nobody"])
        #expect(store.conversationTitle(for: "文件传输助手") == "文件传输助手" && store.conversationTitle(for: "chatId:wr1") == "imctl测试群")
    }

    @Test func recentSendsIncludeInFlightSendsPastTheCheckpoint() throws {
        let store = try ControlStore(path: ":memory:")
        let submitted = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"x","idempotencyKey":"i1"}"#, idempotencyKey: "i1", nowMs: 10)
        let notYet = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"y","idempotencyKey":"i2"}"#, idempotencyKey: "i2", nowMs: 11)
        for r in [submitted, notYet] { _ = try store.insertCommand(r) }
        try store.updateCommand(id: submitted.id, state: .running, nowMs: 12, checkpointMs: 12)
        try store.updateCommand(id: notYet.id, state: .running, nowMs: 12)
        #expect(try store.recentSends(sinceMs: 0).map(\.text) == ["x"])
    }

    @Test func countsCommandsByMethodStateAndTime() throws {
        let store = try ControlStore(path: ":memory:")
        for (i, state) in [CommandStateV1.succeeded, .succeeded, .failed].enumerated() {
            let r = CommandRecord(method: .contactRequestAccept, paramsJSON: "{}", idempotencyKey: "a\(i)", nowMs: Int64(10 + i))
            _ = try store.insertCommand(r); try store.updateCommand(id: r.id, state: state, nowMs: Int64(20 + i))
        }
        #expect(try store.countCommands(method: .contactRequestAccept, state: .succeeded, sinceMs: 0) == 2)
        #expect(try store.countCommands(method: .contactRequestAccept, state: .succeeded, sinceMs: 21) == 1)
        #expect(try store.countCommands(method: .groupCreate, state: .succeeded, sinceMs: 0) == 0)
    }

    @Test func recentSendsIncludeFileSendsWithTheirName() throws {
        let store = try ControlStore(path: ":memory:")
        let params = #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}"#
        let record = CommandRecord(method: .messageSendFile, paramsJSON: params, idempotencyKey: "f1", nowMs: 10)
        #expect(try store.insertCommand(record))
        try store.updateCommand(id: record.id, state: .succeeded, nowMs: 20, resultJSON: #"{"state":"succeeded","fileName":"a.pdf","bytes":3,"contentType":"application/pdf","kind":"file"}"#, errorCode: nil, errorMessage: nil)
        let sends = try store.recentSends(sinceMs: 0)
        #expect(sends.count == 1 && sends[0].kind == "file" && sends[0].fileName == "a.pdf" && sends[0].target == "文件传输助手" && sends[0].commandId == record.id)
    }

    @Test func sentFileSourceRequiresAnExactSuccessfulControllerEvent() throws {
        let store = try ControlStore(path: ":memory:")
        let key = "abcdef0123456789"
        let params = #"{"target":"文件传输助手","url":"https://cdn.example/a.pdf","idempotencyKey":"f1"}"#
        let record = CommandRecord(method: .messageSendFile, paramsJSON: params, idempotencyKey: "f1", nowMs: 10)
        try store.insertCommand(record)
        try store.updateCommand(id: record.id, state: .succeeded, nowMs: 20,
                                resultJSON: #"{"state":"succeeded","fileName":"a.pdf","bytes":75543,"contentType":"application/pdf","kind":"file"}"#)
        func event(_ origin: String, _ name: String, _ key: String) throws {
            let payload = ["messageKey": key, "kind": "file", "origin": origin, "direction": "outbound",
                           "conversation": "文件传输助手", "commandId": record.id, "fileName": name, "fileSize": "74K"]
            let data = try JSONEncoder().encode(payload)
            try store.appendEvent(kind: .messageObserved, payloadJSON: String(decoding: data, as: UTF8.self), nowMs: 30)
        }
        try event("peer", "a.pdf", "1111111111111111")
        try event("controller", "other.pdf", "2222222222222222")
        try event("controller", "a.pdf", key)
        #expect(try store.sentAttachmentSource(forMessageKey: "1111111111111111") == nil)
        #expect(try store.sentAttachmentSource(forMessageKey: "2222222222222222") == nil)
        #expect(try store.sentAttachmentSource(forMessageKey: "../abcdef0123456789") == nil)
        let source = try #require(try store.sentAttachmentSource(forMessageKey: key))
        #expect(source.fileName == "a.pdf" && source.bytes == 75_543 && source.source == .url(URL(string: "https://cdn.example/a.pdf")!))
    }

    @Test func outboundVideoSourceDoesNotNeedAFileNameOnTheVideoRow() throws {
        let store = try ControlStore(path: ":memory:")
        let key = "0123456789abcdef"
        let record = CommandRecord(method: .messageSendFile,
            paramsJSON: #"{"target":"文件传输助手","ossKey":"original/movie.mp4","idempotencyKey":"v1"}"#,
            idempotencyKey: "v1", nowMs: 10)
        try store.insertCommand(record)
        try store.updateCommand(id: record.id, state: .succeeded, nowMs: 20,
            resultJSON: #"{"state":"succeeded","fileName":"movie.mp4","bytes":12,"contentType":"video/mp4","kind":"video"}"#)
        let payload = ["messageKey": key, "kind": "video", "origin": "controller", "direction": "outbound",
                       "conversation": "文件传输助手", "commandId": record.id]
        let raw = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try store.appendEvent(kind: .messageObserved, payloadJSON: raw, nowMs: 30)
        #expect(try store.sentAttachmentSource(forMessageKey: key)?.source == .ossKey("original/movie.mp4"))
    }

    @Test func sentAttachmentLookupResolvesAnIdTargetOnTheSameDatabaseRead() throws {
        let store = try ControlStore(path: ":memory:")
        try store.upsertIdentity(kind: .group, id: "wr-test", title: "测试群", nowMs: 1)
        let record = CommandRecord(method: .messageSendFile,
            paramsJSON: #"{"target":"chatId:wr-test","ossKey":"original/a.pdf","idempotencyKey":"f1"}"#,
            idempotencyKey: "f1", nowMs: 10)
        try store.insertCommand(record)
        try store.updateCommand(id: record.id, state: .succeeded, nowMs: 20,
            resultJSON: #"{"state":"succeeded","fileName":"a.pdf","bytes":8,"contentType":"application/pdf","kind":"file"}"#)
        let payload = ["messageKey": "abcdef0123456789", "kind": "file", "origin": "controller", "direction": "outbound",
                       "conversation": "测试群", "commandId": record.id, "fileName": "a.pdf"]
        try store.appendEvent(kind: .messageObserved, payloadJSON: String(decoding: JSONEncoder().encode(payload), as: UTF8.self), nowMs: 30)
        #expect(try store.sentAttachmentSource(forMessageKey: "abcdef0123456789")?.source == .ossKey("original/a.pdf"))
    }

    /// Review 2026-09-22: text and file sends live in one list, and a send that only carried an object-store
    /// key is still attributable by that key's last path component.
    @Test func recentSendsMixTextAndFileSendsAndNameOssKeyOnlySends() throws {
        let store = try ControlStore(path: ":memory:")
        let text = CommandRecord(method: .messageSend, paramsJSON: #"{"target":"文件传输助手","text":"a","idempotencyKey":"k1"}"#, idempotencyKey: "k1", nowMs: 10)
        _ = try store.insertCommand(text); try store.updateCommand(id: text.id, state: .succeeded, nowMs: 20)
        let file = CommandRecord(method: .messageSendFile, paramsJSON: #"{"target":"文件传输助手","ossKey":"imctl/2026-09-22/shot.png","idempotencyKey":"k2"}"#, idempotencyKey: "k2", nowMs: 30)
        _ = try store.insertCommand(file); try store.updateCommand(id: file.id, state: .unknown, nowMs: 40)
        let sends = try store.recentSends(sinceMs: 0)
        #expect(sends.map(\.kind) == ["text", "file"] && sends.map(\.commandId) == [text.id, file.id])
        #expect(sends[0].text == "a" && sends[0].fileName == nil)
        #expect(sends[1].fileName == "shot.png" && sends[1].text == "" && sends[1].target == "文件传输助手")
    }

    @Test func commandsAreCountedByStateAndTime() throws {
        let store = try ControlStore(path: ":memory:")
        func add(_ state: CommandStateV1, at ms: Int64) throws {
            var record = CommandRecord(method: .conversationList, paramsJSON: "{}", idempotencyKey: nil, nowMs: ms)
            record.state = state; record.updatedMs = ms
            _ = try store.insertCommand(record)
        }
        try add(.running, at: 10); try add(.accepted, at: 20); try add(.failed, at: 5); try add(.failed, at: 500); try add(.unknown, at: 600)
        #expect(try store.countCommands(states: [.accepted, .running]) == 2)
        #expect(try store.countCommands(states: [.failed], sinceMs: 100) == 1)
        #expect(try store.countCommands(states: [.unknown], sinceMs: 100) == 1)
    }

    /// B54: the diagnosis column round-trips; a record without one reads back nil.
    @Test func aDiagnosisRoundTripsAndPlainRecordsHaveNone() throws {
        let store = try ControlStore(path: ":memory:")
        let plain = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "p", nowMs: 1)
        let ended = CommandRecord(method: .contactAdd, paramsJSON: "{}", idempotencyKey: "e", nowMs: 1)
        _ = try store.insertCommand(plain)
        _ = try store.insertCommand(ended)
        try store.updateCommand(id: ended.id, state: .unknown, nowMs: 2, diagnosisJSON: #"{"irreversibleSteps":1}"#)
        #expect(try store.command(id: plain.id)?.diagnosisJSON == nil)
        #expect(try store.command(id: ended.id)?.diagnosisJSON == #"{"irreversibleSteps":1}"#)
    }

    /// Review Focus 4: a database from 1.0.16 has no diagnosis column; opening it adds the column, old records
    /// read back without a diagnosis, and new diagnoses can be written.
    @Test func aDatabaseFromBeforeB54GainsTheColumn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("imctl-b54-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = CommandRecord(method: .messageSend, paramsJSON: "{}", idempotencyKey: "old", nowMs: 1)
        do {
            let store = try ControlStore(path: path)
            _ = try store.insertCommand(old)
        }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "ALTER TABLE commands DROP COLUMN diagnosis_json; DELETE FROM grdb_migrations WHERE identifier = 'v4-diagnosis';", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = try ControlStore(path: path)
        #expect(try store.command(id: old.id)?.diagnosisJSON == nil)
        try store.updateCommand(id: old.id, state: .unknown, nowMs: 2, diagnosisJSON: #"{"irreversibleSteps":1}"#)
        #expect(try store.command(id: old.id)?.diagnosisJSON == #"{"irreversibleSteps":1}"#)
    }
}
