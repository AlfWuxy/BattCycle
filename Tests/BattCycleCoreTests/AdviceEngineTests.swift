@testable import BattCycleCore
import XCTest

final class AdviceEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let engine = AdviceEngine(cooldown: AdviceEngine.defaultCooldown)

    // MARK: - 各规则触发（A）

    func testSustainedHighDischargeTriggers() {
        let context = makeContext(
            samples: makeSamples(
                count: 61,
                watts: -28,
                direction: "discharging",
                pluggedIn: false,
                useAdapter: false
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .sustainedHighDischarge))
        XCTAssertFalse(contains(advice, .insufficientWattsSamples))
        assertNoForbiddenLanguage(advice)
    }

    func testDischargingWhileAdapterConnectedTriggers() {
        let context = makeContext(
            samples: makeSamples(
                count: 13,
                watts: -5,
                direction: "discharging",
                pluggedIn: true,
                useAdapter: nil
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .dischargingWhileAdapterConnected))
        XCTAssertFalse(contains(advice, .sustainedHighDischarge))
        XCTAssertFalse(contains(advice, .adapterStateConflictsBatteryDirection))
        assertNoForbiddenLanguage(advice)
    }

    func testChargePowerWellBelowAdapterCapabilityTriggers() {
        let context = makeContext(
            samples: makeSamples(
                count: 61,
                watts: 12,
                direction: "charging",
                pluggedIn: true,
                useAdapter: true
            ),
            ratedWatts: 96
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .chargePowerWellBelowAdapterCapability))
        let item = first(advice, .chargePowerWellBelowAdapterCapability)
        XCTAssertTrue(item.observedFactsZH.contains { $0.contains("96") })
        assertNoForbiddenLanguage(advice)
    }

    func testChargePowerRuleSkippedWhenRatedWattsMissing() {
        let context = makeContext(
            samples: makeSamples(
                count: 61,
                watts: 12,
                direction: "charging",
                pluggedIn: true,
                useAdapter: true
            ),
            ratedWatts: nil
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertFalse(contains(advice, .chargePowerWellBelowAdapterCapability))
        XCTAssertFalse(advice.current.contains { $0.ruleDescriptionZH.contains("96") })
    }

    func testRapidDirectionChatterTriggers() {
        let samples = (0..<10).map { index in
            AdviceSample(
                epoch: now.timeIntervalSince1970 - TimeInterval(9 - index) * 10,
                watts: 0,
                percent: 50,
                direction: index.isMultiple(of: 2) ? "charging" : "discharging",
                pluggedIn: false,
                useAdapter: false,
                thermal: "nominal",
                enginePhase: "idle"
            )
        }
        let context = makeContext(samples: samples)
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .rapidDirectionChatter))
        assertNoForbiddenLanguage(advice)
    }

    func testThermalTooHighTriggers() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "serious"
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .thermalTooHigh))
        XCTAssertEqual(first(advice, .thermalTooHigh).severity, .warning)
        assertNoForbiddenLanguage(advice)
    }

    func testThermalCriticalUsesHighSeverity() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "critical"
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertEqual(first(advice, .thermalTooHigh).severity, .high)
    }

    func testStaleDataTriggers() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                lastEpoch: now.timeIntervalSince1970 - 120,
                watts: 0,
                direction: "idle"
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .staleData))
        assertNoForbiddenLanguage(advice)
    }

    func testShortIntervalLongRetentionTriggers() {
        let context = makeContext(
            samples: makeSamples(count: 5, watts: 0, direction: "idle"),
            interval: 2,
            retentionDays: 90
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .shortIntervalLongRetention))
        XCTAssertEqual(first(advice, .shortIntervalLongRetention).severity, .info)
        assertNoForbiddenLanguage(advice)
    }

    func testCycleLoadPlusHeatTriggers() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: -5,
                direction: "discharging",
                pluggedIn: false,
                useAdapter: false,
                thermal: "fair",
                enginePhase: "discharging"
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .cycleLoadPlusHeat))
        XCTAssertFalse(contains(advice, .sustainedHighDischarge))
        assertNoForbiddenLanguage(advice)
    }

    func testAdapterStateConflictsWhenAdapterOnButDischarging() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: -4,
                direction: "discharging",
                pluggedIn: true,
                useAdapter: true
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .adapterStateConflictsBatteryDirection))
        XCTAssertFalse(contains(advice, .dischargingWhileAdapterConnected))
        let item = first(advice, .adapterStateConflictsBatteryDirection)
        XCTAssertGreaterThan(item.confidence, 0)
        XCTAssertLessThanOrEqual(item.confidence, 1)
        assertNoForbiddenLanguage(advice)
    }

    func testAdapterStateConflictsWhenAdapterOffButCharging() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 10,
                direction: "charging",
                pluggedIn: true,
                useAdapter: false
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .adapterStateConflictsBatteryDirection))
        XCTAssertFalse(contains(advice, .chargePowerWellBelowAdapterCapability))
        assertNoForbiddenLanguage(advice)
    }

    // MARK: - A+B：多规则同时为真且集合稳定

    func testActiveRulesAAndBStayTogetherWithoutRotation() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "serious"
            ),
            interval: 2,
            retentionDays: 90
        )
        let firstPass = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(firstPass, .thermalTooHigh))
        XCTAssertTrue(contains(firstPass, .shortIntervalLongRetention))

        let second = engine.evaluateAll(
            context: context,
            previous: firstPass.current,
            now: now.addingTimeInterval(30)
        )
        XCTAssertTrue(contains(second, .thermalTooHigh))
        XCTAssertTrue(contains(second, .shortIntervalLongRetention))
        XCTAssertEqual(
            Set(firstPass.current.map(\.ruleId)),
            Set(second.current.map(\.ruleId))
        )
        XCTAssertTrue(second.suppressedByCooldown.contains(AdviceRuleID.thermalTooHigh.rawValue))
        XCTAssertTrue(second.suppressedByCooldown.contains(AdviceRuleID.shortIntervalLongRetention.rawValue))
    }

    // MARK: - 条件结束即消失

    func testAdviceDisappearsWhenConditionClears() {
        let hot = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "critical"
            )
        )
        let firstPass = engine.evaluateAll(context: hot, previous: [], now: now)
        XCTAssertTrue(contains(firstPass, .thermalTooHigh))

        let cool = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "nominal"
            )
        )
        let cleared = engine.evaluateAll(
            context: cool,
            previous: firstPass.current,
            now: now.addingTimeInterval(30)
        )
        XCTAssertFalse(contains(cleared, .thermalTooHigh))
        XCTAssertFalse(cleared.suppressedByCooldown.contains(AdviceRuleID.thermalTooHigh.rawValue))
    }

    // MARK: - 数据不足

    func testInsufficientDataEmitsExplicitMessage() {
        let samples = makeSamples(
            count: 2,
            watts: nil,
            direction: "idle"
        )
        let context = makeContext(samples: samples)
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(advice.current.contains { $0.dataInsufficient })
        XCTAssertTrue(contains(advice, .insufficientWattsSamples))
        let item = first(advice, .insufficientWattsSamples)
        XCTAssertTrue(joinedText(item).contains("数据不足"))
        XCTAssertEqual(item.displayNameZH, AdviceRuleID.insufficientWattsSamples.displayNameZH)
        XCTAssertNotEqual(item.displayNameZH, AdviceRuleID.insufficientWattsSamples.rawValue)
        XCTAssertLessThan(item.confidence, 1)
        XCTAssertEqual(item.confidence, AdviceEngine.insufficientDataConfidence)
        XCTAssertNil(item.displayedConfidence)
        XCTAssertFalse(contains(advice, .sustainedHighDischarge))
        XCTAssertFalse(contains(advice, .chargePowerWellBelowAdapterCapability))
        assertNoForbiddenLanguage(advice)
    }

    func testInsufficientDataDoesNotFabricatePowerAdvice() {
        let context = makeContext(
            samples: makeSamples(
                count: 2,
                watts: -80,
                direction: "discharging",
                pluggedIn: false,
                useAdapter: false
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(advice, .insufficientWattsSamples))
        XCTAssertFalse(contains(advice, .sustainedHighDischarge))
        XCTAssertTrue(first(advice, .insufficientWattsSamples).dataInsufficient)
        XCTAssertNotEqual(first(advice, .insufficientWattsSamples).confidence, 1)
        XCTAssertEqual(first(advice, .insufficientWattsSamples).confidence, AdviceEngine.insufficientDataConfidence)
        XCTAssertNil(first(advice, .insufficientWattsSamples).displayedConfidence)
    }

    func testRuleDisplayNameZHIsChineseNotRawId() {
        for rule in AdviceRuleID.allCases {
            XCTAssertFalse(rule.displayNameZH.isEmpty)
            XCTAssertNotEqual(rule.displayNameZH, rule.rawValue)
            XCTAssertFalse(rule.displayNameZH.contains(rule.rawValue))
        }
        XCTAssertEqual(AdviceRuleID.insufficientWattsSamples.displayNameZH, "有效功率样本不足")
    }

    // MARK: - 去重与冷却：冷却不隐藏仍为真的规则

    func testDedupCooldownDoesNotHideCurrentlyTrueAdvice() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "critical"
            )
        )
        let firstPass = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertTrue(contains(firstPass, .thermalTooHigh))
        XCTAssertFalse(firstPass.suppressedByCooldown.contains(AdviceRuleID.thermalTooHigh.rawValue))

        let duringCooldown = engine.evaluateAll(
            context: context,
            previous: firstPass.current,
            now: now.addingTimeInterval(60)
        )
        XCTAssertTrue(contains(duringCooldown, .thermalTooHigh))
        XCTAssertTrue(duringCooldown.suppressedByCooldown.contains(AdviceRuleID.thermalTooHigh.rawValue))
    }

    func testDedupCooldownAllowsNewEmitAfterExpiry() {
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "critical"
            )
        )
        let firstPass = engine.evaluateAll(context: context, previous: [], now: now)
        let after = engine.evaluateAll(
            context: context,
            previous: firstPass.current,
            now: now.addingTimeInterval(AdviceEngine.defaultCooldown + 1)
        )
        XCTAssertTrue(contains(after, .thermalTooHigh))
        XCTAssertFalse(after.suppressedByCooldown.contains(AdviceRuleID.thermalTooHigh.rawValue))
    }

    func testDeduperInMemoryKeepsCurrentAndRecordsEmit() {
        var deduper = AdviceDeduper()
        let context = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "serious"
            )
        )
        let firstPass = engine.evaluateAll(context: context, deduper: &deduper, now: now)
        XCTAssertTrue(contains(firstPass, .thermalTooHigh))
        XCTAssertNotNil(deduper.lastEmitAtByRuleId[AdviceRuleID.thermalTooHigh.rawValue])
        let firstEmit = deduper.lastEmitAtByRuleId[AdviceRuleID.thermalTooHigh.rawValue]

        let second = engine.evaluateAll(
            context: context,
            deduper: &deduper,
            now: now.addingTimeInterval(30)
        )
        XCTAssertTrue(contains(second, .thermalTooHigh))
        XCTAssertTrue(second.suppressedByCooldown.contains(AdviceRuleID.thermalTooHigh.rawValue))
        XCTAssertEqual(deduper.lastEmitAtByRuleId[AdviceRuleID.thermalTooHigh.rawValue], firstEmit)
    }

    // MARK: - 未知方向与间隙

    func testUnknownDirectionFilteredBeforeChatterCount() {
        let samples = (0..<12).map { index in
            AdviceSample(
                epoch: now.timeIntervalSince1970 - TimeInterval(11 - index) * 10,
                watts: 0,
                percent: 50,
                direction: index.isMultiple(of: 2) ? "charging" : "unknown",
                pluggedIn: false,
                useAdapter: false,
                thermal: "nominal",
                enginePhase: "idle"
            )
        }
        let context = makeContext(samples: samples)
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertFalse(contains(advice, .rapidDirectionChatter))
    }

    func testScatteredDischargeAcrossGapIsNotSustained() {
        let interval: TimeInterval = 10
        let clusterCount = 36
        let gap: TimeInterval = 3_600
        let secondStart = now.timeIntervalSince1970
        let firstEnd = secondStart - gap
        let first = makeSamples(
            count: clusterCount,
            interval: interval,
            lastEpoch: firstEnd,
            watts: -28,
            direction: "discharging",
            pluggedIn: false,
            useAdapter: false
        )
        var second = makeSamples(
            count: clusterCount,
            interval: interval,
            lastEpoch: secondStart,
            watts: -28,
            direction: "discharging",
            pluggedIn: false,
            useAdapter: false
        )
        if !second.isEmpty {
            second[0].sleepGap = true
        }
        let context = makeContext(samples: first + second, interval: interval)
        let naiveSpan = (second.last?.epoch ?? 0) - (first.first?.epoch ?? 0)
        XCTAssertGreaterThan(naiveSpan, AdviceEngine.highDischargeMinSeconds)
        XCTAssertGreaterThanOrEqual(first.count + second.count, AdviceEngine.minValidWattsSamples)

        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertFalse(contains(advice, .sustainedHighDischarge))
    }

    func testCycleDischargingSkipsAdapterDischargeAnomaly() {
        let context = makeContext(
            samples: makeSamples(
                count: 13,
                watts: -5,
                direction: "discharging",
                pluggedIn: true,
                useAdapter: false,
                thermal: "fair",
                enginePhase: "discharging"
            )
        )
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertFalse(contains(advice, .dischargingWhileAdapterConnected))
        XCTAssertFalse(contains(advice, .adapterStateConflictsBatteryDirection))
        XCTAssertTrue(contains(advice, .cycleLoadPlusHeat))
        assertNoForbiddenLanguage(advice)
    }

    func testPastCycleDischargeDoesNotFalsePositiveAfterReturningToIdle() {
        let cycle = makeSamples(
            count: 13,
            lastEpoch: now.timeIntervalSince1970 - 60,
            watts: -5,
            direction: "discharging",
            pluggedIn: true,
            useAdapter: false,
            thermal: "fair",
            enginePhase: "discharging"
        )
        let idle = makeSamples(
            count: 5,
            watts: 0,
            direction: "idle",
            pluggedIn: true,
            useAdapter: false,
            thermal: "nominal",
            enginePhase: "idle"
        )
        let context = makeContext(samples: cycle + idle)
        let advice = engine.evaluateAll(context: context, previous: [], now: now)
        XCTAssertFalse(contains(advice, .dischargingWhileAdapterConnected))
        XCTAssertFalse(contains(advice, .adapterStateConflictsBatteryDirection))
    }

    func testEvaluateReturnsOnlyCurrentlyTrueRulesNotPrevious() {
        let hot = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "critical"
            )
        )
        let previous = engine.evaluate(context: hot, previous: [], now: now)
        XCTAssertTrue(contains(previous, .thermalTooHigh))

        let cool = makeContext(
            samples: makeSamples(
                count: 5,
                watts: 0,
                direction: "idle",
                thermal: "nominal"
            )
        )
        let current = engine.evaluate(
            context: cool,
            previous: previous,
            now: now.addingTimeInterval(30)
        )
        XCTAssertFalse(contains(current, .thermalTooHigh))
        XCTAssertEqual(
            current.map(\.ruleId),
            engine.evaluateAll(context: cool, previous: previous, now: now.addingTimeInterval(30)).current.map(\.ruleId)
        )
    }

    func testEveryEmittedAdviceHasRequiredChineseDisplayName() {
        for context in allRuleFixtures() {
            let advice = engine.evaluate(context: context, previous: [], now: now)
            XCTAssertFalse(advice.isEmpty)
            for item in advice {
                XCTAssertFalse(item.displayNameZH.isEmpty)
                XCTAssertNotEqual(item.displayNameZH, item.ruleId)
            }
        }
    }

    // MARK: - 文案约束

    func testNoHealthClaimStrings() {
        let fixtures = allRuleFixtures()
        for context in fixtures {
            let advice = engine.evaluateAll(context: context, previous: [], now: now)
            XCTAssertFalse(advice.current.isEmpty, "每个规则夹具至少应产生一条建议")
            assertNoForbiddenLanguage(advice)
        }
    }

    func testSuggestedActionDoesNotClaimAutomaticAdapterOff() {
        for context in allRuleFixtures() {
            let advice = engine.evaluateAll(context: context, previous: [], now: now)
            for item in advice.current {
                XCTAssertFalse(item.suggestedActionZH.contains("自动关闭适配器"))
                XCTAssertFalse(item.suggestedActionZH.contains("将自动"))
                XCTAssertFalse(item.observedFactsZH.contains { $0.contains("自动关闭适配器") })
            }
        }
    }

    func testAdviceFieldsAreTransparent() {
        let context = makeContext(
            samples: makeSamples(
                count: 61,
                watts: -30,
                direction: "discharging",
                pluggedIn: false,
                useAdapter: false
            )
        )
        let item = first(
            engine.evaluateAll(context: context, previous: [], now: now),
            .sustainedHighDischarge
        )
        XCTAssertFalse(item.observedFactsZH.isEmpty)
        XCTAssertFalse(item.timeRangeDescriptionZH.isEmpty)
        XCTAssertEqual(item.ruleId, AdviceRuleID.sustainedHighDischarge.rawValue)
        XCTAssertEqual(item.displayNameZH, AdviceRuleID.sustainedHighDischarge.displayNameZH)
        XCTAssertNotEqual(item.displayNameZH, item.ruleId)
        XCTAssertFalse(item.ruleDescriptionZH.isEmpty)
        XCTAssertGreaterThanOrEqual(item.confidence, 0)
        XCTAssertLessThanOrEqual(item.confidence, 1)
        XCTAssertEqual(item.displayedConfidence, item.confidence)
        XCTAssertFalse(item.suggestedActionZH.isEmpty)
        XCTAssertEqual(item.generatedAt, now)
        XCTAssertFalse(item.dataInsufficient)
        XCTAssertFalse(item.suggestedActionZH.contains("将自动"))
    }

    func testConfidenceIsClampedOnInit() {
        let over = Advice(
            id: "x",
            severity: .info,
            observedFactsZH: ["事实"],
            timeRangeDescriptionZH: "窗口",
            ruleId: "x",
            ruleDescriptionZH: "规则",
            confidence: 2,
            suggestedActionZH: "请考虑检查读数。",
            generatedAt: now,
            displayNameZH: "测试"
        )
        XCTAssertEqual(over.confidence, 1)

        let under = Advice(
            id: "y",
            severity: .info,
            observedFactsZH: ["事实"],
            timeRangeDescriptionZH: "窗口",
            ruleId: "y",
            ruleDescriptionZH: "规则",
            confidence: -1,
            suggestedActionZH: "请考虑检查读数。",
            generatedAt: now,
            displayNameZH: "测试"
        )
        XCTAssertEqual(under.confidence, 0)
    }

    func testAdapterConflictConfidenceRisesWithSampleCount() {
        let few = engine.evaluateAll(
            context: makeContext(
                samples: makeSamples(
                    count: 3,
                    watts: -3,
                    direction: "discharging",
                    pluggedIn: true,
                    useAdapter: true
                )
            ),
            previous: [],
            now: now
        )
        let many = engine.evaluateAll(
            context: makeContext(
                samples: makeSamples(
                    count: 10,
                    watts: -3,
                    direction: "discharging",
                    pluggedIn: true,
                    useAdapter: true
                )
            ),
            previous: [],
            now: now
        )
        let fewItem = first(few, .adapterStateConflictsBatteryDirection)
        let manyItem = first(many, .adapterStateConflictsBatteryDirection)
        XCTAssertLessThan(fewItem.confidence, manyItem.confidence)
    }

    // MARK: - 夹具

    private func allRuleFixtures() -> [AdviceContext] {
        [
            makeContext(
                samples: makeSamples(
                    count: 61,
                    watts: -28,
                    direction: "discharging",
                    pluggedIn: false,
                    useAdapter: false
                )
            ),
            makeContext(
                samples: makeSamples(
                    count: 13,
                    watts: -5,
                    direction: "discharging",
                    pluggedIn: true,
                    useAdapter: nil
                )
            ),
            makeContext(
                samples: makeSamples(
                    count: 61,
                    watts: 12,
                    direction: "charging",
                    pluggedIn: true,
                    useAdapter: true
                ),
                ratedWatts: 96
            ),
            makeContext(
                samples: (0..<10).map { index in
                    AdviceSample(
                        epoch: now.timeIntervalSince1970 - TimeInterval(9 - index) * 10,
                        watts: 0,
                        percent: 50,
                        direction: index.isMultiple(of: 2) ? "charging" : "discharging",
                        pluggedIn: false,
                        useAdapter: false,
                        thermal: "nominal",
                        enginePhase: "idle"
                    )
                }
            ),
            makeContext(
                samples: makeSamples(
                    count: 5,
                    watts: 0,
                    direction: "idle",
                    thermal: "critical"
                )
            ),
            makeContext(
                samples: makeSamples(
                    count: 5,
                    lastEpoch: now.timeIntervalSince1970 - 120,
                    watts: 0,
                    direction: "idle"
                )
            ),
            makeContext(
                samples: makeSamples(count: 5, watts: 0, direction: "idle"),
                interval: 2,
                retentionDays: 90
            ),
            makeContext(
                samples: makeSamples(
                    count: 5,
                    watts: -5,
                    direction: "discharging",
                    pluggedIn: false,
                    useAdapter: false,
                    thermal: "fair",
                    enginePhase: "discharging"
                )
            ),
            makeContext(
                samples: makeSamples(
                    count: 5,
                    watts: -4,
                    direction: "discharging",
                    pluggedIn: true,
                    useAdapter: true
                )
            ),
            makeContext(
                samples: makeSamples(
                    count: 2,
                    watts: nil,
                    direction: "idle"
                )
            )
        ]
    }

    private func makeContext(
        samples: [AdviceSample],
        interval: TimeInterval = 10,
        retentionDays: Int = 14,
        ratedWatts: Double? = nil
    ) -> AdviceContext {
        AdviceContext(
            samples: samples,
            historyIntervalSeconds: interval,
            recordingPaused: false,
            sampleCount: samples.count,
            retentionDays: retentionDays,
            adapterRatedMaxWatts: ratedWatts
        )
    }

    private func makeSamples(
        count: Int,
        interval: TimeInterval = 10,
        lastEpoch: TimeInterval? = nil,
        watts: Double?,
        direction: String,
        pluggedIn: Bool? = false,
        useAdapter: Bool? = false,
        thermal: String? = "nominal",
        enginePhase: String? = "idle",
        percent: Double? = 55,
        sleepGap: Bool? = nil
    ) -> [AdviceSample] {
        let last = lastEpoch ?? now.timeIntervalSince1970
        return (0..<count).map { index in
            AdviceSample(
                epoch: last - TimeInterval(count - 1 - index) * interval,
                watts: watts,
                percent: percent,
                direction: direction,
                pluggedIn: pluggedIn,
                useAdapter: useAdapter,
                thermal: thermal,
                enginePhase: enginePhase,
                sleepGap: index == 0 ? sleepGap : nil
            )
        }
    }

    private func contains(_ evaluation: AdviceEvaluation, _ rule: AdviceRuleID) -> Bool {
        contains(evaluation.current, rule)
    }

    private func contains(_ advice: [Advice], _ rule: AdviceRuleID) -> Bool {
        advice.contains { $0.ruleId == rule.rawValue }
    }

    private func first(_ evaluation: AdviceEvaluation, _ rule: AdviceRuleID) -> Advice {
        first(evaluation.current, rule)
    }

    private func first(_ advice: [Advice], _ rule: AdviceRuleID) -> Advice {
        let match = advice.first { $0.ruleId == rule.rawValue }
        XCTAssertNotNil(match, "缺少规则 \(rule.rawValue)：\(advice.map(\.ruleId))")
        return match ?? Advice(
            id: "missing",
            severity: .info,
            observedFactsZH: [],
            timeRangeDescriptionZH: "",
            ruleId: rule.rawValue,
            ruleDescriptionZH: "",
            confidence: 0,
            suggestedActionZH: "",
            generatedAt: now,
            displayNameZH: rule.displayNameZH
        )
    }

    private func joinedText(_ item: Advice) -> String {
        (
            item.observedFactsZH
                + [
                    item.displayNameZH,
                    item.timeRangeDescriptionZH,
                    item.ruleDescriptionZH,
                    item.suggestedActionZH
                ]
        ).joined(separator: "\n")
    }

    private func assertNoForbiddenLanguage(
        _ evaluation: AdviceEvaluation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertNoForbiddenLanguage(evaluation.current, file: file, line: line)
    }

    private func assertNoForbiddenLanguage(_ advice: [Advice], file: StaticString = #filePath, line: UInt = #line) {
        let forbidden = ["延长寿命", "修复健康", "自动关闭适配器", "将自动"]
        for item in advice {
            let text = joinedText(item)
            for term in forbidden {
                XCTAssertFalse(
                    text.contains(term),
                    "建议 \(item.ruleId) 含禁用文案「\(term)」：\(text)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
