#if os(macOS) || os(iOS) || os(watchOS)
import Foundation
import LocalAuthentication
import Security

enum PassiveKeychainAccess {
    // Public Security constants exist for these values, but the fail-mode
    // constant is deprecated even though Apple's own header still documents it
    // as the dictionary key/value for non-interactive reads. Using the raw
    // values avoids a compile warning while preserving the same query shape.
    private static let authenticationUIKey = "u_AuthUI"
    private static let authenticationUIFail = "u_AuthUIF"

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[authenticationUIKey] = authenticationUIFail
    }
}
#endif
