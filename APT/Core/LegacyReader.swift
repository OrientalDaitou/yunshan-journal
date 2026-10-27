import Foundation
import SQLite3
import CryptoKit

/// 旧版的一行记录：`(id, created_at, updated_at, data JSON)`。
struct LegacyRow {
    var id: String
    var createdAt: String
    var updatedAt: String
    /// 原始 JSON 文本（`data` 列，或 JSON 导出中的整条记录）。
    var json: String

    var object: [String: Any] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}

/// 旧版数据的完整快照。所有表、设置项、审计日志都保留原文。
struct LegacySnapshot {
    enum Source: String { case sqlite = "旧版 SQLite 数据库", json = "旧版 JSON 导出" }

    var source: Source
    var path: String
    var sha256: String
    var schemaVersion: Int
    var collections: [String: [LegacyRow]] = [:]
    /// 设置项：key → 原始 JSON 文本。
    var settings: [String: String] = [:]
    /// 审计日志、回收站等其它内容：每条为原始 JSON 文本。
    var extras: [String: [String]] = [:]

    var recordCount: Int { collections.values.reduce(0) { $0 + $1.count } }

    func settingObject(_ key: String) -> Any? {
        guard let raw = settings[key], let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

enum LegacyReaderError: LocalizedError {
    case notFound(String)
    case openFailed(String)
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path): "找不到文件：\(path)"
        case .openFailed(let message): "无法打开旧版数据库：\(message)"
        case .invalidFormat(let message): "文件格式不正确：\(message)"
        }
    }
}

enum LegacyReader {
    /// 旧版生产数据库的默认位置。
    static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LegacyPersonalOS/legacy.sqlite3")
    }

    static func read(url: URL) throws -> LegacySnapshot {
        let ext = url.pathExtension.lowercased()
        if ext == "json" { return try readJSONExport(url: url) }
        return try readSQLite(url: url)
    }

    static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: SQLite

    /// 先把数据库连同 -wal / -shm 复制到临时目录，再只读打开副本；原文件不做任何写入。
    static func readSQLite(url: URL) throws -> LegacySnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw LegacyReaderError.notFound(url.path) }
        let workDir = fm.temporaryDirectory.appendingPathComponent("APT-legacy-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        let copy = workDir.appendingPathComponent("legacy.sqlite3")
        try fm.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: side.path) {
                try fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw LegacyReaderError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        var snapshot = LegacySnapshot(source: .sqlite, path: url.path, sha256: sha256(of: url),
                                      schemaVersion: Int(try query(db, "PRAGMA user_version").first?.first ?? "0") ?? 0)
        let tables = try query(db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").compactMap(\.first)
        for table in tables {
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let columns = try query(db, "PRAGMA table_info(\(quoted))").compactMap { $0.count > 1 ? $0[1] : nil }
            if Set(columns).isSuperset(of: ["id", "created_at", "updated_at", "data"]) {
                let rows = try query(db, "SELECT id, created_at, updated_at, data FROM \(quoted) ORDER BY created_at, id")
                snapshot.collections[table] = rows.map { LegacyRow(id: $0[0], createdAt: $0[1], updatedAt: $0[2], json: $0[3]) }
            } else if table == "settings" {
                for row in try query(db, "SELECT key, value FROM settings") { snapshot.settings[row[0]] = row[1] }
            } else if table != "sqlite_sequence" {
                // audit_log、schema_migrations 等：整行转成 JSON 原样保留。
                let rows = try query(db, "SELECT * FROM \(quoted)")
                snapshot.extras[table] = rows.map { values in
                    var object: [String: String] = [:]
                    for (index, name) in columns.enumerated() where index < values.count { object[name] = values[index] }
                    return jsonText(object)
                }
            }
        }
        return snapshot
    }

    private static func query(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LegacyReaderError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw LegacyReaderError.openFailed(String(cString: sqlite3_errmsg(db))) }
            let count = sqlite3_column_count(statement)
            rows.append((0..<count).map { index in
                guard let text = sqlite3_column_text(statement, index) else { return "" }
                return String(cString: text)
            })
        }
        return rows
    }

    // MARK: JSON 导出

    static func readJSONExport(url: URL) throws -> LegacySnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LegacyReaderError.notFound(url.path) }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collections = root["collections"] as? [String: Any] else {
            throw LegacyReaderError.invalidFormat("缺少 collections 字段，不是旧版 APT 的 JSON 导出")
        }
        var snapshot = LegacySnapshot(source: .json, path: url.path,
                                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                      schemaVersion: root["schema_version"] as? Int ?? 0)
        for (kind, value) in collections {
            guard let items = value as? [[String: Any]] else { continue }
            snapshot.collections[kind] = items.map { item in
                var body = item
                let id = body.removeValue(forKey: "id") as? String ?? UUID().uuidString
                let created = body.removeValue(forKey: "created_at") as? String ?? ""
                let updated = body.removeValue(forKey: "updated_at") as? String ?? ""
                return LegacyRow(id: id, createdAt: created, updatedAt: updated, json: jsonText(body))
            }
        }
        for (key, value) in root["settings"] as? [String: Any] ?? [:] {
            snapshot.settings[key] = jsonText(value)
        }
        for key in ["audit_log", "recycle_bin"] {
            if let items = root[key] as? [Any] { snapshot.extras[key] = items.map(jsonText) }
        }
        return snapshot
    }

    static func jsonText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
