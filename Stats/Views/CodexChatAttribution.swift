import Foundation
import Darwin
import SQLite3

struct CodexChatLinkScan {
    var owners: [WatchedProcessID: CodexChatOwnership] = [:]
    var limited = false
    var unavailable = 0
    var tagReads = 0
    var metadataAvailable = false
    var titles: [String: String] = [:]
}

struct CodexChatAttribution {
    static let maxReads = 64
    static let maxTitles = 20
    static func scan(_ processes: [WatchedProcess], enabled: Bool, metadataURL: URL? = nil,
                     sharedHelpers: Set<WatchedProcessID> = [], additionalIDs: [String] = []) -> CodexChatLinkScan {
        guard enabled else { return CodexChatLinkScan() }
        let ordered = processes.filter { !sharedHelpers.contains($0.id) }.sorted { a, b in
            if ProcessGrouping.isBuildTool(a) != ProcessGrouping.isBuildTool(b) { return ProcessGrouping.isBuildTool(a) }
            return a.footprint == b.footprint ? a.id.pid < b.id.pid : (a.footprint ?? 0) > (b.footprint ?? 0)
        }
        var result = CodexChatLinkScan(limited: ordered.count > maxReads)
        var tags: [WatchedProcessID: String] = [:]
        for process in ordered.prefix(maxReads) {
            result.tagReads += 1
            guard let tag = readTag(process.id) else { result.unavailable += 1; continue }
            if case let .linked(id) = tag { tags[process.id] = id }
        }
        let ids = Array(Set(Array(tags.values) + additionalIDs)).sorted()
        let titleIDs = Array(ids.prefix(maxTitles))
        let metadata = metadataURL.map { CodexChatTitles.read(ids: titleIDs, databaseURL: $0) } ?? CodexChatTitles.read(ids: titleIDs)
        result.metadataAvailable = metadata.available
        result.titles = metadata.titles
        result.limited = result.limited || ids.count > maxTitles
        for (process, id) in tags { result.owners[process] = CodexChatOwnership(id: id, title: metadata.titles[id]) }
        return result
    }
    private static func identityMatches(_ id: WatchedProcessID) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(id.pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
            && info.pbi_start_tvsec == id.startSeconds && info.pbi_start_tvusec == id.startMicroseconds
    }
    private static func readTag(_ id: WatchedProcessID) -> CodexThreadTag? {
        guard identityMatches(id) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, id.pid]
        var count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0, count >= 4, count <= CodexThreadTagParser.maxBytes else { return nil }
        let capacity = count
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<Int32>.alignment)
        defer { _ = memset_s(buffer, capacity, 0, capacity); buffer.deallocate() }
        guard sysctl(&mib, 3, buffer, &count, nil, 0) == 0, count >= 4, count <= capacity else { return nil }
        let value = CodexThreadTagParser.parse(UnsafeRawBufferPointer(start: buffer, count: count))
        guard identityMatches(id) else { return nil }
        return value
    }
}

struct CodexChatTitles {
    // Undocumented local metadata only: no opening-prompt/title/transcript/history/log/config/auth reads or database writes.
    static func read(ids: [String], databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")) -> (titles: [String: String], available: Bool) {
        guard !ids.isEmpty else { return ([:], true) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return ([:], false)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 10)
        sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA cache_size=-512", nil, nil, nil)
        var statement: OpaquePointer?
        let query = "SELECT substr(name,1,120) FROM threads WHERE id=? LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return ([:], false) }
        defer { sqlite3_finalize(statement) }
        var deadline = ProcessInfo.processInfo.systemUptime + 0.05
        return withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(db, 500, { context in
                guard let context else { return 1 }
                return ProcessInfo.processInfo.systemUptime >= context.assumingMemoryBound(to: TimeInterval.self).pointee ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            var titles: [String: String] = [:]
            var available = true
            for id in ids.prefix(CodexChatAttribution.maxTitles) {
                guard ProcessInfo.processInfo.systemUptime < pointer.pointee else { available = false; break }
                guard UUID(uuidString: id) != nil else { continue }
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                let step: Int32 = id.withCString { pointer in
                    guard sqlite3_bind_text(statement, 1, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { return SQLITE_ERROR }
                    return sqlite3_step(statement)
                }
                if step == SQLITE_ROW {
                    if let value = sqlite3_column_text(statement, 0), sqlite3_column_bytes(statement, 0) <= 480 {
                        titles[id] = CodexChatOwnership.cleanTitle(String(cString: value))
                    }
                } else if step != SQLITE_DONE { available = false }
            }
            return (titles, available)
        }
    }
}
