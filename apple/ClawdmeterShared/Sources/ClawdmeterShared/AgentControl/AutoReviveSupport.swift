import Foundation

/// Single source of truth for which providers support `AutoReviver`
/// "keep the 5h timer warm" semantics. Lives in shared so the
/// `ProviderConfigAutoReviveTests` suite can assert the contract from
/// a swift-package XCTest target (no Mac target test scaffolding needed).
///
/// No provider currently qualifies. Claude used to be enabled here, but the
/// implementation kept the window warm by sending a tiny model prompt, which
/// consumed quota and created visible throwaway conversations. Any future
/// provider must use a non-generative endpoint before opting in.
///
/// When a new provider lands, add it here AND add the corresponding
/// `ProviderConfig.<provider>.supportsAutoRevive` constant (the
/// `ProviderHardcodingAuditTests` snapshot already covers the literal-
/// branch refactor).
public enum AutoReviveSupport {
    public static func supports(_ providerID: String) -> Bool {
        switch providerID {
        case "claude": return false
        case "codex":  return false
        case "gemini": return false
        default:       return false
        }
    }
}
