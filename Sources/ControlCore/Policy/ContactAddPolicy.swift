import Foundation

/// B12: limits on `contact.add`. Until B54 it also kept a list of the only phone numbers that could be
/// searched and added; the user decided on 2026-10-13 that any number may be (whether the person accepts is
/// theirs to decide), so a list left in an older policy file is read, ignored and never written back. Real adds
/// and searches each keep an hourly cap. Logs and events only ever carry a number's length or last digits.
public struct ContactAddPolicy: Codable, Equatable {
    /// Hard cap on successful `contact.add` per hour (like `maxAcceptsPerHour`); 0 turns real adds off.
    public var maxAddsPerHour: Int
    /// Hard cap on searches (`dryRun`) per hour (user decision 2026-10-13); 0 turns searches off.
    public var maxSearchesPerHour: Int

    public init(maxAddsPerHour: Int = 20, maxSearchesPerHour: Int = 60) {
        self.maxAddsPerHour = maxAddsPerHour; self.maxSearchesPerHour = maxSearchesPerHour
    }

    enum CodingKeys: String, CodingKey { case maxAddsPerHour, maxSearchesPerHour }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxAddsPerHour = try c.decodeIfPresent(Int.self, forKey: .maxAddsPerHour) ?? 20
        maxSearchesPerHour = try c.decodeIfPresent(Int.self, forKey: .maxSearchesPerHour) ?? 60
    }

    /// Digits only: "138 0000 0000" and "+86-138…" compare equal to the typed form the client searches.
    public static func normalize(_ phone: String) -> String {
        String(phone.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    /// A phone number as typed: digits with optional `+ - ( )` and spaces, 5–20 digits. Nothing else reaches
    /// WeCom's search field (the removed list used to be the only format check).
    public static func isPhoneNumber(_ phone: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789+-() ")
        guard phone.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return (5...20).contains(normalize(phone).count)
    }

    /// Any phone number (user decision 2026-10-13: no list of allowed numbers).
    public func allows(_ phone: String) -> Bool {
        Self.isPhoneNumber(phone)
    }

    /// "138****0000": what logs, traces and the CLI show instead of a number.
    public static func mask(_ phone: String) -> String {
        let n = normalize(phone)
        guard n.count > 5 else { return String(repeating: "*", count: n.count) }
        return n.prefix(3) + String(repeating: "*", count: n.count - 5) + n.suffix(2)
    }

    public var summary: String { "phones=any maxAddsPerHour=\(maxAddsPerHour) maxSearchesPerHour=\(maxSearchesPerHour)" }
}
