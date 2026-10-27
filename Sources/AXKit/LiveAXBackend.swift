import ApplicationServices
import Foundation

/// The only file in the package that touches AXUIElement / CFTypeRef.
public final class LiveAXBackend: AXBackend {
    public let name = "live"
    private let timeout: Float

    /// - Parameter messagingTimeoutSeconds: per-application AX messaging timeout,
    ///   so a hung client fails with `cannotComplete` instead of blocking forever.
    public init(messagingTimeoutSeconds: Float = 2) {
        timeout = messagingTimeoutSeconds
    }

    /// Hashable box so `AXElementHandle` can carry an AXUIElement.
    final class Ref: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (lhs: Ref, rhs: Ref) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private static func handle(_ element: AXUIElement) -> AXElementHandle { AXElementHandle(id: Ref(element)) }

    private func ref(_ handle: AXElementHandle) throws -> AXUIElement {
        guard let r = handle.id.base as? Ref else { throw AXKitError.invalidElement }
        return r.element
    }

    // MARK: AXBackend

    public func isProcessTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func applicationElement(pid: pid_t) -> AXElementHandle {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return Self.handle(element)
    }

    public func attributeNames(of element: AXElementHandle) throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyAttributeNames(try ref(element), &names)
        try check(err, operation: "copy attribute names", subject: "")
        return (names as? [String]) ?? []
    }

    public func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(try ref(element), name as CFString, &value)
        if err == .noValue { return nil }
        try check(err, operation: "get", subject: name)
        guard let value else { return nil }
        return Self.convert(value)
    }

    /// B61: one `AXUIElementCopyMultipleAttributeValues` round trip; per-attribute
    /// errors come back inside the array (options 0) and map like single reads. When the
    /// element cannot batch, the result is empty and each attribute is read on access.
    public func attributes(_ names: [String], of element: AXElementHandle) throws -> [String: AXAttributeResult] {
        var unique: [String] = []
        for name in names where !unique.contains(name) { unique.append(name) }
        guard !unique.isEmpty, !batchingDisabled else { return [:] }
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(try ref(element), unique as CFArray, AXCopyMultipleAttributeOptions(), &values)
        switch Self.batchCallDisposition(err, names: unique) {
        case .proceed: break
        case .fallBack: noteFallback(); return [:]
        case .fail(let error): throw error
        }
        guard let items = values as? [AnyObject], let results = Self.mapBatchItems(items, names: unique) else {
            noteFallback()
            return [:]
        }
        latchLock.lock()
        latch.noteSuccess()
        latchLock.unlock()
        return results
    }

    /// The array of one batched read mapped onto its names, as single reads would map
    /// each value; nil when its length does not match (the caller reads on access).
    static func mapBatchItems(_ items: [AnyObject], names: [String]) -> [String: AXAttributeResult]? {
        guard items.count == names.count else { return nil }
        var results: [String: AXAttributeResult] = [:]
        for (name, item) in zip(names, items) {
            let typeID = CFGetTypeID(item)
            if typeID == CFNullGetTypeID() {
                results[name] = .success(nil)
            } else if typeID == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError {
                // The CFTypeID check is the guard, as in `convert`.
                var code = AXError.success
                _ = AXValueGetValue(item as! AXValue, .axError, &code)
                results[name] = itemResult(code: code, name: name)
            } else {
                results[name] = .success(convert(item))
            }
        }
        return results
    }

    /// B62: stops batching for the rest of the process when the client never answers a
    /// batch (fallbacks only, no success); each element would otherwise pay one wasted
    /// round trip before its on-access reads. One success keeps batching on.
    struct BatchLatch: Equatable {
        static let fallbacksBeforeDisabling = 50
        private(set) var successes = 0
        private(set) var fallbacks = 0
        private(set) var disabled = false

        mutating func noteSuccess() { successes += 1 }

        /// True exactly once: for the fallback that disables batching.
        mutating func noteFallback() -> Bool {
            fallbacks += 1
            guard !disabled, successes == 0, fallbacks >= Self.fallbacksBeforeDisabling else { return false }
            disabled = true
            return true
        }
    }

    private let latchLock = NSLock()
    private var latch = BatchLatch()
    /// Called once, when batching is switched off; the daemon logs it.
    public var onBatchingDisabled: (() -> Void)?

    /// Batched reads this backend answered with an empty result (the element could not
    /// batch, or the array was malformed); the probe and the daemon report it.
    public var batchFallbacks: Int {
        latchLock.lock()
        defer { latchLock.unlock() }
        return latch.fallbacks
    }

    /// True once `BatchLatch` switched batching off: every attribute is then read on access.
    public var batchingDisabled: Bool {
        latchLock.lock()
        defer { latchLock.unlock() }
        return latch.disabled
    }

    private func noteFallback() {
        latchLock.lock()
        let disabledNow = latch.noteFallback()
        latchLock.unlock()
        if disabledNow { onBatchingDisabled?() }
    }

    /// What a batched call's own status means for the read.
    enum BatchCallDisposition: Equatable {
        case proceed
        /// The element cannot answer a batch: read each attribute when it is asked for.
        case fallBack
        /// Every single read would fail the same way at once; no fallback, so one
        /// messaging timeout is not multiplied by the number of attributes.
        case fail(AXKitError)
    }

    /// A whole-batch timeout names the requested attributes (code constants), as a single read names its one.
    static func batchCallDisposition(_ err: AXError, names: [String]) -> BatchCallDisposition {
        switch err {
        case .success: return .proceed
        case .cannotComplete: return .fail(.cannotComplete("get \(names.joined(separator: ","))"))
        case .invalidUIElement: return .fail(.invalidElement)
        case .apiDisabled: return .fail(.notTrusted)
        default: return .fallBack
        }
    }

    /// One array item that carried an AXError, mapped exactly like a single read of `name`.
    static func itemResult(code: AXError, name: String) -> AXAttributeResult {
        guard code != .noValue, let error = mapError(code, operation: "get", subject: name) else { return .success(nil) }
        return .failure(error)
    }

    public func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool {
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(try ref(element), name as CFString, &settable)
        if err == .attributeUnsupported || err == .noValue { return false }
        try check(err, operation: "is settable", subject: name)
        return settable.boolValue
    }

    public func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws {
        let cf = try toCF(value)
        let err = AXUIElementSetAttributeValue(try ref(element), name as CFString, cf)
        if err == .attributeUnsupported || err == .illegalArgument {
            throw AXKitError.attributeNotSettable(name)
        }
        try check(err, operation: "set", subject: name)
    }

    public func actionNames(of element: AXElementHandle) throws -> [String] {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(try ref(element), &names)
        try check(err, operation: "copy action names", subject: "")
        return (names as? [String]) ?? []
    }

    public func performAction(_ name: String, on element: AXElementHandle) throws {
        let err = AXUIElementPerformAction(try ref(element), name as CFString)
        try check(err, operation: "perform", subject: name)
    }

    public func pid(of element: AXElementHandle) throws -> pid_t {
        var pid: pid_t = 0
        let err = AXUIElementGetPid(try ref(element), &pid)
        try check(err, operation: "get pid", subject: "")
        return pid
    }

    public func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        try LiveAXObserver(pid: pid, handler: handler)
    }

    // MARK: Error mapping

    private func check(_ err: AXError, operation: String, subject: String) throws {
        if let error = Self.mapError(err, operation: operation, subject: subject) { throw error }
    }

    /// nil for success; shared by single reads and batched array items.
    static func mapError(_ err: AXError, operation: String, subject: String) -> AXKitError? {
        let what = subject.isEmpty ? operation : "\(operation) \(subject)"
        switch err {
        case .success: return nil
        case .attributeUnsupported, .parameterizedAttributeUnsupported: return .attributeUnsupported(subject)
        case .actionUnsupported: return .actionUnsupported(subject)
        case .cannotComplete: return .cannotComplete(what)
        case .invalidUIElement: return .invalidElement
        case .apiDisabled: return .notTrusted
        case .notImplemented: return .notImplemented(what)
        default: return .apiFailure(code: err.rawValue, operation: what)
        }
    }

    // MARK: CFTypeRef <-> AXAttributeValue

    private static func convert(_ value: CFTypeRef) -> AXAttributeValue {
        let typeID = CFGetTypeID(value)
        // CF types cannot be conditionally cast; the CFTypeID check above is
        // the guard, so the forced casts below are sound.
        if typeID == AXUIElementGetTypeID() {
            return .element(handle(value as! AXUIElement))
        }
        if typeID == CFStringGetTypeID() {
            return .string((value as? String) ?? "")
        }
        if typeID == CFBooleanGetTypeID() {
            return .bool((value as? NSNumber)?.boolValue ?? false)
        }
        if typeID == CFNumberGetTypeID() {
            guard let number = value as? NSNumber else { return .unknown("CFNumber cast failed") }
            return CFNumberIsFloatType(number) ? .double(number.doubleValue) : .integer(number.intValue)
        }
        if typeID == CFArrayGetTypeID() {
            let items = (value as? [AnyObject]) ?? []
            if items.isEmpty { return .elements([]) }
            if items.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) {
                return .elements(items.map { handle($0 as! AXUIElement) })
            }
            if let strings = items as? [String] { return .strings(strings) }
            return .unknown("array of \(items.count) mixed items")
        }
        if typeID == AXValueGetTypeID() {
            return convertAXValue(value as! AXValue)
        }
        if typeID == CFURLGetTypeID() {
            if let url = value as? URL { return .url(url) }
            return .unknown("CFURL cast failed")
        }
        if typeID == CFAttributedStringGetTypeID() {
            return .string((value as? NSAttributedString)?.string ?? "")
        }
        let description = (CFCopyTypeIDDescription(typeID) as String?) ?? "typeID \(typeID)"
        return .unknown(description)
    }

    private static func convertAXValue(_ axValue: AXValue) -> AXAttributeValue {
        switch AXValueGetType(axValue) {
        case .cgPoint:
            var point = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &point) ? .point(point) : .unknown("AXValue cgPoint")
        case .cgSize:
            var size = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &size) ? .size(size) : .unknown("AXValue cgSize")
        case .cgRect:
            var rect = CGRect.zero
            return AXValueGetValue(axValue, .cgRect, &rect) ? .rect(rect) : .unknown("AXValue cgRect")
        case .cfRange:
            var range = CFRange()
            return AXValueGetValue(axValue, .cfRange, &range)
                ? .range(NSRange(location: range.location, length: range.length))
                : .unknown("AXValue cfRange")
        case .axError:
            var error = AXError.success
            _ = AXValueGetValue(axValue, .axError, &error)
            return .unknown("AXError \(error.rawValue)")
        case .illegal:
            return .unknown("AXValue illegal")
        @unknown default:
            return .unknown("AXValue type \(AXValueGetType(axValue).rawValue)")
        }
    }

    private func toCF(_ value: AXAttributeValue) throws -> CFTypeRef {
        switch value {
        case .string(let s): return s as CFString
        case .bool(let b): return NSNumber(value: b)
        case .integer(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .point(var p):
            guard let v = AXValueCreate(.cgPoint, &p) else { throw AXKitError.valueNotConvertible("point") }
            return v
        case .size(var s):
            guard let v = AXValueCreate(.cgSize, &s) else { throw AXKitError.valueNotConvertible("size") }
            return v
        case .rect(var r):
            guard let v = AXValueCreate(.cgRect, &r) else { throw AXKitError.valueNotConvertible("rect") }
            return v
        case .range(let r):
            var cf = CFRange(location: r.location, length: r.length)
            guard let v = AXValueCreate(.cfRange, &cf) else { throw AXKitError.valueNotConvertible("range") }
            return v
        case .url(let u): return u as CFURL
        case .element(let h): return try ref(h)
        case .elements(let hs): return try hs.map(ref) as CFArray
        case .strings(let s): return s as CFArray
        case .unknown(let d): throw AXKitError.valueNotConvertible(d)
        }
    }
}

/// AXObserver bridge. Notifications arrive on the main run loop; the caller
/// keeps `CFRunLoopRun()` (or equivalent) going.
final class LiveAXObserver: AXObserving {
    private let observer: AXObserver
    private let handler: (AXNotificationEvent) -> Void
    private var stopped = false

    init(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws {
        self.handler = handler
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<LiveAXObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.handler(AXNotificationEvent(
                name: notification as String,
                element: AXElementHandle(id: LiveAXBackend.Ref(element))
            ))
        }
        let err = AXObserverCreate(pid, callback, &created)
        guard err == .success, let created else {
            throw AXKitError.apiFailure(code: err.rawValue, operation: "AXObserverCreate")
        }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    deinit { stop() }

    private func element(_ handle: AXElementHandle) throws -> AXUIElement {
        guard let ref = handle.id.base as? LiveAXBackend.Ref else { throw AXKitError.invalidElement }
        return ref.element
    }

    func add(_ notification: String, to element: AXElementHandle) throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, try self.element(element), notification as CFString, refcon)
        switch err {
        case .success, .notificationAlreadyRegistered: return
        case .notificationUnsupported: throw AXKitError.notImplemented("notification \(notification)")
        case .invalidUIElement: throw AXKitError.invalidElement
        case .cannotComplete: throw AXKitError.cannotComplete("add notification \(notification)")
        default: throw AXKitError.apiFailure(code: err.rawValue, operation: "AXObserverAddNotification \(notification)")
        }
    }

    func remove(_ notification: String, from element: AXElementHandle) throws {
        let err = AXObserverRemoveNotification(observer, try self.element(element), notification as CFString)
        guard err == .success || err == .notificationNotRegistered else {
            throw AXKitError.apiFailure(code: err.rawValue, operation: "AXObserverRemoveNotification \(notification)")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
