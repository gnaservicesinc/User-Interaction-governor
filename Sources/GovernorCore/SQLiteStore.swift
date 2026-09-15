import CSQLite
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct CleanupTombstone: Codable, Sendable {
    public var uuid: String
    public var directory: String
    public var paths: ProtocolPaths
    public var identities: [String: FileIdentity]
}

public final class SQLiteStore: @unchecked Sendable {
    private var database: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(handle)
            throw StructuredError("IO_ERROR", "cannot open state database: \(message)")
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=5000")
            try execute("CREATE TABLE IF NOT EXISTS interactions (uuid TEXT PRIMARY KEY, record BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS path_reservations (path TEXT PRIMARY KEY, uuid TEXT NOT NULL, role TEXT NOT NULL, FOREIGN KEY(uuid) REFERENCES interactions(uuid) ON DELETE CASCADE)")
            try execute("CREATE TABLE IF NOT EXISTS file_identities (uuid TEXT NOT NULL, role TEXT NOT NULL, path TEXT NOT NULL, device INTEGER NOT NULL, inode INTEGER NOT NULL, PRIMARY KEY(uuid, role), FOREIGN KEY(uuid) REFERENCES interactions(uuid) ON DELETE CASCADE)")
            try execute("CREATE TABLE IF NOT EXISTS cleanup_tombstones (uuid TEXT PRIMARY KEY, tombstone BLOB NOT NULL)")
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func insert(_ record: InteractionRecord) throws {
        let data = try governorJSONEncoder().encode(record)
        try transaction {
            try statement("INSERT INTO interactions(uuid, record) VALUES(?, ?)", text: record.uuid, blob: data)
            for item in record.paths.all {
                try statement("INSERT INTO path_reservations(path, uuid, role) VALUES(?, ?, ?)", texts: [pathReservationKey(item.path), record.uuid, item.role])
            }
        }
    }

    public func record(uuid: String) throws -> InteractionRecord? {
        guard let data = try queryBlob("SELECT record FROM interactions WHERE uuid = ?", text: uuid) else { return nil }
        do { return try governorJSONDecoder().decode(InteractionRecord.self, from: data) }
        catch { throw StructuredError("IO_ERROR", "stored interaction is corrupt: \(error.localizedDescription)") }
    }

    public func allRecords() throws -> [InteractionRecord] {
        let blobs = try queryBlobs("SELECT record FROM interactions")
        return try blobs.map {
            do { return try governorJSONDecoder().decode(InteractionRecord.self, from: $0) }
            catch { throw StructuredError("IO_ERROR", "stored interaction is corrupt: \(error.localizedDescription)") }
        }
    }

    public func update(_ record: InteractionRecord) throws {
        let data = try governorJSONEncoder().encode(record)
        try statement("UPDATE interactions SET record = ? WHERE uuid = ?", blob: data, text: record.uuid)
        guard sqlite3_changes(database) == 1 else { throw StructuredError("NOT_FOUND", "interaction not found") }
    }

    public func deleteNew(uuid: String) throws {
        try statement("DELETE FROM interactions WHERE uuid = ?", text: uuid)
    }

    public func deleteAndTombstone(_ record: InteractionRecord, directory: String) throws -> CleanupTombstone {
        let tombstone = CleanupTombstone(uuid: record.uuid, directory: directory, paths: record.paths, identities: try identities(uuid: record.uuid))
        let data = try governorJSONEncoder().encode(tombstone)
        try transaction {
            try statement("INSERT OR REPLACE INTO cleanup_tombstones(uuid, tombstone) VALUES(?, ?)", text: record.uuid, blob: data)
            try statement("DELETE FROM interactions WHERE uuid = ?", text: record.uuid)
        }
        return tombstone
    }

    public func tombstones() throws -> [CleanupTombstone] {
        try queryBlobs("SELECT tombstone FROM cleanup_tombstones").map { try governorJSONDecoder().decode(CleanupTombstone.self, from: $0) }
    }

    public func removeTombstone(uuid: String) throws {
        try statement("DELETE FROM cleanup_tombstones WHERE uuid = ?", text: uuid)
    }

    public func setIdentity(uuid: String, role: String, path: String, identity: FileIdentity) throws {
        try statement(
            "INSERT OR REPLACE INTO file_identities(uuid, role, path, device, inode) VALUES(?, ?, ?, ?, ?)",
            texts: [uuid, role, path], integers: [Int64(identity.device), Int64(identity.inode)]
        )
    }

    public func removeIdentity(uuid: String, role: String) throws {
        try statement("DELETE FROM file_identities WHERE uuid = ? AND role = ?", texts: [uuid, role])
    }

    public func identities(uuid: String) throws -> [String: FileIdentity] {
        guard let database else { throw StructuredError("IO_ERROR", "state database is closed") }
        var query: OpaquePointer?
        try prepare("SELECT role, device, inode FROM file_identities WHERE uuid = ?", into: &query)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, uuid, -1, sqliteTransient)
        var result: [String: FileIdentity] = [:]
        while sqlite3_step(query) == SQLITE_ROW {
            let role = String(cString: sqlite3_column_text(query, 0))
            result[role] = FileIdentity(device: UInt64(sqlite3_column_int64(query, 1)), inode: UInt64(sqlite3_column_int64(query, 2)))
        }
        if sqlite3_errcode(database) != SQLITE_OK && sqlite3_errcode(database) != SQLITE_DONE && sqlite3_errcode(database) != SQLITE_ROW {
            throw sqliteError("cannot read file identities")
        }
        return result
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StructuredError("IO_ERROR", "state database is closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw StructuredError("IO_ERROR", "state database error: \(detail)")
        }
    }

    private func prepare(_ sql: String, into query: inout OpaquePointer?) throws {
        guard let database, sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK else { throw sqliteError("cannot prepare state query") }
    }

    private func statement(_ sql: String, text: String) throws {
        try statement(sql, texts: [text])
    }

    private func statement(_ sql: String, blob: Data, text: String) throws {
        var query: OpaquePointer?
        try prepare(sql, into: &query)
        defer { sqlite3_finalize(query) }
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(query, 1, $0.baseAddress, Int32($0.count), sqliteTransient) }
        sqlite3_bind_text(query, 2, text, -1, sqliteTransient)
        guard sqlite3_step(query) == SQLITE_DONE else { throw sqliteError("cannot update state") }
    }

    private func statement(_ sql: String, text: String, blob: Data) throws {
        var query: OpaquePointer?
        try prepare(sql, into: &query)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, text, -1, sqliteTransient)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(query, 2, $0.baseAddress, Int32($0.count), sqliteTransient) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw sqliteError("cannot update state") }
    }

    private func statement(_ sql: String, texts: [String], integers: [Int64] = []) throws {
        var query: OpaquePointer?
        try prepare(sql, into: &query)
        defer { sqlite3_finalize(query) }
        var index: Int32 = 1
        for text in texts { sqlite3_bind_text(query, index, text, -1, sqliteTransient); index += 1 }
        for integer in integers { sqlite3_bind_int64(query, index, integer); index += 1 }
        guard sqlite3_step(query) == SQLITE_DONE else { throw sqliteError("cannot update state") }
    }

    private func queryBlob(_ sql: String, text: String) throws -> Data? {
        var query: OpaquePointer?
        try prepare(sql, into: &query)
        defer { sqlite3_finalize(query) }
        sqlite3_bind_text(query, 1, text, -1, sqliteTransient)
        let result = sqlite3_step(query)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError("cannot read state") }
        return columnData(query, index: 0)
    }

    private func queryBlobs(_ sql: String) throws -> [Data] {
        var query: OpaquePointer?
        try prepare(sql, into: &query)
        defer { sqlite3_finalize(query) }
        var results: [Data] = []
        while sqlite3_step(query) == SQLITE_ROW { results.append(columnData(query, index: 0)) }
        return results
    }

    private func columnData(_ query: OpaquePointer?, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(query, index))
        guard count > 0, let bytes = sqlite3_column_blob(query, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func sqliteError(_ prefix: String) -> StructuredError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
        let code = database.map { sqlite3_errcode($0) } ?? SQLITE_ERROR
        let stableCode = code == SQLITE_CONSTRAINT ? "PATH_CONFLICT" : "IO_ERROR"
        return StructuredError(stableCode, "\(prefix): \(detail)")
    }
}
