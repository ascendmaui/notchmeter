import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "chatgpt")

/// ChatGPT Plus/Pro chat usage — John's priority assistant.
///
/// Distinct from Codex (ToolID.codex): Codex meters chatgpt.com's *codex* usage page. This provider is for
/// the ChatGPT chat product, which John runs with **four weekly usage resets**.
///
/// Under John's priority routing, ChatGPT-heavy work is routed first to empty weekly resets before other platforms,
/// and Sol 5.6, Astra or Luna are preferred for best-quality work when those models exist (see docs/john-providers.md
/// and Advisor.johnRouting).
///
/// Detection: `/Applications/ChatGPT.app` (bundle id currently `com.openai.codex`),
/// `~/Library/Application Support/OpenAI`, crash-reporter hints, and defaults for `com.openai.codex`.
/// Local usage overrides can be supplied via `NOTCHMETER_CHATGPT_USAGE` environment variable (comma-separated
/// fractions, e.g. "0.0,0.1,0.0,0.0") or `chatgpt-usage.json` in OpenAI / Notchmeter Application Support.
struct ChatGPTProvider: UsageProvider {
    let tool: ToolID = .chatgpt
    let refreshInterval: TimeInterval = 300
    let home: URL
    let applications: URL

    /// The four weekly reset windows John burns through — ids the Advisor and parser share.
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
        if ProcessInfo.processInfo.environment["NOTCHMETER_CHATGPT_USAGE"] != nil {
            return true
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: appBundle.path) { return true }
        if fm.fileExists(atPath: openAISupport.path) { return true }
        if let names = try? fm.contentsOfDirectory(atPath: crashReporterHint.path),
           names.contains(where: { $0.hasPrefix("ChatGPT_") }) {
            return true
        }
        if UserDefaults(suiteName: "com.openai.codex")?.object(forKey: "LastRunAppBundlePath") != nil {
            return true
        }
        return false
    }

    func fetch() async throws -> UsageReading {
        DiagnosticLog.request(log, "chatgpt-probe", status: 200, bytes: 0)
        let now = Date()
        let observed = lastLaunchedAt()
        let windows = loadWindows(now: now)
        return UsageReading(tool: tool,
                            windows: windows,
                            plan: "Plus/Pro (4 weekly resets)",
                            fetchedAt: now,
                            observedAt: observed)
    }

    /// Placeholder windows for tests / future wiring: four equal weekly slots, unused.
    static func stubWindows(now: Date = Date(), customOffsets: [TimeInterval]? = nil) -> [LimitWindow] {
        weeklyWindowIDs.enumerated().map { index, id in
            let resetOffset = (customOffsets != nil && index < customOffsets!.count)
                ? customOffsets![index]
                : Double(index + 1) * (Period.week / 4.0) + Period.week / 2.0
            return LimitWindow(id: id,
                               label: .filled("Weekly reset %ld", [.number(index + 1)]),
                               usedFraction: 0,
                               resetsAt: now.addingTimeInterval(resetOffset),
                               note: L("Four weekly resets reserved; prefer burning empty weeks before other platforms"),
                               periodDuration: Period.week,
                               source: .localEstimate,
                               hiddenByDefault: false)
        }
    }

    /// Loads the four weekly windows from env override, local json file, or defaults to stub windows.
    func loadWindows(now: Date = Date()) -> [LimitWindow] {
        var customOffsets: [TimeInterval]?
        if let resetEnv = ProcessInfo.processInfo.environment["NOTCHMETER_CHATGPT_RESET_HOURS"] {
            let hours = resetEnv.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if !hours.isEmpty {
                customOffsets = hours.map { $0 * 3600 }
            }
        }

        // 1. Check environment variable override: NOTCHMETER_CHATGPT_USAGE="0.0,0.1,0.0,0.0"
        if let env = ProcessInfo.processInfo.environment["NOTCHMETER_CHATGPT_USAGE"] {
            let fractions = env.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if !fractions.isEmpty {
                return Self.weeklyWindowIDs.enumerated().map { index, id in
                    let used = index < fractions.count ? min(max(fractions[index], 0), 1) : 0
                    let resetOffset = (customOffsets != nil && index < customOffsets!.count)
                        ? customOffsets![index]
                        : Double(index + 1) * (Period.week / 4.0) + Period.week / 2.0
                    return LimitWindow(id: id,
                                       label: .filled("Weekly reset %ld", [.number(index + 1)]),
                                       usedFraction: used,
                                       resetsAt: now.addingTimeInterval(resetOffset),
                                       note: L("Configured via NOTCHMETER_CHATGPT_USAGE"),
                                       periodDuration: Period.week,
                                       source: .localEstimate,
                                       hiddenByDefault: false)
                }
            }
        }

        // 2. Check local usage file: ~/Library/Application Support/OpenAI/chatgpt-usage.json
        let fileCandidates = [
            openAISupport.appendingPathComponent("chatgpt-usage.json"),
            Paths.applicationSupport.appendingPathComponent("chatgpt-usage.json")
        ]
        for file in fileCandidates {
            if let data = try? Data(contentsOf: file),
               let parsed = try? Self.parseUsageFile(data, now: now) {
                return parsed
            }
        }

        // 3. Fallback to stub windows (empty, ready for heavy burn)
        return Self.stubWindows(now: now, customOffsets: customOffsets)
    }

    /// Parses a custom chatgpt-usage.json file.
    static func parseUsageFile(_ data: Data, now: Date = Date()) throws -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse(L("ChatGPT usage file unreadable"))
        }
        var windows: [LimitWindow] = []
        if let weeks = root["weeks"] as? [Double] {
            windows = weeklyWindowIDs.enumerated().map { index, id in
                let used = index < weeks.count ? min(max(weeks[index], 0), 1) : 0
                return LimitWindow(id: id,
                                   label: .filled("Weekly reset %ld", [.number(index + 1)]),
                                   usedFraction: used,
                                   resetsAt: now.addingTimeInterval(Double(index + 1) * (Period.week / 4.0) + Period.week / 2.0),
                                   periodDuration: Period.week,
                                   source: .localSnapshot,
                                   hiddenByDefault: false)
            }
        } else if let windowObjs = root["windows"] as? [[String: Any]] {
            for (index, obj) in windowObjs.prefix(4).enumerated() {
                let id = (obj["id"] as? String) ?? weeklyWindowIDs[min(index, 3)]
                let used = JSON.number(obj["usedFraction"]) ?? 0
                let resets = (obj["resetsAt"] as? String).flatMap(DateParsing.iso8601)
                    ?? now.addingTimeInterval(Double(index + 1) * (Period.week / 4.0) + Period.week / 2.0)
                windows.append(LimitWindow(id: id,
                                           label: .filled("Weekly reset %ld", [.number(index + 1)]),
                                           usedFraction: min(max(used, 0), 1),
                                           resetsAt: resets,
                                           periodDuration: Period.week,
                                           source: .localSnapshot,
                                           hiddenByDefault: false))
            }
        }
        return windows.isEmpty ? stubWindows(now: now) : windows
    }

    /// Retrieves last launch timestamp from com.openai.codex user defaults if available.
    func lastLaunchedAt() -> Date? {
        let defaults = UserDefaults(suiteName: "com.openai.codex")
        if let time = defaults?.object(forKey: "SULastCheckTime") as? Date {
            return time
        }
        return nil
    }
}
