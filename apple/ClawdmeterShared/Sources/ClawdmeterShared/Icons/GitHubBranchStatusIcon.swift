#if canImport(SwiftUI)
import SwiftUI

/// GitHub Octicon branch / pull-request glyphs with Primer semantic colors.
///
/// Icons are sourced from [primer/octicons](https://github.com/primer/octicons)
/// (MIT). Colors follow the Octicons usage guidelines
/// ([primer.style/octicons/usage-guidelines](https://primer.style/octicons/usage-guidelines/)):
/// `git-pull-request` → fg.success, `git-pull-request-closed` → fg.danger,
/// `git-merge` → fg.done, `git-branch` / draft → fg.muted.
public enum GitHubBranchIconKind: Equatable, Sendable {
    case branch
    case pullRequestOpen
    case pullRequestDraft
    case pullRequestClosed
    case pullRequestMerged

    /// Asset-catalog name for the bundled 16×16 Octicon SVG.
    public var assetName: String {
        switch self {
        case .branch:               return "github-octicon-git-branch"
        case .pullRequestOpen:      return "github-octicon-git-pull-request"
        case .pullRequestDraft:     return "github-octicon-git-pull-request-draft"
        case .pullRequestClosed:    return "github-octicon-git-pull-request-closed"
        case .pullRequestMerged:    return "github-octicon-git-merge"
        }
    }

    /// Primer `fgColor-*` token for the dark theme (github.com).
    public var color: Color {
        switch self {
        case .branch, .pullRequestDraft:
            return GitHubBranchIconPalette.muted
        case .pullRequestOpen:
            return GitHubBranchIconPalette.success
        case .pullRequestClosed:
            return GitHubBranchIconPalette.danger
        case .pullRequestMerged:
            return GitHubBranchIconPalette.done
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .branch:               return "Branch"
        case .pullRequestOpen:      return "Open pull request"
        case .pullRequestDraft:     return "Draft pull request"
        case .pullRequestClosed:    return "Closed pull request"
        case .pullRequestMerged:    return "Merged pull request"
        }
    }

    public static func from(prState: PRStatus.State?) -> GitHubBranchIconKind {
        guard let prState else { return .branch }
        return from(prStateRaw: prState.rawValue)
    }

    public static func from(prStateRaw: String?) -> GitHubBranchIconKind {
        switch prStateRaw?.lowercased() {
        case "open":   return .pullRequestOpen
        case "draft":  return .pullRequestDraft
        case "closed": return .pullRequestClosed
        case "merged": return .pullRequestMerged
        default:      return .branch
        }
    }

    /// When multiple sessions on a worktree disagree, prefer the most
    /// actionable PR state (open beats draft beats merged beats closed).
    public static func preferred(from states: [PRStatus.State]) -> GitHubBranchIconKind {
        guard !states.isEmpty else { return .branch }
        if states.contains(.open) { return .pullRequestOpen }
        if states.contains(.draft) { return .pullRequestDraft }
        if states.contains(.merged) { return .pullRequestMerged }
        if states.contains(.closed) { return .pullRequestClosed }
        return .branch
    }
}

/// GitHub Primer foreground semantic colors (dark theme output values).
public enum GitHubBranchIconPalette {
    /// `--fgColor-success` — open pull requests.
    public static let success = Color(red: 0x3F / 255.0, green: 0xB9 / 255.0, blue: 0x50 / 255.0)
    /// `--fgColor-danger` — closed-without-merge pull requests.
    public static let danger = Color(red: 0xF8 / 255.0, green: 0x51 / 255.0, blue: 0x49 / 255.0)
    /// `--fgColor-done` — merged pull requests.
    public static let done = Color(red: 0xA3 / 255.0, green: 0x71 / 255.0, blue: 0xF7 / 255.0)
    /// `--fgColor-muted` — plain branches and draft PRs.
    public static let muted = Color(red: 0x8B / 255.0, green: 0x94 / 255.0, blue: 0x9E / 255.0)
}

public struct GitHubBranchStatusIcon: View {
    public let kind: GitHubBranchIconKind
    public var size: CGFloat

    public init(_ kind: GitHubBranchIconKind, size: CGFloat = 14) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        Image(kind.assetName, bundle: .module)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(kind.color)
            .accessibilityLabel(kind.accessibilityLabel)
    }
}
#endif
