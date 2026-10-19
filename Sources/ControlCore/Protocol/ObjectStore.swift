import Foundation

/// What the daemon needs from a private object store (Aliyun OSS in `OSSClient`). Bytes never cross the
/// protocol: consumers get signed GET URLs. Implemented by `OSSObjectStore`; faked in tests.
public protocol ObjectStore: AnyObject {
    /// Endpoint host + bucket + base dir + masked key id, for `describe` / logs — never a secret or a signed URL.
    var summary: String { get }
    var baseDir: String { get }
    var maxUploadBytes: Int64 { get }
    var viewExpireSeconds: Int { get }
    func exists(key: String) throws -> Bool
    func put(fileURL: URL, key: String, contentType: String) throws
    func signedGetURL(key: String, expiresIn: TimeInterval) throws -> URL
    /// Streams `key` to `destination` (at most `maxBytes`, checked by HEAD first); returns the byte count.
    func download(key: String, to destination: URL, maxBytes: Int64) throws -> Int64
    func delete(key: String) throws
}
