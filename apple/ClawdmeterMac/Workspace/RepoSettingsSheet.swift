import SwiftUI
import ClawdmeterShared

/// Repo-scoped settings surfaced from the Code sidebar gear menu. Combines
/// worktree copy defaults with the full repo env-variable manager, locked to
/// the project the user clicked.
struct RepoSettingsContext: Identifiable, Hashable {
    let repoKey: String
    let repoDisplayName: String
    let repoRoot: String
    let workspaceId: UUID?

    var id: String { repoKey }
}

struct RepoSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t

    let context: RepoSettingsContext
    let workspaceStore: WorkspaceStore?
    let envStore: RepoEnvStore?
    let resolver: RepoEnvRuntimeResolver?
    var onOpenFullSettings: (UUID?) -> Void

    @State private var workspaceRecord: CodeWorkspaceRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    worktreeSetupSection
                    envVariablesSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 920, idealWidth: 960, maxWidth: 1040, minHeight: 680, idealHeight: 820, maxHeight: 900)
        .background(t.surfaceSolid)
        .accessibilityIdentifier("code.repo.settings.sheet")
        .task { refreshWorkspaceRecord() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings & Env Variables")
                    .font(TahoeFont.body(20, weight: .bold))
                    .foregroundStyle(t.fg)
                Text(context.repoDisplayName)
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg2)
                Text(context.repoRoot)
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg3)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                TahoeIcon("x", size: 12, weight: .bold)
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
    }

    @ViewBuilder
    private var worktreeSetupSection: some View {
        TahoeGlass(radius: 8, tone: .panel) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WORKTREE SETUP")
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(t.fg3)
                    Text("Files copied into new worktrees for this repository.")
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg3)
                }

                if let workspaceRecord {
                    let effective = effectivePatterns(for: workspaceRecord)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(effective.sourceLabel)
                                .font(TahoeFont.body(11, weight: .semibold))
                                .foregroundStyle(effective.readOnly ? t.accent : t.fg3)
                            Spacer(minLength: 0)
                            Text("max \(workspaceRecord.filesToCopy.maxFiles) files")
                                .font(TahoeFont.body(11))
                                .foregroundStyle(t.fg4)
                        }
                        Text(effective.display)
                            .font(TahoeFont.body(12))
                            .foregroundStyle(t.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("per file \(Self.bytes(workspaceRecord.filesToCopy.maxBytesPerFile)) · total \(Self.bytes(workspaceRecord.filesToCopy.maxTotalBytes)) · directories \(workspaceRecord.filesToCopy.allowDirectories ? "allowed" : "files only")")
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg4)
                    }
                    .accessibilityIdentifier("code.repo.settings.worktree")
                } else {
                    Text("This repository is visible in the sidebar but does not have a managed workspace record yet. Env variables and worktree defaults become available once the repo is registered.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var envVariablesSection: some View {
        if workspaceRecord != nil || context.workspaceId != nil {
            RepoEnvVariablesSettingsView(
                workspaceStore: workspaceStore,
                envStore: envStore,
                resolver: resolver,
                preferredWorkspaceId: workspaceRecord?.id ?? context.workspaceId,
                lockRepositorySelection: true
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Open in Settings…") {
                onOpenFullSettings(workspaceRecord?.id ?? context.workspaceId)
                dismiss()
            }
            .accessibilityIdentifier("code.repo.settings.open-full-settings")

            Spacer(minLength: 0)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("code.repo.settings.done")
        }
    }

    private func refreshWorkspaceRecord() {
        guard let workspaceStore else {
            workspaceRecord = nil
            return
        }
        if let workspaceId = context.workspaceId,
           let record = workspaceStore.workspace(id: workspaceId) {
            workspaceRecord = record
            return
        }
        if let record = workspaceStore.workspace(forRepoRoot: context.repoRoot) {
            workspaceRecord = record
            return
        }
        workspaceRecord = workspaceStore.all().first { record in
            RepoSettingsContext.matches(record: record, repoKey: context.repoKey, repoRoot: context.repoRoot)
        }
    }

    private func effectivePatterns(for record: CodeWorkspaceRecord) -> (sourceLabel: String, display: String, readOnly: Bool) {
        let includeURL = URL(fileURLWithPath: record.repoRoot, isDirectory: true)
            .appendingPathComponent(".worktreeinclude")
        if let text = try? String(contentsOf: includeURL, encoding: .utf8) {
            return (
                ".worktreeinclude read-only",
                text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).joined(separator: ", "),
                true
            )
        }
        if !record.filesToCopy.enabled {
            return ("disabled", "(disabled)", false)
        }
        let isDefault = record.filesToCopy.mode == .allIgnored
            && record.filesToCopy.patterns == WorkspaceFilesToCopySettings.defaultPatterns
            && record.filesToCopy.maxFiles == WorkspaceFilesToCopySettings.defaultMaxFiles
            && record.filesToCopy.maxBytesPerFile == WorkspaceFilesToCopySettings.defaultMaxBytesPerFile
            && record.filesToCopy.maxTotalBytes == WorkspaceFilesToCopySettings.defaultMaxTotalBytes
            && record.filesToCopy.allowDirectories == true
        let display = record.filesToCopy.mode == .allIgnored
            ? "all ignored files, directories, dependencies, build artifacts, and local databases"
            : record.filesToCopy.patterns.joined(separator: ", ")
        return (isDefault ? "default" : "settings", display, false)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

extension RepoSettingsContext {
    static func matches(record: CodeWorkspaceRecord, repoKey: String, repoRoot: String) -> Bool {
        var candidates: Set<String> = []
        func addCandidate(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let canonical = WorkspaceKey.canonicalPath(trimmed)
            candidates.insert(trimmed)
            candidates.insert(canonical)
            candidates.insert(RepoIdentity.normalize(trimmed))
            candidates.insert(RepoIdentity.normalize(canonical))
        }

        addCandidate(repoKey)
        addCandidate(repoRoot)

        var workspaceKeys: Set<String> = []
        let canonical = WorkspaceKey.canonicalPath(record.repoRoot)
        workspaceKeys.insert(record.repoRoot)
        workspaceKeys.insert(canonical)
        workspaceKeys.insert(RepoIdentity.normalize(record.repoRoot))
        workspaceKeys.insert(RepoIdentity.normalize(canonical))
        return !workspaceKeys.isDisjoint(with: candidates)
    }
}
