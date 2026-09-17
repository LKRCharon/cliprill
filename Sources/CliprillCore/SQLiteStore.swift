// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CSQLite

/// Access is serialized by QueueCore. A state snapshot and its retry receipt commit together.
final class SQLiteStore {
    private var db: OpaquePointer?
    private var savedBoards: [Pinboard]?
    private var retainedImageIDs: Set<String>?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        try CliprillPaths.prepare(directory)
        let url = directory.appendingPathComponent("cliprill.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw CoreError("storage", "Cannot open the Cliprill database.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;")
        try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL); CREATE TABLE IF NOT EXISTS receipts (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, response BLOB NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS boards (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL);")
        try execute("CREATE TABLE IF NOT EXISTS images (id TEXT PRIMARY KEY, png BLOB NOT NULL, thumbnail BLOB NOT NULL);")
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> CoreError { CoreError("storage", "Database operation failed (\(sqlite3_errcode(db))).") }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var p: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &p, nil) == SQLITE_OK, let p else { throw failure() }
        return p
    }
    private func blob(_ stmt: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard let ptr = sqlite3_column_blob(stmt, column), count > 0 else { return Data() }
        return Data(bytes: ptr, count: count)
    }
    func load() throws -> CoreState {
        let s = try statement("SELECT payload FROM state WHERE id=1"); defer { sqlite3_finalize(s) }
        switch sqlite3_step(s) {
        case SQLITE_ROW:
            var value = try JSONDecoder().decode(CoreState.self, from: blob(s, 0))
            guard (1...3).contains(value.schema) else { throw CoreError("schema", "This database requires a newer Cliprill version.") }
            let boards = try statement("SELECT payload FROM boards WHERE id=1"); defer { sqlite3_finalize(boards) }
            switch sqlite3_step(boards) {
            case SQLITE_ROW:
                value.boards = try JSONDecoder().decode([Pinboard].self, from: blob(boards, 0))
                savedBoards = value.boards
            case SQLITE_DONE: break
            default: throw failure()
            }
            return value
        case SQLITE_DONE: return CoreState()
        default: throw failure()
        }
    }
    func receipt(key: String, fingerprint: String) throws -> JSONValue? {
        let s = try statement("SELECT fingerprint,response FROM receipts WHERE key=?"); defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, key, -1, transient)
        switch sqlite3_step(s) {
        case SQLITE_ROW:
            let saved = String(cString: sqlite3_column_text(s, 0))
            guard saved == fingerprint else { throw CoreError("idempotency_conflict", "This idempotency key was already used with different arguments.") }
            return try JSONDecoder().decode(JSONValue.self, from: blob(s, 1))
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }
    func imageData(id: String, thumbnail: Bool = false) throws -> Data {
        let s = try statement(thumbnail ? "SELECT thumbnail FROM images WHERE id=?" : "SELECT png FROM images WHERE id=?")
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id, -1, transient)
        switch sqlite3_step(s) {
        case SQLITE_ROW: return blob(s, 0)
        case SQLITE_DONE: throw CoreError("image_missing", "The saved image is unavailable.")
        default: throw failure()
        }
    }
    func save(_ value: CoreState, receipt: (String, String, JSONValue)? = nil, image: PreparedClipboardImage? = nil) throws {
        var snapshot = value; snapshot.boards = []
        let data = try JSONEncoder().encode(snapshot)
        let retained = Set(value.history.compactMap { $0.image?.id } + value.queues.flatMap { $0.items.compactMap { $0.image?.id } } + value.boards.flatMap { $0.items.compactMap { $0.image?.id } })
        try execute("BEGIN IMMEDIATE")
        do {
            if let image {
                let insert = try statement("INSERT OR IGNORE INTO images(id,png,thumbnail) VALUES(?,?,?)")
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_text(insert, 1, image.image.id, -1, transient)
                _ = image.png.withUnsafeBytes { sqlite3_bind_blob(insert, 2, $0.baseAddress, Int32($0.count), transient) }
                _ = image.thumbnail.withUnsafeBytes { sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            }
            let s = try statement("INSERT INTO state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
            defer { sqlite3_finalize(s) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(s, 1, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
            if savedBoards != value.boards {
                let b = try statement("INSERT INTO boards(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(b) }
                let bytes = try JSONEncoder().encode(value.boards)
                _ = bytes.withUnsafeBytes { sqlite3_bind_blob(b, 1, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(b) == SQLITE_DONE else { throw failure() }
            }
            if let (key, fingerprint, response) = receipt {
                let r = try statement("INSERT INTO receipts(key,fingerprint,response) VALUES(?,?,?)")
                defer { sqlite3_finalize(r) }
                sqlite3_bind_text(r, 1, key, -1, transient)
                sqlite3_bind_text(r, 2, fingerprint, -1, transient)
                let bytes = try response.encoded()
                _ = bytes.withUnsafeBytes { sqlite3_bind_blob(r, 3, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(r) == SQLITE_DONE else { throw failure() }
            }
            // History and queue snapshots share immutable blobs. Collect only unreferenced images,
            // including consumed queue items in the retained set so Undo remains possible.
            if retainedImageIDs != retained || (image.map { !retained.contains($0.image.id) } ?? false) {
                let all = try statement("SELECT id FROM images"); defer { sqlite3_finalize(all) }
                var obsolete: [String] = []
                var step = sqlite3_step(all)
                while step == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(all, 0))
                    if !retained.contains(id) { obsolete.append(id) }
                    step = sqlite3_step(all)
                }
                guard step == SQLITE_DONE else { throw failure() }
                let delete = try statement("DELETE FROM images WHERE id=?"); defer { sqlite3_finalize(delete) }
                for id in obsolete {
                    sqlite3_reset(delete); sqlite3_bind_text(delete, 1, id, -1, transient)
                    guard sqlite3_step(delete) == SQLITE_DONE else { throw failure() }
                }
            }
            try execute("COMMIT")
            savedBoards = value.boards; retainedImageIDs = retained
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
