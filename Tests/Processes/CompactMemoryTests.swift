import Foundation

struct CompactMemoryTests {
    static func run() {
        let check = ProcessesTests.check
        let a = ProcessesTests.process(901, name: "ChatGPT", assistant: true, bytes: 100)
        let b = ProcessesTests.process(902, parent: 901, name: "Codex (Renderer)", assistant: true, bytes: 200)
        let c = ProcessesTests.process(903, name: "codex", assistant: true, bytes: 300)
        let job = ProcessesTests.process(904, name: "node", bytes: 400)
        func total(_ processes: [WatchedProcess], complete: Bool = true, limited: Bool = false, unknown: Bool = false) -> AssistantMemoryTotal {
            AssistantMemoryTotal.summarize(ProcessGrouping.groups(processes), complete: complete, limited: limited, unknown: unknown)
        }
        check("menu total combines assistant roots and renderers while excluding local jobs") {
            let t = total([a, b, c, job]); return t.bytes == 600 && !t.partial
        }
        check("menu total never counts a duplicate process identity twice") {
            let group = ProcessGrouping.groups([a, b])[0]
            let t = AssistantMemoryTotal.summarize([group, group], complete: true, limited: false, unknown: false)
            return t.bytes == 300 && !t.partial
        }
        check("conflicting duplicate footprints become unknown rather than inflated") {
            var conflict = b; conflict.footprint = 999
            let first = WatchedProcessGroup(key: "a", root: a, kind: .assistant, members: [a, b])
            let second = WatchedProcessGroup(key: "b", root: b, kind: .assistant, members: [conflict])
            let t = AssistantMemoryTotal.summarize([first, second], complete: true, limited: false, unknown: false)
            return t.bytes == 100 && t.partial
        }
        check("missing member memory marks the observed menu total partial") {
            var missing = b; missing.footprint = nil
            let t = total([a, missing]); return t.bytes == 100 && t.partial
        }
        check("all missing memory cannot display a false zero") {
            var missing = a; missing.footprint = nil
            return total([missing]).bytes == nil
        }
        check("complete empty assistant sample is zero even with local jobs") {
            let t = total([job]); return t.bytes == 0 && !t.partial
        }
        check("failed process enumeration hides the menu number") { total([a], complete: false).bytes == nil }
        check("truncated and unknown process metadata remain explicitly partial") {
            total([a], limited: true).partial && total([a], unknown: true).partial && total([], unknown: true).bytes == nil
        }
        check("menu sum overflow cannot wrap to a low value") {
            var huge = a; huge.footprint = UInt64.max
            return total([huge, b]).bytes == nil
        }
        check("menu starts unavailable before the first sample") {
            AssistantMemoryStore().current(time: 0).text { String($0) } == "—"
        }
        check("fresh cache displays memory and preserves the partial marker") {
            let store = AssistantMemoryStore(); store.publish(bytes: 123, status: .live, time: 100)
            let live = store.current(time: 105).text { String($0) }
            store.publish(bytes: 456, status: .partial, time: 105)
            return live == "123" && store.current(time: 106).text { String($0) } == "~456"
        }
        check("old samples become unavailable after three sampler intervals") {
            let store = AssistantMemoryStore(); store.publish(bytes: 123, status: .live, time: 100)
            return store.current(time: 115).bytes == 123 && store.current(time: 115.1).text { String($0) } == "—"
        }
        check("invalid or backwards sample clocks cannot look current") {
            let store = AssistantMemoryStore(); store.publish(bytes: 123, status: .live, time: 100)
            let backwards = store.current(time: 99).status == .stale
            let invalid = store.current(time: .infinity).status == .stale
            store.publish(bytes: 123, status: .live, time: .nan)
            return backwards && invalid && store.current(time: 101).status == .stale
        }
        check("pause off sleep and unavailable states discard the displayed number") {
            let store = AssistantMemoryStore()
            return [AssistantMemoryReading.Status.paused, .off, .sleeping, .unavailable].allSatisfy {
                store.publish(bytes: 123, status: $0, time: 100)
                return store.current(time: 101).bytes == nil && store.current(time: 101).text { String($0) } == "—"
            }
        }
        check("resuming replaces the paused value with a fresh reading") {
            let store = AssistantMemoryStore(); store.publish(bytes: nil, status: .paused, time: 100)
            store.publish(bytes: 321, status: .live, time: 105)
            return store.current(time: 106).text { String($0) } == "321"
        }
        check("only the exact app-memory token is replaced, including repeated tokens") {
            let text = "GPT $chatgpt.used · $chatgpt.used/$swap.used · $chatgpt.used_extra"
            return AssistantMemoryTemplate.render(text, value: "~1 GB") == "GPT ~1 GB · ~1 GB/$swap.used · $chatgpt.used_extra"
                && AssistantMemoryTemplate.contains(text) && !AssistantMemoryTemplate.contains("$chatgpt.used_extra")
        }
        check("readable status without bytes becomes unavailable") {
            let store = AssistantMemoryStore(); store.publish(bytes: nil, status: .live, time: 100)
            return store.current(time: 101).status == .unavailable
        }
    }
}
