// Local, read-only process memory monitoring for the personal Stats fork.
import Foundation

struct WatchedProcessID: Hashable, Codable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    var key: String { "\(pid):\(startSeconds):\(startMicroseconds)" }
}

struct WatchedProcess {
    let id: WatchedProcessID
    let parentPID: Int32
    let name: String
    let assistantAffinity: Bool
    var footprint: UInt64?
}

enum ProcessWatchKind: String, Codable { case assistant, job }

struct MemoryAlertRule: Codable, Equatable {
    var budgetGB: Double
    var growthGB: Double
    func validated() -> MemoryAlertRule {
        MemoryAlertRule(budgetGB: budgetGB.isFinite ? min(128, max(0.05, budgetGB)) : 8,
                        growthGB: growthGB.isFinite ? min(128, max(0, growthGB)) : 0)
    }
}

struct ProcessesConfiguration: Codable, Equatable {
    var enabled = true
    var alerts = false
    var assistant = MemoryAlertRule(budgetGB: 8, growthGB: 1)
    var jobs = MemoryAlertRule(budgetGB: 4, growthGB: 1)
    var sustainedSeconds: Double = 15
    var cooldownSeconds: Double = 300
    var overrides: [String: MemoryAlertRule] = [:]
    func rule(for kind: ProcessWatchKind) -> MemoryAlertRule { kind == .assistant ? assistant : jobs }
    func validated() -> ProcessesConfiguration {
        var c = self
        c.assistant = assistant.validated(); c.jobs = jobs.validated()
        c.sustainedSeconds = sustainedSeconds.isFinite ? min(300, max(5, sustainedSeconds)) : 15
        c.cooldownSeconds = cooldownSeconds.isFinite ? min(3600, max(30, cooldownSeconds)) : 300
        c.overrides = Dictionary(uniqueKeysWithValues: overrides.sorted { $0.key < $1.key }.prefix(20).map { ($0.key, $0.value.validated()) })
        return c
    }
}

struct WatchedProcessGroup {
    let key: String
    let root: WatchedProcess
    let kind: ProcessWatchKind
    let members: [WatchedProcess]
    var title: String { kind == .assistant ? "ChatGPT / Codex" : "Local job: \(root.name)" }
    var footprint: UInt64? {
        var total: UInt64 = 0
        for p in members {
            guard let bytes = p.footprint else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }
}

struct ProcessGrouping {
    static let buildNames: Set<String> = ["node", "bun", "deno", "python", "python3", "pypy", "swift", "swift-frontend", "swiftc", "clang", "clang++", "cc", "gcc", "g++", "xcodebuild", "make", "cmake", "ninja", "cargo", "rustc", "npm", "esbuild", "tsc", "webpack", "rollup", "vite", "java", "gradle"]
    static func isBuildTool(_ p: WatchedProcess) -> Bool {
        let name = p.name.lowercased()
        return !p.assistantAffinity && (buildNames.contains(name) || name.hasPrefix("python3.") || name.hasPrefix("pypy3"))
    }
    static func groups(_ processes: [WatchedProcess]) -> [WatchedProcessGroup] {
        let byPID = Dictionary(processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { a, b in a.id.startSeconds > b.id.startSeconds ? a : b })
        var roots: [String: (WatchedProcess, ProcessWatchKind)] = [:]
        var members: [String: [WatchedProcess]] = [:]
        for process in processes {
            var chain: [WatchedProcess] = []
            var next: WatchedProcess? = process
            var seen: Set<Int32> = []
            while let p = next, seen.insert(p.id.pid).inserted, chain.count < 64 {
                chain.append(p)
                next = byPID[p.parentPID]
            }
            // External build trees are separate from the desktop app, avoiding overlap.
            let job = chain.last(where: isBuildTool)
            let assistant = chain.last(where: { $0.assistantAffinity })
            guard let root = job ?? assistant else { continue }
            let kind: ProcessWatchKind = job != nil ? .job : .assistant
            let key = "group:\(kind.rawValue):\(root.id.key)"
            roots[key] = (root, kind)
            members[key, default: []].append(process)
        }
        return roots.map { key, value in
            WatchedProcessGroup(key: key, root: value.0, kind: value.1,
                                members: (members[key] ?? []).sorted { $0.id.pid < $1.id.pid })
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .assistant }
            return $0.root.id.startSeconds == $1.root.id.startSeconds ? $0.root.id.pid > $1.root.id.pid : $0.root.id.startSeconds > $1.root.id.startSeconds
        }
    }
}

struct MemoryHistoryPoint {
    let time: TimeInterval
    let bytes: UInt64?
}

final class ProcessMemoryRow: NSObject {
    let key: String
    let name: String
    let pid: Int32
    let kind: ProcessWatchKind
    let isGroup: Bool
    let current: UInt64?
    let peak: UInt64
    let growth: Double?
    let status: String
    let children: [ProcessMemoryRow]
    init(key: String, name: String, pid: Int32, kind: ProcessWatchKind, isGroup: Bool,
         current: UInt64?, peak: UInt64, growth: Double?, status: String, children: [ProcessMemoryRow] = []) {
        self.key = key; self.name = name; self.pid = pid; self.kind = kind; self.isGroup = isGroup
        self.current = current; self.peak = peak; self.growth = growth; self.status = status; self.children = children
    }
}

struct ProcessMemoryAlert {
    let key: String
    let name: String
    let bytes: UInt64
    let reason: String
}

struct ProcessesSnapshot {
    var rows: [ProcessMemoryRow] = []
    var selectedKey: String?
    var history: [MemoryHistoryPoint] = []
    var alerts: [ProcessMemoryAlert] = []
    var limited = false
    var complete = true
}

private final class ProcessMemorySeries {
    let key: String
    var name: String
    let pid: Int32
    let kind: ProcessWatchKind
    let isGroup: Bool
    var parent: String?
    var current: UInt64?
    var peak: UInt64 = 0
    var growth: Double?
    var status = "Collecting"
    var lastSeen: TimeInterval
    var history: [MemoryHistoryPoint] = []
    var thresholdSince: TimeInterval?
    var incident = false
    var lastAlert: TimeInterval = -.infinity
    init(key: String, name: String, pid: Int32, kind: ProcessWatchKind, isGroup: Bool, parent: String?, time: TimeInterval) {
        self.key = key; self.name = name; self.pid = pid; self.kind = kind; self.isGroup = isGroup
        self.parent = parent; lastSeen = time
    }
    func sample(_ bytes: UInt64?, status: String, time: TimeInterval) {
        if let last = history.last, time <= last.time || time - last.time > 15 {
            thresholdSince = nil
            history.append(MemoryHistoryPoint(time: time - 0.001, bytes: nil))
        }
        current = bytes; self.status = status
        if let bytes { peak = max(peak, bytes) }
        history.append(MemoryHistoryPoint(time: time, bytes: bytes))
        history.removeAll { $0.time < time - 3600 }
        if history.count > 721 { history.removeFirst(history.count - 721) }
        growth = nil
        if let bytes, let baseline = history.last(where: { $0.time <= time - 300 }), let old = baseline.bytes,
           !history.contains(where: { $0.time >= baseline.time && $0.bytes == nil }) {
            growth = Double(bytes) - Double(old)
        }
        if bytes == nil { thresholdSince = nil }
    }
    func resetAlert() { thresholdSince = nil; incident = false; lastAlert = -.infinity }
}

final class ProcessesEngine {
    static let maxGroups = 20
    static let maxSeries = 544
    private var series: [String: ProcessMemorySeries] = [:]
    var configuration = ProcessesConfiguration()
    var selectedKey: String?
    func configure(_ value: ProcessesConfiguration) {
        configuration = value.validated()
        series.values.forEach { $0.resetAlert() }
    }
    func update(_ groups: [WatchedProcessGroup], complete: Bool, time: TimeInterval, unknownPIDs: Set<Int32> = []) -> ProcessesSnapshot {
        series = series.filter { time - $0.value.lastSeen <= 3600 }
        var present: Set<String> = []
        var events: [ProcessMemoryAlert] = []
        for group in groups.prefix(Self.maxGroups) {
            let s = obtain(key: group.key, name: group.title, pid: group.root.id.pid, kind: group.kind, isGroup: true, parent: nil, time: time)
            guard let s else { continue }
            present.insert(s.key); s.lastSeen = time
            let missingMember = series.values.contains { $0.parent == group.key && unknownPIDs.contains($0.pid) }
            let current = complete && !missingMember ? group.footprint : nil
            s.sample(current, status: !complete ? "Unavailable" : current == nil ? "Partial" : "Live", time: time)
            if let event = alert(s, time: time) { events.append(event) }
            for member in group.members {
                let key = "process:\(member.id.key)"
                guard let child = obtain(key: key, name: member.name, pid: member.id.pid, kind: group.kind, isGroup: false, parent: group.key, time: time) else { continue }
                present.insert(key); child.lastSeen = time; child.parent = group.key
                let bytes = complete ? member.footprint : nil
                child.sample(bytes, status: !complete || bytes == nil ? "Unavailable" : "Live", time: time)
                if let event = alert(child, time: time) { events.append(event) }
            }
        }
        for s in series.values where !present.contains(s.key) {
            s.sample(nil, status: complete && !unknownPIDs.contains(s.pid) ? "Exited" : "Unavailable", time: time)
        }
        var result = snapshot()
        result.alerts = events
        result.limited = groups.count > Self.maxGroups || series.count >= Self.maxSeries
        result.complete = complete
        return result
    }
    func pause(time: TimeInterval) -> ProcessesSnapshot {
        for s in series.values { s.sample(nil, status: "Paused", time: time); s.thresholdSince = nil }
        return snapshot()
    }
    private func obtain(key: String, name: String, pid: Int32, kind: ProcessWatchKind, isGroup: Bool, parent: String?, time: TimeInterval) -> ProcessMemorySeries? {
        if let s = series[key] { return s }
        if series.count >= Self.maxSeries {
            if let oldest = series.values.filter({ $0.current == nil }).min(by: { $0.lastSeen < $1.lastSeen }) { series.removeValue(forKey: oldest.key) }
            else { return nil }
        }
        let s = ProcessMemorySeries(key: key, name: name, pid: pid, kind: kind, isGroup: isGroup, parent: parent, time: time)
        series[key] = s
        return s
    }
    private func alert(_ s: ProcessMemorySeries, time: TimeInterval) -> ProcessMemoryAlert? {
        guard configuration.alerts, configuration.enabled, let bytes = s.current else { s.thresholdSince = nil; return nil }
        guard let rule = configuration.overrides[s.key] ?? (s.isGroup ? configuration.rule(for: s.kind) : nil) else { return nil }
        let budget = rule.budgetGB * 1073741824
        let growthExceeded = rule.growthGB > 0 && (s.growth ?? -.infinity) >= rule.growthGB * 1073741824
        let exceeded = Double(bytes) >= budget || growthExceeded
        if !exceeded {
            s.thresholdSince = nil
            if Double(bytes) < budget * 0.9 { s.incident = false }
            return nil
        }
        if s.thresholdSince == nil { s.thresholdSince = time }
        guard !s.incident, time - (s.thresholdSince ?? time) >= configuration.sustainedSeconds,
              time - s.lastAlert >= configuration.cooldownSeconds else { return nil }
        s.incident = true; s.lastAlert = time
        return ProcessMemoryAlert(key: s.key, name: s.name, bytes: bytes,
                                  reason: Double(bytes) >= budget ? "Memory budget exceeded" : "Memory grew beyond the five-minute threshold")
    }
    func snapshot() -> ProcessesSnapshot {
        func row(_ s: ProcessMemorySeries, children: [ProcessMemoryRow] = []) -> ProcessMemoryRow {
            ProcessMemoryRow(key: s.key, name: s.name, pid: s.pid, kind: s.kind, isGroup: s.isGroup,
                             current: s.current, peak: s.peak, growth: s.growth, status: s.status, children: children)
        }
        let groups = series.values.filter { $0.isGroup }.sorted {
            if ($0.current != nil) != ($1.current != nil) { return $0.current != nil }
            if $0.kind != $1.kind { return $0.kind == .assistant }
            return ($0.current ?? 0) > ($1.current ?? 0)
        }
        let rows = groups.map { s in
            let children = series.values.filter { $0.parent == s.key }.sorted {
                if ($0.current != nil) != ($1.current != nil) { return $0.current != nil }
                return ($0.current ?? 0) > ($1.current ?? 0)
            }.map { row($0) }
            return row(s, children: children)
        }
        if selectedKey == nil || series[selectedKey!] == nil { selectedKey = rows.first?.key }
        return ProcessesSnapshot(rows: rows, selectedKey: selectedKey, history: selectedKey.flatMap { series[$0]?.history } ?? [])
    }
}
