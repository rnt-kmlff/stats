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
    static func main() {
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
        print("Executed \(passed) process monitoring tests, 0 failures")
    }
}
