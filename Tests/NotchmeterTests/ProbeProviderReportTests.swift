import Foundation
import Testing
@testable import Notchmeter

/// What `--probe --json` writes for the five tools that meter a plan by windows (Codex, Cursor, Antigravity, Gemini,
/// Copilot), and which errors the app asks the user to fix (`ProviderError.needsAttention`) rather than retry.
@Suite struct ProbeProviderReport {
    init() { Localization.use(language: "en") }

    let now = DateParsing.iso8601("2026-10-07T12:00:00Z")!

    func window(_ id: String, _ label: WindowLabel, used: Double?, resetsIn: TimeInterval? = 3600, period: TimeInterval? = nil, model: String? = nil,
                source: WindowSource = .vendorEndpoint) -> LimitWindow {
        LimitWindow(id: id, label: label, usedFraction: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) }, periodDuration: period, model: model, source: source)
    }

    func reading(_ tool: ToolID, plan: String?, _ windows: [LimitWindow]) -> UsageReading {
        UsageReading(tool: tool, windows: windows, plan: plan, fetchedAt: now, observedAt: nil)
    }

    func tools(_ report: UsageReport) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        return try #require(object["tools"] as? [[String: Any]])
    }

    func entry(_ list: [[String: Any]], _ tool: ToolID) throws -> [String: Any] {
        try #require(list.first { $0["tool"] as? String == tool.rawValue })
    }

    var fiveTools: [ToolID: ToolStatus] {
        [
            .codex: .ready(reading(.codex, plan: "Plus", [window("five_hour", "Session", used: 0.42, resetsIn: 7200, period: 5 * 3600),
                                                        window("weekly", "Weekly", used: 0.1, resetsIn: 6 * 86400, period: 7 * 86400)])),
            .cursor: .ready(reading(.cursor, plan: "Pro", [window("included", "Included", used: 0.25, resetsIn: 20 * 86400, period: 30 * 86400)])),
            .antigravity: .ready(reading(.antigravity, plan: "AI Pro", [window("session", "Session", used: 0.9, resetsIn: 3600, period: 5 * 3600, model: "Gemini 3 Pro")])),
            .gemini: .ready(reading(.gemini, plan: nil, [window("pro", .vendor("Pro"), used: 0, resetsIn: 86400, model: "gemini-3-pro")])),
            .copilot: .ready(reading(.copilot, plan: "Pro+", [window("premium", "Premium requests", used: 0.5, resetsIn: 10 * 86400, period: 30 * 86400)])),
        ]
    }

    @Test func everyToolGetsOneEntryInTheOrderGiven() throws {
        let order: [ToolID] = [.codex, .cursor, .antigravity, .gemini, .copilot]
        let report = UsageReport(tools: fiveTools, order: order, cost: nil, advice: [], now: now)
        let list = try tools(report)
        #expect(list.compactMap { $0["tool"] as? String } == order.map(\.rawValue))
        #expect(list.allSatisfy { $0["status"] as? String == "ready" })
        #expect(list.allSatisfy { $0["stale"] as? Bool == false })
        #expect(try entry(list, .antigravity)["name"] as? String == "Antigravity")
    }

    @Test func aToolMissingFromTheStatusesIsLeftOutRatherThanInvented() throws {
        var statuses = fiveTools
        statuses[.gemini] = nil
        let list = try tools(UsageReport(tools: statuses, order: [.codex, .gemini, .copilot], cost: nil, advice: [], now: now))
        #expect(list.compactMap { $0["tool"] as? String } == ["codex", "copilot"])
    }

    @Test func eachWindowCarriesItsIdLabelFractionAndReset() throws {
        let list = try tools(UsageReport(tools: fiveTools, order: [.codex], cost: nil, advice: [], now: now))
        let codex = try entry(list, .codex)
        #expect(codex["plan"] as? String == "Plus")
        let windows = try #require(codex["windows"] as? [[String: Any]])
        #expect(windows.compactMap { $0["id"] as? String } == ["five_hour", "weekly"])
        #expect(windows.compactMap { $0["label"] as? String } == ["Session", "Weekly"])
        #expect(JSON.number(windows[0]["usedFraction"]) == 0.42)
        #expect(windows[0]["resetsAt"] as? String == "2026-10-07T14:00:00.000Z")
        #expect(windows[0]["periodDuration"] as? Int == 5 * 3600)
        #expect(windows[0]["source"] as? String == "vendorEndpoint")
        #expect(windows[0]["hiddenByDefault"] as? Bool == false)
    }

    @Test func aVendorsModelAndLabelPassThroughUntranslated() throws {
        let list = try tools(UsageReport(tools: fiveTools, order: [.gemini, .antigravity], cost: nil, advice: [], now: now))
        let gemini = try #require((try entry(list, .gemini)["windows"] as? [[String: Any]])?.first)
        #expect(gemini["label"] as? String == "Pro")
        #expect(gemini["model"] as? String == "gemini-3-pro")
        #expect(JSON.number(gemini["usedFraction"]) == 0, "an exhausted-to-untouched zero is a number, not a missing figure")
        let antigravity = try #require((try entry(list, .antigravity)["windows"] as? [[String: Any]])?.first)
        #expect(antigravity["model"] as? String == "Gemini 3 Pro")
    }

    @Test func aWindowWithNoFigureIsNullNotZero() throws {
        let status = ToolStatus.ready(reading(.cursor, plan: "Business", [window("spend", "Spend", used: nil, resetsIn: nil)]))
        let list = try tools(UsageReport(tools: [.cursor: status], order: [.cursor], cost: nil, advice: [], now: now))
        let only = try #require((try entry(list, .cursor)["windows"] as? [[String: Any]])?.first)
        #expect(only["usedFraction"] is NSNull)
        #expect(only["resetsAt"] is NSNull)
    }

    @Test func fractionsAreWrittenAsShortDecimalsNotBinaryDoubles() throws {
        let status = ToolStatus.ready(reading(.copilot, plan: nil, [window("premium", "Premium requests", used: 0.1 + 0.2)]))
        let text = String(decoding: UsageReport(tools: [.copilot: status], order: [.copilot], cost: nil, advice: [], now: now).json, as: UTF8.self)
        #expect(text.contains("\"usedFraction\" : 0.3"))
        #expect(!text.contains("0.30000000000000004"))
    }

    @Test func theJSONIsSchemaVersionedAndSortedSoItDiffs() throws {
        let report = UsageReport(tools: fiveTools, order: [.codex, .copilot], cost: nil, advice: [], now: now)
        let object = try #require(try JSONSerialization.jsonObject(with: report.json) as? [String: Any])
        #expect(object["schema"] as? String == "notchmeter.limits.v1")
        #expect(object["generatedAt"] as? String == "2026-10-07T12:00:00.000Z")
        #expect(report.json == report.json)
        let text = String(decoding: report.json, as: UTF8.self)
        let keys = ["\"advice\"", "\"exitCode\"", "\"generatedAt\"", "\"schema\"", "\"sessions\"", "\"tools\""]
        let positions = try keys.map { try #require(text.range(of: $0)?.lowerBound) }
        #expect(positions == positions.sorted())
    }

    // MARK: - Exit codes

    @Test func theExitCodeFollowsTheTightestWindowAcrossTools() {
        func code(_ statuses: [ToolID: ToolStatus]) -> UsageReport.ExitCode {
            UsageReport(tools: statuses, order: Array(statuses.keys), cost: nil, advice: [], now: now).exitCode
        }
        #expect(code([:]) == .noData)
        #expect(code([.codex: .needsAttention("Sign in", cached: nil), .gemini: .notInstalled]) == .noData)
        #expect(code([.codex: .ready(reading(.codex, plan: nil, [window("w", "Weekly", used: 0, resetsIn: 86400)])),
                      .cursor: .ready(reading(.cursor, plan: nil, [window("m", "Monthly", used: 0, resetsIn: 86400)]))]) == .noSession)
        #expect(code([.copilot: .ready(reading(.copilot, plan: nil, [window("m", "Monthly", used: 0.3, resetsIn: 86400 * 20)]))]) != .noData)
        #expect(code([.antigravity: .ready(reading(.antigravity, plan: nil, [window("s", "Session", used: 0.85, resetsIn: 3600)]))]) == .nearLimit)
        #expect(code([.codex: .ready(reading(.codex, plan: nil, [window("s", "Session", used: 0.2, resetsIn: 3600)])),
                      .gemini: .ready(reading(.gemini, plan: nil, [window("p", "Pro", used: 1, resetsIn: 3600)]))]) == .limitHit)
    }

    @Test func aWindowWithoutAFigureNeverCountsTowardTheExitCode() {
        let status = ToolStatus.ready(reading(.cursor, plan: nil, [window("spend", "Spend", used: nil)]))
        #expect(UsageReport(tools: [.cursor: status], order: [.cursor], cost: nil, advice: [], now: now).exitCode == .noData)
    }

    // MARK: - Needs attention

    @Test func aRefusedLoginReadsNeedsAttentionWithItsStaleReadingKept() throws {
        let cached = reading(.antigravity, plan: "AI Pro", [window("session", "Session", used: 0.4)])
        let status = ToolStatus(.tokenExpired("Antigravity's login has expired"), cached: cached)
        let list = try tools(UsageReport(tools: [.antigravity: status], order: [.antigravity], cost: nil, advice: [], now: now))
        let entry = try entry(list, .antigravity)
        #expect(entry["status"] as? String == "needsAttention")
        #expect(entry["problem"] as? String == "Antigravity's login has expired")
        #expect(entry["stale"] as? Bool == true)
        #expect((entry["windows"] as? [[String: Any]])?.count == 1)
    }

    @Test func aColdNeedsAttentionHasAProblemAndNoWindows() throws {
        let status = ToolStatus(.notSignedIn("Sign in to Codex (run `codex login`) to read your usage"), cached: nil)
        let entry = try entry(try tools(UsageReport(tools: [.codex: status], order: [.codex], cost: nil, advice: [], now: now)), .codex)
        #expect(entry["status"] as? String == "needsAttention")
        #expect(entry["problem"] as? String == "Sign in to Codex (run `codex login`) to read your usage")
        #expect(entry["windows"] == nil)
        #expect(entry["stale"] == nil)
    }

    @Test func aCalmStateIsIdleWithANoteAndNoProblem() throws {
        let status = ToolStatus(.notServed("Google no longer serves Gemini CLI quota for personal accounts"), cached: nil)
        let entry = try entry(try tools(UsageReport(tools: [.gemini: status], order: [.gemini], cost: nil, advice: [], now: now)), .gemini)
        #expect(entry["status"] as? String == "idle")
        #expect(entry["note"] as? String == "Google no longer serves Gemini CLI quota for personal accounts")
        #expect(entry["problem"] is NSNull)
    }

    @Test func everyProviderErrorIsClassifiedAsExactlyOneKind() {
        let errors: [(ProviderError, attention: Bool, calm: Bool)] = [
            (.notSignedIn("x"), true, false), (.tokenExpired("x"), true, false), (.accessDenied("x"), true, false),
            (.parse("x"), false, false), (.unavailable("x"), false, false), (.offline("x"), false, false),
            (.rateLimited(retryAfter: nil), false, false), (.rateLimited(retryAfter: 90), false, false),
            (.http(401, "x"), true, false), (.http(403, "x"), true, false),
            (.http(400, "x"), false, false), (.http(404, "x"), false, false), (.http(500, "x"), false, false), (.http(0, "x"), false, false),
            (.nothingYet("x"), false, true), (.apiKeyOnly("x"), false, true), (.notServed("x"), false, true),
        ]
        for (error, attention, calm) in errors {
            #expect(error.needsAttention == attention, "\(error)")
            #expect(error.isCalm == calm, "\(error)")
            #expect(!(error.needsAttention && error.isCalm), "a state is a fault to fix or a calm one, never both: \(error)")
        }
    }

    @Test func anUnclassifiedRefusalStillAsksForASignInRatherThanRetrying() {
        let cached = reading(.copilot, plan: nil, [window("m", "Monthly", used: 0.3)])
        #expect(ToolStatus(.http(401, "GitHub's Copilot endpoint answered"), cached: cached)
                == .needsAttention("GitHub's Copilot endpoint answered (HTTP 401)", cached: cached))
        #expect(ToolStatus(.http(403, "Codex usage endpoint answered"), cached: nil) == .needsAttention("Codex usage endpoint answered (HTTP 403)", cached: nil))
        #expect(ToolStatus(.http(503, "Cursor usage endpoint answered"), cached: nil) == .failed("Cursor usage endpoint answered (HTTP 503)", cached: nil))
    }

    @Test func aTransportFailureIsOfflineNeverNeedsAttention() {
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed, .timedOut] {
            let error = ProviderError.offline(from: URLError(code))
            #expect(error?.needsAttention == false)
            #expect(error.map { ToolStatus($0, cached: nil) } == .offline(cached: nil))
        }
        #expect(ProviderError.offline(from: URLError(.badServerResponse)) == nil)
        #expect(ProviderError.offline(from: URLError(.userAuthenticationRequired)) == nil)
    }
}
