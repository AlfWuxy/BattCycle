import Foundation

/// 追加结果：暂停时显式跳过，避免调用方把暂停当成写入成功。
public enum HistoryStoreAppendResult {
    /// 已追加到 JSONL 并更新元数据。
    case written
    /// 记录暂停：未落盘，也不消费睡眠间隙。
    case skippedPaused
    /// 写入或元数据更新失败。
    case failed(any Error)
}

/// 追加写入本地 JSONL 历史。本类型只负责存储，不含采样器。
/// 可变状态（设置、日历、元数据）由同一把锁串行保护，不使用 `@unchecked Sendable` 掩盖竞态。
public final class HistoryStore {
    public let directory: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private var _settings: MonitorSettings
    private var _calendar: Calendar
    /// 内存中的增量元数据；缺失时从磁盘重建。
    private var cachedMeta: HistoryMeta?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()
    private let metaEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let metaDecoder = JSONDecoder()

    public var settings: MonitorSettings {
        get { withLock { _settings } }
        set { withLock { _settings = newValue } }
    }

    public var calendar: Calendar {
        get { withLock { _calendar } }
        set { withLock { _calendar = newValue } }
    }

    public init(
        directory: URL = SupportPaths.historyDirectory,
        settings: MonitorSettings = .default,
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self._settings = settings
        self._calendar = calendar
        self.fileManager = fileManager
    }

    /// 暂停时返回 `.skippedPaused` 且不写盘；失败返回 `.failed`，不再把暂停伪装成成功。
    @discardableResult
    public func append(_ sample: HistorySample) -> HistoryStoreAppendResult {
        withLock {
            do {
                return try appendLocked(sample)
            } catch {
                return .failed(error)
            }
        }
    }

    /// 心跳路径使用：失败不抛向调用方，避免阻塞采样循环。
    @discardableResult
    public func bestEffortAppend(_ sample: HistorySample) -> HistoryStoreAppendResult {
        append(sample)
    }

    public func sampleCount() throws -> Int {
        try withLock {
            try loadOrRebuildMetaLocked()
            return cachedMeta?.sampleCount ?? 0
        }
    }

    public func estimatedBytes() throws -> Int {
        try withLock {
            try loadOrRebuildMetaLocked()
            return cachedMeta?.estimatedBytes ?? 0
        }
    }

    public func samples(from start: Date, to end: Date) throws -> [HistorySample] {
        try withLock {
            let startEpoch = min(start, end).timeIntervalSince1970
            let endEpoch = max(start, end).timeIntervalSince1970
            var collected: [HistorySample] = []
            var day = _calendar.startOfDay(for: min(start, end))
            let lastDay = _calendar.startOfDay(for: max(start, end))
            while day <= lastDay {
                let url = directory.appendingPathComponent(fileName(for: day))
                if fileManager.fileExists(atPath: url.path) {
                    collected.append(contentsOf: try decodeLines(at: url).filter { sample in
                        sample.epoch >= startEpoch && sample.epoch <= endEpoch
                    })
                }
                guard let next = _calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            collected.sort { $0.epoch < $1.epoch }
            return collected
        }
    }

    /// 只删除 history 目录内的 `*.jsonl` 并重置 meta，不触碰 config.json、日志、venv 或锁文件。
    public func clearHistory() throws {
        try withLock {
            for url in try jsonlURLsLocked() {
                try fileManager.removeItem(at: url)
            }
            cachedMeta = .empty
            if fileManager.fileExists(atPath: directory.path) {
                try persistMetaLocked()
            }
        }
    }

    public func prune(now: Date = Date()) throws {
        try withLock {
            let start = _calendar.startOfDay(for: now)
            guard let cutoff = _calendar.date(byAdding: .day, value: -_settings.retentionDays, to: start) else {
                return
            }
            var removed = false
            for url in try jsonlURLsLocked() {
                guard let fileDate = date(fromFileName: url.lastPathComponent) else { continue }
                if fileDate < cutoff {
                    try fileManager.removeItem(at: url)
                    removed = true
                }
            }
            if removed {
                cachedMeta = try rebuildMetaLocked()
                try persistMetaLocked()
            } else {
                try loadOrRebuildMetaLocked()
            }
        }
    }

    private func appendLocked(_ sample: HistorySample) throws -> HistoryStoreAppendResult {
        // 暂停仅为落盘开关，不写盘、不改 meta、不消费睡眠间隙。
        if _settings.recordingPaused { return .skippedPaused }
        try ensureDirectoryLocked()
        // 先读侧车再写 JSONL，避免把刚写入的行算进 rebuild 后再 +1。
        try loadOrRebuildMetaLocked(persistIfRebuilt: false)
        let url = directory.appendingPathComponent(fileName(for: sample.date))
        var data = try encoder.encode(sample)
        data.append(0x0A)
        if !fileManager.fileExists(atPath: url.path) {
            let created = fileManager.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
            if !created {
                throw HistoryStoreError.cannotCreateFile(url.path)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        applyAppendToMetaLocked(fileName: url.lastPathComponent, byteCount: data.count)
        do {
            try persistMetaLocked()
        } catch {
            // 侧车失败时丢掉内存计数，下次按 JSONL 重建，避免脏增量继续累加。
            cachedMeta = nil
            throw error
        }
        return .written
    }

    private func applyAppendToMetaLocked(fileName: String, byteCount: Int) {
        var meta = cachedMeta ?? .empty
        meta.sampleCount += 1
        meta.estimatedBytes += byteCount
        meta.lineCounts[fileName, default: 0] += 1
        cachedMeta = meta
    }

    private func loadOrRebuildMetaLocked(persistIfRebuilt: Bool = true) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            cachedMeta = .empty
            return
        }
        let url = metaURL
        let sidecarExists = fileManager.fileExists(atPath: url.path)
        // 内存增量优先；仅当侧车缺失时才扫 JSONL 重建，避免每次 append 重读磁盘。
        if cachedMeta != nil, sidecarExists {
            return
        }
        if sidecarExists,
           let data = try? Data(contentsOf: url),
           let decoded = try? metaDecoder.decode(HistoryMeta.self, from: data) {
            cachedMeta = decoded
            return
        }
        cachedMeta = try rebuildMetaLocked()
        if persistIfRebuilt {
            try persistMetaLocked()
        }
    }

    private func rebuildMetaLocked() throws -> HistoryMeta {
        var lineCounts: [String: Int] = [:]
        var sampleCount = 0
        var estimatedBytes = 0
        for url in try jsonlURLsLocked() {
            let lines = try lineCount(at: url)
            lineCounts[url.lastPathComponent] = lines
            sampleCount += lines
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            estimatedBytes += values.fileSize ?? 0
        }
        return HistoryMeta(sampleCount: sampleCount, estimatedBytes: estimatedBytes, lineCounts: lineCounts)
    }

    private func persistMetaLocked() throws {
        // 不在计数路径创建 history 目录：暂停且从未写入时目录应保持不存在。
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let data = try metaEncoder.encode(cachedMeta ?? .empty)
        let url = metaURL
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private var metaURL: URL {
        directory.appendingPathComponent("meta.json")
    }

    private func lineCount(at url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        var count = 0
        text.enumerateLines { line, _ in
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                count += 1
            }
        }
        return count
    }

    private func ensureDirectoryLocked() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw HistoryStoreError.symbolicLink(directory.path)
            }
            guard isDirectory.boolValue else {
                throw HistoryStoreError.notDirectory(directory.path)
            }
        }
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func jsonlURLsLocked() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("samples-")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func decodeLines(at url: URL) throws -> [HistorySample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var samples: [HistorySample] = []
        samples.reserveCapacity(256)
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
            if let sample = try? self.decoder.decode(HistorySample.self, from: data) {
                samples.append(sample)
            }
        }
        return samples
    }

    private func fileName(for date: Date) -> String {
        let parts = _calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "samples-%04d-%02d-%02d.jsonl", year, month, day)
    }

    private func date(fromFileName name: String) -> Date? {
        guard name.hasPrefix("samples-"), name.hasSuffix(".jsonl") else { return nil }
        let stamp = name.dropFirst("samples-".count).dropLast(".jsonl".count)
        let parts = stamp.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return _calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// 历史目录侧车：样本数、字节估算、各 JSONL 行数。`sampleCount` / `estimatedBytes` 读它而不是每次扫全量。
private struct HistoryMeta: Codable, Equatable {
    var sampleCount: Int
    var estimatedBytes: Int
    var lineCounts: [String: Int]

    static let empty = HistoryMeta(sampleCount: 0, estimatedBytes: 0, lineCounts: [:])
}

public enum HistoryStoreError: LocalizedError {
    case symbolicLink(String)
    case notDirectory(String)
    case cannotCreateFile(String)

    public var errorDescription: String? {
        switch self {
        case .symbolicLink(let path):
            return "历史目录不能是符号链接：\(path)"
        case .notDirectory(let path):
            return "历史路径不是目录：\(path)"
        case .cannotCreateFile(let path):
            return "无法创建历史文件：\(path)"
        }
    }
}
