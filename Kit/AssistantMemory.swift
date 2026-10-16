import Foundation

// One aggregate from the existing serial Processes sampler. No identifiers or disk state.
public struct AssistantMemoryReading {
    public enum Status: String {
        case waiting = "Waiting for a process sample"
        case live = "Current observed process memory"
        case partial = "Observed subset; some processes or readings may be missing"
        case unavailable = "Process memory unavailable"
        case paused = "Process monitoring paused"
        case off = "Process monitoring off"
        case sleeping = "Mac sleeping"
        case stale = "Process sample is out of date"
    }
    public let bytes: UInt64?
    public let status: Status
    public let sampledAt: TimeInterval

    public func text(formatBytes: (UInt64) -> String) -> String {
        guard let bytes, status == .live || status == .partial else { return "—" }
        return (status == .partial ? "~" : "") + formatBytes(bytes)
    }
}

public final class AssistantMemoryStore {
    public static let shared = AssistantMemoryStore()
    public static let didChange = Notification.Name("Stats.AssistantMemoryChanged")
    public static let maxAge: TimeInterval = 15
    private let lock = NSLock()
    private var value = AssistantMemoryReading(bytes: nil, status: .waiting, sampledAt: 0)
    public init() {}

    public func publish(bytes: UInt64?, status: AssistantMemoryReading.Status,
                        time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let readable = status == .live || status == .partial
        lock.lock()
        value = AssistantMemoryReading(bytes: readable ? bytes : nil,
            status: readable && bytes == nil ? .unavailable : status, sampledAt: time)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    public func current(time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AssistantMemoryReading {
        lock.lock(); let sample = value; lock.unlock()
        guard sample.status == .live || sample.status == .partial else { return sample }
        guard time.isFinite, sample.sampledAt.isFinite, time >= sample.sampledAt, time - sample.sampledAt <= Self.maxAge else {
            return AssistantMemoryReading(bytes: nil, status: .stale, sampledAt: sample.sampledAt)
        }
        return sample
    }
}

public enum AssistantMemoryTemplate {
    private static let token = try? NSRegularExpression(pattern: #"\$chatgpt\.used(?![a-zA-Z0-9_])"#)
    public static func contains(_ text: String) -> Bool {
        token?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    public static func render(_ text: String, value: String) -> String {
        token?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: value)) ?? text
    }
}
