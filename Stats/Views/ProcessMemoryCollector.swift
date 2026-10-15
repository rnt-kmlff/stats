import Foundation
import Darwin

struct ProcessMemoryScan {
    let groups: [WatchedProcessGroup]
    let complete: Bool
    let limited: Bool
    var unknownPIDs: Set<Int32> = []
    var chatLinks = CodexChatLinkScan()
}

struct ProcessMemoryCollector {
    // No task ports or administrator rights. Optional chat linking follows its reviewed metadata contract.
    static func scan(linkChats: Bool = false) -> ProcessMemoryScan {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ProcessMemoryScan(groups: [], complete: false, limited: false) }
        let capacity = min(8192, max(1024, Int(count) + 256))
        var pids = [Int32](repeating: 0, count: capacity)
        let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard found > 0 else { return ProcessMemoryScan(groups: [], complete: false, limited: false) }
        var records: [WatchedProcess] = []
        var unknown: Set<Int32> = []
        for pid in pids.prefix(min(Int(found), capacity)) where pid > 0 {
            guard let info = identity(pid) else { unknown.insert(pid); continue }
            guard info.pbi_uid == getuid() else { continue }
            var buffer = [CChar](repeating: 0, count: 4096)
            let pathResult = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let path = pathResult > 0 ? String(cString: buffer) : ""
            let name: String
            if !path.isEmpty { name = (path as NSString).lastPathComponent } else {
                var nameBuffer = [CChar](repeating: 0, count: 256)
                _ = nameBuffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
                name = String(cString: nameBuffer)
            }
            let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") })?.lowercased()
            let assistant = app == "chatgpt.app" || app == "codex.app" || name.lowercased() == "codex"
            records.append(WatchedProcess(id: WatchedProcessID(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec),
                                          parentPID: Int32(clamping: info.pbi_ppid), name: String(name.prefix(80)), assistantAffinity: assistant, footprint: nil,
                                          role: ProcessRole.identify(name: name, path: path, assistant: assistant)))
        }
        let candidates = ProcessGrouping.groups(records)
        let selected = Array(candidates.prefix(ProcessesEngine.maxGroups))
        var measured: [WatchedProcessID: UInt64] = [:]
        var reads = 0
        for group in selected {
            for process in group.members where reads < 512 {
                reads += 1
                if let bytes = footprint(process.id) { measured[process.id] = bytes }
            }
        }
        let live = selected.flatMap { $0.members }.map { p in var value = p; value.footprint = measured[p.id]; return value }
        let links = CodexChatAttribution.scan(live, enabled: linkChats)
        let groups = selected.map { group in
            WatchedProcessGroup(key: group.key, root: group.root, kind: group.kind,
                                members: group.members.map { p in var value = p; value.footprint = measured[p.id]; value.chat = links.owners[p.id]; return value })
        }
        return ProcessMemoryScan(groups: groups, complete: Int(found) < capacity,
                                 limited: candidates.count > ProcessesEngine.maxGroups || selected.reduce(0, { $0 + $1.members.count }) > 512, unknownPIDs: unknown, chatLinks: links)
    }
    private static func identity(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }
    private static func footprint(_ id: WatchedProcessID) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(id.pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0, let after = identity(id.pid), after.pbi_start_tvsec == id.startSeconds,
              after.pbi_start_tvusec == id.startMicroseconds else { return nil }
        return usage.ri_phys_footprint
    }
}
