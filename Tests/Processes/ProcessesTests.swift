import Foundation
import Darwin

@main
struct ProcessesTests {
    static var passed = 0
    static func check(_ name: String, _ body: () -> Bool) {
        guard body() else { print("FAIL: \(name)"); exit(1) }
        passed += 1
        print("PASS: \(name)")
    }
    static func process(_ pid: Int32, parent: Int32 = 1, name: String = "node", start: UInt64 = 1, assistant: Bool = false, bytes: UInt64? = 1073741824) -> WatchedProcess {
        WatchedProcess(id: WatchedProcessID(pid: pid, startSeconds: start, startMicroseconds: 0), parentPID: parent, name: name, assistantAffinity: assistant, footprint: bytes)
    }
    static func group(_ bytes: UInt64?, start: UInt64 = 1) -> WatchedProcessGroup { ProcessGrouping.groups([process(100, start: start, bytes: bytes)])[0] }
    static func enabled(_ hold: Double = 10) -> ProcessesEngine {
        let engine = ProcessesEngine()
        var c = ProcessesConfiguration(); c.alerts = true; c.jobs.budgetGB = 1; c.jobs.growthGB = 0; c.sustainedSeconds = hold; c.cooldownSeconds = 30
        engine.configure(c)
        return engine
    }
    static let chatA = "1000000a-0000-0000-0000-000000000001"
    static let chatB = "1000000b-0000-0000-0000-000000000002"
    static func tagged(_ pid: Int32, chat: String?, bytes: UInt64? = 1073741824) -> WatchedProcess {
        var value = process(pid, parent: pid == 20 ? 1 : 20, bytes: bytes)
        value.chat = chat.map { CodexChatOwnership(id: $0, title: $0 == chatA ? "Synthetic workbook" : "Synthetic render") }
        return value
    }
    static func kernelFixture(_ environment: [String], arguments: [String] = ["node"], padding: Int = 2) -> [UInt8] {
        var count = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &count) { Array($0) }
        bytes += Array("/synthetic/node".utf8) + [0] + Array(repeating: 0, count: padding)
        for value in arguments + environment { bytes += Array(value.utf8) + [0] }
        return bytes + [0]
    }
    static func parse(_ bytes: [UInt8]) -> CodexThreadTag { bytes.withUnsafeBytes { CodexThreadTagParser.parse($0) } }
    static func main() {
        if CommandLine.arguments.contains("--synthetic-tag-child") { Thread.sleep(forTimeInterval: 10); return }
        let gb: UInt64 = 1073741824
        check("assistant includes bundled workers") {
            let groups = ProcessGrouping.groups([process(10, name: "ChatGPT", assistant: true), process(11, parent: 10, name: "node", assistant: true)])
            return groups.count == 1 && groups[0].kind == .assistant && groups[0].members.count == 2
        }
        check("external build tree separated from app without duplicate members") {
            let groups = ProcessGrouping.groups([process(10, name: "ChatGPT", assistant: true), process(20, parent: 10), process(21, parent: 20, name: "clang")])
            return groups.count == 2 && Set(groups.flatMap { $0.members.map { $0.id } }).count == 3 && groups.first { $0.kind == .job }?.root.id.pid == 20
        }
        check("build descendants count under highest build ancestor") {
            let g = ProcessGrouping.groups([process(20), process(21, parent: 20, name: "python3.12"), process(22, parent: 21, name: "helper")])
            return g.count == 1 && g[0].members.count == 3
        }
        check("unrelated desktop processes excluded") { ProcessGrouping.groups([process(5, name: "Mail")]).isEmpty }
        check("parent cycle bounded") { ProcessGrouping.groups([process(10, parent: 11), process(11, parent: 10)]).count <= 2 }
        check("missing member makes group partial") {
            let groups = ProcessGrouping.groups([process(20), process(21, parent: 20, bytes: nil)])
            let e = enabled(); let result = e.update(groups, complete: true, time: 0)
            return result.rows[0].current == nil && result.rows[0].status == "Partial" && result.alerts.isEmpty
        }
        check("zero memory remains a known value") {
            let r = ProcessesEngine().update([group(0)], complete: true, time: 0)
            return r.rows[0].current == 0 && r.rows[0].status == "Live"
        }
        check("overflow is unavailable instead of wrapped memory") {
            let g = ProcessGrouping.groups([process(20, bytes: UInt64.max), process(21, parent: 20, bytes: 1)])
            return g[0].footprint == nil
        }
        check("budget alert waits for sustained duration") {
            let e = enabled()
            let a = e.update([group(2*gb)], complete: true, time: 0)
            let b = e.update([group(2*gb)], complete: true, time: 5)
            let c = e.update([group(2*gb)], complete: true, time: 10)
            return a.alerts.isEmpty && b.alerts.isEmpty && c.alerts.count == 1
        }
        check("no repeated alert during same incident") {
            let e = enabled(); var total = 0
            for t in stride(from: 0.0, through: 100, by: 5) { total += e.update([group(2*gb)], complete: true, time: t).alerts.count }
            return total == 1
        }
        check("hysteresis avoids threshold flapping") {
            let e = enabled(); _ = e.update([group(2*gb)], complete: true, time: 0); _ = e.update([group(2*gb)], complete: true, time: 5); _ = e.update([group(2*gb)], complete: true, time: 10)
            _ = e.update([group(UInt64(Double(gb)*0.95))], complete: true, time: 15)
            var count = 0
            for t in stride(from: 20.0, through: 50, by: 5) { count += e.update([group(2*gb)], complete: true, time: t).alerts.count }
            return count == 0
        }
        check("recovery rearms after cooldown") {
            let e = enabled(); _ = e.update([group(2*gb)], complete: true, time: 0); _ = e.update([group(2*gb)], complete: true, time: 5); _ = e.update([group(2*gb)], complete: true, time: 10)
            _ = e.update([group(gb/2)], complete: true, time: 15)
            var count = 0
            for t in stride(from: 20.0, through: 50, by: 5) { count += e.update([group(2*gb)], complete: true, time: t).alerts.count }
            return count == 1
        }
        check("missing read resets duration") {
            let e = enabled(); _ = e.update([group(2*gb)], complete: true, time: 0); _ = e.update([group(nil)], complete: true, time: 5)
            _ = e.update([group(2*gb)], complete: true, time: 10)
            return e.update([group(2*gb)], complete: true, time: 15).alerts.isEmpty && e.update([group(2*gb)], complete: true, time: 20).alerts.count == 1
        }
        check("incomplete scan cannot emit or record zero") {
            let e = enabled(); let r = e.update([group(2*gb)], complete: false, time: 0)
            return r.alerts.isEmpty && r.rows[0].status == "Unavailable" && r.history.last?.bytes == nil
        }
        check("metadata denial stays unavailable rather than exited") {
            let e = enabled(); _ = e.update([group(gb)], complete: true, time: 0)
            let r = e.update([], complete: true, time: 5, unknownPIDs: [100])
            return r.rows[0].status == "Unavailable" && r.rows[0].current == nil && r.alerts.isEmpty
        }
        check("PID reuse starts a separate series") {
            let e = enabled(); _ = e.update([group(2*gb)], complete: true, time: 0); _ = e.update([group(2*gb)], complete: true, time: 5)
            let r = e.update([group(gb/2, start: 2)], complete: true, time: 10)
            return r.alerts.isEmpty && r.rows.count == 2 && r.rows.contains { $0.status == "Exited" }
        }
        check("exited group retains history and no current value") {
            let e = enabled(); _ = e.update([group(gb)], complete: true, time: 0)
            let r = e.update([], complete: true, time: 5)
            return r.rows[0].status == "Exited" && r.rows[0].current == nil && r.history.first?.bytes == gb
        }
        check("pause resets streak and marks graph gap") {
            let e = enabled(); _ = e.update([group(2*gb)], complete: true, time: 0); _ = e.pause(time: 5)
            let r = e.update([group(2*gb)], complete: true, time: 10)
            return r.alerts.isEmpty && r.history.contains { $0.bytes == nil }
        }
        check("long sampling gap does not imply sustained breach") {
            let e = enabled(); _ = e.update([group(2*gb)], complete: true, time: 0)
            return e.update([group(2*gb)], complete: true, time: 60).alerts.isEmpty
        }
        check("growth requires complete five minute baseline") {
            let e = ProcessesEngine()
            for t in stride(from: 0.0, through: 295, by: 5) { _ = e.update([group(gb)], complete: true, time: t) }
            return e.snapshot().rows[0].growth == nil && e.update([group(2*gb)], complete: true, time: 300).rows[0].growth == Double(gb)
        }
        check("growth across a missing sample is unknown") {
            let e = ProcessesEngine()
            for t in stride(from: 0.0, through: 300, by: 5) { _ = e.update([group(t == 150 ? nil : gb)], complete: true, time: t) }
            return e.snapshot().rows[0].growth == nil
        }
        check("growth alert independent of budget") {
            let e = enabled(5); var c = e.configuration; c.jobs.budgetGB = 8; c.jobs.growthGB = 0.5; e.configure(c)
            for t in stride(from: 0.0, through: 300, by: 5) { _ = e.update([group(t < 300 ? gb : 2*gb)], complete: true, time: t) }
            return e.update([group(2*gb)], complete: true, time: 305).alerts.first?.reason.contains("grew") == true
        }
        check("child alerts need an explicit override") {
            let e = enabled(5)
            _ = e.update([group(2*gb)], complete: true, time: 0)
            return e.update([group(2*gb)], complete: true, time: 5).alerts.count == 1
        }
        check("selected process override is evaluated") {
            let e = enabled(5); var c = e.configuration; c.jobs.budgetGB = 8
            c.overrides["process:100:1:0"] = MemoryAlertRule(budgetGB: 0.5, growthGB: 0); e.configure(c)
            _ = e.update([group(gb)], complete: true, time: 0)
            let r = e.update([group(gb)], complete: true, time: 5)
            return r.alerts.count == 1 && r.alerts[0].key.hasPrefix("process:")
        }
        check("alerts off is respected") {
            let e = enabled(); var c = e.configuration; c.alerts = false; e.configure(c)
            for t in stride(from: 0.0, through: 30, by: 5) where !e.update([group(2*gb)], complete: true, time: t).alerts.isEmpty { return false }
            return true
        }
        check("history capped by time and sample count") {
            let e = ProcessesEngine()
            for t in stride(from: 0.0, through: 4500, by: 5) { _ = e.update([group(gb)], complete: true, time: t) }
            let h = e.snapshot().history
            return h.count <= 721 && h.first!.time >= 900
        }
        check("expired exit rows removed") {
            let e = ProcessesEngine(); _ = e.update([group(gb)], complete: true, time: 0)
            return e.update([], complete: true, time: 3601).rows.isEmpty
        }
        check("group limit explicitly flagged") {
            let g = ProcessGrouping.groups((1...25).map { process(Int32(100 + $0), start: UInt64($0)) })
            let r = ProcessesEngine().update(g, complete: true, time: 0)
            return r.rows.count == 20 && r.limited
        }
        check("configuration bounds and encoding round trip") {
            var c = ProcessesConfiguration(); c.jobs.budgetGB = -1; c.sustainedSeconds = 0; c.cooldownSeconds = .infinity
            c.overrides = Dictionary(uniqueKeysWithValues: (0..<30).map { ("synthetic\($0)", MemoryAlertRule(budgetGB: 1, growthGB: 0)) })
            let v = c.validated()
            do {
                let data = try JSONEncoder().encode(v)
                let decoded = try JSONDecoder().decode(ProcessesConfiguration.self, from: data)
                return decoded == v && v.jobs.budgetGB == 0.05 && v.sustainedSeconds == 5 && v.cooldownSeconds == 300 && v.overrides.count == 20
            } catch { return false }
        }
        check("legacy configuration preserves alerts and defaults chat linking off") {
            var old = ProcessesConfiguration(); old.alerts = true
            do {
                let encoded = try JSONEncoder().encode(old)
                var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
                object.removeValue(forKey: "linkChats")
                let value = try JSONDecoder().decode(ProcessesConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
                return value.alerts && !value.linkChats && value.assistant == old.assistant && value.jobs == old.jobs
            } catch { return false }
        }
        check("kernel tag parser extracts only exact thread UUID key") {
            parse(kernelFixture(["CODEX_THREAD_ID=\(chatA)", "OTHER_SYNTHETIC_VALUE=\(chatB)"])) == .linked(chatA)
        }
        check("matching session and thread keys canonicalize safely") {
            parse(kernelFixture(["CODEX_THREAD_ID=\(chatA.uppercased())", "CODEX_SESSION_ID=\(chatA)"])) == .linked(chatA)
        }
        check("session ID fallback is recognized") { parse(kernelFixture(["CODEX_SESSION_ID=\(chatB)"])) == .linked(chatB) }
        check("argv UUID and unrelated environment never assign ownership") {
            parse(kernelFixture(["SYNTHETIC_SECRET=CODEX_THREAD_ID=\(chatA)", "XCODEX_THREAD_ID=\(chatA)"], arguments: ["node", "CODEX_THREAD_ID=\(chatB)"])) == .absent
        }
        check("conflicting thread and session IDs stay unlinked") {
            parse(kernelFixture(["CODEX_THREAD_ID=\(chatA)", "CODEX_SESSION_ID=\(chatB)"])) == .conflict
        }
        check("duplicate conflicting thread keys stay unlinked") {
            parse(kernelFixture(["CODEX_THREAD_ID=\(chatA)", "CODEX_THREAD_ID=\(chatB)"])) == .conflict
        }
        check("invalid UUID key fails closed") { parse(kernelFixture(["CODEX_THREAD_ID=not-a-uuid"])) == .invalid }
        check("truncated environment and impossible argc fail closed") {
            var truncated = kernelFixture(["CODEX_THREAD_ID=\(chatA)"]); truncated.removeLast(2)
            return parse(truncated) == .invalid && parse([255, 255, 255, 127, 0]) == .invalid && parse([1, 0]) == .invalid
        }
        check("oversized argument buffer is rejected") { parse(Array(repeating: 0, count: CodexThreadTagParser.maxBytes + 1)) == .invalid }
        check("parser respects variable executable padding and multiple arguments") {
            parse(kernelFixture(["CODEX_THREAD_ID=\(chatA)"], arguments: ["node", "--synthetic", ""], padding: 9)) == .linked(chatA)
        }
        check("bounded malformed-buffer fuzz never invents a chat tag") {
            var seed: UInt64 = 42
            for length in 0..<512 {
                var bytes: [UInt8] = []
                for _ in 0..<length { seed = seed &* 6364136223846793005 &+ 1; bytes.append(UInt8(truncatingIfNeeded: seed >> 32)) }
                if case .linked = parse(bytes) { return false }
            }
            return true
        }
        check("group label requires every member to have the same chat") {
            CodexChatUsage.commonOwner([tagged(20, chat: chatA), tagged(21, chat: chatA)])?.id == chatA
                && CodexChatUsage.commonOwner([tagged(20, chat: chatA), tagged(21, chat: nil)]) == nil
                && CodexChatUsage.commonOwner([tagged(20, chat: chatA), tagged(21, chat: chatB)]) == nil
        }
        check("chat totals count unique processes and keep unlinked memory separate") {
            let p = tagged(20, chat: chatA, bytes: gb)
            let total = CodexChatUsage.summarize([p, p, tagged(21, chat: chatA, bytes: gb), tagged(22, chat: nil, bytes: gb)])
            return total.linked.count == 1 && total.linked[0].bytes == 2 * gb && total.linked[0].processes == 2 && total.unlinked.bytes == gb
        }
        check("conflicting duplicate ownership never blames either chat") {
            let total = CodexChatUsage.summarize([tagged(20, chat: chatA), tagged(20, chat: chatB)])
            return total.linked.isEmpty && total.unlinked.processes == 1 && total.unlinked.missing == 1
        }
        check("missing task footprint stays explicitly incomplete") {
            let total = CodexChatUsage.summarize([tagged(20, chat: chatA, bytes: nil), tagged(21, chat: chatA, bytes: gb)])
            return total.linked[0].bytes == gb && total.linked[0].missing == 1 && total.linked[0].processes == 2
        }
        check("chat footprint overflow never wraps into a false low reading") {
            let total = CodexChatUsage.summarize([tagged(20, chat: chatA, bytes: UInt64.max), tagged(21, chat: chatA, bytes: 1)])
            return total.linked[0].missing == 1
        }
        check("link toggle clears retained exited chat labels") {
            let e = ProcessesEngine(); var c = ProcessesConfiguration(); c.linkChats = true; e.configure(c)
            let first = e.update(ProcessGrouping.groups([tagged(20, chat: chatA)]), complete: true, time: 0)
            let exited = e.update([], complete: true, time: 5)
            c.linkChats = false; e.configure(c)
            return first.rows[0].chat?.id == chatA && exited.rows[0].chat?.id == chatA && e.snapshot().rows[0].chat == nil
        }
        check("changed current tag does not retain previous chat ownership") {
            let e = ProcessesEngine(); var c = ProcessesConfiguration(); c.linkChats = true; e.configure(c)
            _ = e.update(ProcessGrouping.groups([tagged(20, chat: chatA)]), complete: true, time: 0)
            let next = e.update(ProcessGrouping.groups([tagged(20, chat: chatB)]), complete: true, time: 5)
            return next.rows[0].chat?.id == chatB && next.rows[0].children[0].chat?.id == chatB
        }
        check("notifications never include chat names or IDs") {
            let e = enabled(5); var c = e.configuration; c.linkChats = true; e.configure(c)
            let groups = ProcessGrouping.groups([tagged(20, chat: chatA, bytes: 2 * gb)])
            _ = e.update(groups, complete: true, time: 0)
            let events = e.update(groups, complete: true, time: 5).alerts
            return events.count == 1 && !events[0].name.contains("Synthetic workbook") && !events[0].name.contains(chatA)
        }
        check("same folder or app ancestry never invents chat ownership") {
            let e = ProcessesEngine(); var c = ProcessesConfiguration(); c.linkChats = true; e.configure(c)
            let result = e.update(ProcessGrouping.groups([process(10, name: "Codex", assistant: true), process(11, parent: 10, name: "worker")]), complete: true, time: 0)
            return result.rows.allSatisfy { $0.chat == nil && $0.children.allSatisfy { $0.chat == nil } }
        }
        check("title controls and bidi overrides are removed with a bounded label") {
            let text = CodexChatOwnership.cleanTitle("  Synthetic\nWorkbook\u{202E}" + String(repeating: "x", count: 200))
            return text?.count == 120 && !(text?.contains("\n") ?? true) && !(text?.contains("\u{202E}") ?? true)
        }
        HelperOwnershipTests.run()
        ProcessInspectionTests.run()
        ChatMetadataTests.run()
        print("Executed \(passed) process monitoring tests, 0 failures")
    }
}
