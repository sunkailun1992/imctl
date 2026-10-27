import Foundation

/// Walks an element subtree and produces an `AXNode` snapshot. Best effort:
/// an unsupported attribute leaves its field nil; any other error also leaves
/// the field nil but is counted in `Stats.errors`. Never throws, never
/// performs actions or sets attributes.
public struct AXTreeDumper {
    public var maxDepth: Int
    public var maxChildren: Int
    public var extraAttributes: [String]

    /// Attributes probed with `isAttributeSettable`; these are the ones a
    /// controller could ever want to set.
    public static let settableProbes = [
        AXAttribute.value, AXAttribute.selectedRows, AXAttribute.selectedChildren, AXAttribute.focused,
        AXAttribute.selectedText, AXAttribute.minimized, AXAttribute.hidden,
    ]

    public struct Stats: Equatable {
        public var nodes = 0
        public var errors = 0
        public var truncated = 0
        public init() {}
    }

    public init(maxDepth: Int = 12, maxChildren: Int = 400, extraAttributes: [String] = []) {
        self.maxDepth = maxDepth
        self.maxChildren = maxChildren
        self.extraAttributes = extraAttributes
    }

    public func dump(_ element: AXElement) -> AXNode {
        dumpWithStats(element).node
    }

    public func dumpWithStats(_ element: AXElement) -> (node: AXNode, stats: Stats) {
        var stats = Stats()
        let node = visit(element, depth: 0, stats: &stats)
        return (node, stats)
    }

    /// B61: read together in one round trip per node, with `extraAttributes`.
    static let batchedAttributes = [
        AXAttribute.role, AXAttribute.subrole, AXAttribute.roleDescription, AXAttribute.title, AXAttribute.value,
        AXAttribute.description, AXAttribute.identifier, AXAttribute.help, AXAttribute.placeholderValue,
        AXAttribute.enabled, AXAttribute.selected, AXAttribute.focused,
        AXAttribute.frame, AXAttribute.position, AXAttribute.size, AXAttribute.children,
    ]

    private func visit(_ element: AXElement, depth: Int, stats: inout Stats) -> AXNode {
        stats.nodes += 1
        var node = AXNode()
        // A batch that fails as a whole counts once and leaves every batched field nil.
        var snapshot: AXAttributeSnapshot?
        do { snapshot = try element.read(Self.batchedAttributes + extraAttributes) } catch { stats.errors += 1 }
        node.role = read(snapshot, AXAttribute.role, &stats)?.stringValue
        node.subrole = read(snapshot, AXAttribute.subrole, &stats)?.stringValue
        node.roleDescription = read(snapshot, AXAttribute.roleDescription, &stats)?.stringValue
        node.title = read(snapshot, AXAttribute.title, &stats)?.stringValue
        node.value = read(snapshot, AXAttribute.value, &stats).map(AXNodeValue.init)
        node.description = read(snapshot, AXAttribute.description, &stats)?.stringValue
        node.identifier = read(snapshot, AXAttribute.identifier, &stats)?.stringValue
        node.help = read(snapshot, AXAttribute.help, &stats)?.stringValue
        node.placeholder = read(snapshot, AXAttribute.placeholderValue, &stats)?.stringValue
        node.enabled = read(snapshot, AXAttribute.enabled, &stats)?.boolValue
        node.selected = read(snapshot, AXAttribute.selected, &stats)?.boolValue
        node.focused = read(snapshot, AXAttribute.focused, &stats)?.boolValue
        if let snapshot {
            do { node.frame = try snapshot.frame().map(AXFrame.init) } catch { stats.errors += 1 }
        }
        do { node.actions = try element.actions() } catch { stats.errors += 1 }
        for name in Self.settableProbes {
            do { if try element.isSettable(name) { node.settable.append(name) } } catch { stats.errors += 1 }
        }
        for name in extraAttributes {
            if let v = read(snapshot, name, &stats) { node.extra[name] = v.summary }
        }

        var children: [AXElement] = []
        if let snapshot {
            do { children = try snapshot.children() } catch { stats.errors += 1 }
        }
        if children.isEmpty { return node }
        if depth >= maxDepth {
            node.truncated = true
            stats.truncated += 1
            return node
        }
        if children.count > maxChildren {
            node.truncated = true
            stats.truncated += 1
            children = Array(children.prefix(maxChildren))
        }
        node.children = children.map { visit($0, depth: depth + 1, stats: &stats) }
        return node
    }

    private func read(_ snapshot: AXAttributeSnapshot?, _ name: String, _ stats: inout Stats) -> AXAttributeValue? {
        guard let snapshot else { return nil }
        do { return try snapshot.attributeIfSupported(name) } catch {
            stats.errors += 1
            return nil
        }
    }
}
