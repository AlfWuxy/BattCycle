import Foundation

/// 导出当前查询范围内的逐点 CSV。能量汇总单独标注为估算。
public enum HistoryCSV {
    /// 小范围导出为完整字符串，供测试与短结果使用。逐行拼接，不预先攒成 `[String]`。
    public static func export(samples: [HistorySample], energy: EnergyEstimates? = nil) -> String {
        var output = ""
        writeLines(samples: samples, energy: energy) { line in
            output.append(line)
            output.append("\n")
        }
        return output
    }

    /// 从任意序列流式写入目标文件，不要求先收集为数组。
    public static func export<S: Sequence>(
        to url: URL,
        samples: S,
        energy: EnergyEstimates? = nil
    ) throws where S.Element == HistorySample {
        try withTruncatedHandle(at: url) { handle in
            try export(to: handle, samples: samples, energy: energy)
        }
    }

    /// 从任意序列流式写入已打开的文件句柄。调用方负责打开与关闭。
    public static func export<S: Sequence>(
        to handle: FileHandle,
        samples: S,
        energy: EnergyEstimates? = nil
    ) throws where S.Element == HistorySample {
        try writePrefix(energy: energy, write: { try writeLine($0, to: handle) })
        for sample in samples {
            try writeLine(sampleRow(sample), to: handle)
        }
    }

    /// 由调用方逐条推入样本；导出侧只写当前行，不攒齐窗口。空 produce 仍写出表头。
    public static func export(
        to url: URL,
        energy: EnergyEstimates? = nil,
        produce: ((HistorySample) throws -> Void) throws -> Void
    ) throws {
        try withTruncatedHandle(at: url) { handle in
            try export(to: handle, energy: energy, produce: produce)
        }
    }

    /// 由调用方逐条推入样本到已打开的句柄。
    public static func export(
        to handle: FileHandle,
        energy: EnergyEstimates? = nil,
        produce: ((HistorySample) throws -> Void) throws -> Void
    ) throws {
        try writePrefix(energy: energy, write: { try writeLine($0, to: handle) })
        try produce { sample in
            try writeLine(sampleRow(sample), to: handle)
        }
    }

    /// 逐行写出 CSV；若含能量汇总则保留「估算」标注。
    private static func writeLines(
        samples: [HistorySample],
        energy: EnergyEstimates?,
        write: (String) throws -> Void
    ) rethrows {
        try writePrefix(energy: energy, write: write)
        for sample in samples {
            try write(sampleRow(sample))
        }
    }

    /// 写出可选能量汇总（含「估算」）与样本表头。
    private static func writePrefix(
        energy: EnergyEstimates?,
        write: (String) throws -> Void
    ) rethrows {
        if let energy {
            try write(["field", "value", "unit", "note"].joined(separator: ","))
            try write(summaryRow("energyInWh", value: energy.energyInWh, unit: "Wh"))
            try write(summaryRow("energyOutWh", value: energy.energyOutWh, unit: "Wh"))
            try write(summaryRow("netWh", value: energy.netWh, unit: "Wh"))
            try write(summaryRow("meanChargeW", value: energy.meanChargeW, unit: "W"))
            try write(summaryRow("meanDischargeW", value: energy.meanDischargeW, unit: "W"))
            try write(summaryRow("peakInW", value: energy.peakInW, unit: "W"))
            try write(summaryRow("peakOutW", value: energy.peakOutW, unit: "W"))
            try write(summaryRow("completeness", value: energy.completeness, unit: "0-1"))
            try write(
                ["isEstimate", energy.isEstimate ? "true" : "false", "", EnergyEstimates.estimateLabel]
                    .joined(separator: ",")
            )
            try write("")
        }
        try write(sampleHeader)
    }

    private static func withTruncatedHandle(at url: URL, body: (FileHandle) throws -> Void) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try "".write(to: url, atomically: false, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try body(handle)
    }

    private static func writeLine(_ line: String, to handle: FileHandle) throws {
        var data = Data(line.utf8)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static let sampleHeader = [
        "epoch (s)",
        "iso8601",
        "percent (%)",
        "watts (W)",
        "wattsAvailable",
        "direction",
        "pluggedIn",
        "useAdapter",
        "thermal",
        "enginePhase",
        "recordingPaused",
        "sleepGap"
    ].joined(separator: ",")

    private static func sampleRow(_ sample: HistorySample) -> String {
        [
            formatNumber(sample.epoch),
            csv(sample.iso8601),
            sample.percent.map(String.init) ?? "",
            sample.watts.map(formatNumber) ?? "",
            sample.wattsAvailable ? "true" : "false",
            csv(sample.direction),
            boolCell(sample.pluggedIn),
            boolCell(sample.useAdapter),
            csv(sample.thermal ?? ""),
            csv(sample.enginePhase ?? ""),
            sample.recordingPaused ? "true" : "false",
            boolCell(sample.sleepGap)
        ].joined(separator: ",")
    }

    private static func summaryRow(_ name: String, value: Double?, unit: String) -> String {
        [name, value.map(formatNumber) ?? "", unit, EnergyEstimates.estimateLabel].joined(separator: ",")
    }

    private static func boolCell(_ value: Bool?) -> String {
        guard let value else { return "" }
        return value ? "true" : "false"
    }

    private static func formatNumber(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) {
            return String(Int(value))
        }
        return String(value)
    }

    private static func csv(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
