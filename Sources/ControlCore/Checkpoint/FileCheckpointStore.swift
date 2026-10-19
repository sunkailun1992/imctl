import Foundation

/// One JSON file per checkpoint, written atomically. Good enough for phase 1;
/// the GRDB log replaces it in phase 2.
public final class FileCheckpointStore: CheckpointStore {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("imctl/checkpoints", isDirectory: true)
    }

    private func url(for id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    public func write(_ checkpoint: SubmitCheckpoint) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checkpoint).write(to: url(for: checkpoint.id), options: .atomic)
    }

    public func load(id: String) throws -> SubmitCheckpoint? {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(SubmitCheckpoint.self, from: Data(contentsOf: file))
    }

    public func pending() throws -> [SubmitCheckpoint] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(SubmitCheckpoint.self, from: Data(contentsOf: $0)) }
            .filter { $0.state == .pending }
            .sorted { $0.createdAtMs < $1.createdAtMs }
    }
}
