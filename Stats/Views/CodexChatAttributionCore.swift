import Foundation

struct CodexChatOwnership: Equatable {
    let id: String
    let title: String?
    var label: String { title ?? "Chat \(id.prefix(8)) (title unavailable)" }
    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(120))
    }
}

enum CodexThreadTag: Equatable {
    case linked(String), absent, invalid, conflict
}

struct CodexThreadTagParser {
    static let maxBytes = 1048576
    private static let keys = [Array("CODEX_THREAD_ID=".utf8), Array("CODEX_SESSION_ID=".utf8)]
    // Only the two exact keys become strings. Arguments and unrelated environment bytes are skipped.
    static func parse(_ bytes: UnsafeRawBufferPointer) -> CodexThreadTag {
        guard bytes.count >= 4, bytes.count <= maxBytes else { return .invalid }
        let argc = bytes.loadUnaligned(as: Int32.self)
        guard argc > 0, argc <= 4096 else { return .invalid }
        var offset = 4
        func end(_ start: Int) -> Int? {
            guard start < bytes.count else { return nil }
            var cursor = start
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            return cursor < bytes.count ? cursor : nil
        }
        guard let executableEnd = end(offset) else { return .invalid }
        offset = executableEnd + 1
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc {
            guard let argumentEnd = end(offset) else { return .invalid }
            offset = argumentEnd + 1
        }
        var found: String?
        while offset < bytes.count {
            guard let valueEnd = end(offset) else { return .invalid }
            if valueEnd == offset { break }
            for key in keys where valueEnd - offset >= key.count && bytes[offset..<(offset + key.count)].elementsEqual(key) {
                let start = offset + key.count
                guard valueEnd - start == 36 else { return .invalid }
                for index in 0..<36 {
                    let value = bytes[start + index]
                    if [8, 13, 18, 23].contains(index) {
                        guard value == 45 else { return .invalid }
                    } else if !(48...57).contains(value) && !(65...70).contains(value) && !(97...102).contains(value) { return .invalid }
                }
                let id = String(decoding: bytes[start..<valueEnd], as: UTF8.self).lowercased()
                if let previous = found, previous != id { return .conflict }
                found = id
            }
            offset = valueEnd + 1
        }
        return found.map(CodexThreadTag.linked) ?? .absent
    }
}

struct CodexChatTotal {
    let chat: CodexChatOwnership?
    var bytes: UInt64 = 0
    var processes = 0
    var missing = 0
    mutating func add(_ process: WatchedProcess) {
        processes += 1
        guard let value = process.footprint else { missing += 1; return }
        let sum = bytes.addingReportingOverflow(value)
        if sum.overflow { missing += 1 } else { bytes = sum.partialValue }
    }
}

struct CodexChatUsage {
    var linked: [CodexChatTotal]
    var unlinked: CodexChatTotal
    static func commonOwner(_ processes: [WatchedProcess]) -> CodexChatOwnership? {
        guard let first = processes.first?.chat, processes.allSatisfy({ $0.chat?.id == first.id }) else { return nil }
        return first
    }
    static func uniqueProcesses(_ processes: [WatchedProcess]) -> [WatchedProcess] {
        var unique: [WatchedProcessID: WatchedProcess] = [:]
        for process in processes {
            if let existing = unique[process.id] {
                if existing.chat?.id != process.chat?.id || existing.footprint != process.footprint || existing.role != process.role {
                    var uncertain = process; uncertain.chat = nil; uncertain.footprint = nil; uncertain.role = .other; unique[process.id] = uncertain
                }
            } else { unique[process.id] = process }
        }
        return Array(unique.values)
    }
    static func summarize(_ processes: [WatchedProcess]) -> CodexChatUsage {
        var totals: [String: CodexChatTotal] = [:]
        var unlinked = CodexChatTotal(chat: nil)
        for process in uniqueProcesses(processes) {
            if let chat = process.chat { totals[chat.id, default: CodexChatTotal(chat: chat)].add(process) } else { unlinked.add(process) }
        }
        return CodexChatUsage(linked: totals.values.sorted { $0.bytes == $1.bytes ? ($0.chat?.id ?? "") < ($1.chat?.id ?? "") : $0.bytes > $1.bytes }, unlinked: unlinked)
    }
}

struct ProcessRoleUsage {
    let role: ProcessRole
    let total: CodexChatTotal
    static func summarize(_ processes: [WatchedProcess]) -> [ProcessRoleUsage] {
        var totals: [ProcessRole: CodexChatTotal] = [:]
        for process in CodexChatUsage.uniqueProcesses(processes) {
            totals[process.role, default: CodexChatTotal(chat: nil)].add(process)
        }
        return ProcessRole.allCases.compactMap { role in totals[role].map { ProcessRoleUsage(role: role, total: $0) } }
    }
}

struct CodexChatCoverage {
    let linkedProcesses: Int
    let processes: Int
    let missing: Int
    let linkedBytes: UInt64?
    let measuredBytes: UInt64?
    var memoryPercent: Double? {
        guard let linkedBytes, let measuredBytes, measuredBytes > 0 else { return nil }
        return 100 * Double(linkedBytes) / Double(measuredBytes)
    }
    init(_ usage: CodexChatUsage) {
        let all = usage.linked + [usage.unlinked]
        linkedProcesses = usage.linked.reduce(0) { $0 + $1.processes }
        processes = all.reduce(0) { $0 + $1.processes }
        missing = all.reduce(0) { $0 + $1.missing }
        func sum(_ values: [CodexChatTotal]) -> UInt64? {
            var result: UInt64 = 0
            for value in values {
                let next = result.addingReportingOverflow(value.bytes)
                guard !next.overflow else { return nil }
                result = next.partialValue
            }
            return result
        }
        linkedBytes = sum(usage.linked); measuredBytes = sum(all)
    }
}
