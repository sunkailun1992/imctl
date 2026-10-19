import Foundation

private final class ProbeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.lock(); if stored == nil { stored = value }; lock.unlock() }
    var value: Result<T, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// A bounded wait on a callback-style completion (B52 readiness): `publish(_:)` waits for PUBACK without any
/// limit, which a readiness probe must not. nil = no completion within `timeout`.
enum ProbeWait {
    static func wait<T>(timeout: TimeInterval, _ register: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error>? {
        let box = ProbeBox<T>()
        let done = DispatchSemaphore(value: 0)
        register { result in box.set(result); done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}
