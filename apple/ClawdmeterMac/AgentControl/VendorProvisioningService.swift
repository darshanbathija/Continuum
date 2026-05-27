import AppKit
import Foundation
import OSLog
import ClawdmeterShared

private let vendorProvisioningLogger = Logger(
    subsystem: "com.clawdmeter.mac",
    category: "VendorProvisioning"
)

enum VendorProvisioningError: Error, LocalizedError, Equatable {
    case unknownVendor(String)
    case unknownAction(vendorId: String, actionId: String)
    case unsupportedAction(String)
    case noWorkspaces
    case workspaceNotFound(UUID)
    case emptyEnvPayload

    var errorDescription: String? {
        switch self {
        case .unknownVendor(let id):
            return "Unknown vendor: \(id)"
        case .unknownAction(let vendorId, let actionId):
            return "Unknown action \(actionId) for vendor \(vendorId)"
        case .unsupportedAction(let actionId):
            return "Unsupported vendor action: \(actionId)"
        case .noWorkspaces:
            return "No repositories are registered yet."
        case .workspaceNotFound(let id):
            return "Repository workspace not found: \(id.uuidString)"
        case .emptyEnvPayload:
            return "No environment variables were provided."
        }
    }
}

@MainActor
public final class VendorProvisioningService: ObservableObject {
    struct TerminalLaunchResult: Sendable {
        let launched: Bool
        let message: String
        let windowId: String?
        let paneId: String?

        init(
            launched: Bool,
            message: String,
            windowId: String? = nil,
            paneId: String? = nil
        ) {
            self.launched = launched
            self.message = message
            self.windowId = windowId
            self.paneId = paneId
        }
    }

    private let workspaceStore: WorkspaceStore
    private let envStore: RepoEnvStore
    private let repoEnvResolver: RepoEnvRuntimeResolver
    private let catalog: [VendorProvisioningVendor]
    private let pluginDiscovery: () -> [PluginInfo]
    private let shellRunner: ShellRunner
    private let openURL: (URL) -> Bool
    private let launchTerminalCommand: (String) async -> TerminalLaunchResult
    private let deviceProbe: ((VendorProvisioningVendor, [PluginInfo]) async -> VendorProvisioningStatus)?

    init(
        workspaceStore: WorkspaceStore,
        envStore: RepoEnvStore,
        repoEnvResolver: RepoEnvRuntimeResolver,
        catalog: [VendorProvisioningVendor] = VendorProvisioningCatalog.vendors,
        pluginDiscovery: @escaping () -> [PluginInfo] = { PluginRegistry.discover() },
        shellRunner: ShellRunner = .shared,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        tmuxClient: TmuxControlClient? = nil,
        launchTerminalCommand: ((String) async -> TerminalLaunchResult)? = nil,
        deviceProbe: ((VendorProvisioningVendor, [PluginInfo]) async -> VendorProvisioningStatus)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.envStore = envStore
        self.repoEnvResolver = repoEnvResolver
        self.catalog = catalog
        self.pluginDiscovery = pluginDiscovery
        self.shellRunner = shellRunner
        self.openURL = openURL
        self.launchTerminalCommand = launchTerminalCommand ?? { command in
            await VisibleTerminalCommandLauncher.launch(command, tmuxClient: tmuxClient)
        }
        self.deviceProbe = deviceProbe
    }

    func vendorsResponse() -> VendorProvisioningVendorsResponse {
        VendorProvisioningVendorsResponse(vendors: catalog)
    }

    func checkDevice() async -> VendorProvisioningCheckResponse {
        let plugins = pluginDiscovery()
        let statuses = await withTaskGroup(of: (Int, VendorProvisioningStatus).self) { group in
            for (index, vendor) in catalog.enumerated() {
                group.addTask { [plugins, deviceProbe] in
                    let status: VendorProvisioningStatus
                    if let deviceProbe {
                        status = await deviceProbe(vendor, plugins)
                    } else {
                        status = await self.probe(vendor: vendor, plugins: plugins)
                    }
                    return (index, status)
                }
            }

            var ordered = Array<VendorProvisioningStatus?>(repeating: nil, count: catalog.count)
            for await (index, status) in group {
                ordered[index] = status
            }
            return ordered.compactMap { $0 }
        }
        return VendorProvisioningCheckResponse(vendors: catalog, statuses: statuses)
    }

    func performAction(
        vendorId: String,
        actionId: String
    ) async throws -> VendorProvisioningActionResponse {
        let vendor = try vendor(id: vendorId)
        guard let action = vendor.actions.first(where: { $0.id == actionId }) else {
            throw VendorProvisioningError.unknownAction(vendorId: vendorId, actionId: actionId)
        }
        switch action.kind {
        case .signup:
            guard let url = action.url ?? vendor.signupURL else {
                throw VendorProvisioningError.unsupportedAction(actionId)
            }
            let opened = openURL(url)
            return VendorProvisioningActionResponse(
                vendorId: vendor.id,
                actionId: action.id,
                launched: opened,
                url: url,
                message: opened ? "Opened signup flow in the browser." : "Could not open signup URL."
            )
        case .install, .authenticate:
            guard let command = action.command,
                  isAllowlisted(command: command, vendor: vendor)
            else {
                throw VendorProvisioningError.unsupportedAction(actionId)
            }
            let launch = await launchTerminalCommand(command)
            return VendorProvisioningActionResponse(
                vendorId: vendor.id,
                actionId: action.id,
                launched: launch.launched,
                command: command,
                terminalWindowId: launch.windowId,
                terminalPaneId: launch.paneId,
                message: launch.message
            )
        }
    }

    func previewEnv(
        vendorId: String,
        request: VendorEnvPreviewRequest
    ) throws -> VendorEnvPreviewResponse {
        let vendor = try vendor(id: vendorId)
        let workspace = try resolveWorkspace(id: request.currentWorkspaceId)
        let text = try envText(from: request.envText, candidates: request.candidates)
        let targetWorkspaceIds = try resolveTargetWorkspaceIds(
            request.workspaceIds.isEmpty ? [workspace.id] : request.workspaceIds
        )
        let previews = previewImport(text, targetWorkspaceIds: targetWorkspaceIds)
        return VendorEnvPreviewResponse(
            vendorId: vendor.id,
            workspaceId: workspace.id,
            previews: previews.map(Self.previewItem(from:))
        )
    }

    func importEnv(
        vendorId: String,
        request: VendorEnvImportRequest
    ) throws -> VendorEnvImportResponse {
        let vendor = try vendor(id: vendorId)
        let currentWorkspace = try resolveWorkspace(id: request.currentWorkspaceId)
        let targetWorkspaceIds = try resolveTargetWorkspaceIds(request.workspaceIds)
        let selectedSetIds = Set(request.selectedSetIds)
        let text = try envText(from: request.envText, candidates: request.candidates)
        let previews = envStore.previewImport(text, workspaceId: currentWorkspace.id)
        let batch = try envStore.importVariables(
            previews: previews,
            workspaceIds: targetWorkspaceIds,
            selectedSetIds: selectedSetIds,
            currentWorkspaceId: currentWorkspace.id,
            conflictStrategy: request.conflictStrategy.repoEnvStrategy,
            kind: .sensitive,
            actor: "vendor:\(vendor.id)"
        )
        let materialized = try repoEnvResolver.materializeActiveSet(repoRoot: currentWorkspace.repoRoot) != nil
        return VendorEnvImportResponse(
            vendorId: vendor.id,
            batchId: batch.id,
            workspaceIds: batch.workspaceIds,
            importedCount: batch.importedCount,
            overwrittenCount: batch.overwrittenCount,
            skippedCount: batch.skippedCount,
            invalidCount: batch.invalidCount,
            actor: batch.actor,
            materializedCurrentRepo: materialized
        )
    }

    func isAllowlisted(command: String, vendor: VendorProvisioningVendor) -> Bool {
        vendor.actions.contains { action in
            (action.kind == .install || action.kind == .authenticate) && action.command == command
        }
    }

    private func vendor(id: String) throws -> VendorProvisioningVendor {
        guard let found = catalog.first(where: { $0.id == id }) else {
            throw VendorProvisioningError.unknownVendor(id)
        }
        return found
    }

    private func resolveWorkspace(id: UUID?) throws -> CodeWorkspaceRecord {
        if let id {
            guard let workspace = workspaceStore.workspace(id: id) else {
                throw VendorProvisioningError.workspaceNotFound(id)
            }
            return workspace
        }
        guard let first = workspaceStore.all().sorted(by: Self.workspaceSort).first else {
            throw VendorProvisioningError.noWorkspaces
        }
        return first
    }

    private func resolveTargetWorkspaceIds(_ ids: [UUID]) throws -> [UUID] {
        let all = workspaceStore.all()
        if ids.isEmpty {
            return all.map(\.id)
        }
        let known = Set(all.map(\.id))
        for id in ids where !known.contains(id) {
            throw VendorProvisioningError.workspaceNotFound(id)
        }
        return Array(Set(ids))
    }

    private func previewImport(
        _ text: String,
        targetWorkspaceIds: [UUID]
    ) -> [RepoEnvImportPreviewRecord] {
        let existingKeys = Set(targetWorkspaceIds.flatMap { envStore.variables(for: $0).map(\.key) })
        return RepoEnvImportParser.parse(text).map { preview in
            guard preview.status == .ready,
                  let key = preview.key,
                  existingKeys.contains(key)
            else { return preview }
            return RepoEnvImportPreviewRecord(
                line: preview.line,
                key: key,
                value: preview.value,
                status: .duplicate,
                message: "\(key) already exists in the selected repo targets."
            )
        }
    }

    private func envText(from rawText: String?, candidates: [VendorEnvCandidate]) throws -> String {
        if let rawText,
           !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawText
        }
        let lines = candidates
            .map { candidate in
                (
                    key: candidate.key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                    value: candidate.value
                )
            }
            .filter { !$0.key.isEmpty && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.key)=\(RepoEnvFileMaterializer.encodeEnvValue($0.value))" }
        guard !lines.isEmpty else {
            throw VendorProvisioningError.emptyEnvPayload
        }
        return lines.joined(separator: "\n")
    }

    private func probe(
        vendor: VendorProvisioningVendor,
        plugins: [PluginInfo]
    ) async -> VendorProvisioningStatus {
        let matches = mcpMatches(for: vendor, plugins: plugins)
        guard let binary = firstInstalledBinary(for: vendor) else {
            return VendorProvisioningStatus(
                vendorId: vendor.id,
                cliStatus: .notInstalled,
                message: "CLI not installed.",
                mcpMatches: matches
            )
        }

        async let version = cliVersion(binary: binary)
        async let auth = authStatus(vendor: vendor, binary: binary)
        let resolvedVersion = await version
        let authProbe = await auth
        return VendorProvisioningStatus(
            vendorId: vendor.id,
            cliStatus: authProbe.status,
            installedBinary: binary,
            version: resolvedVersion,
            accountLabel: authProbe.accountLabel,
            projectLabel: authProbe.projectLabel,
            message: authProbe.message,
            mcpMatches: matches
        )
    }

    private func firstInstalledBinary(for vendor: VendorProvisioningVendor) -> String? {
        for name in vendor.cliNames {
            if let binary = ShellRunner.locateBinary(name) {
                return binary
            }
        }
        return nil
    }

    private func cliVersion(binary: String) async -> String? {
        do {
            let result = try await shellRunner.run(
                executable: binary,
                arguments: ["--version"],
                timeout: 3
            )
            guard result.exitStatus == 0 else { return nil }
            return Self.oneLine(result.stdoutString, limit: 100)
        } catch {
            return nil
        }
    }

    private struct AuthProbe {
        let status: VendorProvisioningCLIAuthStatus
        let accountLabel: String?
        let projectLabel: String?
        let message: String?
    }

    private func authStatus(
        vendor: VendorProvisioningVendor,
        binary: String
    ) async -> AuthProbe {
        let args = authProbeArguments(for: vendor.id)
        guard !args.isEmpty else {
            return AuthProbe(status: .installed, accountLabel: nil, projectLabel: nil, message: "CLI installed.")
        }
        do {
            let result = try await shellRunner.run(
                executable: binary,
                arguments: args,
                timeout: 6
            )
            if result.exitStatus == 0 {
                return parseAuthenticatedProbe(vendor: vendor, stdout: result.stdoutString)
            }
            return AuthProbe(
                status: .unauthenticated,
                accountLabel: nil,
                projectLabel: nil,
                message: Self.safeMessage(result.stderrString, fallback: "CLI installed, authentication not confirmed.")
            )
        } catch let error as ShellRunner.ShellError {
            return AuthProbe(
                status: .error,
                accountLabel: nil,
                projectLabel: nil,
                message: Self.safeMessage(String(describing: error), fallback: "CLI probe failed.")
            )
        } catch {
            return AuthProbe(
                status: .error,
                accountLabel: nil,
                projectLabel: nil,
                message: "CLI probe failed."
            )
        }
    }

    private func authProbeArguments(for vendorId: String) -> [String] {
        switch vendorId {
        case "mongodb-atlas": return ["auth", "whoami"]
        case "upstash": return ["redis", "list"]
        case "supabase": return ["projects", "list", "--output", "json"]
        case "fly": return ["auth", "whoami"]
        case "railway": return ["whoami", "--json"]
        case "hetzner": return ["context", "active"]
        case "aws": return ["sts", "get-caller-identity", "--output", "json", "--no-cli-pager"]
        case "gcp": return ["auth", "list", "--filter=status:ACTIVE", "--format=value(account)"]
        case "azure": return ["account", "show", "--output", "json"]
        case "cloudflare": return ["whoami"]
        default: return []
        }
    }

    private func parseAuthenticatedProbe(
        vendor: VendorProvisioningVendor,
        stdout: String
    ) -> AuthProbe {
        let line = Self.oneLine(stdout, limit: 140)
        switch vendor.id {
        case "aws":
            if let json = Self.jsonObject(stdout),
               let account = json["Account"] as? String {
                return AuthProbe(
                    status: .authenticated,
                    accountLabel: "Account \(Self.redact(account))",
                    projectLabel: nil,
                    message: "AWS credentials are active."
                )
            }
        case "azure":
            if let json = Self.jsonObject(stdout) {
                let user = (json["user"] as? [String: Any])?["name"] as? String
                let subscription = json["name"] as? String ?? json["id"] as? String
                return AuthProbe(
                    status: .authenticated,
                    accountLabel: user.map(Self.redact),
                    projectLabel: subscription.map(Self.redact),
                    message: "Azure account is active."
                )
            }
        case "railway":
            if let json = Self.jsonObject(stdout) {
                let email = json["email"] as? String ?? json["name"] as? String
                return AuthProbe(
                    status: .authenticated,
                    accountLabel: email.map(Self.redact),
                    projectLabel: nil,
                    message: "Railway account is active."
                )
            }
        case "supabase":
            return AuthProbe(
                status: .authenticated,
                accountLabel: nil,
                projectLabel: "Projects visible",
                message: "Supabase CLI is authenticated."
            )
        default:
            break
        }
        if let line, !line.isEmpty {
            return AuthProbe(
                status: .authenticated,
                accountLabel: Self.redact(line),
                projectLabel: nil,
                message: "\(vendor.displayName) CLI is authenticated."
            )
        }
        return AuthProbe(
            status: .installed,
            accountLabel: nil,
            projectLabel: nil,
            message: "CLI installed. Authentication status could not be confirmed."
        )
    }

    private func mcpMatches(
        for vendor: VendorProvisioningVendor,
        plugins: [PluginInfo]
    ) -> [VendorProvisioningMCPMatch] {
        let aliases = Set(([vendor.id, vendor.displayName] + vendor.mcpAliases)
            .map { Self.normalized($0) }
            .filter { !$0.isEmpty })
        return plugins.compactMap { plugin in
            let haystack = [
                plugin.name,
                plugin.source,
                plugin.kind.rawValue,
            ].map(Self.normalized).joined(separator: " ")
            guard aliases.contains(where: { haystack.contains($0) }) else { return nil }
            return VendorProvisioningMCPMatch(
                name: plugin.name,
                kind: plugin.kind.rawValue,
                source: plugin.source
            )
        }
    }

    private static func previewItem(from preview: RepoEnvImportPreviewRecord) -> VendorEnvPreviewItem {
        VendorEnvPreviewItem(
            id: preview.id,
            line: preview.line,
            key: preview.key,
            status: preview.status.rawValue,
            message: preview.message,
            canImport: preview.canImport
        )
    }

    private static func workspaceSort(_ lhs: CodeWorkspaceRecord, _ rhs: CodeWorkspaceRecord) -> Bool {
        lhs.repoDisplayName.localizedCaseInsensitiveCompare(rhs.repoDisplayName) == .orderedAscending
    }

    private static func oneLine(_ text: String, limit: Int) -> String? {
        let trimmed = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let trimmed else { return nil }
        return String(trimmed.prefix(limit))
    }

    private static func safeMessage(_ text: String, fallback: String) -> String {
        guard let line = oneLine(text, limit: 160), !line.isEmpty else { return fallback }
        return redact(line)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func redact(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.contains("token")
            || lower.contains("secret")
            || lower.contains("password")
            || lower.contains("bearer ")
            || lower.hasPrefix("sk-") {
            return "[redacted]"
        }
        if trimmed.count > 72 {
            return "\(trimmed.prefix(32))...\(trimmed.suffix(8))"
        }
        return trimmed
    }
}

private enum VisibleTerminalCommandLauncher {
    static func launch(
        _ command: String,
        tmuxClient: TmuxControlClient?
    ) async -> VendorProvisioningService.TerminalLaunchResult {
        guard let tmuxClient else {
            return .init(launched: false, message: "tmux is unavailable for vendor provisioning commands.")
        }

        do {
            try await tmuxClient.start()
            let ref = try await tmuxClient.newWindow(
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                child: ["/bin/zsh", "-lc", tmuxShellScript(for: command)]
            )
            _ = try? await tmuxClient.command(["select-window", "-t", ref.windowId])
            let attachOpened = launchTerminalAttach(tmuxClient: tmuxClient)
            let message = attachOpened
                ? "Opened a visible tmux terminal for this command."
                : "Launched in tmux, but Terminal attach automation failed."
            return .init(
                launched: true,
                message: message,
                windowId: ref.windowId,
                paneId: ref.paneId
            )
        } catch {
            vendorProvisioningLogger.error("tmux vendor command launch failed: \(error.localizedDescription, privacy: .public)")
            return .init(
                launched: false,
                message: "Could not launch tmux command: \(error.localizedDescription)"
            )
        }
    }

    private static func launchTerminalAttach(tmuxClient: TmuxControlClient) -> Bool {
        let command = [
            shellQuoted(tmuxClient.configuration.tmuxBinary),
            "-L",
            shellQuoted(tmuxClient.configuration.socketName),
            "attach",
            "-t",
            "control",
        ].joined(separator: " ")
        let script = """
        tell application "Terminal"
          activate
          do script "\(appleScriptEscaped(command))"
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: script)?.executeAndReturnError(&error) != nil {
            return true
        }
        if let error {
            vendorProvisioningLogger.warning("Terminal launch failed: \(String(describing: error), privacy: .public)")
        }
        return false
    }

    private static func tmuxShellScript(for command: String) -> String {
        """
        clear
        echo 'Clawdmeter vendor provisioning'
        echo '+ \(shellQuoted(command))'
        \(command)
        status=$?
        echo
        echo "Command exited with status $status."
        echo "Press Return to close this terminal."
        read _
        exit $status
        """
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private extension VendorEnvConflictStrategy {
    var repoEnvStrategy: RepoEnvImportConflictStrategy {
        switch self {
        case .skip: return .skip
        case .overwrite: return .overwrite
        case .createDisabledDrafts: return .createDisabledDrafts
        }
    }
}
