import Foundation
import Security

/// What a file's code signature says. `apple` is Apple's own signing chain (`anchor apple`).
enum CodeSignature: Equatable, Sendable {
    case apple
    case signed(identifier: String?, teamID: String?)
    case unsigned
    case invalid
    case unreadable

    /// A signature that is missing, broken or unreadable is a reason to review the item.
    var isProblem: Bool {
        switch self {
        case .unsigned, .invalid, .unreadable: true
        case .apple, .signed: false
        }
    }
}

/// Security.framework checks. Blocking calls: run them from a detached task, never on the main actor.
enum CodeSigning {
    static func check(_ url: URL) -> CodeSignature {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unreadable }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return .unreadable
        }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil)
        if validity == errSecCSUnsigned { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }
        if matches(code, requirement: "anchor apple") { return .apple }
        let info = signingInfo(code)
        return .signed(identifier: info.identifier, teamID: info.teamID)
    }

    /// True when Apple signed the file. Used as a guard before any file is moved.
    static func isApple(at url: URL) -> Bool {
        check(url) == .apple
    }

    private static func matches(_ code: SecStaticCode, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func signingInfo(_ code: SecStaticCode) -> (identifier: String?, teamID: String?) {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return (nil, nil)
        }
        return (dictionary[kSecCodeInfoIdentifier as String] as? String,
                dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
    }
}
