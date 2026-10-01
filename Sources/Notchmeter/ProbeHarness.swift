import Foundation
import os

/// Comprehensive inspection and diagnostic harness for all Notchmeter providers.
///
/// Probes provider installation states, audits filesystem detection paths, tests fetch outcomes
/// (including stub error handling for John providers: ChatGPT, Grok, Hermes, OpenClaw), analyzes
/// ChatGPT-heavy metrics, and evaluates Advisor routing decisions in both live and synthetic environments.
enum ProbeHarness {
    struct PathStatus: Equatable, Sendable {
        let path: String
        let exists: Bool
        let kind: String
        let isDirectory: Bool
    }

    enum FetchOutcome: Equatable, Sendable {
        case ready(windowsCount: Int, plan: String?)
        case stub(message: String)
        case rateLimited(message: String)
        case notInstalled
        case failure(message: String)

        var description: String {
            switch self {
            case .ready(let count, let plan):
                return "ready (\(count) window(s)\(plan.map { ", \($0)" } ?? ""))"
            case .stub(let message):
                return "stub: \(message)"
            case .rateLimited(let message):
                return "rate limited: \(message)"
            case .notInstalled:
                return "not installed"
            case .failure(let message):
                return "failed: \(message)"
            }
        }
    }

    struct ProviderProbeResult: Equatable, Sendable {
        let tool: ToolID
        let displayName: String
        let isInstalled: Bool
        let paths: [PathStatus]
        let outcome: FetchOutcome
        let latencyMs: Double
        let chatGPTMetrics: ChatGPTHeavyMetrics?
    }

    struct ProbeReport: Sendable {
        let timestamp: Date
        let environment: String
        let results: [ProviderProbeResult]
        let advice: [Advice]

        var installedTools: [ToolID] {
            results.filter(\.isInstalled).map(\.tool)
        }

        var stubTools: [ToolID] {
            results.filter {
                if case .stub = $0.outcome { return true }
                return false
            }.map(\.tool)
        }

        var chatGPTMetrics: ChatGPTHeavyMetrics? {
            results.first(where: { $0.tool == .chatgpt })?.chatGPTMetrics
        }

        var dictionary: [String: Any] {
            [
                "timestamp": Oracle.timestamp(timestamp),
                "environment": environment,
                "installedCount": installedTools.count,
                "installedTools": installedTools.map(\.rawValue),
                "stubCount": stubTools.count,
                "stubTools": stubTools.map(\.rawValue),
                "advice": advice.map { [
                    "id": $0.id,
                    "priority": String(describing: $0.priority),
                    "tool": $0.tool?.rawValue as Any,
                    "text": $0.text
                ] },
                "providers": results.map { res in
                    var pDict: [String: Any] = [
                        "tool": res.tool.rawValue,
                        "name": res.displayName,
                        "isInstalled": res.isInstalled,
                        "outcome": res.outcome.description,
                        "latencyMs": res.latencyMs,
                        "paths": res.paths.map { [
                            "path": $0.path,
                            "exists": $0.exists,
                            "kind": $0.kind,
                            "isDirectory": $0.isDirectory
                        ] }
                    ]
                    if let metrics = res.chatGPTMetrics {
                        pDict["chatgptHeavyMetrics"] = metrics.dictionary
                    }
                    return pDict
                }
            ]
        }

        var json: Data {
            (try? JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        }

        var summaryText: String {
            var lines: [String] = []
            lines.append("=== Notchmeter Probe Harness Report (\(environment)) ===")
            lines.append("Timestamp: \(Oracle.timestamp(timestamp))")
            lines.append("Installed: \(installedTools.count)/\(results.count) providers")
            lines.append("Stubs: \(stubTools.map(\.displayName).joined(separator: ", "))")
            lines.append("")
            lines.append("Providers:")
            for res in results {
                let mark = res.isInstalled ? "✓" : "✗"
                lines.append("  [\(mark)] \(res.displayName) (\(res.tool.rawValue)): \(res.outcome.description) (\(String(format: "%.1f", res.latencyMs))ms)")
                for p in res.paths {
                    let pMark = p.exists ? "found" : "missing"
                    lines.append("      - \(p.kind): \(p.path) [\(pMark)]")
                }
            }
            if let metrics = chatGPTMetrics {
                lines.append("")
                lines.append("ChatGPT Heavy Metrics:")
                lines.append("  \(metrics.summaryText)")
            }
            if !advice.isEmpty {
                lines.append("")
                lines.append("Advisor Recommendations:")
                for adv in advice {
                    lines.append("  [\(adv.priority)] \(adv.text)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Path Inspection Helpers

    static func inspectPath(_ url: URL, kind: String, fm: FileManager = .default) -> PathStatus {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        return PathStatus(path: url.path, exists: exists, kind: kind, isDirectory: isDir.boolValue)
    }

    static func detectCrashReporterPlists(in crashDir: URL, prefix: String, fm: FileManager = .default) -> PathStatus {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: crashDir.path, isDirectory: &isDir)
        var foundPlist = false
        if exists, let files = try? fm.contentsOfDirectory(atPath: crashDir.path) {
            foundPlist = files.contains { $0.hasPrefix(prefix) && $0.hasSuffix(".plist") }
        }
        return PathStatus(
            path: crashDir.appendingPathComponent("\(prefix)*.plist").path,
            exists: foundPlist,
            kind: "CrashReporter Breadcrumb",
            isDirectory: false
        )
    }

    // MARK: - Live Probe

    /// Probes all providers on this Mac with path inspection, live fetch execution, and Advisor routing.
    static func probeAll(
        home: URL = Paths.home,
        applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        now: Date = Date()
    ) async -> ProbeReport {
        let fm = FileManager.default
        var results: [ProviderProbeResult] = []
        var gatheredReadings: [UsageReading] = []

        for tool in ToolID.allCases {
            var paths: [PathStatus] = []
            var isInstalled = false
            var outcome: FetchOutcome = .notInstalled
            var chatgptMetrics: ChatGPTHeavyMetrics? = nil

            let start = DispatchTime.now()

            switch tool {
            case .chatgpt:
                let p = ChatGPTProvider(home: home, applications: applications)
                paths.append(inspectPath(p.appBundle, kind: "Application Bundle", fm: fm))
                paths.append(inspectPath(p.openAISupport, kind: "OpenAI Support Directory", fm: fm))
                paths.append(detectCrashReporterPlists(in: p.crashReporterHint, prefix: "ChatGPT_", fm: fm))
                isInstalled = p.isInstalled()
                if isInstalled {
                    do {
                        let reading = try await p.fetch()
                        outcome = .ready(windowsCount: reading.windows.count, plan: reading.plan)
                        gatheredReadings.append(reading)
                        chatgptMetrics = reading.chatGPTHeavyMetrics
                    } catch let err as ProviderError {
                        if case .nothingYet(let msg) = err {
                            outcome = .stub(message: msg)
                        } else {
                            outcome = .failure(message: err.message)
                        }
                    } catch {
                        outcome = .failure(message: error.localizedDescription)
                    }
                }

            case .grok:
                let p = GrokProvider(home: home, applications: applications)
                paths.append(inspectPath(p.appBundle, kind: "Application Bundle", fm: fm))
                paths.append(inspectPath(p.supportDirectory, kind: "Grok Bot Support Directory", fm: fm))
                paths.append(inspectPath(p.buildSupport, kind: "Grok Build Support Directory", fm: fm))
                isInstalled = p.isInstalled()
                if isInstalled {
                    do {
                        let reading = try await p.fetch()
                        outcome = .ready(windowsCount: reading.windows.count, plan: reading.plan)
                        gatheredReadings.append(reading)
                    } catch let err as ProviderError {
                        if case .nothingYet(let msg) = err {
                            outcome = .stub(message: msg)
                        } else {
                            outcome = .failure(message: err.message)
                        }
                    } catch {
                        outcome = .failure(message: error.localizedDescription)
                    }
                }

            case .hermes:
                let p = HermesProvider(home: home)
                paths.append(inspectPath(p.supportDirectory, kind: "Hermes Support Directory", fm: fm))
                isInstalled = p.isInstalled()
                if isInstalled {
                    do {
                        let reading = try await p.fetch()
                        outcome = .ready(windowsCount: reading.windows.count, plan: reading.plan)
                        gatheredReadings.append(reading)
                    } catch let err as ProviderError {
                        if case .nothingYet(let msg) = err {
                            outcome = .stub(message: msg)
                        } else {
                            outcome = .failure(message: err.message)
                        }
                    } catch {
                        outcome = .failure(message: error.localizedDescription)
                    }
                }

            case .openclaw:
                let p = OpenClawProvider(home: home, applications: applications)
                paths.append(inspectPath(p.supportDirectory, kind: "OpenClaw Support Directory", fm: fm))
                paths.append(inspectPath(p.dashboardSupport, kind: "OpenClaw Dashboard Support", fm: fm))
                paths.append(inspectPath(p.dashboardApp, kind: "OpenClaw Dashboard App", fm: fm))
                isInstalled = p.isInstalled()
                if isInstalled {
                    do {
                        let reading = try await p.fetch()
                        outcome = .ready(windowsCount: reading.windows.count, plan: reading.plan)
                        gatheredReadings.append(reading)
                    } catch let err as ProviderError {
                        if case .nothingYet(let msg) = err {
                            outcome = .stub(message: msg)
                        } else {
                            outcome = .failure(message: err.message)
                        }
                    } catch {
                        outcome = .failure(message: error.localizedDescription)
                    }
                }

            default:
                // Standard providers in registry
                if let provider = ProviderRegistry.all().first(where: { $0.tool == tool }) {
                    isInstalled = provider.isInstalled()
                    if isInstalled {
                        do {
                            let reading = try await provider.fetch()
                            outcome = .ready(windowsCount: reading.windows.count, plan: reading.plan)
                            gatheredReadings.append(reading)
                        } catch let err as ProviderError {
                            if case .nothingYet(let msg) = err {
                                outcome = .stub(message: msg)
                            } else if case .rateLimited = err {
                                outcome = .rateLimited(message: err.message)
                            } else {
                                outcome = .failure(message: err.message)
                            }
                        } catch {
                            outcome = .failure(message: error.localizedDescription)
                        }
                    }
                }
            }

            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            let latencyMs = Double(elapsedNs) / 1_000_000.0

            results.append(ProviderProbeResult(
                tool: tool,
                displayName: tool.displayName,
                isInstalled: isInstalled,
                paths: paths,
                outcome: outcome,
                latencyMs: latencyMs,
                chatGPTMetrics: chatgptMetrics
            ))
        }

        let context = Advisor.Context(readings: gatheredReadings, now: now)
        var advice = Advisor.advise(context)
        for line in Advisor.johnRouting(context) where !advice.contains(where: { $0.id == line.id }) {
            advice.append(line)
        }

        return ProbeReport(
            timestamp: now,
            environment: "live",
            results: results,
            advice: advice
        )
    }

    // MARK: - Simulation Harness

    enum SimulationScenario {
        /// All John providers stubbed; ChatGPT unmetered (nothingYet).
        case freshStubs
        /// ChatGPT has 4 weekly resets completely unused (100% capacity).
        case chatGPTPristine
        /// ChatGPT has 2 empty weeks (<15%), 1 active (50%), 1 exhausted (95%).
        case chatGPTStaggered
        /// All 4 ChatGPT weekly resets exhausted (>=90%).
        case chatGPTExhausted
    }

    static func runSimulation(scenario: SimulationScenario, now: Date = Date()) -> ProbeReport {
        var gatheredReadings: [UsageReading] = []
        var results: [ProviderProbeResult] = []

        for tool in ToolID.allCases {
            var isInstalled = false
            var outcome: FetchOutcome = .notInstalled
            var paths: [PathStatus] = []
            var metrics: ChatGPTHeavyMetrics? = nil

            switch tool {
            case .chatgpt:
                isInstalled = true
                paths.append(PathStatus(path: "/Applications/ChatGPT.app", exists: true, kind: "Application Bundle", isDirectory: true))
                switch scenario {
                case .freshStubs:
                    outcome = .stub(message: "ChatGPT is on this Mac, but its four weekly chat resets are not readable yet.")
                case .chatGPTPristine:
                    let windows = ChatGPTProvider.stubWindows(now: now)
                    let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
                    outcome = .ready(windowsCount: windows.count, plan: "Pro")
                    gatheredReadings.append(reading)
                    metrics = reading.chatGPTHeavyMetrics
                case .chatGPTStaggered:
                    let windows: [LimitWindow] = [
                        LimitWindow(id: "chatgpt_week_1", label: "Weekly reset 1", usedFraction: 0.95, resetsAt: now.addingTimeInterval(86400 * 5), periodDuration: Period.week, source: .localEstimate),
                        LimitWindow(id: "chatgpt_week_2", label: "Weekly reset 2", usedFraction: 0.05, resetsAt: now.addingTimeInterval(86400 * 1), periodDuration: Period.week, source: .localEstimate),
                        LimitWindow(id: "chatgpt_week_3", label: "Weekly reset 3", usedFraction: 0.50, resetsAt: now.addingTimeInterval(86400 * 6), periodDuration: Period.week, source: .localEstimate),
                        LimitWindow(id: "chatgpt_week_4", label: "Weekly reset 4", usedFraction: 0.08, resetsAt: now.addingTimeInterval(86400 * 3), periodDuration: Period.week, source: .localEstimate),
                    ]
                    let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
                    outcome = .ready(windowsCount: windows.count, plan: "Pro")
                    gatheredReadings.append(reading)
                    metrics = reading.chatGPTHeavyMetrics
                case .chatGPTExhausted:
                    let windows: [LimitWindow] = [
                        LimitWindow(id: "chatgpt_week_1", label: "Weekly reset 1", usedFraction: 0.95, resetsAt: now.addingTimeInterval(86400 * 1), periodDuration: Period.week, source: .localEstimate),
                        LimitWindow(id: "chatgpt_week_2", label: "Weekly reset 2", usedFraction: 0.92, resetsAt: now.addingTimeInterval(86400 * 2), periodDuration: Period.week, source: .localEstimate),
                        LimitWindow(id: "chatgpt_week_3", label: "Weekly reset 3", usedFraction: 0.91, resetsAt: now.addingTimeInterval(86400 * 3), periodDuration: Period.week, source: .localEstimate),
                        LimitWindow(id: "chatgpt_week_4", label: "Weekly reset 4", usedFraction: 0.94, resetsAt: now.addingTimeInterval(86400 * 4), periodDuration: Period.week, source: .localEstimate),
                    ]
                    let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus", fetchedAt: now, observedAt: nil)
                    outcome = .ready(windowsCount: windows.count, plan: "Plus")
                    gatheredReadings.append(reading)
                    metrics = reading.chatGPTHeavyMetrics
                }

            case .grok:
                isInstalled = true
                paths.append(PathStatus(path: "/Applications/Grok Bot.app", exists: true, kind: "Application Bundle", isDirectory: true))
                outcome = .stub(message: "Grok / xAI is on this Mac, but standalone plan usage is not readable yet.")

            case .hermes:
                isInstalled = true
                paths.append(PathStatus(path: "/Users/test/Library/Application Support/Hermes", exists: true, kind: "Hermes Support Directory", isDirectory: true))
                outcome = .stub(message: "Hermes is on this Mac, but its usage store is not mapped yet.")

            case .openclaw:
                isInstalled = true
                paths.append(PathStatus(path: "/Applications/OpenClaw Dashboard.app", exists: true, kind: "OpenClaw Dashboard App", isDirectory: true))
                outcome = .stub(message: "OpenClaw is on this Mac, but its usage store is not mapped yet.")

            default:
                break
            }

            results.append(ProviderProbeResult(
                tool: tool,
                displayName: tool.displayName,
                isInstalled: isInstalled,
                paths: paths,
                outcome: outcome,
                latencyMs: 1.0,
                chatGPTMetrics: metrics
            ))
        }

        let context = Advisor.Context(readings: gatheredReadings, now: now)
        var advice = Advisor.advise(context)
        for line in Advisor.johnRouting(context) where !advice.contains(where: { $0.id == line.id }) {
            advice.append(line)
        }

        return ProbeReport(
            timestamp: now,
            environment: "simulation-\(scenario)",
            results: results,
            advice: advice
        )
    }
}
