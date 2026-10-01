import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "chatgpt")

/// ChatGPT Plus/Pro chat usage — John's priority assistant.
///
/// Distinct from Codex (ToolID.codex): Codex already meters chatgpt.com's *codex* usage page. This provider is for
/// the ChatGPT chat product, which John runs with **four weekly usage resets**. Until OpenAI's chat usage endpoint
/// or the desktop app's local store is reverse-documented, this provider only detects installation and surfaces a
/// structured "nothing yet" fault that names the four weekly windows the Advisor will prioritize once readings exist
/// (see docs/john-providers.md and Advisor.chatGPTBurnAdvice).
///
/// Detection on John's MacBook Pro (2026-10-01): `/Applications/ChatGPT.app` (bundle id currently `com.openai.codex`),
/// crash-reporter breadcrumbs, and OpenAI Application Support. Presence ≠ usable chat usage numbers.
struct ChatGPTProvider: UsageProvider {
    let tool: ToolID = .chatgpt
    /// Poll often once a real endpoint exists; while stubbed, stay calm.
    let refreshInterval: TimeInterval = 300
    let home: URL
    let applications: URL

    /// The four weekly reset windows John burns through — ids the Advisor and future parser share.
    static let weeklyWindowIDs = ["chatgpt_week_1", "chatgpt_week_2", "chatgpt_week_3", "chatgpt_week_4"]

    init(home: URL = Paths.home, applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.home = home
        self.applications = applications
    }

    var appBundle: URL { applications.appendingPathComponent("ChatGPT.app") }
    var openAISupport: URL { home.appendingPathComponent("Library/Application Support/OpenAI") }
    var crashReporterHint: URL {
        home.appendingPathComponent("Library/Application Support/CrashReporter")
    }

    func isInstalled() -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: appBundle.path) { return true }
        if fm.fileExists(atPath: openAISupport.path) { return true }
        // CrashReporter leaves ChatGPT_*.plist after the desktop app has run.
        if let names = try? fm.contentsOfDirectory(atPath: crashReporterHint.path),
           names.contains(where: { $0.hasPrefix("ChatGPT_") }) {
            return true
        }
        return false
    }

    func fetch() async throws -> UsageReading {
        DiagnosticLog.request(log, "chatgpt-stub", status: 0, bytes: 0)
        // Prefer best models when Sol / Astra / Luna exist as tools; until then, burn empty ChatGPT weeks first.
        throw ProviderError.nothingYet(L("ChatGPT is on this Mac, but its four weekly chat resets are not readable yet. Prefer burning empty ChatGPT weeks before other platforms; when Sol 5.6, Astra or Luna tools exist, prefer those models. See docs/john-providers.md."))
    }

    /// Placeholder windows for tests / future wiring: four equal weekly slots, unused.
    static func stubWindows(now: Date = Date()) -> [LimitWindow] {
        weeklyWindowIDs.enumerated().map { index, id in
            LimitWindow(id: id, label: .filled("Weekly reset %ld", [.number(index + 1)]), usedFraction: 0,
                        resetsAt: now.addingTimeInterval(Period.week), periodDuration: Period.week,
                        source: .localEstimate, hiddenByDefault: false)
        }
    }
}
