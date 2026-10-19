import AXKit
import Foundation

/// Structural summary of a dumped tree: safe to paste into gate notes because
/// it carries no text values, only roles, identifiers and counts.
struct TreeReport: Codable, Equatable {
    var nodes: Int
    var maxDepth: Int
    var roles: [String: Int]
    var identifiers: [String]
    var truncated: Int
    var errors: Int
    var redacted: Bool

    static func make(from node: AXNode, stats: AXTreeDumper.Stats, redacted: Bool) -> TreeReport {
        var roles: [String: Int] = [:]
        var identifiers: Set<String> = []
        func walk(_ n: AXNode) {
            roles[n.role ?? "<nil>", default: 0] += 1
            if let id = n.identifier, !id.isEmpty { identifiers.insert(id) }
            n.children.forEach(walk)
        }
        walk(node)
        return TreeReport(
            nodes: node.count, maxDepth: node.maxDepth, roles: roles,
            identifiers: identifiers.sorted().prefix(60).map { $0 },
            truncated: stats.truncated, errors: stats.errors, redacted: redacted
        )
    }

    func render() -> String {
        var lines = [
            "nodes: \(nodes)",
            "max_depth: \(maxDepth)",
            "truncated: \(truncated)",
            "errors: \(errors)",
            "redacted: \(redacted)",
            "roles:",
        ]
        for (role, count) in roles.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            lines.append("  \(role): \(count)")
        }
        lines.append("identifiers (\(identifiers.count)):")
        lines += identifiers.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }
}
