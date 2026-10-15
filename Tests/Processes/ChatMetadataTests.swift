import Foundation
import Darwin
import SQLite3

struct ChatMetadataTests {
    static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        if result != SQLITE_OK { throw NSError(domain: "SyntheticSQLiteFixture", code: Int(result)) }
    }
    static func fixture(_ body: (URL, OpaquePointer?) throws -> Bool) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stats-synthetic-chat-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("synthetic.sqlite")
            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK else { if let db { sqlite3_close(db) }; return false }
            defer { sqlite3_close(db) }
            return try body(url, db)
        } catch { return false }
    }
    static func ownedProcess(_ body: (WatchedProcess) -> Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        process.arguments = ["--synthetic-tag-child"]
        process.environment = ["CODEX_THREAD_ID": ProcessesTests.chatA, "CODEX_SESSION_ID": ProcessesTests.chatA, "SYNTHETIC_SECRET": "not-a-real-secret"]
        do { try process.run() } catch { return false }
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var ready = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            var path = [CChar](repeating: 0, count: 4096)
            let count = path.withUnsafeMutableBytes { proc_pidpath(process.processIdentifier, $0.baseAddress, UInt32($0.count)) }
            if count > 0 && (String(cString: path) as NSString).lastPathComponent == process.executableURL?.lastPathComponent { ready = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard ready else { print("Synthetic executable did not become visible; running=\(process.isRunning)"); return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.processIdentifier, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        let id = WatchedProcessID(pid: process.processIdentifier, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        return body(WatchedProcess(id: id, parentPID: Int32(getpid()), name: "synthetic-node-fixture", assistantAffinity: false, footprint: 1048576))
    }
    static func run() {
        ProcessesTests.check("metadata reader prefers renamed title and never reads conversation payloads") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, first_user_message TEXT)")
                try execute(db, "INSERT INTO threads VALUES ('\(ProcessesTests.chatA)','Synthetic renamed task','Synthetic old title','not selected')")
                let before = try Data(contentsOf: url)
                let result = CodexChatTitles.read(ids: [ProcessesTests.chatA], databaseURL: url)
                let after = try Data(contentsOf: url)
                return result.available && result.titles[ProcessesTests.chatA] == "Synthetic renamed task" && before == after
            }
        }
        ProcessesTests.check("missing metadata file remains absent with read-only access") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-absent-\(UUID().uuidString).sqlite")
            let result = CodexChatTitles.read(ids: [ProcessesTests.chatA], databaseURL: url)
            return !result.available && result.titles.isEmpty && !FileManager.default.fileExists(atPath: url.path)
        }
        ProcessesTests.check("metadata schema drift leaves names unavailable without transcript fallback") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, first_user_message TEXT)")
                try execute(db, "INSERT INTO threads VALUES ('\(ProcessesTests.chatA)','not a title')")
                let result = CodexChatTitles.read(ids: [ProcessesTests.chatA], databaseURL: url)
                return !result.available && result.titles.isEmpty
            }
        }
        ProcessesTests.check("metadata names are bounded and sanitized without prompt fallback") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
                try execute(db, "INSERT INTO threads VALUES ('\(ProcessesTests.chatA)','Synthetic\nTitle\u{202E}\(String(repeating: "x", count: 200))','not selected')")
                let result = CodexChatTitles.read(ids: [ProcessesTests.chatA, "invalid-id' OR 1=1"], databaseURL: url)
                let title = result.titles[ProcessesTests.chatA] ?? ""
                return result.available && result.titles.count == 1 && title.count <= 120 && !title.contains("\n") && !title.contains("\u{202E}")
            }
        }
        ProcessesTests.check("missing chat name never falls back to opening-prompt title") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
                try execute(db, "INSERT INTO threads VALUES ('\(ProcessesTests.chatA)',NULL,'Synthetic private prompt decoy')")
                let result = CodexChatTitles.read(ids: [ProcessesTests.chatA], databaseURL: url)
                return result.available && result.titles.isEmpty
            }
        }
        ProcessesTests.check("metadata row lookup count is capped") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
                var ids: [String] = []
                for index in 1...25 {
                    let id = String(format: "20000000-0000-0000-0000-%012d", index); ids.append(id)
                    try execute(db, "INSERT INTO threads VALUES ('\(id)','Synthetic task','Synthetic title')")
                }
                return CodexChatTitles.read(ids: ids, databaseURL: url).titles.count == CodexChatAttribution.maxTitles
            }
        }
        ProcessesTests.check("busy metadata fails promptly without changing the writer") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
                try execute(db, "BEGIN EXCLUSIVE")
                defer { try? execute(db, "ROLLBACK") }
                let start = ProcessInfo.processInfo.systemUptime
                let result = CodexChatTitles.read(ids: [ProcessesTests.chatA], databaseURL: url)
                return !result.available && result.titles.isEmpty && ProcessInfo.processInfo.systemUptime - start < 1
            }
        }
        ProcessesTests.check("disabled chat linking performs no kernel reads or metadata creation") {
            ownedProcess { value in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-absent-\(UUID().uuidString).sqlite")
                let result = CodexChatAttribution.scan([value], enabled: false, metadataURL: url)
                return result.owners.isEmpty && result.tagReads == 0 && !FileManager.default.fileExists(atPath: url.path)
            }
        }
        ProcessesTests.check("owned synthetic process links by UUID and read-only title metadata") {
            fixture { url, db in
                try execute(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT)")
                try execute(db, "INSERT INTO threads VALUES ('\(ProcessesTests.chatA)','Synthetic process task','Synthetic title')")
                return ownedProcess { value in
                    let result = CodexChatAttribution.scan([value], enabled: true, metadataURL: url)
                    let okay = result.owners[value.id]?.id == ProcessesTests.chatA && result.owners[value.id]?.label == "Synthetic process task" && result.tagReads == 1
                    if !okay { print("Synthetic fixture counts: reads=\(result.tagReads), unavailable=\(result.unavailable), owners=\(result.owners.count), metadata=\(result.metadataAvailable)") }
                    return okay
                }
            }
        }
        ProcessesTests.check("wrong process start identity is never assigned a chat") {
            ownedProcess { value in
                let mismatch = WatchedProcessID(pid: value.id.pid, startSeconds: value.id.startSeconds + 1, startMicroseconds: value.id.startMicroseconds)
                let input = WatchedProcess(id: mismatch, parentPID: 1, name: "synthetic", assistantAffinity: false, footprint: 1)
                let result = CodexChatAttribution.scan([input], enabled: true)
                return result.owners.isEmpty && result.unavailable == 1
            }
        }
        ProcessesTests.check("kernel tag reads are capped independently of footprint sampling") {
            let values = (1...100).map { index in
                WatchedProcess(id: WatchedProcessID(pid: -Int32(index), startSeconds: 0, startMicroseconds: 0),
                               parentPID: 1, name: "synthetic", assistantAffinity: false, footprint: 1)
            }
            let result = CodexChatAttribution.scan(values, enabled: true)
            return result.limited && result.tagReads == CodexChatAttribution.maxReads && result.owners.isEmpty
        }
    }
}
