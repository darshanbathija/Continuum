import Foundation

/// Single source of truth for which providers support `AutoReviver`
/// "keep the 5h timer warm" semantics. Lives in shared so the
/// `ProviderConfigAutoReviveTests` suite can assert the contract from
/// a swift-package XCTest target (no Mac target test scaffolding needed).
///
/// Today only Claude qualifies — Anthropic's perpetual 5h-window quota
/// model is what auto-revive targets. Codex's wham/usage quota is
/// already tied to user activity; firing a "1-token Hi" wouldn't
/// meaningfully extend the window. Gemini's cloudcode-pa quota uses
/// 24h-style refreshes per model with no benefit from auto-revive.
///
/// When a new provider lands, add it here AND add the corresponding
/// `ProviderConfig.<provider>.supportsAutoRevive` constant (the
/// `ProviderHardcodingAuditTests` snapshot already covers the literal-
/// branch refactor).
public enum AutoReviveSupport {
    public static func supports(_ providerID: String) -> Bool {
        switch providerID {
        case "claude": return true
        case "codex":  return false
        case "gemini": return false
        default:       return false
        }
    }
}
