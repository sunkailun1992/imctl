import CoreGraphics

public extension AXElement {
    /// Breadth-first descendants (self excluded) with depth and node caps.
    /// Errors while reading a node's children are swallowed: that subtree is
    /// simply not expanded. Read-only.
    func descendants(maxDepth: Int = 12, maxNodes: Int = 2000) -> [AXElement] {
        var out: [AXElement] = []
        var frontier: [(AXElement, Int)] = [(self, 0)]
        while !frontier.isEmpty, out.count < maxNodes {
            let (node, depth) = frontier.removeFirst()
            guard depth < maxDepth, let children = try? node.children() else { continue }
            for child in children {
                out.append(child)
                frontier.append((child, depth + 1))
                if out.count >= maxNodes { break }
            }
        }
        return out
    }
}
