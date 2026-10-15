import Foundation

struct ProcessInspectionTests {
    static func run() {
        func check(_ name: String, _ body: () -> Bool) { ProcessesTests.check(name, body) }
        func process(_ pid: Int32, bytes: UInt64? = 100, chat: String? = nil, role: ProcessRole = .renderer) -> WatchedProcess {
            var p = ProcessesTests.tagged(pid, chat: chat, bytes: bytes); p.role = role; return p
        }
        check("app executable and CLI keep distinct roles without reading arguments") {
            ProcessRole.identify(name: "Codex", path: "/Applications/Codex.app/Contents/MacOS/Codex", assistant: true) == .application
                && ProcessRole.identify(name: "codex", path: "/synthetic/bin/codex", assistant: true) == .server
        }
        check("renderer role requires assistant context; bundled Node remains helper") {
            ProcessRole.identify(name: "Codex (Renderer)", path: "", assistant: true) == .renderer
                && ProcessRole.identify(name: "Codex (Renderer)", path: "", assistant: false) == .other
                && ProcessRole.identify(name: "node", path: "", assistant: true) == .helper
                && ProcessRole.identify(name: "python3.12", path: "", assistant: false) == .job
        }
        check("process age predates monitor and includes microseconds") {
            let id = WatchedProcessID(pid: 9, startSeconds: 100, startMicroseconds: 500_000)
            return ProcessAge.seconds(id, wallTime: 1000) == 899.5
        }
        check("invalid starts and clock rollback leave age unavailable") {
            ProcessAge.seconds(WatchedProcessID(pid: 9, startSeconds: 0, startMicroseconds: 0), wallTime: 1000) == nil
                && ProcessAge.seconds(WatchedProcessID(pid: 9, startSeconds: 100, startMicroseconds: 1_000_000), wallTime: 1000) == nil
                && ProcessAge.seconds(WatchedProcessID(pid: 9, startSeconds: 100, startMicroseconds: 0), wallTime: 99) == nil
                && ProcessAge.seconds(WatchedProcessID(pid: 9, startSeconds: 100, startMicroseconds: 0), wallTime: .nan) == nil
        }
        check("age formatting handles seconds minutes hours days and missing values") {
            ProcessAge.label(59) == "59s" && ProcessAge.label(60) == "1m" && ProcessAge.label(3660) == "1h 1m"
                && ProcessAge.label(90000) == "1d 1h" && ProcessAge.label(nil) == "—" && ProcessAge.label(.infinity) == "—"
        }
        check("root and member ages use their own OS starts and exited ages freeze") {
            let e = ProcessesEngine()
            var root = ProcessesTests.process(20, start: 100); root.role = .job
            var child = ProcessesTests.process(21, parent: 20, name: "worker", start: 150); child.role = .helper
            let live = e.update(ProcessGrouping.groups([root, child]), complete: true, time: 0, wallTime: 200)
            let exited = e.update([], complete: true, time: 5, wallTime: 205)
            return live.rows[0].age == 100 && live.rows[0].role == .group
                && live.rows[0].children.first { $0.pid == 21 }?.age == 50
                && exited.rows[0].age == 100 && exited.rows[0].status == "Exited"
        }
        check("PID reuse cannot inherit the previous process age") {
            let e = ProcessesEngine()
            _ = e.update(ProcessGrouping.groups([ProcessesTests.process(20, start: 100)]), complete: true, time: 0, wallTime: 200)
            let next = e.update(ProcessGrouping.groups([ProcessesTests.process(20, start: 204)]), complete: true, time: 5, wallTime: 205)
            return next.rows.contains { $0.status == "Live" && $0.age == 1 }
                && next.rows.contains { $0.status == "Exited" && $0.age == 100 }
        }
        check("memory coverage weights bytes separately from process coverage and deduplicates") {
            let tagged = process(20, bytes: 100, chat: ProcessesTests.chatA)
            let coverage = CodexChatCoverage(CodexChatUsage.summarize([tagged, tagged, process(21, bytes: 300)]))
            return coverage.memoryPercent == 25 && coverage.linkedProcesses == 1 && coverage.processes == 2 && coverage.missing == 0
        }
        check("missing footprints leave coverage partial and preserve unknown process counts") {
            let coverage = CodexChatCoverage(CodexChatUsage.summarize([process(20, chat: ProcessesTests.chatA), process(21, bytes: nil)]))
            return coverage.memoryPercent == 100 && coverage.missing == 1 && coverage.processes == 2 && coverage.linkedProcesses == 1
        }
        check("empty and zero-byte coverage never claim full visibility") {
            CodexChatCoverage(CodexChatUsage.summarize([])).memoryPercent == nil
                && CodexChatCoverage(CodexChatUsage.summarize([process(20, bytes: 0, chat: ProcessesTests.chatA)])).memoryPercent == nil
                && CodexChatCoverage(CodexChatUsage.summarize([process(20, bytes: nil)])).memoryPercent == nil
        }
        check("unlinked measured processes have zero rather than unknown coverage") {
            let c = CodexChatCoverage(CodexChatUsage.summarize([process(20)]))
            return c.memoryPercent == 0 && c.linkedProcesses == 0 && c.processes == 1
        }
        check("coverage sum overflow is unavailable rather than a false percentage") {
            let c = CodexChatCoverage(CodexChatUsage.summarize([process(20, bytes: UInt64.max, chat: ProcessesTests.chatA), process(21)]))
            return c.memoryPercent == nil && c.measuredBytes == nil
        }
        check("role summaries deduplicate and keep missing bytes explicit") {
            let p = process(20)
            let roles = ProcessRoleUsage.summarize([p, p, process(21, bytes: nil), process(22, bytes: 50, role: .helper)])
            return roles.count == 2 && roles[0].role == .renderer && roles[0].total.processes == 2
                && roles[0].total.bytes == 100 && roles[0].total.missing == 1 && roles[1].total.bytes == 50
        }
        check("conflicting duplicate identities stay unknown across repeated observations") {
            let a = process(20, chat: ProcessesTests.chatA)
            let b = process(20, chat: ProcessesTests.chatB)
            let c = CodexChatCoverage(CodexChatUsage.summarize([a, b, a]))
            return c.memoryPercent == nil && c.processes == 1 && c.missing == 1 && c.linkedProcesses == 0
        }
    }
}
