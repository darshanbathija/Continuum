import Foundation
import OSLog
import ClawdmeterShared

/// Installs/removes `~/.local/bin/<kind>-<name>` wrappers whenever
/// secondary provider accounts change.
enum ProviderInstanceShellShimInstaller {

    private static let logger = Logger(
        subsystem: "com.clawdmeter.mac",
        category: "ProviderInstanceShellShimInstaller"
    )

    private static let manifestFileName = "provider-shell-shims.json"

    private struct Manifest: Codable {
        var version: Int
        var commands: [String]
    }

    /// Default install dir — same location Claude Code and Codex use.
    static func installDirectory() -> URL {
        ClawdmeterRealHome.url()
            .appendingPathComponent(".local/bin", isDirectory: true)
    }

    static func manifestURL(appSupportDirectory: URL) -> URL {
        appSupportDirectory.appendingPathComponent(manifestFileName)
    }

    /// Reconcile on-disk shims with the current secondary-instance set.
    /// Safe to call on boot replay, add-account, and remove-account.
    static func sync(
        instances: [ProviderInstanceId],
        appSupportDirectory: URL,
        installDirectoryOverride: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let installDir = installDirectoryOverride ?? installDirectory()
        let desired = instances.compactMap { instance -> String? in
            guard let command = ProviderInstanceShellShim.commandName(for: instance),
                  ProviderInstanceShellShim.script(for: instance) != nil else {
                return nil
            }
            return command
        }
        let desiredSet = Set(desired)

        do {
            try fileManager.createDirectory(at: installDir, withIntermediateDirectories: true)
        } catch {
            logger.error("sync: couldn't create \(installDir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        var installed = Set(loadManifest(appSupportDirectory: appSupportDirectory, fileManager: fileManager))

        for instance in instances {
            guard let command = ProviderInstanceShellShim.commandName(for: instance),
                  let body = ProviderInstanceShellShim.script(for: instance) else {
                continue
            }
            let shimURL = installDir.appendingPathComponent(command)
            do {
                try body.write(to: shimURL, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)
                installed.insert(command)
            } catch {
                logger.error(
                    "sync: couldn't write shim \(command, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let stale = installed.subtracting(desiredSet)
        for command in stale {
            let shimURL = installDir.appendingPathComponent(command)
            do {
                if fileManager.fileExists(atPath: shimURL.path) {
                    try fileManager.removeItem(at: shimURL)
                }
                installed.remove(command)
            } catch {
                logger.error(
                    "sync: couldn't remove stale shim \(command, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        saveManifest(Array(installed).sorted(), appSupportDirectory: appSupportDirectory, fileManager: fileManager)
        logger.info("sync: \(desired.count, privacy: .public) provider shell shims active")
    }

    // MARK: - Manifest

    private static func loadManifest(
        appSupportDirectory: URL,
        fileManager: FileManager
    ) -> [String] {
        let url = manifestURL(appSupportDirectory: appSupportDirectory)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1 else {
            return []
        }
        return manifest.commands
    }

    private static func saveManifest(
        _ commands: [String],
        appSupportDirectory: URL,
        fileManager: FileManager
    ) {
        let url = manifestURL(appSupportDirectory: appSupportDirectory)
        let manifest = Manifest(version: 1, commands: commands)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? fileManager.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
