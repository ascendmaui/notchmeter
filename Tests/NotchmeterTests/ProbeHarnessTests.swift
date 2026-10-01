import Foundation
import Testing
@testable import Notchmeter

@Suite struct ProbeHarnessTests {
    let now = Date(timeIntervalSince1970: 1727769600) // 2024-10-01T08:00:00Z

    @Test func testPathInspectionHelpers() throws {
        let fm = FileManager.default
        let id = UUID().uuidString
        let tempDir = fm.temporaryDirectory.appendingPathComponent("probe-test-\(id)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // Directory inspection
        let dirStatus = ProbeHarness.inspectPath(tempDir, kind: "Test Directory", fm: fm)
        #expect(dirStatus.exists == true)
        #expect(dirStatus.isDirectory == true)
        #expect(dirStatus.kind == "Test Directory")

        // Nonexistent file inspection
        let missing = tempDir.appendingPathComponent("missing.txt")
        let missingStatus = ProbeHarness.inspectPath(missing, kind: "Missing File", fm: fm)
        #expect(missingStatus.exists == false)

        // CrashReporter plists detection
        let crashStatusBefore = ProbeHarness.detectCrashReporterPlists(in: tempDir, prefix: "ChatGPT_", fm: fm)
        #expect(crashStatusBefore.exists == false)

        let dummyPlist = tempDir.appendingPathComponent("ChatGPT_2026-10-01.plist")
        try "plist".write(to: dummyPlist, atomically: true, encoding: .utf8)

        let crashStatusAfter = ProbeHarness.detectCrashReporterPlists(in: tempDir, prefix: "ChatGPT_", fm: fm)
        #expect(crashStatusAfter.exists == true)
    }

    @Test func testLiveProbeReturnsAllTools() async {
        let report = await ProbeHarness.probeAll(now: now)
        #expect(report.results.count == ToolID.allCases.count)
        let probedTools = Set(report.results.map(\.tool))
        #expect(probedTools == Set(ToolID.allCases))

        for res in report.results {
            #expect(!res.displayName.isEmpty)
            #expect(res.latencyMs >= 0)
        }

        #expect(!report.summaryText.isEmpty)
        #expect(!report.json.isEmpty)
        #expect(report.dictionary["environment"] as? String == "live")
    }

    @Test func testSimulationFreshStubs() {
        let report = ProbeHarness.runSimulation(scenario: .freshStubs, now: now)
        #expect(report.stubTools.contains(.chatgpt))
        #expect(report.stubTools.contains(.grok))
        #expect(report.stubTools.contains(.hermes))
        #expect(report.stubTools.contains(.openclaw))
        #expect(report.chatGPTMetrics == nil)
    }

    @Test func testSimulationChatGPTStaggeredSelectsActiveTargetAndBurns() {
        let report = ProbeHarness.runSimulation(scenario: .chatGPTStaggered, now: now)
        let metrics = report.chatGPTMetrics
        #expect(metrics != nil)
        #expect(metrics?.slots.count == 4)
        #expect(metrics?.emptySlots.count == 2)
        #expect(metrics?.activeSlots.count == 1)
        #expect(metrics?.exhaustedSlots.count == 1)

        // Week 2 resets in 1 day with 95% room; Week 4 resets in 3 days with 92% room.
        // Target is Week 2 because it resets sooner!
        #expect(metrics?.activeBurnTarget?.id == "chatgpt_week_2")
        #expect(metrics?.activeBurnTarget?.index == 2)

        // Advisor recommendation includes john/chatgpt-burn
        #expect(report.advice.contains { $0.id == "john/chatgpt-burn" })
        let burnAdvice = report.advice.first { $0.id == "john/chatgpt-burn" }
        #expect(burnAdvice?.priority == .info)
        #expect(burnAdvice?.text.contains("2 weekly reset(s) with room") == true)
    }

    @Test func testSimulationChatGPTExhaustedWarns() {
        let report = ProbeHarness.runSimulation(scenario: .chatGPTExhausted, now: now)
        let metrics = report.chatGPTMetrics
        #expect(metrics != nil)
        #expect(metrics?.exhaustedSlots.count == 4)
        #expect(metrics?.activeBurnTarget == nil)

        // Advisor recommendation includes john/chatgpt-exhausted
        #expect(report.advice.contains { $0.id == "john/chatgpt-exhausted" })
        let exhaustedAdvice = report.advice.first { $0.id == "john/chatgpt-exhausted" }
        #expect(exhaustedAdvice?.priority == .warn)
        #expect(exhaustedAdvice?.text.contains("mostly spent") == true)
    }

    @Test func testSimulationReportFormatting() {
        let report = ProbeHarness.runSimulation(scenario: .chatGPTStaggered, now: now)
        let summary = report.summaryText
        #expect(summary.contains("=== Notchmeter Probe Harness Report"))
        #expect(summary.contains("ChatGPT"))
        #expect(summary.contains("ChatGPT Heavy Metrics:"))
        #expect(summary.contains("Advisor Recommendations:"))
    }
}
