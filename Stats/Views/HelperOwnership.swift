import Foundation
import Darwin

struct HelperChatAssociation: Equatable {
    let chats: [CodexChatOwnership]
    let overflow: Bool
    var label: String { "Shared · " + chats.map { $0.label }.joined(separator: ", ") + (overflow ? " + others" : "") }
}

struct HelperOwnershipRecord: Codable {
    let version: Int
    let instanceId: String
    let sharing: String
    let pid: Int32
    let uid: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let chatIds: [String]
    let overflow: Bool
    let writtenAt: Double
    func validated(for id: WatchedProcessID, now: TimeInterval) -> Bool {
        let start = Double(id.startSeconds) + Double(id.startMicroseconds) / 1_000_000
        return version == 1 && sharing == "shared" && UUID(uuidString: instanceId) != nil
            && pid == id.pid && uid == getuid() && startSeconds == id.startSeconds && startMicroseconds == id.startMicroseconds
            && startSeconds > 0 && startMicroseconds < 1_000_000 && writtenAt.isFinite && writtenAt >= start && writtenAt <= now + 5
            && !chatIds.isEmpty && chatIds.count <= HelperOwnershipReader.maxChats && Set(chatIds).count == chatIds.count
            && chatIds.allSatisfy { $0.count == 36 && UUID(uuidString: $0)?.uuidString.lowercased() == $0 }
    }
}

struct HelperOwnershipScan {
    var records: [WatchedProcessID: HelperOwnershipRecord] = [:]
    var limited = false
    var unavailable = 0
    var directoryAvailable = false
}

final class HelperOwnershipReader {
    static let maxChats = 8
    static let maxEntries = 128
    static let maxReads = 32
    static let maxBytes = 8192
    static let maxCached = 128
    private let applicationSupport: URL
    private let lock = NSLock()
    private var cache: [WatchedProcessID: HelperOwnershipRecord] = [:]
    init(applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")) {
        self.applicationSupport = applicationSupport
    }
    func clear() { lock.lock(); defer { lock.unlock() }; cache.removeAll() }
    func scan(_ processes: [WatchedProcess], enabled: Bool, now: TimeInterval = Date().timeIntervalSince1970) -> HelperOwnershipScan {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { cache.removeAll(); return HelperOwnershipScan() }
        let eligible = processes.filter { $0.role != .application && $0.role != .renderer && $0.role != .group }
        let byName = Dictionary(eligible.map { (Self.filename($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        let live = Set(eligible.map { $0.id })
        cache = cache.filter { live.contains($0.key) || Self.identityState($0.key) != false }
        var result = HelperOwnershipScan(records: cache.filter { live.contains($0.key) })
        let root = open(applicationSupport.appendingPathComponent("Stats Helper Ownership").path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return result }
        defer { close(root) }
        guard Self.privateDirectory(root) else { result.unavailable += 1; return result }
        let directory = openat(root, "v1", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return result }
        defer { close(directory) }
        guard Self.privateDirectory(directory) else { result.unavailable += 1; return result }
        result.directoryAvailable = true
        let listingFD = dup(directory)
        guard listingFD >= 0 else { result.unavailable += 1; return result }
        guard let listing = fdopendir(listingFD) else { close(listingFD); result.unavailable += 1; return result }
        defer { closedir(listing) }
        var found: [WatchedProcess] = []
        var entries = 0
        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard entries < Self.maxEntries else { result.limited = true; break }
            entries += 1
            if let process = byName[name] { found.append(process) }
        }
        found.sort { $0.footprint == $1.footprint ? $0.id.pid < $1.id.pid : ($0.footprint ?? 0) > ($1.footprint ?? 0) }
        if found.count > Self.maxReads { result.limited = true }
        for process in found.prefix(Self.maxReads) {
            guard let record = Self.read(directory: directory, id: process.id, now: now) else { result.unavailable += 1; continue }
            if let old = cache[process.id] {
                let union = old.chatIds + Set(record.chatIds).subtracting(old.chatIds).sorted()
                cache[process.id] = HelperOwnershipRecord(version: 1, instanceId: record.instanceId, sharing: "shared", pid: record.pid,
                    uid: record.uid, startSeconds: record.startSeconds, startMicroseconds: record.startMicroseconds,
                    chatIds: Array(union.prefix(Self.maxChats)), overflow: old.overflow || record.overflow || union.count > Self.maxChats, writtenAt: record.writtenAt)
            } else if cache.count < Self.maxCached { cache[process.id] = record } else { result.limited = true }
        }
        // Historical associations remain shared for the observed lifetime even if an export
        // disappears. No heartbeat or idle expiry is needed; a reused PID has a different key.
        result.records = cache.filter { live.contains($0.key) }
        return result
    }
    static func filename(_ id: WatchedProcessID) -> String { "\(id.pid)-\(id.startSeconds)-\(id.startMicroseconds).json" }
    private static func privateDirectory(_ fd: Int32) -> Bool {
        var details = stat()
        return fstat(fd, &details) == 0 && details.st_uid == getuid() && details.st_mode & 0o7777 == 0o700 && details.st_mode & S_IFMT == S_IFDIR
    }
    private static func identityState(_ id: WatchedProcessID) -> Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(id.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return errno == ESRCH ? false : nil }
        return info.pbi_uid == getuid() && info.pbi_start_tvsec == id.startSeconds && info.pbi_start_tvusec == id.startMicroseconds
    }
    private static func read(directory: Int32, id: WatchedProcessID, now: TimeInterval) -> HelperOwnershipRecord? {
        guard identityState(id) == true else { return nil }
        let fd = openat(directory, filename(id), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_uid == getuid(), details.st_mode & S_IFMT == S_IFREG,
              details.st_mode & 0o7777 == 0o600, details.st_nlink == 1, details.st_size > 0, details.st_size <= maxBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(details.st_size) + 1)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        let expectedKeys: Set<String> = ["version", "instanceId", "sharing", "pid", "uid", "startSeconds", "startMicroseconds", "chatIds", "overflow", "writtenAt"]
        guard count == details.st_size,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(count))) as? [String: Any], Set(object.keys) == expectedKeys,
              let value = try? JSONDecoder().decode(HelperOwnershipRecord.self, from: Data(bytes.prefix(count))),
              value.validated(for: id, now: now), identityState(id) == true else { return nil }
        return value
    }
}
