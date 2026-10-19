import Foundation
import Security

/// Our own code-signing identity, read through the Security framework.
/// `signed` means a certificate chain is present (ad-hoc signatures have an
/// identifier but no certificates).
struct CodeSigningInfo {
    var identifier: String?
    var team: String?
    var signed: Bool

    static func current() -> CodeSigningInfo {
        let none = CodeSigningInfo(identifier: nil, team: nil, signed: false)
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return none }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return none }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return none }
        let certificates = (dict[kSecCodeInfoCertificates as String] as? [Any]) ?? []
        return CodeSigningInfo(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String,
            team: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            signed: !certificates.isEmpty
        )
    }
}
