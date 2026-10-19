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

    private func visit(_ element: AXElement, depth: Int, stats: inout Stats) -> AXNode {
        stats.nodes += 1
        var node = AXNode()
        node.role = read(element, AXAttribute.role, &stats)?.stringValue
        node.subrole = read(element, AXAttribute.subrole, &stats)?.stringValue
        node.roleDescription = read(element, AXAttribute.roleDescription, &stats)?.stringValue
        node.title = read(element, AXAttribute.title, &stats)?.stringValue
        node.value = read(element, AXAttribute.value, &stats).map(AXNodeValue.init)
        node.description = read(element, AXAttribute.description, &stats)?.stringValue
        node.identifier = read(element, AXAttribute.identifier, &stats)?.stringValue
        node.help = read(element, AXAttribute.help, &stats)?.stringValue
        node.placeholder = read(element, AXAttribute.placeholderValue, &stats)?.stringValue
        node.enabled = read(element, AXAttribute.enabled, &stats)?.boolValue
        node.selected = read(element, AXAttribute.selected, &stats)?.boolValue
        node.focused = read(element, AXAttribute.focused, &stats)?.boolValue
        do { node.frame = try element.frame().map(AXFrame.init) } catch { stats.errors += 1 }
        do { node.actions = try element.actions() } catch { stats.errors += 1 }
        for name in Self.settableProbes {
            do { if try element.isSettable(name) { node.settable.append(name) } } catch { stats.errors += 1 }
        }
        for name in extraAttributes {
            if let v = read(element, name, &stats) { node.extra[name] = v.summary }
        }

        var children: [AXElement] = []
        do { children = try element.children() } catch { stats.errors += 1 }
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

    private func read(_ element: AXElement, _ name: String, _ stats: inout Stats) -> AXAttributeValue? {
        do { return try element.attributeIfSupported(name) } catch {
            stats.errors += 1
            return nil
        }
    }
}
