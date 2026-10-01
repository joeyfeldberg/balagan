import Foundation
import SQLite3

public enum BoardStateStoreError: Error, Equatable, Sendable {
    case snapshotNotFound
    case unsupportedSchemaVersion(Int)
    case sqlite(String)
}

extension BoardStateStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .snapshotNotFound:
            return "No board snapshot has been saved."
        case let .unsupportedSchemaVersion(version):
            return "Unsupported board snapshot schema version \(version)."
        case let .sqlite(message):
            return "SQLite board state error: \(message)"
        }
    }
}

extension BoardSnapshot {
    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public struct BoardStateFileStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> BoardSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = BoardSnapshot.jsonDecoder()
        let snapshot = try decoder.decode(BoardSnapshot.self, from: data)

        guard snapshot.schemaVersion == BoardSnapshot.currentSchemaVersion else {
            throw BoardStateStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }

        return snapshot
    }

    public func save(_ snapshot: BoardSnapshot) throws {
        guard snapshot.schemaVersion == BoardSnapshot.currentSchemaVersion else {
            throw BoardStateStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = BoardSnapshot.jsonEncoder()
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}

public struct SQLiteBoardStateStore: Sendable {
    public static let currentSnapshotID = "current"

    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> BoardSnapshot {
        guard let snapshot = try loadLatest() else {
            throw BoardStateStoreError.snapshotNotFound
        }

        return snapshot
    }

    public func loadLatest() throws -> BoardSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return try withDatabase(flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX) { database in
            let statement = try prepare(
                database: database,
                sql: """
                SELECT schema_version, payload_json
                FROM board_snapshots
                WHERE id = ?
                LIMIT 1
                """
            )
            defer { sqlite3_finalize(statement) }

            try bindText(SQLiteBoardStateStore.currentSnapshotID, to: statement, index: 1, database: database)

            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let schemaVersion = Int(sqlite3_column_int(statement, 0))
                guard schemaVersion == BoardSnapshot.currentSchemaVersion else {
                    throw BoardStateStoreError.unsupportedSchemaVersion(schemaVersion)
                }

                guard let payload = sqlite3_column_text(statement, 1) else {
                    throw BoardStateStoreError.sqlite("Snapshot payload was NULL.")
                }

                let json = String(cString: UnsafeRawPointer(payload).assumingMemoryBound(to: CChar.self))
                guard let data = json.data(using: .utf8) else {
                    throw BoardStateStoreError.sqlite("Snapshot payload was not valid UTF-8.")
                }

                let snapshot = try BoardSnapshot.jsonDecoder().decode(BoardSnapshot.self, from: data)
                guard snapshot.schemaVersion == BoardSnapshot.currentSchemaVersion else {
                    throw BoardStateStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
                }

                return snapshot
            case SQLITE_DONE:
                return nil
            default:
                throw sqliteError(database)
            }
        }
    }

    public func save(_ snapshot: BoardSnapshot) throws {
        guard snapshot.schemaVersion == BoardSnapshot.currentSchemaVersion else {
            throw BoardStateStoreError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) { database in
            try execute(database: database, sql: "PRAGMA journal_mode = WAL")
            try execute(database: database, sql: "PRAGMA foreign_keys = ON")
            try execute(
                database: database,
                sql: """
                CREATE TABLE IF NOT EXISTS board_snapshots (
                    id TEXT PRIMARY KEY NOT NULL,
                    schema_version INTEGER NOT NULL,
                    saved_at TEXT NOT NULL,
                    payload_json TEXT NOT NULL
                )
                """
            )

            let jsonData = try BoardSnapshot.jsonEncoder().encode(snapshot)
            guard let json = String(data: jsonData, encoding: .utf8) else {
                throw BoardStateStoreError.sqlite("Could not encode snapshot as UTF-8 JSON.")
            }

            let statement = try prepare(
                database: database,
                sql: """
                INSERT INTO board_snapshots(id, schema_version, saved_at, payload_json)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    schema_version = excluded.schema_version,
                    saved_at = excluded.saved_at,
                    payload_json = excluded.payload_json
                """
            )
            defer { sqlite3_finalize(statement) }

            try bindText(SQLiteBoardStateStore.currentSnapshotID, to: statement, index: 1, database: database)
            guard sqlite3_bind_int(statement, 2, Int32(snapshot.schemaVersion)) == SQLITE_OK else {
                throw sqliteError(database)
            }
            try bindText(Self.formatSavedAt(snapshot.savedAt), to: statement, index: 3, database: database)
            try bindText(json, to: statement, index: 4, database: database)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(database)
            }
        }
    }

    private static func formatSavedAt(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func withDatabase<T>(flags: Int32, operation: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            defer {
                if let database {
                    sqlite3_close(database)
                }
            }
            throw BoardStateStoreError.sqlite(Self.openErrorMessage(database: database))
        }

        defer { sqlite3_close(database) }
        return try operation(database)
    }

    private func execute(database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func prepare(database: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(database)
        }

        return statement
    }

    private func bindText(_ value: String, to statement: OpaquePointer, index: Int32, database: OpaquePointer) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, Self.transientDestructor)
        }

        guard result == SQLITE_OK else {
            throw sqliteError(database)
        }
    }

    private func sqliteError(_ database: OpaquePointer) -> BoardStateStoreError {
        BoardStateStoreError.sqlite(Self.openErrorMessage(database: database))
    }

    private static var transientDestructor: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func openErrorMessage(database: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(database) else {
            return "unknown SQLite error"
        }

        return String(cString: message)
    }
}
