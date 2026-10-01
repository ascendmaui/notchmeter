import Foundation
import Testing
@testable import Notchmeter

@Suite struct ChatGPTMetricsTests {
    let now = Date(timeIntervalSince1970: 1727769600) // 2024-10-01T08:00:00Z

    @Test func testInitialStubReadingAllUnused() {
        let windows = ChatGPTProvider.stubWindows(now: now)
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)

        let metrics = ChatGPTHeavyMetrics(reading: reading, now: now)
        #expect(metrics.slots.count == 4)
        #expect(metrics.emptySlots.count == 4)
        #expect(metrics.activeSlots.isEmpty)
        #expect(metrics.exhaustedSlots.isEmpty)
        #expect(metrics.unmeteredSlots.isEmpty)
        #expect(metrics.equivalentWeeksRemaining == 4.0)
        #expect(metrics.averageUsedFraction == 0.0)
        #expect(metrics.totalAvailableFraction == 1.0)

        // With equal resets, first index wins
        #expect(metrics.activeBurnTarget?.id == "chatgpt_week_1")
        #expect(metrics.activeBurnTarget?.index == 1)
        #expect(metrics.activeBurnTarget?.headroom == 1.0)
        #expect(metrics.recommendation.isBurnTarget == true)

        let summary = metrics.summaryText
        #expect(summary.contains("4/4 weeks available"))
        #expect(summary.contains("Active target: Weekly reset 1"))
    }

    @Test func testStaggeredWeeklyResetsSelectsSoonestReset() {
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: 0.05, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: 0.10, resetsAt: now.addingTimeInterval(1 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: 0.02, resetsAt: now.addingTimeInterval(6 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: 0.08, resetsAt: now.addingTimeInterval(2 * 86400), periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
        let metrics = ChatGPTHeavyMetrics(reading: reading, now: now)

        #expect(metrics.emptySlots.count == 4)
        // Week 2 resets in 1 day (soonest), so burn Week 2 first to prevent wasting quota
        #expect(metrics.activeBurnTarget?.id == "chatgpt_week_2")
        #expect(metrics.activeBurnTarget?.index == 2)
    }

    @Test func testExhaustedSlotsAndActiveFallback() {
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: 0.95, resetsAt: now.addingTimeInterval(86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: 0.92, resetsAt: now.addingTimeInterval(2 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: 0.40, resetsAt: now.addingTimeInterval(5 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: 0.90, resetsAt: now.addingTimeInterval(3 * 86400), periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus", fetchedAt: now, observedAt: nil)
        let metrics = ChatGPTHeavyMetrics(reading: reading, now: now)

        #expect(metrics.emptySlots.isEmpty)
        #expect(metrics.activeSlots.count == 1)
        #expect(metrics.exhaustedSlots.count == 3)
        #expect(metrics.activeBurnTarget?.id == "chatgpt_week_3")
        let headroom = metrics.activeBurnTarget?.headroom ?? 0
        #expect(abs(headroom - 0.60) < 0.001)

        if case .burnChatGPT(let slotId, let idx, let headroom, let reason) = metrics.recommendation {
            #expect(slotId == "chatgpt_week_3")
            #expect(idx == 3)
            #expect(abs(headroom - 0.60) < 0.001)
            #expect(reason.contains("Weekly reset 3 is active"))
        } else {
            Issue.record("Expected .burnChatGPT recommendation")
        }
    }

    @Test func testAllSlotsExhaustedRoutesElsewhere() {
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: 0.95, resetsAt: now.addingTimeInterval(86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: 0.98, resetsAt: now.addingTimeInterval(2 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: 0.91, resetsAt: now.addingTimeInterval(3 * 86400), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: 0.94, resetsAt: now.addingTimeInterval(4 * 86400), periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
        let metrics = ChatGPTHeavyMetrics(reading: reading, now: now)

        #expect(metrics.emptySlots.isEmpty)
        #expect(metrics.activeSlots.isEmpty)
        #expect(metrics.exhaustedSlots.count == 4)
        #expect(metrics.activeBurnTarget == nil)

        if case .cycleExhausted(let nextReset, let reason) = metrics.recommendation {
            #expect(nextReset == now.addingTimeInterval(86400))
            #expect(reason.contains("exhausted"))
        } else {
            Issue.record("Expected .cycleExhausted recommendation")
        }

        #expect(metrics.summaryText.contains("All resets exhausted; route elsewhere"))
    }

    @Test func testUnmeteredSlots() {
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: nil, resetsAt: nil, periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: nil, resetsAt: nil, periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: nil, resetsAt: nil, periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: nil, resetsAt: nil, periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: nil, fetchedAt: now, observedAt: nil)
        let metrics = ChatGPTHeavyMetrics(reading: reading, now: now)

        #expect(metrics.unmeteredSlots.count == 4)
        #expect(metrics.averageUsedFraction == nil)
        #expect(metrics.totalAvailableFraction == nil)
        #expect(metrics.activeBurnTarget == nil)
        if case .unmetered(let reason) = metrics.recommendation {
            #expect(reason.contains("not readable yet"))
        } else {
            Issue.record("Expected .unmetered recommendation")
        }
    }

    @Test func testDictionaryExport() {
        let windows = ChatGPTProvider.stubWindows(now: now)
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus", fetchedAt: now, observedAt: nil)
        let metrics = ChatGPTHeavyMetrics(reading: reading, now: now)

        let dict = metrics.dictionary
        #expect(dict["totalSlots"] as? Int == 4)
        #expect(dict["emptySlots"] as? Int == 4)
        #expect(dict["activeSlots"] as? Int == 0)
        #expect(dict["exhaustedSlots"] as? Int == 0)
        #expect(dict["equivalentWeeksRemaining"] as? Double == 4.0)
        #expect(dict["averageUsedFraction"] as? Double == 0.0)
        #expect(dict["totalAvailableFraction"] as? Double == 1.0)

        let slots = dict["slots"] as? [[String: Any]]
        #expect(slots?.count == 4)
        #expect(slots?.first?["id"] as? String == "chatgpt_week_1")
        #expect(slots?.first?["state"] as? String == "empty")
    }

    @Test func testUsageReadingExtensionIntegration() {
        let windows = ChatGPTProvider.stubWindows(now: now)
        let chatGPTReading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
        #expect(chatGPTReading.chatGPTHeavyMetrics != nil)

        let claudeReading = UsageReading(tool: .claude, windows: [], plan: "Max", fetchedAt: now, observedAt: nil)
        #expect(claudeReading.chatGPTHeavyMetrics == nil)
    }
}
