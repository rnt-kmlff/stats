import Foundation
import Darwin

struct HelperOwnershipTests {
    static func fixture(_ body: (URL, URL, WatchedProcess, HelperOwnershipRecord) throws -> Bool) -> Bool {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("stats-owned-export-\(UUID().uuidString)")
        let root = support.appendingPathComponent("Stats Helper Ownership")
        let folder = root.appendingPathComponent("v1")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: support) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
            let id = WatchedProcessID(pid: getpid(), startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
            let process = WatchedProcess(id: id, parentPID: 1, name: "synthetic-helper", assistantAffinity: true, footprint: 100, role: .helper)
            let record = HelperOwnershipRecord(version: 1, instanceId: UUID().uuidString.lowercased(), sharing: "shared", pid: getpid(), uid: getuid(),
                startSeconds: id.startSeconds, startMicroseconds: id.startMicroseconds, chatIds: [ProcessesTests.chatA], overflow: false, writtenAt: Date().timeIntervalSince1970)
            return try body(support, folder, process, record)
        } catch { return false }
    }
    static func write(_ record: HelperOwnershipRecord, folder: URL, process: WatchedProcess) throws {
        let path = folder.appendingPathComponent(HelperOwnershipReader.filename(process.id))
        try JSONEncoder().encode(record).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    static func run() {
        func check(_ name: String, _ body: () -> Bool) { ProcessesTests.check(name, body) }
        check("helper reader off creates no export directories or names") {
            fixture { support, folder, p, record in
                try write(record, folder: folder, process: p)
                let reader = HelperOwnershipReader(applicationSupport: support)
                return reader.scan([p], enabled: false).records.isEmpty
                    && reader.scan([p], enabled: true).records[p.id]?.chatIds == [ProcessesTests.chatA]
            }
        }
        check("private helper export matches UID PID and exact start identity") {
            fixture { support, folder, p, record in
                try write(record, folder: folder, process: p)
                let scan = HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true)
                return scan.directoryAvailable && scan.records[p.id]?.sharing == "shared" && scan.unavailable == 0
            }
        }
        check("PID reuse and forged birth identity cannot restore a stale association") {
            fixture { support, folder, p, record in
                let id = WatchedProcessID(pid: p.id.pid, startSeconds: p.id.startSeconds - 1, startMicroseconds: p.id.startMicroseconds)
                let reused = WatchedProcess(id: id, parentPID: 1, name: "synthetic", assistantAffinity: true, footprint: 100, role: .helper)
                try write(record, folder: folder, process: reused)
                return HelperOwnershipReader(applicationSupport: support).scan([reused], enabled: true).records.isEmpty
            }
        }
        check("file permissions and hard links are rejected") {
            fixture { support, folder, p, record in
                try write(record, folder: folder, process: p)
                let file = folder.appendingPathComponent(HelperOwnershipReader.filename(p.id))
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
                guard HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty else { return false }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try FileManager.default.linkItem(at: file, to: folder.appendingPathComponent("synthetic-link"))
                return HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty
            }
        }
        check("symlink and oversized records are rejected without blocking") {
            fixture { support, folder, p, record in
                let file = folder.appendingPathComponent(HelperOwnershipReader.filename(p.id))
                let target = support.appendingPathComponent("synthetic-target")
                try JSONEncoder().encode(record).write(to: target)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
                guard HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty else { return false }
                try FileManager.default.removeItem(at: file)
                try Data(repeating: 0, count: HelperOwnershipReader.maxBytes + 1).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty
            }
        }
        check("unsafe export parent and directory symlinks are rejected") {
            fixture { support, folder, p, record in
                try write(record, folder: folder, process: p)
                let root = folder.deletingLastPathComponent()
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
                guard HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty else { return false }
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                let moved = support.appendingPathComponent("synthetic-other")
                try FileManager.default.moveItem(at: folder, to: moved)
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
                return HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty
            }
        }
        check("lifetime helper associations merge and stay shared after file removal") {
            fixture { support, folder, p, record in
                try write(record, folder: folder, process: p)
                let reader = HelperOwnershipReader(applicationSupport: support)
                _ = reader.scan([p], enabled: true)
                let next = HelperOwnershipRecord(version: 1, instanceId: UUID().uuidString, sharing: "shared", pid: record.pid, uid: record.uid,
                    startSeconds: record.startSeconds, startMicroseconds: record.startMicroseconds, chatIds: [ProcessesTests.chatB], overflow: false, writtenAt: Date().timeIntervalSince1970)
                try write(next, folder: folder, process: p)
                let both = reader.scan([p], enabled: true).records[p.id]?.chatIds
                try FileManager.default.removeItem(at: folder.appendingPathComponent(HelperOwnershipReader.filename(p.id)))
                let retained = reader.scan([p], enabled: true).records[p.id]?.chatIds
                guard reader.scan([], enabled: true).records.isEmpty,
                      reader.scan([p], enabled: true).records[p.id]?.chatIds == both else { return false }
                let off = reader.scan([p], enabled: false)
                return both == [ProcessesTests.chatA, ProcessesTests.chatB] && retained == both && off.records.isEmpty
                    && reader.scan([p], enabled: true).records.isEmpty
            }
        }
        check("wrong schema ownership claims bad IDs and future timestamps fail closed") {
            fixture { _, _, p, record in
                let now = Date().timeIntervalSince1970
                let data = try JSONEncoder().encode(record)
                let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                for (key, value) in [("version", 2), ("sharing", "exclusive"), ("uid", Int(getuid()) + 1),
                                     ("chatIds", ["invalid"]), ("chatIds", [ProcessesTests.chatA, ProcessesTests.chatA]),
                                     ("writtenAt", now + 60)] as [(String, Any)] {
                    var changed = original; changed[key] = value
                    let parsed = try JSONDecoder().decode(HelperOwnershipRecord.self, from: JSONSerialization.data(withJSONObject: changed))
                    if parsed.validated(for: p.id, now: now) { return false }
                }
                return true
            }
        }
        check("helper associations never become assigned RAM or inflate tagged coverage") {
            var p = ProcessesTests.tagged(20, chat: ProcessesTests.chatA, bytes: 100)
            p.helper = HelperChatAssociation(chats: [CodexChatOwnership(id: ProcessesTests.chatA, title: "Synthetic helper chat")], overflow: false)
            let usage = CodexChatUsage.summarize([p, p])
            let shared = SharedHelperUsage.summarize([p, p])
            let coverage = CodexChatCoverage(usage)
            return usage.linked.isEmpty && usage.unlinked.bytes == 100 && coverage.memoryPercent == 0 && coverage.linkedProcesses == 0
                && shared.total.bytes == 100 && shared.total.processes == 1 && shared.chatCount == 1
                && CodexChatUsage.commonOwner([p]) == nil
        }
        check("shared association names clear from history when disabled") {
            let e = ProcessesEngine(); var c = ProcessesConfiguration(); c.linkChats = true; c.helperExports = true; e.configure(c)
            var p = ProcessesTests.process(20)
            p.helper = HelperChatAssociation(chats: [CodexChatOwnership(id: ProcessesTests.chatA, title: "Synthetic helper chat")], overflow: false)
            let live = e.update(ProcessGrouping.groups([p]), complete: true, time: 0)
            c.helperExports = false; e.configure(c)
            return live.rows[0].helper != nil && e.snapshot().rows.allSatisfy { $0.helper == nil && $0.children.allSatisfy { $0.helper == nil } }
        }
        check("malformed extra-field and FIFO exports fail closed without blocking") {
            fixture { support, folder, p, record in
                let file = folder.appendingPathComponent(HelperOwnershipReader.filename(p.id))
                try write(record, folder: folder, process: p)
                var extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
                extra["syntheticPromptDecoy"] = "not part of metadata"
                try JSONSerialization.data(withJSONObject: extra).write(to: file)
                guard HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty else { return false }
                try Data("{bad synthetic JSON".utf8).write(to: file)
                guard HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty else { return false }
                try FileManager.default.removeItem(at: file)
                guard mkfifo(file.path, 0o600) == 0 else { return false }
                let start = ProcessInfo.processInfo.systemUptime
                return HelperOwnershipReader(applicationSupport: support).scan([p], enabled: true).records.isEmpty
                    && ProcessInfo.processInfo.systemUptime - start < 1
            }
        }
        check("helper directory enumeration and file reads have independent caps") {
            fixture { support, folder, _, record in
                var fake: [WatchedProcess] = []
                for n in 0..<140 {
                    let id = WatchedProcessID(pid: 2_000_000 + Int32(n), startSeconds: 1, startMicroseconds: 0)
                    let p = WatchedProcess(id: id, parentPID: 1, name: "synthetic", assistantAffinity: true, footprint: 100, role: .helper)
                    fake.append(p); try write(record, folder: folder, process: p)
                }
                let scan = HelperOwnershipReader(applicationSupport: support).scan(fake, enabled: true)
                return scan.limited && scan.records.isEmpty && scan.unavailable == HelperOwnershipReader.maxReads
            }
        }
        check("shared helpers bypass tag assignment and retain one title lookup budget") {
            fixture { support, _, p, _ in
                let absent = support.appendingPathComponent("synthetic-missing.sqlite")
                let result = CodexChatAttribution.scan([p], enabled: true, metadataURL: absent,
                    sharedHelpers: [p.id], additionalIDs: [ProcessesTests.chatA, ProcessesTests.chatB])
                return result.tagReads == 0 && result.owners.isEmpty && !result.metadataAvailable
                    && !FileManager.default.fileExists(atPath: absent.path)
            }
        }
        check("bounded lifetime unions retain earlier chats when a publisher changes") {
            fixture { support, folder, p, record in
                try write(record, folder: folder, process: p)
                let reader = HelperOwnershipReader(applicationSupport: support)
                _ = reader.scan([p], enabled: true)
                let ids = (0..<8).map { String(format: "00000000-0000-0000-0000-%012d", $0) }
                let replacement = HelperOwnershipRecord(version: 1, instanceId: UUID().uuidString, sharing: "shared", pid: record.pid, uid: record.uid,
                    startSeconds: record.startSeconds, startMicroseconds: record.startMicroseconds, chatIds: ids, overflow: false, writtenAt: Date().timeIntervalSince1970)
                try write(replacement, folder: folder, process: p)
                let value = reader.scan([p], enabled: true).records[p.id]
                return value?.chatIds.count == 8 && value?.chatIds.contains(ProcessesTests.chatA) == true && value?.overflow == true
            }
        }
        check("legacy preferences keep helper reading off") {
            do {
                let encoded = try JSONEncoder().encode(ProcessesConfiguration())
                guard var data = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return false }
                data.removeValue(forKey: "helperExports")
                let legacy = try JSONSerialization.data(withJSONObject: data)
                return !(try JSONDecoder().decode(ProcessesConfiguration.self, from: legacy)).helperExports
            } catch { return false }
        }
    }
}
