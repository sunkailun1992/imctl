import Foundation

/// The size the client prints on a file chip / row ("74K", "23.5M", live 2026-09-22): binary units, rounded.
public enum FileSizeLabel {
    static let pattern = try? NSRegularExpression(pattern: "^([0-9]+(?:\\.[0-9]+)?)([BKMG])$")
    static let multipliers: [String: Double] = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824]

    /// Parses a label into its byte count and its unit's multiplier. Shared by `bytes` and `matches` so the
    /// two can never disagree about what a label means: the label is trimmed once, matched against `pattern`
    /// once, and its unit looked up in `multipliers` once.
    ///
    /// The byte count is rounded using `Decimal`, not `Double`: a label at exactly `Int64.max` bytes
    /// ("9223372036854775807B") would otherwise have its number parsed by `Double.init` as `2^63` — the
    /// nearest value a binary float can hold — which no longer fits `Int64` and would make a valid label
    /// wrongly fail to parse. `Decimal` keeps every digit of the label exact, so only the label's actual
    /// value (not binary-float rounding) decides whether it fits. Returns `nil` when the label doesn't match
    /// `pattern`, or when the rounded value doesn't fit `Int64` (e.g. "99999999999G") — never traps.
    private static func parse(_ label: String) -> (bytes: Int64, unit: Double)? {
        let s = label.trimmingCharacters(in: .whitespaces)
        guard let pattern, let m = pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let numberRange = Range(m.range(at: 1), in: s), let unitRange = Range(m.range(at: 2), in: s),
              let number = Decimal(string: String(s[numberRange])), let unit = multipliers[String(s[unitRange])]
        else { return nil }
        var product = number * Decimal(unit)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, .plain)
        guard rounded <= Decimal(Int64.max) else { return nil }
        return (NSDecimalNumber(decimal: rounded).int64Value, unit)
    }

    /// The label's byte count, or `nil` when it doesn't parse or its value doesn't fit `Int64` — never traps
    /// on an oversized label.
    public static func bytes(_ label: String) -> Int64? {
        parse(label)?.bytes
    }

    /// True when `size` rounds to `label` under the client's rule: within 5 % or within one unit (whichever is larger).
    public static func matches(size: Int64, label: String) -> Bool {
        guard let parsed = parse(label) else { return false }
        let tolerance = max(Double(parsed.bytes) * 0.05, parsed.unit)
        return abs(Double(size - parsed.bytes)) <= tolerance
    }
}
