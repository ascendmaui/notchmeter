import Foundation
import Testing
@testable import Notchmeter

@Suite struct JohnProvidersTests {
    // MARK: - Temp dir helpers

    private func withTempDirs(_ body: (URL, URL) throws -> Void) rethrows {
        let fm = FileManager.default
        let id = UUID().uuidString
        let home = fm.temporaryDirectory.appendingPathComponent("notchmeter-test-home-\(id)")
        let apps = fm.temporaryDirectory.appendingPathComponent("notchmeter-test-apps-\(id)")
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        try? fm.createDirectory(at: apps, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: home)
            try? fm.removeItem(at: apps)
        }
        try body(home, apps)
    }

    // MARK: - General Provider & ToolID Tests

    @Test func johnToolIDsExistAndDoNotReportCost() {
        for tool in [ToolID.chatgpt, .grok, .hermes, .openclaw] {
            #expect(ToolID(rawValue: tool.rawValue) == tool)
            #expect(tool.reportsCost == false)
            #expect(!tool.displayName.isEmpty)
            #expect(!tool.productName.isEmpty)
            #expect(!tool.symbolName.isEmpty)
        }
    }

    @Test func providerRegistryIncludesJohnProviders() {
        let tools = Set(ProviderRegistry.all().map(\.tool))
        #expect(tools.contains(.chatgpt))
        #expect(tools.contains(.grok))
        #expect(tools.contains(.hermes))
        #expect(tools.contains(.openclaw))
    }

    // MARK: - ChatGPTProvider Tests

    @Test func chatGPTReservesFourWeeklyWindowIDs() {
        #expect(ChatGPTProvider.weeklyWindowIDs.count == 4)
        let now = Date()
        let windows = ChatGPTProvider.stubWindows(now: now)
        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0.usedFraction == 0 })
        #expect(windows.allSatisfy { $0.periodDuration == Period.week })
        #expect(windows.allSatisfy { $0.source == .localEstimate })
        #expect(windows.allSatisfy { !$0.hiddenByDefault })
        #expect(Set(windows.map(\.id)) == Set(ChatGPTProvider.weeklyWindowIDs))
        for (idx, w) in windows.enumerated() {
            #expect(w.id == "chatgpt_week_\(idx + 1)")
        }
    }

    @Test func chatGPTProviderPropertiesAndPaths() {
        let home = URL(fileURLWithPath: "/custom/home", isDirectory: true)
        let apps = URL(fileURLWithPath: "/custom/apps", isDirectory: true)
        let provider = ChatGPTProvider(home: home, applications: apps)
        #expect(provider.tool == .chatgpt)
        #expect(provider.refreshInterval == 300)
        #expect(provider.appBundle.path == "/custom/apps/ChatGPT.app")
        #expect(provider.openAISupport.path == "/custom/home/Library/Application Support/OpenAI")
        #expect(provider.crashReporterHint.path == "/custom/home/Library/Application Support/CrashReporter")
    }

    @Test func chatGPTProviderDetection() throws {
        let fm = FileManager.default
        try withTempDirs { home, apps in
            let provider = ChatGPTProvider(home: home, applications: apps)
            #expect(!provider.isInstalled(), "Not installed in empty dirs")

            // 1. App bundle detection
            let appBundle = apps.appendingPathComponent("ChatGPT.app")
            try fm.createDirectory(at: appBundle, withIntermediateDirectories: true)
            #expect(provider.isInstalled(), "Detected via ChatGPT.app")
            try fm.removeItem(at: appBundle)
            #expect(!provider.isInstalled())

            // 2. OpenAI Application Support detection
            let support = home.appendingPathComponent("Library/Application Support/OpenAI")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            #expect(provider.isInstalled(), "Detected via Application Support/OpenAI")
            try fm.removeItem(at: support)
            #expect(!provider.isInstalled())

            // 3. CrashReporter breadcrumb detection
            let crashDir = home.appendingPathComponent("Library/Application Support/CrashReporter")
            try fm.createDirectory(at: crashDir, withIntermediateDirectories: true)
            let unrelatedFile = crashDir.appendingPathComponent("OtherApp_2026-09-01.plist")
            try "plist".write(to: unrelatedFile, atomically: true, encoding: .utf8)
            #expect(!provider.isInstalled(), "Unrelated crash reporter file should not trigger install")

            let chatGPTCrash = crashDir.appendingPathComponent("ChatGPT_2026-10-01-080000.plist")
            try "plist".write(to: chatGPTCrash, atomically: true, encoding: .utf8)
            #expect(provider.isInstalled(), "Detected via CrashReporter/ChatGPT_*.plist")
        }
    }

    @Test func chatGPTProviderFetchThrowsNothingYet() async {
        let provider = ChatGPTProvider()
        do {
            _ = try await provider.fetch()
            Issue.record("Expected fetch() to throw ProviderError.nothingYet")
        } catch let error as ProviderError {
            guard case .nothingYet(let message) = error else {
                Issue.record("Expected .nothingYet but got: \(error)")
                return
            }
            #expect(message.contains("ChatGPT is on this Mac"))
            #expect(message.contains("four weekly chat resets"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - GrokProvider Tests

    @Test func grokProviderPropertiesAndPaths() {
        let home = URL(fileURLWithPath: "/custom/home", isDirectory: true)
        let apps = URL(fileURLWithPath: "/custom/apps", isDirectory: true)
        let provider = GrokProvider(home: home, applications: apps)
        #expect(provider.tool == .grok)
        #expect(provider.refreshInterval == 300)
        #expect(provider.appBundle.path == "/custom/apps/Grok Bot.app")
        #expect(provider.supportDirectory.path == "/custom/home/Library/Application Support/Grok Bot")
        #expect(provider.buildSupport.path == "/custom/home/Library/Application Support/Grok Build Desktop")
    }

    @Test func grokProviderDetection() throws {
        let fm = FileManager.default
        try withTempDirs { home, apps in
            let provider = GrokProvider(home: home, applications: apps)
            #expect(!provider.isInstalled())

            // 1. Grok Bot.app
            let app = apps.appendingPathComponent("Grok Bot.app")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
            try fm.removeItem(at: app)
            #expect(!provider.isInstalled())

            // 2. Grok Bot Application Support
            let support = home.appendingPathComponent("Library/Application Support/Grok Bot")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
            try fm.removeItem(at: support)
            #expect(!provider.isInstalled())

            // 3. Grok Build Desktop Application Support
            let buildSupport = home.appendingPathComponent("Library/Application Support/Grok Build Desktop")
            try fm.createDirectory(at: buildSupport, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
        }
    }

    @Test func grokProviderFetchThrowsNothingYet() async {
        let provider = GrokProvider()
        do {
            _ = try await provider.fetch()
            Issue.record("Expected fetch() to throw ProviderError.nothingYet")
        } catch let error as ProviderError {
            guard case .nothingYet(let message) = error else {
                Issue.record("Expected .nothingYet but got: \(error)")
                return
            }
            #expect(message.contains("Grok / xAI is on this Mac"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - HermesProvider Tests

    @Test func hermesProviderPropertiesAndPaths() {
        let home = URL(fileURLWithPath: "/custom/home", isDirectory: true)
        let provider = HermesProvider(home: home)
        #expect(provider.tool == .hermes)
        #expect(provider.refreshInterval == 300)
        #expect(provider.supportDirectory.path == "/custom/home/Library/Application Support/Hermes")
    }

    @Test func hermesProviderDetection() throws {
        let fm = FileManager.default
        try withTempDirs { home, _ in
            let provider = HermesProvider(home: home)
            #expect(!provider.isInstalled())

            let support = home.appendingPathComponent("Library/Application Support/Hermes")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
            try fm.removeItem(at: support)
            #expect(!provider.isInstalled())
        }
    }

    @Test func hermesProviderFetchThrowsNothingYet() async {
        let provider = HermesProvider()
        do {
            _ = try await provider.fetch()
            Issue.record("Expected fetch() to throw ProviderError.nothingYet")
        } catch let error as ProviderError {
            guard case .nothingYet(let message) = error else {
                Issue.record("Expected .nothingYet but got: \(error)")
                return
            }
            #expect(message.contains("Hermes is on this Mac"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - OpenClawProvider Tests

    @Test func openClawProviderPropertiesAndPaths() {
        let home = URL(fileURLWithPath: "/custom/home", isDirectory: true)
        let apps = URL(fileURLWithPath: "/custom/apps", isDirectory: true)
        let provider = OpenClawProvider(home: home, applications: apps)
        #expect(provider.tool == .openclaw)
        #expect(provider.refreshInterval == 300)
        #expect(provider.supportDirectory.path == "/custom/home/Library/Application Support/OpenClaw")
        #expect(provider.dashboardSupport.path == "/custom/home/Library/Application Support/openclaw-dashboard")
        #expect(provider.dashboardApp.path == "/custom/apps/OpenClaw Dashboard.app")
    }

    @Test func openClawProviderDetection() throws {
        let fm = FileManager.default
        try withTempDirs { home, apps in
            let provider = OpenClawProvider(home: home, applications: apps)
            #expect(!provider.isInstalled())

            // 1. Support directory
            let support = home.appendingPathComponent("Library/Application Support/OpenClaw")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
            try fm.removeItem(at: support)
            #expect(!provider.isInstalled())

            // 2. Dashboard support
            let dashSupport = home.appendingPathComponent("Library/Application Support/openclaw-dashboard")
            try fm.createDirectory(at: dashSupport, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
            try fm.removeItem(at: dashSupport)
            #expect(!provider.isInstalled())

            // 3. Dashboard.app
            let dashApp = apps.appendingPathComponent("OpenClaw Dashboard.app")
            try fm.createDirectory(at: dashApp, withIntermediateDirectories: true)
            #expect(provider.isInstalled())
        }
    }

    @Test func openClawProviderFetchThrowsNothingYet() async {
        let provider = OpenClawProvider()
        do {
            _ = try await provider.fetch()
            Issue.record("Expected fetch() to throw ProviderError.nothingYet")
        } catch let error as ProviderError {
            guard case .nothingYet(let message) = error else {
                Issue.record("Expected .nothingYet but got: \(error)")
                return
            }
            #expect(message.contains("OpenClaw is on this Mac"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - PreferredModels & Advisor Routing Tests

    @Test func preferredModelsStubHasNoToolsYet() {
        #expect(PreferredModels.allCases.map(\.tool).allSatisfy { $0 == nil })
        let context = Advisor.Context(readings: [], toolOrder: ToolID.allCases)
        #expect(PreferredModels.available(in: context).isEmpty)
        #expect(Advisor.johnRouting(context).isEmpty)
    }

    @Test func johnRoutingPrefersEmptyChatGPTWeeks() {
        let windows = ChatGPTProvider.stubWindows()
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus", fetchedAt: Date(), observedAt: nil)
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases)
        let advice = Advisor.johnRouting(context)
        #expect(advice.contains { $0.id == "john/chatgpt-burn" })
        let burn = advice.first { $0.id == "john/chatgpt-burn" }
        #expect(burn?.priority == .info)
        #expect(burn?.symbol == "flame")
        #expect(burn?.text.contains("4 weekly reset(s) with room") == true)
    }

    @Test func johnRoutingPartialEmptyChatGPTWeeks() {
        let now = Date()
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: 0.80, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: 0.10, resetsAt: now.addingTimeInterval(7200), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: 0.70, resetsAt: now.addingTimeInterval(10800), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: 0.05, resetsAt: now.addingTimeInterval(14400), periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases)
        let advice = Advisor.johnRouting(context)
        let burn = advice.first { $0.id == "john/chatgpt-burn" }
        #expect(burn != nil)
        #expect(burn?.text.contains("2 weekly reset(s) with room") == true)
    }

    @Test func johnRoutingExhaustedChatGPTWeeks() {
        let now = Date()
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: 0.95, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: 0.92, resetsAt: now.addingTimeInterval(7200), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: 0.60, resetsAt: now.addingTimeInterval(10800), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: 0.50, resetsAt: now.addingTimeInterval(14400), periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases)
        let advice = Advisor.johnRouting(context)
        #expect(!advice.contains { $0.id == "john/chatgpt-burn" })
        let exhausted = advice.first { $0.id == "john/chatgpt-exhausted" }
        #expect(exhausted != nil)
        #expect(exhausted?.priority == .warn)
        #expect(exhausted?.text.contains("mostly spent") == true)
    }

    @Test func johnRoutingModerateUsageNoAdvice() {
        let now = Date()
        let windows: [LimitWindow] = [
            LimitWindow(id: "chatgpt_week_1", label: "Week 1", usedFraction: 0.40, resetsAt: now.addingTimeInterval(3600), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_2", label: "Week 2", usedFraction: 0.50, resetsAt: now.addingTimeInterval(7200), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_3", label: "Week 3", usedFraction: 0.45, resetsAt: now.addingTimeInterval(10800), periodDuration: Period.week, source: .localEstimate),
            LimitWindow(id: "chatgpt_week_4", label: "Week 4", usedFraction: 0.55, resetsAt: now.addingTimeInterval(14400), periodDuration: Period.week, source: .localEstimate),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Pro", fetchedAt: now, observedAt: nil)
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases)
        let advice = Advisor.johnRouting(context)
        #expect(advice.isEmpty)
    }

    // MARK: - Theme & Visual Representation Tests

    @Test func johnProvidersHaveThemesAndVisuals() {
        for tool in [ToolID.chatgpt, .grok, .hermes, .openclaw] {
            #expect(!tool.symbolName.isEmpty)
            #expect(!tool.displayName.isEmpty)
            #expect(!tool.productName.isEmpty)

            // ShareCard themes cover each new tool across all themes (.white, .black, .blue)
            for theme in ShareCardTheme.allCases {
                let hex = theme.tool(tool)
                #expect(hex > 0)
            }

            // PanelInk covers each new tool on black and paper
            let ink = PanelInk.tool(tool)
            #expect(ink.onBlack.hex > 0)
            #expect(ink.onPaper.hex > 0)
        }
    }
}
