import ControlCore
import Foundation
import OSSClient

/// Keeps a signed OSS URL out of browser history. A private, verified copy is opened by Launch Services.
/// Every fetch is pinned to this Mac's configured OSS bucket host; FileFetcher checks each redirect and the
/// file signature while streaming, with the same size limit used by message.media.
enum MediaDownload {
    static let directory = IMCTLPaths.dataDirectory.appendingPathComponent("console-downloads", isDirectory: true)

    static func validated(urlString: String, fileName: String, messageKey: String, settings: OSSSettings) throws -> (URL, String) {
        guard let url = URL(string: urlString), url.scheme == "https", url.host == settings.bucketHost,
              url.user == nil, url.password == nil, url.port == nil else {
            throw ControlError.sourceNotAllowed("媒体链接不是当前 OSS 存储桶的 HTTPS 地址")
        }
        let name = FileNames.sanitize(fileName, fallback: "")
        guard !name.isEmpty, name == fileName, FileKind.info(forFileName: name, allowHEICPreview: true) != nil else {
            throw ControlError.sourceUnsupported("媒体文件名或格式无法安全打开")
        }
        guard !messageKey.isEmpty, messageKey.count <= 64,
              messageKey.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef-").contains($0) }) else {
            throw ControlError.invalidParams("无效的消息标识")
        }
        return (url, name)
    }

    static func materialize(urlString: String, fileName: String, messageKey: String, expectedBytes: Int64) throws -> URL {
        let settings = try OSSSettings.load(from: OSSSettings.defaultURL)
        let (url, name) = try validated(urlString: urlString, fileName: fileName, messageKey: messageKey, settings: settings)
        let folder = directory.appendingPathComponent(messageKey, isDirectory: true)
        let local = folder.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: local.path) {
            let bytes = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if bytes > 0, bytes <= settings.maxUploadBytes, (expectedBytes == 0 || bytes == expectedBytes), validSignature(at: local, name: name) {
                return local
            }
            try fm.removeItem(at: local)
        }
        guard expectedBytes <= settings.maxUploadBytes else { throw ControlError.mediaTooLarge("文件超过 OSS 媒体大小上限") }
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        let fetcher = FileFetcher(outbox: staging)
        fetcher.timeout = 120
        defer { try? fm.removeItem(at: staging) }
        let fetched = try fetcher.fetch(url: url, fileName: name,
                                        policy: SendFilePolicy(allowedHosts: [settings.bucketHost], maxBytes: settings.maxUploadBytes),
                                        allowHEICPreview: true)
        guard expectedBytes == 0 || fetched.bytes == expectedBytes else {
            throw ControlError.mediaNotFound("下载内容大小与消息记录不符")
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString)-\(name)")
        try fm.copyItem(at: fetched.url, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do { try fm.moveItem(at: temporary, to: local) }
        catch { try? fm.removeItem(at: temporary); throw error }
        return local
    }

    static func validSignature(at url: URL, name: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 16)) ?? Data())
        return FileKind.rejection(fileName: name, head: head, allowHEICPreview: true) == nil
    }
}
