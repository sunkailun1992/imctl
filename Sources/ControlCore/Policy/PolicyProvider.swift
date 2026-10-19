import Foundation

/// Serves `policy.json` to the executor and notices edits made by
/// `imctl policy` (mtime + size), so a widened allowlist needs no daemon
/// restart. A file that stops parsing keeps the last good policy and records
/// the error: a broken file never widens anything.
public final class PolicyProvider {
    public let url: URL
    public private(set) var lastError: String?
    private var policy: SendPolicy
    private var stamp: String?
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
        do { policy = try SendPolicy.load(from: url) } catch { policy = SendPolicy(); lastError = String(describing: error) }
        stamp = Self.stamp(url)
    }

    public func current() -> SendPolicy {
        lock.lock(); defer { lock.unlock() }
        return policy
    }

    /// The policy and whether the file last parsed, in one locked read (B52 readiness runs off the main loop).
    public func snapshot() -> (policy: SendPolicy, readable: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (policy, lastError == nil)
    }

    /// Task 8 review: `contact.add`'s hourly caps (real adds, searches). While the file does not parse both are
    /// 0 — with no phone list any more, the defaults would widen what a broken file allows.
    public func contactAddCaps() -> (adds: Int, searches: Int) {
        let s = snapshot()
        return s.readable ? (s.policy.contactAdd.maxAddsPerHour, s.policy.contactAdd.maxSearchesPerHour) : (0, 0)
    }

    /// The new policy when the file changed and parsed; nil otherwise.
    public func reloadIfChanged() -> SendPolicy? {
        lock.lock(); defer { lock.unlock() }
        let now = Self.stamp(url)
        guard now != stamp else { return nil }
        stamp = now
        do {
            policy = try SendPolicy.load(from: url)
            lastError = nil
            return policy
        } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    private static func stamp(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        return "\(mtime):\(size)"
    }
}
