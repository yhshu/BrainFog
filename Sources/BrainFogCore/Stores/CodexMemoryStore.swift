import Foundation
import SQLite3

/// Read-only view of Codex's memory pipeline database
/// (`~/.codex/memories_*.sqlite`). Codex owns this file; BrainFog never writes it.
public final class CodexMemoryStore {
    public struct Stats: Sendable {
        public var rawMemories: Int
        public var selected: Int
    }

    public struct RawMemory: Identifiable, Sendable {
        public var id: String { threadID }
        public var threadID: String
        public var slug: String?
        public var summary: String
        public var memory: String
        public var generatedAt: Date
        public var usageCount: Int
    }

    private var db: OpaquePointer?

    /// Opens the newest `memories_<n>.sqlite` under `codexHome`, if any.
    public init?(codexHome: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: codexHome.path)) ?? []
        let newest = files
            .filter { $0.hasPrefix("memories_") && $0.hasSuffix(".sqlite") }
            .max { Self.version($0) < Self.version($1) }
        guard let newest else { return nil }
        // By plain path, not a `file:` URI, so `#` or `?` in a folder name is literal.
        let path = codexHome.appendingPathComponent(newest).path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            // deinit still runs for a failed init, so don't close twice.
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    private static func version(_ name: String) -> Int {
        Int(name.dropFirst("memories_".count).dropLast(".sqlite".count)) ?? 0
    }

    public func stats() -> Stats? {
        guard let rows = query("SELECT COUNT(*), COALESCE(SUM(selected_for_phase2), 0) FROM stage1_outputs",
                               map: { (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))) }),
              let row = rows.first else { return nil }
        return Stats(rawMemories: row.0, selected: row.1)
    }

    public func rawMemories(limit: Int = 200) -> [RawMemory] {
        query("""
            SELECT thread_id, rollout_slug, rollout_summary, raw_memory, generated_at, COALESCE(usage_count, 0)
            FROM stage1_outputs ORDER BY generated_at DESC LIMIT \(limit)
            """) { s in
            RawMemory(threadID: Self.text(s, 0) ?? "", slug: Self.text(s, 1),
                      summary: Self.text(s, 2) ?? "", memory: Self.text(s, 3) ?? "",
                      generatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 4))),
                      usageCount: Int(sqlite3_column_int64(s, 5)))
        } ?? []
    }

    private func query<T>(_ sql: String, map: (OpaquePointer) -> T) -> [T]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
}
