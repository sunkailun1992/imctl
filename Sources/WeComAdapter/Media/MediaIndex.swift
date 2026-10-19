import ControlCore
import Foundation

/// What the daemon knows about message files: when a `media` / `file` / `video` row was observed
/// (per `messageKey`) and which cache file was later tied to it. Small,
/// JSON on disk (0600) so `message.media` still works after a restart.
public final class MediaIndex {
    public struct Observation: Codable, Equatable {
        public var observedMs: Int64
        public var conversation: String
        public var direction: String
        /// `MessageRowKind` raw value of the observed row: `media`, `file` or `video` (B13). `message.media`
        /// resolves each of those from a different cache, so the kind decides which files a key may be given
        /// at all — a `video` key must never be handed a `media` row's picture (review 2026-09-22).
        public var kind: String
        /// What the row itself showed when the watcher saw it: a `file` row's name and size label (`74K`), a
        /// `video` row's duration (`01:14`). Recorded since 2026-09-23 so `message.media` can resolve an
        /// observed row from the caches alone — reading the rows back over Accessibility costs seconds on a
        /// busy client and used to time the whole call out. nil in entries written before that, and in rows
        /// that show no such label.
        public var fileName: String?
        public var fileSize: String?
        public var duration: String?
        public init(observedMs: Int64, conversation: String, direction: String, kind: String = MessageRowKind.media.rawValue,
                    fileName: String? = nil, fileSize: String? = nil, duration: String? = nil) {
            self.observedMs = observedMs; self.conversation = conversation; self.direction = direction; self.kind = kind
            self.fileName = fileName; self.fileSize = fileSize; self.duration = duration
        }
        /// An index written before B13 has no `kind`; every row it recorded was a picture. One written before
        /// 2026-09-23 has none of the row's own labels either — they decode as nil, and such a `file` key falls
        /// back to its visible row.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            observedMs = try c.decode(Int64.self, forKey: .observedMs)
            conversation = try c.decode(String.self, forKey: .conversation)
            direction = try c.decode(String.self, forKey: .direction)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? MessageRowKind.media.rawValue
            fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
            fileSize = try c.decodeIfPresent(String.self, forKey: .fileSize)
            duration = try c.decodeIfPresent(String.self, forKey: .duration)
        }
    }
    public struct Assignment: Codable, Equatable {
        public var file: MediaCacheFile
        public var matchedBy: String
        public var assignedMs: Int64
        public init(file: MediaCacheFile, matchedBy: String, assignedMs: Int64) { self.file = file; self.matchedBy = matchedBy; self.assignedMs = assignedMs }
    }
    struct Snapshot: Codable { var observations: [String: Observation]; var assignments: [String: Assignment] }

    public let fileURL: URL?
    public var maxEntries = 2000
    private let lock = NSLock()
    private var observations: [String: Observation] = [:]
    private var assignments: [String: Assignment] = [:]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            observations = s.observations; assignments = s.assignments
        }
    }

    /// Called from the watcher for every `message.observed{kind: media|file|video}`; keeps the first sighting,
    /// together with the labels that row showed (`fileName` / `fileSize` / `duration`), which the client no
    /// longer has to be asked for.
    public func observe(messageKey: String, conversation: String, direction: String, kind: String = MessageRowKind.media.rawValue,
                        fileName: String? = nil, fileSize: String? = nil, duration: String? = nil, nowMs: Int64) {
        guard !messageKey.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if observations[messageKey] == nil {
            observations[messageKey] = Observation(observedMs: nowMs, conversation: conversation, direction: direction, kind: kind,
                                                   fileName: fileName, fileSize: fileSize, duration: duration)
            trim(); persist()
        }
    }

    public func observation(for key: String) -> Observation? { lock.lock(); defer { lock.unlock() }; return observations[key] }
    public func assignment(for key: String) -> Assignment? { lock.lock(); defer { lock.unlock() }; return assignments[key] }
    public var assignedPaths: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(assignments.values.map { $0.file.root + ":" + $0.file.path }) }
    public var count: (observations: Int, assignments: Int) { lock.lock(); defer { lock.unlock() }; return (observations.count, assignments.count) }

    public func assign(messageKey: String, file: MediaCacheFile, matchedBy: String, nowMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        assignments[messageKey] = Assignment(file: file, matchedBy: matchedBy, assignedMs: nowMs)
        trim(); persist()
    }

    /// Move one pre-canonical-key cache binding and any matching observation after the caller has proved
    /// that the visible row is the same message. Do not leave the old key owning the file: a bare clock
    /// label can be reused by a different message on another day. A third owner or a changed file makes
    /// the move ambiguous.
    public func rebindLegacyAssignment(from oldKey: String, to newKey: String, file: MediaCacheFile, nowMs: Int64) -> Assignment? {
        lock.lock(); defer { lock.unlock() }
        guard oldKey != newKey, assignments[newKey] == nil, observations[newKey] == nil,
              let old = assignments[oldKey], old.file == file,
              !assignments.contains(where: { $0.key != oldKey && $0.value.file.root == file.root && $0.value.file.path == file.path })
        else { return nil }
        let moved = Assignment(file: file, matchedBy: old.matchedBy, assignedMs: nowMs)
        assignments[oldKey] = nil
        assignments[newKey] = moved
        if let observed = observations.removeValue(forKey: oldKey) { observations[newKey] = observed }
        persist()
        return moved
    }

    public func forget(messageKey: String) {
        lock.lock(); defer { lock.unlock() }
        assignments[messageKey] = nil; persist()
    }

    private func trim() {
        if observations.count > maxEntries {
            for (k, _) in observations.sorted(by: { $0.value.observedMs < $1.value.observedMs }).prefix(observations.count - maxEntries) { observations[k] = nil }
        }
        if assignments.count > maxEntries {
            for (k, _) in assignments.sorted(by: { $0.value.assignedMs < $1.value.assignedMs }).prefix(assignments.count - maxEntries) { assignments[k] = nil }
        }
    }

    private func persist() {
        guard let fileURL else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Snapshot(observations: observations, assignments: assignments)) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
