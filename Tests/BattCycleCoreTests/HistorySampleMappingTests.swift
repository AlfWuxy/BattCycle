import BattCycleCore
import XCTest

final class HistorySampleMappingTests: XCTestCase {
    func testDirectionRawValuesMatchEnergyFlowDirection() {
        XCTAssertEqual(PowerDirection.charging.historyDirectionRawValue, EnergyFlowDirection.charge.rawValue)
        XCTAssertEqual(PowerDirection.discharging.historyDirectionRawValue, EnergyFlowDirection.discharge.rawValue)
        XCTAssertEqual(PowerDirection.idle.historyDirectionRawValue, EnergyFlowDirection.idle.rawValue)
        XCTAssertEqual(PowerDirection.unknown.historyDirectionRawValue, EnergyFlowDirection.unknown.rawValue)
    }

    func testMakeLiveOmitsUnavailablePercentAndWatts() {
        let snapshot = BatterySnapshot(
            percent: 0,
            drawingFrom: "unknown",
            isCharging: false,
            externalConnected: false,
            watts: 0,
            summary: "",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isAvailable: false,
            percentIsAvailable: false,
            wattsIsAvailable: false
        )
        let sample = HistorySample.makeLive(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            snapshot: snapshot,
            direction: .unknown,
            battStatus: nil,
            thermal: "nominal",
            enginePhase: "idle",
            recordingPaused: false,
            sleepGap: true
        )
        XCTAssertNil(sample.percent)
        XCTAssertNil(sample.watts)
        XCTAssertFalse(sample.wattsAvailable)
        XCTAssertEqual(sample.direction, "unknown")
        XCTAssertNil(sample.pluggedIn)
        XCTAssertNil(sample.useAdapter)
        XCTAssertEqual(sample.thermal, "nominal")
        XCTAssertEqual(sample.enginePhase, "idle")
        XCTAssertEqual(sample.sleepGap, true)
    }

    func testMakeLiveMapsBattStatusAndAvailableMetrics() {
        let snapshot = BatterySnapshot(
            percent: 82,
            drawingFrom: "电源适配器",
            isCharging: true,
            externalConnected: true,
            watts: 18.5,
            summary: "充电",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
            isAvailable: true,
            percentIsAvailable: true,
            wattsIsAvailable: true
        )
        let status = BattStatusSnapshot(pluggedIn: true, useAdapter: false)
        let sample = HistorySample.makeLive(
            at: Date(timeIntervalSince1970: 1_700_000_100),
            snapshot: snapshot,
            direction: .charging,
            battStatus: status,
            thermal: "fair",
            enginePhase: "charging",
            recordingPaused: true,
            sleepGap: nil
        )
        XCTAssertEqual(sample.percent, 82)
        XCTAssertEqual(sample.watts, 18.5)
        XCTAssertTrue(sample.wattsAvailable)
        XCTAssertEqual(sample.direction, "charge")
        XCTAssertEqual(sample.pluggedIn, true)
        XCTAssertEqual(sample.useAdapter, false)
        XCTAssertTrue(sample.recordingPaused)
        XCTAssertNil(sample.sleepGap)
    }

    func testMakeLiveMapsDischargeDirection() {
        let snapshot = BatterySnapshot(
            percent: 40,
            drawingFrom: "电池供电",
            isCharging: false,
            externalConnected: false,
            watts: -12.2,
            summary: "放电",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_200),
            isAvailable: true,
            wattsIsAvailable: true
        )
        let sample = HistorySample.makeLive(
            at: Date(timeIntervalSince1970: 1_700_000_200),
            snapshot: snapshot,
            direction: .discharging,
            battStatus: BattStatusSnapshot(pluggedIn: false, useAdapter: false),
            thermal: nil,
            enginePhase: "discharging",
            recordingPaused: false,
            sleepGap: nil
        )
        XCTAssertEqual(sample.direction, "discharge")
        XCTAssertEqual(sample.percent, 40)
        XCTAssertEqual(sample.watts, -12.2)
        XCTAssertNil(sample.intervalSeconds)
        XCTAssertNil(sample.segmentId)
        XCTAssertNil(sample.sleepGap)
    }

    func testDecodeLegacyJSONWithoutNewKeysAsNil() throws {
        let json = Data("""
        {"epoch":1700000000,"iso8601":"2023-11-14T22:13:20Z","wattsAvailable":false,"direction":"unknown"}
        """.utf8)
        let sample = try JSONDecoder().decode(HistorySample.self, from: json)
        XCTAssertEqual(sample.epoch, 1_700_000_000)
        XCTAssertEqual(sample.direction, "unknown")
        XCTAssertFalse(sample.recordingPaused)
        XCTAssertNil(sample.intervalSeconds)
        XCTAssertNil(sample.segmentId)
        XCTAssertNil(sample.sleepGap)
    }

    func testHistorySampleKeysAreDisjointFromEngineConfig() throws {
        let sample = HistorySample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            watts: -8.5,
            sleepGap: true,
            intervalSeconds: 10,
            segmentId: "seg-1"
        )
        let object = try jsonObject(from: sample)
        let engineKeys: Set<String> = [
            "upperLimit", "lowerLimit", "gpuSize", "cpuJobs", "pollSeconds", "stopAtEpoch"
        ]
        XCTAssertTrue(engineKeys.isDisjoint(with: Set(object.keys)))
        XCTAssertNil(object["historyIntervalSeconds"])
        XCTAssertNil(object["retentionDays"])
    }

    func testEncodeOmitsNilInterpretationKeys() throws {
        let sample = HistorySample(at: Date(timeIntervalSince1970: 1_700_000_000), watts: 10)
        let object = try jsonObject(from: sample)
        XCTAssertNil(object["intervalSeconds"])
        XCTAssertNil(object["segmentId"])
        XCTAssertNil(object["sleepGap"])
    }

    func testNewKeysRoundTrip() throws {
        let original = HistorySample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            watts: -8.5,
            sleepGap: true,
            intervalSeconds: 10,
            segmentId: "seg-after-wake"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HistorySample.self, from: data)
        XCTAssertEqual(decoded, original)
        let object = try jsonObject(from: original)
        XCTAssertEqual(object["intervalSeconds"] as? Int, 10)
        XCTAssertEqual(object["segmentId"] as? String, "seg-after-wake")
        XCTAssertEqual(object["sleepGap"] as? Bool, true)
    }

    func testMakeLiveSetsIntervalSecondsFromTickPolicy() {
        let snapshot = BatterySnapshot(
            percent: 55,
            drawingFrom: "电池供电",
            isCharging: false,
            externalConnected: false,
            watts: -9.1,
            summary: "放电",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_300),
            isAvailable: true,
            wattsIsAvailable: true
        )
        let flow = EnergyFlow.classify(snapshot)
        let sample = HistorySample.makeLive(
            at: Date(timeIntervalSince1970: 1_700_000_300),
            snapshot: snapshot,
            flow: flow,
            battStatus: BattStatusSnapshot(pluggedIn: false, useAdapter: false),
            thermal: "nominal",
            enginePhase: "discharging",
            recordingPaused: false,
            intervalSeconds: 30,
            segmentId: "seg-contiguous"
        )
        XCTAssertEqual(sample.intervalSeconds, 30)
        XCTAssertEqual(sample.segmentId, "seg-contiguous")
        XCTAssertEqual(sample.direction, "discharge")
        XCTAssertNil(sample.sleepGap)
    }

    func testMakeLiveSetsSleepGapOnlyForExplicitGapSamples() {
        let snapshot = BatterySnapshot(
            percent: 55,
            drawingFrom: "电池供电",
            isCharging: false,
            externalConnected: false,
            watts: -9.1,
            summary: "放电",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_400),
            isAvailable: true,
            wattsIsAvailable: true
        )
        let regular = HistorySample.makeLive(
            at: Date(timeIntervalSince1970: 1_700_000_400),
            snapshot: snapshot,
            direction: .discharging,
            battStatus: nil,
            thermal: nil,
            enginePhase: "discharging",
            recordingPaused: false,
            intervalSeconds: 10,
            sleepGap: false
        )
        XCTAssertEqual(regular.intervalSeconds, 10)
        XCTAssertNil(regular.sleepGap)

        let gap = HistorySample.makeLive(
            at: Date(timeIntervalSince1970: 1_700_000_400),
            snapshot: snapshot,
            direction: .discharging,
            battStatus: nil,
            thermal: nil,
            enginePhase: "discharging",
            recordingPaused: false,
            intervalSeconds: 10,
            segmentId: "seg-after-gap",
            sleepGap: true
        )
        XCTAssertEqual(gap.sleepGap, true)
        XCTAssertEqual(gap.segmentId, "seg-after-gap")
    }

    private func jsonObject(from sample: HistorySample) throws -> [String: Any] {
        let data = try JSONEncoder().encode(sample)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            XCTFail("encoded sample was not a JSON object")
            return [:]
        }
        return dictionary
    }
}
