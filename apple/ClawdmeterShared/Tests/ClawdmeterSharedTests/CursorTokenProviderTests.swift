#if os(macOS)
import XCTest
import SQLite3
@testable import ClawdmeterShared

final class CursorTokenProviderTests: XCTestCase {
    func test_defaultCursorStateDatabaseURLUsesRealHome() {
        let expected = ClawdmeterRealHome.url()
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        XCTAssertEqual(CursorTokenProvider.defaultCursorStateDatabaseURL(), expected)
    }

    func test_readCursorAppAccessToken_readsStateDatabaseToken() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-token-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("state.vscdb")
        let expected = "header.payload.signature"
        try seedCursorStateDatabase(url: dbURL, token: expected)

        XCTAssertEqual(CursorTokenProvider.readCursorAppAccessToken(databaseURL: dbURL), expected)
    }

    func test_readCursorAppAccessToken_rejectsNonJWTValue() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-token-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("state.vscdb")
        try seedCursorStateDatabase(url: dbURL, token: "not-a-token")

        XCTAssertNil(CursorTokenProvider.readCursorAppAccessToken(databaseURL: dbURL))
    }

    private func seedCursorStateDatabase(url: URL, token: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        guard let db else {
            throw NSError(domain: "CursorTokenProviderTests", code: 1)
        }
        defer { sqlite3_close_v2(db) }

        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &stmt, nil), SQLITE_OK)
        guard let stmt else {
            throw NSError(domain: "CursorTokenProviderTests", code: 2)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, "cursorAuth/accessToken", -1, transient)
        sqlite3_bind_text(stmt, 2, token, -1, transient)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }
}
#endif
