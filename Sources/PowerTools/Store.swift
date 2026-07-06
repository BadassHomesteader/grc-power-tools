import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HistoryEntry {
    let id: Int64
    let timestamp: String
    let app: String
    let raw: String
    let polished: String
    let durationMs: Int
}

struct DictEntry {
    let term: String        // the correct spelling ("KYAW", "GridOps")
    let misheard: String    // comma-separated variants ASR produces ("K Y A W, kayak")
}

/// SQLite-backed history + personal dictionary. Single-connection, serialized via a queue.
final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "grc-whisper.store")

    init(path: String = Config.appSupportDir.appendingPathComponent("grc-whisper.sqlite").path) {
        if sqlite3_open(path, &db) != SQLITE_OK {
            log("store: failed to open \(path)")
            db = nil
            return
        }
        exec("""
        CREATE TABLE IF NOT EXISTS history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            app TEXT NOT NULL DEFAULT '',
            raw TEXT NOT NULL,
            polished TEXT NOT NULL,
            duration_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS dictionary(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            term TEXT NOT NULL UNIQUE,
            misheard TEXT NOT NULL DEFAULT ''
        );
        """)
    }

    deinit { if let db { sqlite3_close(db) } }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            log("store: exec error: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    // MARK: History

    func addHistory(app: String, raw: String, polished: String, durationMs: Int) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO history(ts, app, raw, polished, duration_ms) VALUES(?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ISO8601DateFormatter().string(from: Date()), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, app, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, polished, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(durationMs))
            sqlite3_step(stmt)
        }
    }

    func recentHistory(_ limit: Int = 10) -> [HistoryEntry] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT id, ts, app, raw, polished, duration_ms FROM history ORDER BY id DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [HistoryEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(HistoryEntry(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: String(cString: sqlite3_column_text(stmt, 1)),
                    app: String(cString: sqlite3_column_text(stmt, 2)),
                    raw: String(cString: sqlite3_column_text(stmt, 3)),
                    polished: String(cString: sqlite3_column_text(stmt, 4)),
                    durationMs: Int(sqlite3_column_int(stmt, 5))
                ))
            }
            return out
        }
    }

    // MARK: Dictionary

    func addDictTerm(_ term: String, misheard: String = "") {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO dictionary(term, misheard) VALUES(?,?)
            ON CONFLICT(term) DO UPDATE SET misheard=excluded.misheard
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, misheard, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func removeDictTerm(_ term: String) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM dictionary WHERE term = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func dictionary() -> [DictEntry] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT term, misheard FROM dictionary ORDER BY term", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [DictEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DictEntry(
                    term: String(cString: sqlite3_column_text(stmt, 0)),
                    misheard: String(cString: sqlite3_column_text(stmt, 1))
                ))
            }
            return out
        }
    }
}

/// Lightweight stderr logger with timestamps; also appends to a session log file.
func log(_ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)"
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    Log.append(line)
}

enum Log {
    private static let url = Config.appSupportDir.appendingPathComponent("grc-whisper.log")
    private static let queue = DispatchQueue(label: "grc-whisper.log")

    static func append(_ line: String) {
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
