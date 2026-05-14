import Foundation
import SwiftUI
import ClawdmeterShared

/// Per-source UI + behavior config. One per provider (Claude, Codex, ...).
public struct ProviderConfig: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let logoAssetName: String            // Bundle resource name (e.g. "ClaudeLogo")
    public let reviveModel: String              // Model id used by AutoReviver for the "Hi" ping
    public let reviveEndpoint: URL              // POST target for AutoReviver
    public let reviveAuthVersion: String?       // e.g. "anthropic-version: 2023-06-01" (nil for OpenAI)
    public let storageKeyPrefix: String         // Namespacing for @AppStorage

    public static let claude = ProviderConfig(
        id: "claude",
        displayName: "Claude",
        logoAssetName: "ClaudeLogo",
        reviveModel: "claude-haiku-4-5",
        reviveEndpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        reviveAuthVersion: "2023-06-01",
        storageKeyPrefix: "clawdmeter.claude"
    )

    public static let codex = ProviderConfig(
        id: "codex",
        displayName: "Codex",
        logoAssetName: "CodexLogo",
        reviveModel: "gpt-5.5-mini",
        reviveEndpoint: URL(string: "https://chatgpt.com/backend-api/conversation")!,
        reviveAuthVersion: nil,
        storageKeyPrefix: "clawdmeter.codex"
    )
}
