import Foundation
import SQLite3

/// Where a both-⌘ screenshot goes: a new thread in a project, or an existing thread.
struct ChatTarget: Codable, Equatable {
    enum Kind: String, Codable { case newThread, thread }

    var kind: Kind
    var path: String          // project root
    var project: String       // project name
    var threadID: String? = nil
    var title: String? = nil  // thread title

    var label: String { kind == .newThread ? project : (title ?? "Thread") }

    static func == (a: ChatTarget, b: ChatTarget) -> Bool {
        a.kind == b.kind && (a.kind == .thread ? a.threadID == b.threadID : a.path == b.path)
    }

    // MARK: Default

    private static let defaultsKey = "QuickChatTarget"

    /// The target a quick tap sends to. Starts as a new thread in the T3 project (Home).
    static var standard: ChatTarget {
        get {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let target = try? JSONDecoder().decode(ChatTarget.self, from: data) { return target }
            let path = T3Sender.project
            let name = Catalog.projectName(at: path) ?? URL(fileURLWithPath: path).lastPathComponent
            return ChatTarget(kind: .newThread, path: path, project: name)
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        }
    }

    /// Deep link that opens this thread in the desktop app, composer focused.
    var threadURL: URL? {
        guard kind == .thread, let threadID, let env = Catalog.environmentID else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        guard let id = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "t3code://threads/\(env)/\(id)")
    }
}

/// Projects and recent threads, read straight from T3's local state database (read-only).
/// The CLI lists one project's threads per call; this is one quick query for the picker.
enum Catalog {
    private static let userdata = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".t3/userdata", isDirectory: true)

    static var environmentID: String? {
        (try? String(contentsOf: userdata.appendingPathComponent("environment-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func projectName(at path: String) -> String? {
        query("select title from projection_projects where workspace_root = ? and deleted_at is null limit 1", [path]).first?.first
    }

    /// Projects (the T3 project first, then most recently used) and threads, newest first.
    static func load() -> (projects: [ChatTarget], threads: [ChatTarget]) {
        let home = T3Sender.project
        var projects = query("""
            select title, workspace_root from projection_projects
            where deleted_at is null and archived_at is null and workspace_root not like '%/.t3/scratch'
            order by updated_at desc
            """).map { ChatTarget(kind: .newThread, path: $0[1], project: $0[0]) }
        if let i = projects.firstIndex(where: { $0.path == home }) { projects.insert(projects.remove(at: i), at: 0) }
        let threads = query("""
            select t.thread_id, t.title, p.title, p.workspace_root
            from orchestration_v2_projection_threads t join projection_projects p using(project_id)
            where t.archived_at is null and t.deleted_at is null and p.deleted_at is null
              and json_extract(t.payload_json, '$.lineage.parentThreadId') is null
            order by t.updated_at desc limit 80
            """).map { ChatTarget(kind: .thread, path: $0[3], project: $0[2], threadID: $0[0], title: $0[1]) }
        return (projects, threads)
    }

    private static func query(_ sql: String, _ args: [String] = []) -> [[String]] {
        var db: OpaquePointer?
        let path = userdata.appendingPathComponent("statev2.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 300)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = sqlite3_column_count(stmt)
            rows.append((0..<n).map { c in sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "" })
        }
        return rows
    }
}
