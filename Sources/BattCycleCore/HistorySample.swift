import Foundation

/// 电池能量流向标签，JSONL 中以字符串存储。
public enum EnergyFlowDirection: String, Sendable {
    case charge
    case discharge
    case idle
    case unknown
}

/// 一条追加写入的历史样本。缺失功率用 nil，永不把缺失写成 0。
/// 不存储序列号、Apple ID、设备 UUID 或无关路径。
public struct HistorySample: Codable, Equatable, Sendable {
    public var epoch: TimeInterval
    public var iso8601: String
    public var percent: Int?
    public var watts: Double?
    public var wattsAvailable: Bool
    public var direction: String
    public var pluggedIn: Bool?
    public var useAdapter: Bool?
    public var thermal: String?
    public var enginePhase: String?
    public var recordingPaused: Bool
    /// 睡眠间隙可省略整行；若写入则为显式标记。查询仍以 dt 识别间隙。
    public var sleepGap: Bool?
    /// 写入当时的采样间隔（秒），供事后积分与切图；旧样本缺失则为 nil。
    public var intervalSeconds: Int?
    /// 连续段标识；睡眠/唤醒/间隙写入后换新 id。旧样本缺失则为 nil。
    public var segmentId: String?

    public init(
        epoch: TimeInterval,
        iso8601: String,
        percent: Int? = nil,
        watts: Double? = nil,
        wattsAvailable: Bool,
        direction: String,
        pluggedIn: Bool? = nil,
        useAdapter: Bool? = nil,
        thermal: String? = nil,
        enginePhase: String? = nil,
        recordingPaused: Bool = false,
        sleepGap: Bool? = nil,
        intervalSeconds: Int? = nil,
        segmentId: String? = nil
    ) {
        self.epoch = epoch
        self.iso8601 = iso8601
        self.percent = percent
        self.watts = watts
        self.wattsAvailable = wattsAvailable
        self.direction = direction
        self.pluggedIn = pluggedIn
        self.useAdapter = useAdapter
        self.thermal = thermal
        self.enginePhase = enginePhase
        self.recordingPaused = recordingPaused
        self.sleepGap = sleepGap
        self.intervalSeconds = intervalSeconds
        self.segmentId = segmentId
    }

    public init(
        at date: Date,
        percent: Int? = nil,
        watts: Double? = nil,
        wattsAvailable: Bool? = nil,
        direction: String = EnergyFlowDirection.unknown.rawValue,
        pluggedIn: Bool? = nil,
        useAdapter: Bool? = nil,
        thermal: String? = nil,
        enginePhase: String? = nil,
        recordingPaused: Bool = false,
        sleepGap: Bool? = nil,
        intervalSeconds: Int? = nil,
        segmentId: String? = nil
    ) {
        self.init(
            epoch: date.timeIntervalSince1970,
            iso8601: Self.iso8601String(from: date),
            percent: percent,
            watts: watts,
            wattsAvailable: wattsAvailable ?? (watts != nil),
            direction: direction,
            pluggedIn: pluggedIn,
            useAdapter: useAdapter,
            thermal: thermal,
            enginePhase: enginePhase,
            recordingPaused: recordingPaused,
            sleepGap: sleepGap,
            intervalSeconds: intervalSeconds,
            segmentId: segmentId
        )
    }

    public static func iso8601String(from date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    public static func parseISO8601(_ text: String) -> Date? {
        iso8601Formatter.date(from: text) ?? iso8601FractionalFormatter.date(from: text)
    }

    public var date: Date {
        Date(timeIntervalSince1970: epoch)
    }

    /// 可积分的功率：必须显式可用，缺失不得当作 0。
    public var integrableWatts: Double? {
        guard wattsAvailable, let watts else { return nil }
        return watts
    }

    enum CodingKeys: String, CodingKey {
        case epoch, iso8601, percent, watts, wattsAvailable, direction
        case pluggedIn, useAdapter, thermal, enginePhase, recordingPaused, sleepGap
        case intervalSeconds, segmentId
    }

    /// 缺失键解码为 nil（recordingPaused 缺省 false），兼容不含 intervalSeconds / segmentId / sleepGap 的旧 JSONL。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decode(TimeInterval.self, forKey: .epoch)
        iso8601 = try container.decode(String.self, forKey: .iso8601)
        percent = try container.decodeIfPresent(Int.self, forKey: .percent)
        watts = try container.decodeIfPresent(Double.self, forKey: .watts)
        wattsAvailable = try container.decode(Bool.self, forKey: .wattsAvailable)
        direction = try container.decode(String.self, forKey: .direction)
        pluggedIn = try container.decodeIfPresent(Bool.self, forKey: .pluggedIn)
        useAdapter = try container.decodeIfPresent(Bool.self, forKey: .useAdapter)
        thermal = try container.decodeIfPresent(String.self, forKey: .thermal)
        enginePhase = try container.decodeIfPresent(String.self, forKey: .enginePhase)
        // 旧行可能没有 recordingPaused；缺省为 false，不把缺失当成暂停。
        recordingPaused = try container.decodeIfPresent(Bool.self, forKey: .recordingPaused) ?? false
        sleepGap = try container.decodeIfPresent(Bool.self, forKey: .sleepGap)
        intervalSeconds = try container.decodeIfPresent(Int.self, forKey: .intervalSeconds)
        segmentId = try container.decodeIfPresent(String.self, forKey: .segmentId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(iso8601, forKey: .iso8601)
        try container.encodeIfPresent(percent, forKey: .percent)
        try container.encodeIfPresent(watts, forKey: .watts)
        try container.encode(wattsAvailable, forKey: .wattsAvailable)
        try container.encode(direction, forKey: .direction)
        try container.encodeIfPresent(pluggedIn, forKey: .pluggedIn)
        try container.encodeIfPresent(useAdapter, forKey: .useAdapter)
        try container.encodeIfPresent(thermal, forKey: .thermal)
        try container.encodeIfPresent(enginePhase, forKey: .enginePhase)
        try container.encode(recordingPaused, forKey: .recordingPaused)
        try container.encodeIfPresent(sleepGap, forKey: .sleepGap)
        try container.encodeIfPresent(intervalSeconds, forKey: .intervalSeconds)
        try container.encodeIfPresent(segmentId, forKey: .segmentId)
    }
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

private let iso8601FractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()
