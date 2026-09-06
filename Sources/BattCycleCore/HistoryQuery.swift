import Foundation

/// 图表查询窗口。
public enum HistoryRange: Equatable, Hashable, Sendable {
    case minutes15
    case hours1
    case hours6
    case hours24
    case days7
    case days30
    case custom(from: Date, to: Date)

    public func window(now: Date = Date()) -> (start: Date, end: Date) {
        switch self {
        case .minutes15:
            return (now.addingTimeInterval(-15 * 60), now)
        case .hours1:
            return (now.addingTimeInterval(-3_600), now)
        case .hours6:
            return (now.addingTimeInterval(-6 * 3_600), now)
        case .hours24:
            return (now.addingTimeInterval(-24 * 3_600), now)
        case .days7:
            return (now.addingTimeInterval(-7 * 86_400), now)
        case .days30:
            return (now.addingTimeInterval(-30 * 86_400), now)
        case .custom(let start, let end):
            return (start, end)
        }
    }
}

/// 图表点。`watts == nil` 用于打断折线，表示间隙而不是 0。
public struct HistoryChartPoint: Equatable, Sendable {
    public var epoch: TimeInterval
    public var iso8601: String
    public var watts: Double?
    public var percent: Int?
    public var isGap: Bool

    public init(
        epoch: TimeInterval,
        iso8601: String,
        watts: Double?,
        percent: Int?,
        isGap: Bool
    ) {
        self.epoch = epoch
        self.iso8601 = iso8601
        self.watts = watts
        self.percent = percent
        self.isGap = isGap
    }

    public static func from(sample: HistorySample) -> HistoryChartPoint {
        HistoryChartPoint(
            epoch: sample.epoch,
            iso8601: sample.iso8601,
            watts: sample.integrableWatts,
            percent: sample.percent,
            isGap: false
        )
    }
}

public struct HistoryQueryResult: Equatable, Sendable {
    public var samples: [HistorySample]
    public var chartPoints: [HistoryChartPoint]

    public init(samples: [HistorySample], chartPoints: [HistoryChartPoint]) {
        self.samples = samples
        self.chartPoints = chartPoints
    }

    public static let empty = HistoryQueryResult(samples: [], chartPoints: [])
}

/// 按时间范围读取并下采样。缺失与睡眠以 dt / sleepGap 表现为间隙，不做插值。
public enum HistoryQuery {
    public static let defaultMaxPoints = 1_500

    /// 图表间隙阈值：超过 2.5 倍采样间隔即打断折线。
    public static func gapThreshold(intervalSeconds: Int) -> TimeInterval {
        2.5 * TimeInterval(max(intervalSeconds, 1))
    }

    public static func load(
        store: HistoryStore,
        range: HistoryRange,
        now: Date = Date(),
        intervalSeconds: Int,
        maxPoints: Int = HistoryQuery.defaultMaxPoints
    ) throws -> HistoryQueryResult {
        let window = range.window(now: now)
        let start = min(window.start, window.end)
        let end = max(window.start, window.end)
        var reducer = StreamReducer(
            startEpoch: start.timeIntervalSince1970,
            endEpoch: end.timeIntervalSince1970,
            queryInterval: intervalSeconds,
            maxPoints: max(1, maxPoints)
        )
        // 图表路径仍走下采样；全量导出请用 forEachSample。
        try forEachSample(store: store, from: start, to: end) { sample in
            reducer.consume(sample)
        }
        return reducer.finish()
    }

    /// 按时间窗口逐条回调全部样本，不下采样、不攒成数组。空窗口或无文件时不回调。
    public static func forEachSample(
        store: HistoryStore,
        from start: Date,
        to end: Date,
        body: (HistorySample) throws -> Void
    ) throws {
        let orderedStart = min(start, end)
        let orderedEnd = max(start, end)
        let startEpoch = orderedStart.timeIntervalSince1970
        let endEpoch = orderedEnd.timeIntervalSince1970
        let calendar = store.calendar
        let decoder = JSONDecoder()
        var day = calendar.startOfDay(for: orderedStart)
        let lastDay = calendar.startOfDay(for: orderedEnd)
        while day <= lastDay {
            let url = store.directory.appendingPathComponent(dailyFileName(for: day, calendar: calendar))
            try streamJSONL(url, decoder: decoder) { sample in
                guard sample.epoch >= startEpoch, sample.epoch <= endEpoch else { return }
                try body(sample)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    /// HistoryRange 便利入口，仍不下采样。
    public static func forEachSample(
        store: HistoryStore,
        range: HistoryRange,
        now: Date = Date(),
        body: (HistorySample) throws -> Void
    ) throws {
        let window = range.window(now: now)
        try forEachSample(store: store, from: window.start, to: window.end, body: body)
    }

    public static func chartPoints(
        from samples: [HistorySample],
        intervalSeconds: Int,
        maxPoints: Int = HistoryQuery.defaultMaxPoints
    ) -> [HistoryChartPoint] {
        let ordered = samples.sorted { $0.epoch < $1.epoch }
        let segments = splitSegments(ordered, queryInterval: intervalSeconds)
        guard !segments.isEmpty else { return [] }

        let gapCount = max(0, segments.count - 1)
        let sampleBudget = max(segments.count, max(1, maxPoints) - gapCount)
        let budgets = allocate(total: sampleBudget, weights: segments.map(\.count))

        var points: [HistoryChartPoint] = []
        points.reserveCapacity(min(maxPoints, ordered.count + gapCount))
        for (index, segment) in segments.enumerated() {
            let reduced = downsample(segment, maxPoints: budgets[index])
            points.append(contentsOf: reduced.map(HistoryChartPoint.from(sample:)))
            if index + 1 < segments.count, let last = reduced.last, let next = segments[index + 1].first {
                points.append(gapPoint(from: last, to: next))
            }
        }
        if points.count > maxPoints, maxPoints > 0 {
            return cap(points, maxPoints: maxPoints)
        }
        return points
    }

    /// 在已按 epoch 升序排列的图表点中二分查找最近一点，供悬停使用。O(log n)。
    /// 与目标等距时取较早的点。
    public static func nearestPoint(in points: [HistoryChartPoint], epoch: TimeInterval) -> HistoryChartPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = low + (high - low) / 2
            if points[mid].epoch < epoch {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let candidate = points[low]
        if low > 0 {
            let previous = points[low - 1]
            if abs(previous.epoch - epoch) <= abs(candidate.epoch - epoch) {
                return previous
            }
        }
        return candidate
    }

    /// sleepGap 无条件打断；否则 dt > 2.5 × (样本 intervalSeconds ?? 查询间隔)。
    private static func shouldBreakLine(
        from previous: HistorySample,
        to current: HistorySample,
        queryInterval: Int
    ) -> Bool {
        if current.sleepGap == true {
            return true
        }
        let interval = current.intervalSeconds ?? previous.intervalSeconds ?? queryInterval
        return current.epoch - previous.epoch > gapThreshold(intervalSeconds: interval)
    }

    private static func splitSegments(_ samples: [HistorySample], queryInterval: Int) -> [[HistorySample]] {
        var segments: [[HistorySample]] = []
        var current: [HistorySample] = []
        for sample in samples {
            if let last = current.last, shouldBreakLine(from: last, to: sample, queryInterval: queryInterval) {
                segments.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private static func downsample(_ samples: [HistorySample], maxPoints: Int) -> [HistorySample] {
        guard maxPoints > 0 else { return [] }
        guard samples.count > maxPoints else { return samples }
        if maxPoints == 1 {
            return [samples[samples.count / 2]]
        }
        var picked: [HistorySample] = []
        picked.reserveCapacity(maxPoints)
        var lastIndex = -1
        for step in 0..<maxPoints {
            let index = Int((Double(step) * Double(samples.count - 1) / Double(maxPoints - 1)).rounded())
            if index != lastIndex {
                picked.append(samples[index])
                lastIndex = index
            }
        }
        return picked
    }

    private static func allocate(total: Int, weights: [Int]) -> [Int] {
        let sum = max(1, weights.reduce(0, +))
        var budgets = weights.map { max(1, total * $0 / sum) }
        var used = budgets.reduce(0, +)
        var index = 0
        while used < total, !budgets.isEmpty {
            budgets[index % budgets.count] += 1
            used += 1
            index += 1
        }
        while used > total {
            if let largest = budgets.indices.max(by: { budgets[$0] < budgets[$1] }), budgets[largest] > 1 {
                budgets[largest] -= 1
                used -= 1
            } else {
                break
            }
        }
        return budgets
    }

    private static func cap(_ points: [HistoryChartPoint], maxPoints: Int) -> [HistoryChartPoint] {
        guard points.count > maxPoints else { return points }
        var picked: [HistoryChartPoint] = []
        var lastIndex = -1
        for step in 0..<maxPoints {
            let index = Int((Double(step) * Double(points.count - 1) / Double(maxPoints - 1)).rounded())
            if index != lastIndex {
                picked.append(points[index])
                lastIndex = index
            }
        }
        return picked
    }

    private static func gapPoint(from previous: HistorySample, to current: HistorySample) -> HistoryChartPoint {
        let epoch = (previous.epoch + current.epoch) / 2
        return HistoryChartPoint(
            epoch: epoch,
            iso8601: HistorySample.iso8601String(from: Date(timeIntervalSince1970: epoch)),
            watts: nil,
            percent: nil,
            isGap: true
        )
    }

    private static func dailyFileName(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "samples-%04d-%02d-%02d.jsonl",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }

    /// 按行流式解码 JSONL，不把整文件拆成样本数组。
    private static func streamJSONL(
        _ url: URL,
        decoder: JSONDecoder,
        body: (HistorySample) throws -> Void
    ) throws {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var offset = 0
        let newline: UInt8 = 0x0A
        let maxLine = 1_048_576

        func compactIfNeeded() {
            if offset > 32_768 {
                buffer.removeSubrange(0..<offset)
                offset = 0
            }
        }

        func emit(_ line: Data) throws {
            var slice = line
            if slice.last == 0x0D {
                slice.removeLast()
            }
            guard !slice.isEmpty else { return }
            if let sample = try? decoder.decode(HistorySample.self, from: slice) {
                try body(sample)
            }
        }

        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newlineIndex = buffer[offset...].firstIndex(of: newline) {
                try emit(buffer[offset..<newlineIndex])
                offset = newlineIndex + 1
            }
            compactIfNeeded()
            if buffer.count - offset > maxLine {
                offset = buffer.count
                compactIfNeeded()
            }
        }
        if offset < buffer.count {
            try emit(buffer[offset..<buffer.count])
        }
    }

    /// 流式下采样：每个时间桶保留首点，段尾补最后一点，间隙插入 isGap。
    private struct StreamReducer {
        let startEpoch: TimeInterval
        let endEpoch: TimeInterval
        let queryInterval: Int
        let maxPoints: Int

        init(startEpoch: TimeInterval, endEpoch: TimeInterval, queryInterval: Int, maxPoints: Int) {
            self.startEpoch = startEpoch
            self.endEpoch = endEpoch
            self.queryInterval = queryInterval
            self.maxPoints = maxPoints
        }

        private var keptSamples: [HistorySample] = []
        private var points: [HistoryChartPoint] = []
        private var previous: HistorySample?
        private var lastKept: HistorySample?
        private var pending: HistorySample?

        private var bucketWidth: TimeInterval {
            let span = max(endEpoch - startEpoch, TimeInterval.leastNonzeroMagnitude)
            return span / TimeInterval(max(1, maxPoints))
        }

        mutating func consume(_ sample: HistorySample) {
            guard sample.epoch >= startEpoch, sample.epoch <= endEpoch else { return }
            if let previous, HistoryQuery.shouldBreakLine(from: previous, to: sample, queryInterval: queryInterval) {
                closeSegment()
                points.append(HistoryQuery.gapPoint(from: previous, to: sample))
                appendSample(sample)
                self.previous = sample
                return
            }
            if lastKept == nil || bucket(sample.epoch) != bucket(lastKept!.epoch) {
                appendSample(sample)
                pending = nil
            } else {
                pending = sample
            }
            previous = sample
        }

        mutating func finish() -> HistoryQueryResult {
            if let pending, lastKept?.epoch != pending.epoch {
                appendSample(pending)
            }
            if maxPoints > 0, points.count > maxPoints {
                let capped = HistoryQuery.cap(points, maxPoints: maxPoints)
                let epochs = Set(capped.compactMap { $0.isGap ? nil : $0.epoch })
                keptSamples = keptSamples.filter { epochs.contains($0.epoch) }
                points = capped
            }
            return HistoryQueryResult(samples: keptSamples, chartPoints: points)
        }

        private func bucket(_ epoch: TimeInterval) -> Int {
            let raw = Int((epoch - startEpoch) / bucketWidth)
            return min(max(0, raw), max(1, maxPoints) - 1)
        }

        private mutating func closeSegment() {
            if let previous, lastKept?.epoch != previous.epoch {
                appendSample(previous)
            }
            pending = nil
        }

        private mutating func appendSample(_ sample: HistorySample) {
            keptSamples.append(sample)
            points.append(HistoryChartPoint.from(sample: sample))
            lastKept = sample
        }
    }
}
