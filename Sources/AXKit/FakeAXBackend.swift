import CoreGraphics
import Foundation

/// In-memory backend built from an `AXNode` tree. Records every mutating call
/// so tests can assert what would have been done to a real client, and lets
/// tests mutate the tree directly to simulate client-side changes.
public final class FakeAXBackend: AXBackend {
    public let name = "fake"
    public var trusted: Bool
    public let pid: pid_t

    public private(set) var recordedSets: [(handle: AXElementHandle, attribute: String, value: AXAttributeValue)] = []
    public private(set) var recordedActions: [(handle: AXElementHandle, action: String)] = []
    /// Keys: `get:<attr>`, `get:*`, `set:<attr>`, `set:*`, `action:<name>`, `action:*`.
    public var injectedFailures: [String: AXKitError] = [:]
    /// Scripted client behaviour: run after a successful set (`set:<attr>`) or
    /// action (`action:<name>`), e.g. "append a message row when AXConfirm fires".
    public var reactions: [String: () -> Void] = [:]

    private final class Node {
        var attributes: [String: AXAttributeValue] = [:]
        var settable: Set<String> = []
        var actions: [String] = []
        var children: [Int] = []
        var parent: Int?
    }

    private var nodes: [Int: Node] = [:]
    private var nextID = 0
    private var rootID = 0

    public init(root: AXNode, pid: pid_t = 4242, trusted: Bool = true) {
        self.pid = pid
        self.trusted = trusted
        self.rootID = insert(root, parent: nil)
    }

    public var rootHandle: AXElementHandle { AXElementHandle(id: rootID) }
    public var rootElement: AXElement { AXElement(handle: rootHandle, backend: self) }

    // MARK: Tree construction and test-side mutation

    @discardableResult
    private func insert(_ n: AXNode, parent: Int?) -> Int {
        let id = nextID
        nextID += 1
        let node = Node()
        node.parent = parent
        var attrs: [String: AXAttributeValue] = [:]
        if let v = n.role { attrs[AXAttribute.role] = .string(v) }
        if let v = n.subrole { attrs[AXAttribute.subrole] = .string(v) }
        if let v = n.roleDescription { attrs[AXAttribute.roleDescription] = .string(v) }
        if let v = n.title { attrs[AXAttribute.title] = .string(v) }
        if let v = n.value { attrs[AXAttribute.value] = v.attributeValue }
        if let v = n.description { attrs[AXAttribute.description] = .string(v) }
        if let v = n.identifier { attrs[AXAttribute.identifier] = .string(v) }
        if let v = n.help { attrs[AXAttribute.help] = .string(v) }
        if let v = n.placeholder { attrs[AXAttribute.placeholderValue] = .string(v) }
        if let f = n.frame {
            let rect = f.cgRect
            attrs[AXAttribute.frame] = .rect(rect)
            attrs[AXAttribute.position] = .point(rect.origin)
            attrs[AXAttribute.size] = .size(rect.size)
        }
        if let v = n.enabled { attrs[AXAttribute.enabled] = .bool(v) }
        if let v = n.selected { attrs[AXAttribute.selected] = .bool(v) }
        if let v = n.focused { attrs[AXAttribute.focused] = .bool(v) }
        for (k, v) in n.extra { attrs[k] = .string(v) }
        node.attributes = attrs
        node.settable = Set(n.settable)
        node.actions = n.actions
        nodes[id] = node
        node.children = n.children.map { insert($0, parent: id) }
        return id
    }

    private func removeSubtree(_ id: Int) {
        guard let node = nodes.removeValue(forKey: id) else { return }
        node.children.forEach(removeSubtree)
    }

    public func handle(atPath path: [Int]) -> AXElementHandle? {
        var id = rootID
        for index in path {
            guard let node = nodes[id], node.children.indices.contains(index) else { return nil }
            id = node.children[index]
        }
        return AXElementHandle(id: id)
    }

    public func element(atPath path: [Int]) -> AXElement? {
        handle(atPath: path).map { AXElement(handle: $0, backend: self) }
    }

    /// Change the tree without recording, simulating the client itself changing.
    public func mutate(_ handle: AXElementHandle, attribute: String, to value: AXAttributeValue?) {
        guard let node = try? node(for: handle) else { return }
        node.attributes[attribute] = value
    }

    /// Add one subtree under an existing node without invalidating its siblings.
    @discardableResult
    public func appendChild(to handle: AXElementHandle, node: AXNode) -> AXElementHandle? {
        guard let id = handle.id as? Int, let parent = nodes[id] else { return nil }
        let child = insert(node, parent: id)
        parent.children.append(child)
        return AXElementHandle(id: child)
    }

    /// Like `appendChild`, but first among its siblings: the live client lists its newest window
    /// first (the 2026-09-16 add-customer recording has the panel before the main window).
    @discardableResult
    public func prependChild(to handle: AXElementHandle, node: AXNode) -> AXElementHandle? {
        guard let id = handle.id as? Int, let parent = nodes[id] else { return nil }
        let child = insert(node, parent: id)
        parent.children.insert(child, at: 0)
        return AXElementHandle(id: child)
    }

    public func replaceChildren(of handle: AXElementHandle, with newChildren: [AXNode]) {
        guard let id = handle.id as? Int, let node = nodes[id] else { return }
        node.children.forEach(removeSubtree)
        node.children = newChildren.map { insert($0, parent: id) }
    }

    /// Remove one fake client-owned child while preserving sibling AX handles.
    /// This models a sheet closing without rebuilding the conversation list.
    public func removeChild(_ child: AXElementHandle, from parent: AXElementHandle) {
        guard let childID = child.id as? Int, let parentID = parent.id as? Int,
              let node = nodes[parentID], node.children.contains(childID) else { return }
        node.children.removeAll { $0 == childID }
        removeSubtree(childID)
    }

    // MARK: AXBackend

    public func isProcessTrusted(prompt: Bool) -> Bool { trusted }

    public func applicationElement(pid: pid_t) -> AXElementHandle { rootHandle }

    public func attributeNames(of element: AXElementHandle) throws -> [String] {
        let node = try node(for: element)
        var names = Array(node.attributes.keys)
        names.append(AXAttribute.children)
        if node.parent != nil { names.append(AXAttribute.parent) }
        return names.sorted()
    }

    /// Called before every attribute read; tests use it to change the tree after a number of polls.
    public var onRead: ((AXElementHandle, String) -> Void)?

    public func attribute(_ name: String, of element: AXElementHandle) throws -> AXAttributeValue? {
        onRead?(element, name)
        try checkFailure("get:\(name)", "get:*")
        let node = try node(for: element)
        switch name {
        case AXAttribute.children:
            return .elements(node.children.map { AXElementHandle(id: $0) })
        case AXAttribute.parent:
            guard let p = node.parent else { throw AXKitError.attributeUnsupported(name) }
            return .element(AXElementHandle(id: p))
        default:
            if let v = node.attributes[name] { return v }
            // Like the real API, an application's windows are derived from its children, not stored.
            if node.attributes[AXAttribute.role] == .string(AXRole.application) {
                let windows = node.children.filter { nodes[$0]?.attributes[AXAttribute.role] == .string(AXRole.window) }.map { AXElementHandle(id: $0) }
                switch name {
                case AXAttribute.windows: return .elements(windows)
                case AXAttribute.mainWindow, AXAttribute.focusedWindow: if let first = windows.first { return .element(first) }
                default: break
                }
            }
            throw AXKitError.attributeUnsupported(name)
        }
    }

    public func isAttributeSettable(_ name: String, of element: AXElementHandle) throws -> Bool {
        try node(for: element).settable.contains(name)
    }

    public func setAttribute(_ name: String, to value: AXAttributeValue, of element: AXElementHandle) throws {
        try checkFailure("set:\(name)", "set:*")
        let node = try node(for: element)
        guard node.settable.contains(name) else { throw AXKitError.attributeNotSettable(name) }
        node.attributes[name] = value
        recordedSets.append((element, name, value))
        reactions["set:\(name)"]?()
    }

    public func actionNames(of element: AXElementHandle) throws -> [String] {
        try node(for: element).actions
    }

    public func performAction(_ name: String, on element: AXElementHandle) throws {
        try checkFailure("action:\(name)", "action:*")
        let node = try node(for: element)
        guard node.actions.contains(name) else { throw AXKitError.actionUnsupported(name) }
        recordedActions.append((element, name))
        reactions["action:\(name)"]?()
    }

    /// Change the supported actions of a node (tests: "what if the composer had AXConfirm").
    public func setActions(of handle: AXElementHandle, to actions: [String]) {
        guard let node = try? node(for: handle) else { return }
        node.actions = actions
    }

    public func pid(of element: AXElementHandle) throws -> pid_t {
        _ = try node(for: element)
        return pid
    }

    // MARK: Observation

    public final class FakeAXObserver: AXObserving {
        fileprivate var subscriptions: Set<Subscription> = []
        fileprivate let handler: (AXNotificationEvent) -> Void
        fileprivate var stopped = false

        fileprivate struct Subscription: Hashable {
            let name: String
            let element: AXElementHandle
        }

        init(handler: @escaping (AXNotificationEvent) -> Void) { self.handler = handler }

        public func add(_ notification: String, to element: AXElementHandle) throws {
            subscriptions.insert(Subscription(name: notification, element: element))
        }

        public func remove(_ notification: String, from element: AXElementHandle) throws {
            subscriptions.remove(Subscription(name: notification, element: element))
        }

        public func stop() { stopped = true }
    }

    private var observers: [FakeAXObserver] = []

    public func makeObserver(pid: pid_t, handler: @escaping (AXNotificationEvent) -> Void) throws -> AXObserving {
        let observer = FakeAXObserver(handler: handler)
        observers.append(observer)
        return observer
    }

    /// Deliver a notification to every live observer subscribed to (name, element).
    public func emit(_ notification: String, on element: AXElementHandle) {
        let key = FakeAXObserver.Subscription(name: notification, element: element)
        for observer in observers where !observer.stopped && observer.subscriptions.contains(key) {
            observer.handler(AXNotificationEvent(name: notification, element: element))
        }
    }

    // MARK: Helpers

    private func node(for handle: AXElementHandle) throws -> Node {
        guard let id = handle.id as? Int, let node = nodes[id] else { throw AXKitError.invalidElement }
        return node
    }

    private func checkFailure(_ keys: String...) throws {
        for key in keys {
            if let error = injectedFailures[key] { throw error }
        }
    }
}
