import XCTest
@testable import Clawdmeter

@MainActor
final class RepoEnvStoreTests: XCTestCase {
    private final class FakeSecrets: RepoEnvSecretStoring, @unchecked Sendable {
        var values: [String: String] = [:]
        var writeSucceeds = true
        var deleteSucceeds = true

        func read(account: String) -> String? {
            values[account]
        }

        func write(_ value: String, account: String) -> Bool {
            guard writeSucceeds else { return false }
            values[account] = value
            return true
        }

        func delete(account: String) -> Bool {
            guard deleteSucceeds else { return false }
            values.removeValue(forKey: account)
            return true
        }
    }

    private func tempURL(_ fileName: String = "repo-env.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-env-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    func testMetadataJSONDoesNotPersistSecretValues() throws {
        let storeURL = tempURL()
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: storeURL, secrets: secrets)
        let workspaceId = UUID()

        _ = store.ensureDefaultSet(workspaceId: workspaceId)
        _ = try store.createVariable(
            key: "API_TOKEN",
            value: "sk-live-secret",
            workspaceIds: [workspaceId],
            scope: .shared
        )

        let json = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(json.contains("API_TOKEN"))
        XCTAssertFalse(json.contains("sk-live-secret"))
        XCTAssertEqual(secrets.values.values.first, "sk-live-secret")
    }

    func testKeychainWriteFailureDoesNotAppendMetadata() {
        let secrets = FakeSecrets()
        secrets.writeSucceeds = false
        let store = RepoEnvStore(storeURL: tempURL(), secrets: secrets)
        let workspaceId = UUID()
        _ = store.ensureDefaultSet(workspaceId: workspaceId)

        XCTAssertThrowsError(
            try store.createVariable(key: "BROKEN_SECRET", value: "value", workspaceIds: [workspaceId])
        )
        XCTAssertTrue(store.variables.isEmpty)
        XCTAssertTrue(store.assignments.isEmpty)
    }

    func testAssignmentsResolvePerSetAndCanBeDisabled() throws {
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: tempURL(), secrets: secrets)
        let workspaceId = UUID()
        let local = store.ensureDefaultSet(workspaceId: workspaceId)
        let staging = store.createSet(workspaceId: workspaceId, name: "staging")
        let variable = try store.createVariable(
            key: "RPC_URL",
            value: "https://example.test",
            workspaceIds: [workspaceId],
            scope: .shared
        )

        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: local.id).map(\.key), ["RPC_URL"])
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: staging.id).map(\.key), ["RPC_URL"])

        try store.setAssignment(variableId: variable.id, workspaceId: workspaceId, setId: staging.id, enabled: false)
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: staging.id), [])
    }

    func testAssignmentRejectsDuplicateKeyInTargetWorkspace() throws {
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: tempURL(), secrets: secrets)
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        _ = store.ensureDefaultSet(workspaceId: firstWorkspace)
        let secondSet = store.ensureDefaultSet(workspaceId: secondWorkspace)
        let first = try store.createVariable(
            key: "API_TOKEN",
            value: "first",
            workspaceIds: [firstWorkspace],
            scope: .local
        )
        _ = try store.createVariable(
            key: "API_TOKEN",
            value: "second",
            workspaceIds: [secondWorkspace],
            scope: .local
        )

        XCTAssertThrowsError(
            try store.setAssignment(
                variableId: first.id,
                workspaceId: secondWorkspace,
                setId: secondSet.id,
                enabled: true
            )
        ) { error in
            XCTAssertEqual(error as? RepoEnvError, .duplicateKey("API_TOKEN"))
        }
        XCTAssertEqual(try store.resolvedVariables(workspaceId: secondWorkspace, setId: secondSet.id).map(\.key), ["API_TOKEN"])
    }

    func testDeleteFailurePreservesMetadataAndSecret() throws {
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: tempURL(), secrets: secrets)
        let workspaceId = UUID()
        _ = store.ensureDefaultSet(workspaceId: workspaceId)
        let variable = try store.createVariable(
            key: "API_TOKEN",
            value: "secret",
            workspaceIds: [workspaceId],
            scope: .local
        )

        secrets.deleteSucceeds = false
        XCTAssertThrowsError(try store.deleteVariable(variable.id)) { error in
            XCTAssertEqual(error as? RepoEnvError, .keychainDeleteFailed("API_TOKEN"))
        }
        XCTAssertEqual(store.variables.map(\.id), [variable.id])
        XCTAssertEqual(try store.readVariableValue(variableId: variable.id), "secret")
    }

    func testMaterializerPreservesManualLinesAndBlocksConflicts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-env-materializer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let envFile = dir.appendingPathComponent(".env.local")
        try "FOO=manual\nOTHER=1\n".write(to: envFile, atomically: true, encoding: .utf8)

        let materializer = RepoEnvFileMaterializer()
        let conflicting = [
            RepoEnvResolvedVariable(key: "FOO", value: "managed", variableId: UUID(), assignmentId: UUID())
        ]
        let conflicts = try materializer.materialize(variables: conflicting, cwd: dir.path)
        XCTAssertEqual(conflicts.map(\.key), ["FOO"])
        XCTAssertEqual(try String(contentsOf: envFile, encoding: .utf8), "FOO=manual\nOTHER=1\n")

        let clean = [
            RepoEnvResolvedVariable(key: "BAR", value: "managed value", variableId: UUID(), assignmentId: UUID())
        ]
        XCTAssertEqual(try materializer.materialize(variables: clean, cwd: dir.path), [])
        let updated = try String(contentsOf: envFile, encoding: .utf8)
        XCTAssertTrue(updated.contains("OTHER=1"))
        XCTAssertTrue(updated.contains(RepoEnvFileMaterializer.beginMarker))
        XCTAssertTrue(updated.contains("BAR=\"managed value\""))
    }

    func testImportParserHandlesExportQuotesMultilineAndInvalidRows() throws {
        let previews = RepoEnvImportParser.parse("""
        # comment
        export RPC_URL="https://example.test/api?token=one"
        MULTI="line1
        line2"
        PLAIN=abc # trailing comment
        SINGLE='quoted value'
        ESCAPED="line\\nnext\\tok"
        EMPTY=
        BAD-KEY=oops
        MISSING_SEPARATOR
        """)

        XCTAssertEqual(previews.first?.status, .skipped)

        let byKey = Dictionary(
            uniqueKeysWithValues: previews.compactMap { preview -> (String, RepoEnvImportPreviewRecord)? in
                guard let key = preview.key else { return nil }
                return (key, preview)
            }
        )

        XCTAssertEqual(byKey["RPC_URL"]?.value, "https://example.test/api?token=one")
        XCTAssertEqual(byKey["RPC_URL"]?.status, .ready)
        XCTAssertEqual(byKey["MULTI"]?.value, "line1\nline2")
        XCTAssertEqual(byKey["PLAIN"]?.value, "abc")
        XCTAssertEqual(byKey["SINGLE"]?.value, "quoted value")
        XCTAssertEqual(byKey["ESCAPED"]?.value, "line\nnext\tok")
        XCTAssertEqual(byKey["EMPTY"]?.status, .emptyValue)

        XCTAssertTrue(previews.contains { $0.key == "BAD-KEY" && $0.status == .invalid })
        XCTAssertTrue(previews.contains { $0.message == "Missing = separator." && $0.status == .invalid })
    }

    func testImportVariablesWritesSecretsAuditsAndKeepsMetadataSecretFree() throws {
        let storeURL = tempURL()
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: storeURL, secrets: secrets)
        let workspaceId = UUID()
        let local = store.ensureDefaultSet(workspaceId: workspaceId)
        let staging = store.createSet(workspaceId: workspaceId, name: "staging")

        let previews = store.previewImport("""
        API_TOKEN=super-secret
        PUBLIC_URL=https://example.test
        BROKEN-KEY=value
        EMPTY=
        """, workspaceId: workspaceId)

        let batch = try store.importVariables(
            previews: previews,
            workspaceIds: [workspaceId],
            selectedSetIds: [local.id],
            currentWorkspaceId: workspaceId,
            conflictStrategy: .skip,
            kind: .sensitive,
            actor: "test"
        )

        XCTAssertEqual(batch.importedCount, 2)
        XCTAssertEqual(batch.overwrittenCount, 0)
        XCTAssertEqual(batch.invalidCount, 2)
        XCTAssertEqual(batch.skippedCount, 2)
        XCTAssertEqual(store.importBatches.map(\.id), [batch.id])

        let keys = store.variables.map(\.key).sorted()
        XCTAssertEqual(keys, ["API_TOKEN", "PUBLIC_URL"])
        XCTAssertEqual(Set(store.variables.map(\.kind)), [.sensitive])
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: local.id).map(\.key), ["API_TOKEN", "PUBLIC_URL"])
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: staging.id), [])
        XCTAssertTrue(secrets.values.values.contains("super-secret"))

        let json = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertTrue(json.contains("API_TOKEN"))
        XCTAssertFalse(json.contains("super-secret"))
        XCTAssertFalse(json.contains("https://example.test"))
        XCTAssertFalse(store.auditEvents.map(\.message).joined(separator: "\n").contains("super-secret"))
    }

    func testImportOverwriteUpdatesExistingValueAndAssignmentsWithoutPersistingSecrets() throws {
        let storeURL = tempURL()
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: storeURL, secrets: secrets)
        let workspaceId = UUID()
        let local = store.ensureDefaultSet(workspaceId: workspaceId)
        let staging = store.createSet(workspaceId: workspaceId, name: "staging")
        let variable = try store.createVariable(
            key: "API_TOKEN",
            value: "old-secret",
            workspaceIds: [workspaceId],
            scope: .local
        )

        let previews = store.previewImport("API_TOKEN=new-secret\n", workspaceId: workspaceId)
        XCTAssertEqual(previews.first?.status, .duplicate)

        let batch = try store.importVariables(
            previews: previews,
            workspaceIds: [workspaceId],
            selectedSetIds: [staging.id],
            currentWorkspaceId: workspaceId,
            conflictStrategy: .overwrite,
            actor: "test"
        )

        XCTAssertEqual(batch.importedCount, 0)
        XCTAssertEqual(batch.overwrittenCount, 1)
        XCTAssertEqual(try store.readVariableValue(variableId: variable.id), "new-secret")
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: local.id), [])
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: staging.id).map(\.key), ["API_TOKEN"])

        let json = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(json.contains("old-secret"))
        XCTAssertFalse(json.contains("new-secret"))
        XCTAssertFalse(store.auditEvents.map(\.message).joined(separator: "\n").contains("new-secret"))
    }

    func testVariableMetadataRotateAndReveal() throws {
        let secrets = FakeSecrets()
        let store = RepoEnvStore(storeURL: tempURL(), secrets: secrets)
        let workspaceId = UUID()
        let set = store.ensureDefaultSet(workspaceId: workspaceId)
        let variable = try store.createVariable(
            key: "API_TOKEN",
            value: "initial-secret",
            workspaceIds: [workspaceId],
            actor: "test"
        )

        try store.updateVariableMetadata(
            variableId: variable.id,
            key: "PUBLIC_API_TOKEN",
            note: "Safe to show in local tooling",
            kind: .plain,
            isEnabled: false,
            actor: "test"
        )

        var updated = try XCTUnwrap(store.variables.first(where: { $0.id == variable.id }))
        XCTAssertEqual(updated.key, "PUBLIC_API_TOKEN")
        XCTAssertEqual(updated.note, "Safe to show in local tooling")
        XCTAssertEqual(updated.kind, .plain)
        XCTAssertFalse(updated.isEnabled)
        XCTAssertNotNil(updated.disabledAt)
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: set.id), [])

        try store.updateVariableMetadata(
            variableId: variable.id,
            key: "PUBLIC_API_TOKEN",
            note: nil,
            kind: .plain,
            isEnabled: true,
            actor: "test"
        )
        try store.updateVariableValue(variableId: variable.id, value: "rotated-secret", markRotated: true, actor: "test")

        updated = try XCTUnwrap(store.variables.first(where: { $0.id == variable.id }))
        XCTAssertNil(updated.note)
        XCTAssertTrue(updated.isEnabled)
        XCTAssertNil(updated.disabledAt)
        XCTAssertNotNil(updated.lastRotatedAt)
        XCTAssertEqual(try store.readVariableValue(variableId: variable.id), "rotated-secret")
        XCTAssertEqual(try store.resolvedVariables(workspaceId: workspaceId, setId: set.id).map(\.key), ["PUBLIC_API_TOKEN"])
        XCTAssertTrue(store.auditEvents(for: variable.id).contains { $0.action == .rotated })
    }
}
