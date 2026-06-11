import Foundation
import ClawdmeterShared

enum RepoEnvVendorImportSource: String, CaseIterable, Identifiable, Sendable {
    case paste = "Paste / File"
    case aws = "AWS"
    case vercel = "Vercel"
    case gcp = "GCP"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paste: return "Paste / File"
        case .aws: return "AWS Secrets Manager"
        case .vercel: return "Vercel"
        case .gcp: return "GCP Secret Manager"
        }
    }

    var cliBinaryName: String? {
        switch self {
        case .paste: return nil
        case .aws: return "aws"
        case .vercel: return "vercel"
        case .gcp: return "gcloud"
        }
    }

    var oneClickLabel: String {
        switch self {
        case .paste: return "Import"
        case .aws: return "Import from AWS Secrets Manager"
        case .vercel: return "Import from Vercel"
        case .gcp: return "Import from GCP Secret Manager"
        }
    }
}

enum RepoEnvVercelEnvironment: String, CaseIterable, Identifiable, Sendable {
    case production
    case preview
    case development

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

struct RepoEnvVendorImportOptions: Sendable, Equatable {
    var awsRegion: String = ""
    var awsNamePrefix: String = ""
    var gcpProject: String = ""
    var gcpNamePrefix: String = ""
    var vercelEnvironment: RepoEnvVercelEnvironment = .production
    var repoRoot: String?
}

struct RepoEnvVendorImportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case listing
        case fetching(current: Int, total: Int, secretName: String)
        case importing(current: Int, total: Int)
        case complete(variableCount: Int, secretCount: Int?, skippedCount: Int)
        case failed(String)
    }

    let phase: Phase

    var fraction: Double {
        switch phase {
        case .listing:
            return 0.05
        case .fetching(let current, let total, _):
            guard total > 0 else { return 0.1 }
            return 0.1 + (0.75 * Double(current) / Double(total))
        case .importing(let current, let total):
            guard total > 0 else { return 0.9 }
            return 0.85 + (0.15 * Double(current) / Double(total))
        case .complete:
            return 1.0
        case .failed:
            return 0
        }
    }

    var statusLabel: String {
        switch phase {
        case .listing:
            return "Listing secrets…"
        case .fetching(let current, let total, let secretName):
            return "Fetching secret \(current) of \(total): \(secretName)"
        case .importing(let current, let total):
            return "Saving variable \(current) of \(total)…"
        case .complete(let variableCount, let secretCount, let skippedCount):
            var message: String
            if let secretCount, secretCount != variableCount {
                message = "Imported \(variableCount) variable\(variableCount == 1 ? "" : "s") from \(secretCount) secret\(secretCount == 1 ? "" : "s")."
            } else {
                message = "Imported \(variableCount) variable\(variableCount == 1 ? "" : "s")."
            }
            if skippedCount > 0 {
                message += " \(skippedCount) secret\(skippedCount == 1 ? "" : "s") skipped (couldn't be read)."
            }
            return message
        case .failed(let message):
            return message
        }
    }
}

struct RepoEnvVendorSecretsFetchResult: Sendable, Equatable {
    let envText: String
    let secretCount: Int
    let variableCount: Int
    let sourceLabel: String
    /// Secret names that were listed but couldn't be read (e.g. IAM denial, non-UTF-8
    /// binary). The batch still imports everything it could fetch. Empty for Vercel.
    var skippedSecretNames: [String] = []
}

enum RepoEnvVendorSecretsImportError: Error, LocalizedError, Equatable {
    case cliNotInstalled(String)
    case invalidCLIOutput(String)
    case noSecretsFound(String)
    case commandFailed(String)
    case repoRootRequired
    case singleWorkspaceRequired

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled(let binary):
            return "\(binary) CLI is not installed or not on PATH."
        case .invalidCLIOutput(let detail):
            return "Could not parse CLI output: \(detail)"
        case .noSecretsFound(let detail):
            return detail
        case .commandFailed(let detail):
            return detail
        case .repoRootRequired:
            return "Select a repository workspace to import Vercel environment variables."
        case .singleWorkspaceRequired:
            return "Select exactly one repository workspace for vendor import."
        }
    }
}

struct RepoEnvVendorSecretsImporter: Sendable {
    typealias ShellRun = @Sendable (
        String,
        [String],
        String?,
        [String: String]?,
        TimeInterval
    ) async throws -> ShellRunner.Result

    /// Resolves a CLI name to an absolute path (nil = not installed). Injectable so tests
    /// are deterministic regardless of which CLIs happen to be on the host's PATH.
    typealias LocateBinary = @Sendable (String) -> String?

    private let shellRun: ShellRun
    private let locateBinary: LocateBinary

    /// Max seconds to wait for any single vendor CLI invocation.
    private static let cliTimeout: TimeInterval = 120

    init(shellRunner: ShellRunner = .shared) {
        self.shellRun = { executable, arguments, cwd, environment, timeout in
            try await shellRunner.run(
                executable: executable,
                arguments: arguments,
                cwd: cwd,
                environment: environment,
                timeout: timeout
            )
        }
        self.locateBinary = { ShellRunner.locateBinary($0) }
    }

    init(
        shellRun: @escaping ShellRun,
        locateBinary: @escaping LocateBinary = { ShellRunner.locateBinary($0) }
    ) {
        self.shellRun = shellRun
        self.locateBinary = locateBinary
    }

    func fetchSecrets(
        source: RepoEnvVendorImportSource,
        options: RepoEnvVendorImportOptions,
        onProgress: @Sendable (RepoEnvVendorImportProgress) -> Void = { _ in }
    ) async throws -> RepoEnvVendorSecretsFetchResult {
        switch source {
        case .paste:
            throw RepoEnvVendorSecretsImportError.commandFailed("Paste import does not use vendor fetch.")
        case .aws:
            return try await fetchAWSSecrets(options: options, onProgress: onProgress)
        case .vercel:
            return try await fetchVercelSecrets(options: options, onProgress: onProgress)
        case .gcp:
            return try await fetchGCPSecrets(options: options, onProgress: onProgress)
        }
    }

    static func envKey(fromSecretName name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .uppercased()
    }

    static func envLines(fromSecretName name: String, secretString: String) -> [String] {
        let trimmed = secretString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           !object.isEmpty,
           object.values.allSatisfy({ $0 is String || $0 is NSNumber || $0 is Bool }) {
            return object.compactMap { key, value in
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !normalizedKey.isEmpty, RepoEnvStore.isValidKey(normalizedKey) else { return nil }
                let stringValue: String
                // JSON booleans bridge to NSNumber, so they must be detected via CFBoolean
                // BEFORE the NSNumber branch — otherwise `true`/`false` would render as 1/0.
                if CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() {
                    stringValue = (value as? Bool ?? false) ? "true" : "false"
                } else if let string = value as? String {
                    stringValue = string
                } else if let number = value as? NSNumber {
                    stringValue = number.stringValue
                } else {
                    return nil
                }
                guard !stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return "\(normalizedKey)=\(RepoEnvFileMaterializer.encodeEnvValue(stringValue))"
            }
            .sorted()
        }

        let key = envKey(fromSecretName: name)
        guard RepoEnvStore.isValidKey(key) else { return [] }
        return ["\(key)=\(RepoEnvFileMaterializer.encodeEnvValue(trimmed))"]
    }

    /// De-duplicate `KEY=value` lines by key (last occurrence wins, order preserved) so the
    /// reported variable count matches what actually imports — two secrets can expand to the
    /// same key, and the downstream import parser dedups too.
    static func dedupedByKey(_ lines: [String]) -> [String] {
        var indexByKey: [String: Int] = [:]
        var result: [String] = []
        for line in lines {
            let key = String(line.prefix { $0 != "=" })
            if let existing = indexByKey[key] {
                result[existing] = line
            } else {
                indexByKey[key] = result.count
                result.append(line)
            }
        }
        return result
    }

    private func fetchAWSSecrets(
        options: RepoEnvVendorImportOptions,
        onProgress: @Sendable (RepoEnvVendorImportProgress) -> Void
    ) async throws -> RepoEnvVendorSecretsFetchResult {
        let binary = try requireBinary("aws")
        onProgress(.init(phase: .listing))

        let secretNames = try await listAWSSecretNames(binary: binary, options: options)
        let filtered = filterSecretNames(secretNames, prefix: options.awsNamePrefix)
        guard !filtered.isEmpty else {
            throw RepoEnvVendorSecretsImportError.noSecretsFound("No AWS secrets matched the current filters.")
        }

        var lines: [String] = []
        var skipped: [String] = []
        let total = filtered.count
        for (index, name) in filtered.enumerated() {
            try checkCancellation()
            onProgress(.init(phase: .fetching(current: index + 1, total: total, secretName: name)))
            do {
                let secretString = try await fetchAWSSecretValue(binary: binary, name: name, options: options)
                lines.append(contentsOf: Self.envLines(fromSecretName: name, secretString: secretString))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unreadable secret (IAM denial, non-UTF-8 binary, parse error) must not
                // abort the whole batch — skip it and surface it in the result.
                skipped.append(name)
            }
        }

        let deduped = Self.dedupedByKey(lines)
        let envText = deduped.joined(separator: "\n")
        guard !envText.isEmpty else {
            if !skipped.isEmpty {
                throw RepoEnvVendorSecretsImportError.commandFailed(
                    "None of the \(total) AWS secret\(total == 1 ? "" : "s") could be read (access denied or non-UTF-8 binary)."
                )
            }
            throw RepoEnvVendorSecretsImportError.noSecretsFound("AWS secrets were listed but no importable keys were found.")
        }

        return RepoEnvVendorSecretsFetchResult(
            envText: envText,
            secretCount: total - skipped.count,
            variableCount: deduped.count,
            sourceLabel: "AWS Secrets Manager",
            skippedSecretNames: skipped
        )
    }

    private func listAWSSecretNames(
        binary: String,
        options: RepoEnvVendorImportOptions
    ) async throws -> [String] {
        var names: [String] = []
        var nextToken: String?

        repeat {
            try checkCancellation()
            var arguments = ["secretsmanager", "list-secrets", "--output", "json", "--no-cli-pager"]
            appendRegion(&arguments, region: options.awsRegion)
            if let nextToken {
                arguments.append(contentsOf: ["--starting-token", nextToken])
            }

            let result = try await runCLI(binary: binary, arguments: arguments)
            guard let json = parseJSONObject(result.stdoutString) else {
                throw RepoEnvVendorSecretsImportError.invalidCLIOutput("AWS list-secrets response")
            }

            if let secretList = json["SecretList"] as? [[String: Any]] {
                names.append(contentsOf: secretList.compactMap { $0["Name"] as? String })
            }
            nextToken = json["NextToken"] as? String
        } while nextToken != nil

        return names.sorted()
    }

    private func fetchAWSSecretValue(
        binary: String,
        name: String,
        options: RepoEnvVendorImportOptions
    ) async throws -> String {
        var arguments = [
            "secretsmanager",
            "get-secret-value",
            "--secret-id", name,
            "--output", "json",
            "--no-cli-pager",
        ]
        appendRegion(&arguments, region: options.awsRegion)

        let result = try await runCLI(binary: binary, arguments: arguments)
        guard let json = parseJSONObject(result.stdoutString) else {
            throw RepoEnvVendorSecretsImportError.invalidCLIOutput("AWS get-secret-value for \(name)")
        }
        if let secretString = json["SecretString"] as? String {
            return secretString
        }
        if let secretBinary = json["SecretBinary"] as? String,
           let data = Data(base64Encoded: secretBinary),
           let decoded = String(data: data, encoding: .utf8),
           !decoded.isEmpty {
            return decoded
        }
        if json["SecretBinary"] != nil {
            throw RepoEnvVendorSecretsImportError.commandFailed(
                "Binary secret \(name) is not UTF-8 text and cannot be imported."
            )
        }
        throw RepoEnvVendorSecretsImportError.invalidCLIOutput("AWS get-secret-value for \(name)")
    }

    private func fetchVercelSecrets(
        options: RepoEnvVendorImportOptions,
        onProgress: @Sendable (RepoEnvVendorImportProgress) -> Void
    ) async throws -> RepoEnvVendorSecretsFetchResult {
        guard let repoRoot = options.repoRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty
        else {
            throw RepoEnvVendorSecretsImportError.repoRootRequired
        }

        let binary = try requireBinary("vercel")
        onProgress(.init(phase: .listing))
        try checkCancellation()

        // Pull into a per-invocation private directory (0700) and remove the whole directory
        // afterward, so the plaintext .env can't linger world-adjacent in the shared temp root.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-vercel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let tempFile = tempDir.appendingPathComponent("env")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await shellRun(
            binary,
            [
                "env", "pull", tempFile.path,
                "--environment", options.vercelEnvironment.rawValue,
                "--yes",
            ],
            repoRoot,
            SpawnPathResolver.merged(into: ProcessInfo.processInfo.environment),
            Self.cliTimeout
        )
        guard result.exitStatus == 0 else {
            throw RepoEnvVendorSecretsImportError.commandFailed(
                safeMessage(result.stderrString, fallback: "Vercel env pull failed.")
            )
        }

        let envText = (try? String(contentsOf: tempFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !envText.isEmpty else {
            throw RepoEnvVendorSecretsImportError.noSecretsFound(
                "No Vercel environment variables were found for \(options.vercelEnvironment.displayName)."
            )
        }

        let variableCount = RepoEnvImportParser.parse(envText).filter(\.canImport).count

        return RepoEnvVendorSecretsFetchResult(
            envText: envText,
            secretCount: variableCount,
            variableCount: variableCount,
            sourceLabel: "Vercel (\(options.vercelEnvironment.displayName))"
        )
    }

    private func fetchGCPSecrets(
        options: RepoEnvVendorImportOptions,
        onProgress: @Sendable (RepoEnvVendorImportProgress) -> Void
    ) async throws -> RepoEnvVendorSecretsFetchResult {
        let binary = try requireBinary("gcloud")
        onProgress(.init(phase: .listing))

        let secretNames = try await listGCPSecretNames(binary: binary, options: options)
        let filtered = filterSecretNames(secretNames, prefix: options.gcpNamePrefix)
        guard !filtered.isEmpty else {
            throw RepoEnvVendorSecretsImportError.noSecretsFound("No GCP secrets matched the current filters.")
        }

        var lines: [String] = []
        var skipped: [String] = []
        let total = filtered.count
        for (index, name) in filtered.enumerated() {
            try checkCancellation()
            onProgress(.init(phase: .fetching(current: index + 1, total: total, secretName: name)))
            do {
                let secretString = try await fetchGCPSecretValue(binary: binary, name: name, options: options)
                lines.append(contentsOf: Self.envLines(fromSecretName: name, secretString: secretString))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unreadable secret (IAM denial, parse error) must not abort the whole
                // batch — skip it and surface it in the result.
                skipped.append(name)
            }
        }

        let deduped = Self.dedupedByKey(lines)
        let envText = deduped.joined(separator: "\n")
        guard !envText.isEmpty else {
            if !skipped.isEmpty {
                throw RepoEnvVendorSecretsImportError.commandFailed(
                    "None of the \(total) GCP secret\(total == 1 ? "" : "s") could be read (access denied or empty)."
                )
            }
            throw RepoEnvVendorSecretsImportError.noSecretsFound("GCP secrets were listed but no importable keys were found.")
        }

        return RepoEnvVendorSecretsFetchResult(
            envText: envText,
            secretCount: total - skipped.count,
            variableCount: deduped.count,
            sourceLabel: "GCP Secret Manager",
            skippedSecretNames: skipped
        )
    }

    private func listGCPSecretNames(
        binary: String,
        options: RepoEnvVendorImportOptions
    ) async throws -> [String] {
        try checkCancellation()
        // gcloud auto-paginates internally: `gcloud secrets list --format=json` returns
        // every secret in one call. There is no user-facing --page-token flag for this
        // command, and --limit would cap the result — so we pass neither and take the
        // full set gcloud returns. (A prior --limit=100 + stderr-token-scrape loop
        // silently truncated accounts with >100 secrets.)
        var arguments = ["secrets", "list", "--format=json"]
        appendProject(&arguments, project: options.gcpProject)

        let result = try await runCLI(binary: binary, arguments: arguments)
        guard let secrets = parseJSONArray(result.stdoutString) else {
            throw RepoEnvVendorSecretsImportError.invalidCLIOutput("GCP secrets list response")
        }
        return secrets
            .compactMap { $0["name"] as? String }
            .map(shortSecretName)
            .sorted()
    }

    private func fetchGCPSecretValue(
        binary: String,
        name: String,
        options: RepoEnvVendorImportOptions
    ) async throws -> String {
        var arguments = [
            "secrets", "versions", "access", "latest",
            "--secret", name,
        ]
        appendProject(&arguments, project: options.gcpProject)

        let result = try await runCLI(binary: binary, arguments: arguments)
        // gcloud writes the raw secret bytes to stdout. Reject non-UTF-8 (binary) secrets the
        // same way the AWS path does, instead of importing a lossy replacement-char string.
        // (runCLI already threw on a non-zero exit, so only output validation remains.)
        guard let decoded = String(data: result.stdout, encoding: .utf8) else {
            throw RepoEnvVendorSecretsImportError.commandFailed(
                "GCP secret \(name) is not UTF-8 text and cannot be imported."
            )
        }
        let secretString = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secretString.isEmpty else {
            throw RepoEnvVendorSecretsImportError.commandFailed(
                safeMessage(result.stderrString, fallback: "Could not read GCP secret \(name).")
            )
        }
        return secretString
    }

    private func requireBinary(_ name: String) throws -> String {
        guard let binary = locateBinary(name) else {
            throw RepoEnvVendorSecretsImportError.cliNotInstalled(name)
        }
        return binary
    }

    private func runCLI(
        binary: String,
        arguments: [String],
        cwd: String? = nil
    ) async throws -> ShellRunner.Result {
        let result = try await shellRun(
            binary,
            arguments,
            cwd,
            SpawnPathResolver.merged(into: ProcessInfo.processInfo.environment),
            Self.cliTimeout
        )
        guard result.exitStatus == 0 else {
            throw RepoEnvVendorSecretsImportError.commandFailed(
                safeMessage(result.stderrString, fallback: "CLI command failed.")
            )
        }
        return result
    }

    private func filterSecretNames(_ names: [String], prefix: String) -> [String] {
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else { return names }
        return names.filter { $0.hasPrefix(trimmedPrefix) }
    }

    private func appendRegion(_ arguments: inout [String], region: String) {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        arguments.append(contentsOf: ["--region", trimmed])
    }

    private func appendProject(_ arguments: inout [String], project: String) {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        arguments.append(contentsOf: ["--project", trimmed])
    }

    private func shortSecretName(_ fullName: String) -> String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func parseJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return array
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
    }

    private func safeMessage(_ text: String, fallback: String) -> String {
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line, !line.isEmpty else { return fallback }
        return String(line.prefix(180))
    }
}
