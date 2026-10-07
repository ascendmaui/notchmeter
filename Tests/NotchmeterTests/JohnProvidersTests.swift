import Foundation
import Testing
@testable import Notchmeter

@Suite struct JohnProvidersTests {
    @Test func chatGPTReservesFourWeeklyWindowIDs() {
        #expect(ChatGPTProvider.weeklyWindowIDs.count == 4)
        let windows = ChatGPTProvider.stubWindows()
        #expect(windows.count == 4)
        #expect(windows.allSatisfy { $0.usedFraction == 0 })
        #expect(Set(windows.map(\.id)) == Set(ChatGPTProvider.weeklyWindowIDs))
    }

    @Test func johnToolIDsExistAndDoNotReportCost() {
        for tool in [ToolID.chatgpt, .grok, .hermes, .openclaw] {
            #expect(ToolID(rawValue: tool.rawValue) == tool)
            #expect(tool.reportsCost == false)
            #expect(!tool.displayName.isEmpty)
        }
    }

    @Test func providerRegistryIncludesJohnProviders() {
        let tools = Set(ProviderRegistry.all().map(\.tool))
        #expect(tools.contains(.chatgpt))
        #expect(tools.contains(.grok))
        #expect(tools.contains(.hermes))
        #expect(tools.contains(.openclaw))
    }

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
    }

    @Test func antigravityTokenFormatParsedCorrectly() throws {
        // Format from antigravity-cli/antigravity-oauth-token
        let json = """
        {
          "token": {
            "access_token": "ya29.test-token-12345",
            "token_type": "Bearer",
            "expiry": "2026-10-01T07:09:08.000Z"
          },
          "auth_method": "oauth"
        }
        """
        let data = Data(json.utf8)
        let creds = try CodeAssistProvider.parseCredentials(data)
        #expect(creds.accessToken == "ya29.test-token-12345")
        #expect(creds.expiresAt != nil)
    }

    @Test func antigravityJwtEmailExtraction() {
        let header = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
        let payload = "eyJlbWFpbCI6ImFzY2VuZGxpZmVzY0BnbWFpbC5jb20iLCJzdWIiOiIxMjM0NSJ9"
        let signature = "signature"
        let jwt = "\(header).\(payload).\(signature)"
        let email = AntigravityAccounts.extractEmailFromJWT(jwt)
        #expect(email == "ascendlifesc@gmail.com")
    }

    @Test func antigravityMultiAccountDiscovery() {
        let slots = AntigravityAccounts.discoverSlots()
        #expect(!slots.isEmpty)
        #expect(slots[0].slot == "agy")
        #expect(slots[0].index == 1)
        // If .agy-accounts exists on this Mac, verify acct slots
        if slots.count > 1 {
            #expect(slots[1].slot.hasPrefix("agy"))
            #expect(slots[1].index >= 2)
        }
    }

    @Test func antigravityReportFieldsSerialized() {
        let now = Date()
        let account = AntigravityAccount(
            slot: "agy4",
            index: 4,
            email: "ascendlifesc@gmail.com",
            homeDirectory: "/Users/john/.agy-accounts/acct4",
            isCurrent: true,
            status: "ready",
            plan: "Pro",
            windows: [
                LimitWindow(id: "gemini_weekly", label: "Weekly Limit", usedFraction: 0.05, resetsAt: now.addingTimeInterval(86400 * 5)),
                LimitWindow(id: "gemini_session", label: "Session Limit", usedFraction: 0.22, resetsAt: now.addingTimeInterval(3600 * 3)),
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 1.0, resetsAt: now.addingTimeInterval(1800)),
                LimitWindow(id: "claude_and_gpt_weekly", label: "Claude Weekly", usedFraction: 0.35, resetsAt: now.addingTimeInterval(86400 * 6))
            ],
            lastActive: now
        )
        let reading = UsageReading(
            tool: .antigravity,
            windows: account.windows,
            plan: "Pro",
            fetchedAt: now,
            observedAt: nil,
            accounts: [account]
        )
        let report = UsageReport(tools: [.antigravity: .ready(reading)], order: [.antigravity], cost: nil, advice: [])
        let object = report.object
        guard let agyAccounts = object["antigravityAccounts"] as? [String: Any] else {
            Issue.record("antigravityAccounts missing in report object")
            return
        }
        #expect(agyAccounts["total"] as? Int == 1)
        #expect(agyAccounts["signedIn"] as? Int == 1)
        #expect(agyAccounts["currentSlot"] as? String == "agy4")
        #expect(agyAccounts["currentEmail"] as? String == "ascendlifesc@gmail.com")
        #expect(agyAccounts["claudeAvailableCount"] as? Int == 0)
        #expect(agyAccounts["geminiAvailableCount"] as? Int == 1)
        #expect((agyAccounts["rotationOrder"] as? [String]) == AntigravityAccounts.rotationOrder)

        guard let tools = object["tools"] as? [[String: Any]], let agyTool = tools.first(where: { $0["tool"] as? String == "antigravity" }) else {
            Issue.record("antigravity tool object missing")
            return
        }
        #expect(agyTool["accountCount"] as? Int == 1)
        #expect(agyTool["signedInCount"] as? Int == 1)
        #expect(agyTool["currentSlot"] as? String == "agy4")
        guard let accountsList = agyTool["accounts"] as? [[String: Any]] else {
            Issue.record("accounts array missing in antigravity tool")
            return
        }
        #expect(accountsList.count == 1)
        #expect(accountsList[0]["slot"] as? String == "agy4")
        #expect(accountsList[0]["email"] as? String == "ascendlifesc@gmail.com")
        #expect(accountsList[0]["isCurrent"] as? Bool == true)
        #expect(accountsList[0]["hasClaudeRoom"] as? Bool == false)
        #expect(accountsList[0]["hasGeminiRoom"] as? Bool == true)
        #expect(accountsList[0]["claudeSessionUsed"] as? Double == 1.0)
        let geminiUsed = accountsList[0]["geminiSessionUsed"] as? Double ?? 0
        #expect(abs(geminiUsed - 0.22) < 0.001)
    }

    @Test func antigravityRecommendedNextSlotAndEarliestReset() {
        let now = Date()
        let acct3 = AntigravityAccount(
            slot: "agy3", index: 3, email: "503meds@gmail.com", homeDirectory: "/tmp/acct3", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.10, resetsAt: now.addingTimeInterval(3600))
            ]
        )
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 1.0, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let acct6 = AntigravityAccount(
            slot: "agy6", index: 6, email: "powerevllc@gmail.com", homeDirectory: "/tmp/acct6", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.05, resetsAt: now.addingTimeInterval(7200))
            ]
        )

        // Rotation order: agy, agy6, agy3, agy2, agy4, agy5, agy7
        // Between agy3 and agy6, agy6 comes before agy3 in rotationOrder!
        let next = AntigravityAccounts.recommendedNextSlot(accounts: [acct3, acct4, acct6], forModelFamily: "claude")
        #expect(next?.slot == "agy6")

        let earliest = AntigravityAccounts.earliestSessionReset(accounts: [acct3, acct4, acct6], forModelFamily: "claude")
        #expect(earliest?.slot == "agy4")
    }

    @Test func johnRoutingAntigravityRotationAdvice() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 1.0, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let acct6 = AntigravityAccount(
            slot: "agy6", index: 6, email: "powerevllc@gmail.com", homeDirectory: "/tmp/acct6", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4, acct6])
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases, now: now)
        let advice = Advisor.johnRouting(context)
        #expect(advice.contains { $0.id == "john/antigravity-rotate" })
    }

    @Test func chatgptProviderLoadsFourWeeklyWindows() {
        let provider = ChatGPTProvider()
        let windows = provider.loadWindows()
        #expect(windows.count == 4)
        #expect(windows.map(\.id) == ChatGPTProvider.weeklyWindowIDs)
    }

    @Test func chatgptUsageFileParsing() throws {
        let json = """
        {
          "plan": "Plus",
          "weeks": [0.05, 0.12, 0.85, 0.0]
        }
        """
        let windows = try ChatGPTProvider.parseUsageFile(Data(json.utf8))
        #expect(windows.count == 4)
        #expect(windows[0].usedFraction == 0.05)
        #expect(windows[1].usedFraction == 0.12)
        #expect(windows[2].usedFraction == 0.85)
        #expect(windows[3].usedFraction == 0.0)
    }

    @Test func chatgptHeavyReportFieldsSerialized() {
        let now = Date()
        let windows = ChatGPTProvider.stubWindows(now: now)
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus/Pro (4 weekly resets)", fetchedAt: now, observedAt: nil)
        let report = UsageReport(tools: [.chatgpt: .ready(reading)], order: [.chatgpt], cost: nil, advice: [])
        let object = report.object

        guard let chatgptHeavy = object["chatgptHeavy"] as? [String: Any] else {
            Issue.record("chatgptHeavy missing in report object")
            return
        }
        #expect(chatgptHeavy["active"] as? Bool == true)
        #expect(chatgptHeavy["totalResets"] as? Int == 4)
        #expect(chatgptHeavy["emptyResets"] as? Int == 4)
        #expect(chatgptHeavy["burnedResets"] as? Int == 0)
        #expect(chatgptHeavy["inProgressResets"] as? Int == 0)
        #expect(chatgptHeavy["preferBurn"] as? Bool == true)
        #expect(chatgptHeavy["burnPriority"] as? Int == 1)
        #expect(chatgptHeavy["activeWindowID"] as? String == "chatgpt_week_1")

        guard let tools = object["tools"] as? [[String: Any]], let chatgptTool = tools.first(where: { $0["tool"] as? String == "chatgpt" }) else {
            Issue.record("chatgpt tool object missing")
            return
        }
        #expect(chatgptTool["chatgptHeavy"] as? Bool == true)
        #expect(chatgptTool["weeklyResetsCount"] as? Int == 4)
        #expect(chatgptTool["emptyResetsCount"] as? Int == 4)
        #expect(chatgptTool["burnedResetsCount"] as? Int == 0)
        #expect(chatgptTool["burnPriority"] as? Int == 1)
        #expect(chatgptTool["activeWindowID"] as? String == "chatgpt_week_1")
    }

    @Test func antigravityCircularRotationWithStartingAfter() {
        let now = Date()
        let acct3 = AntigravityAccount(
            slot: "agy3", index: 3, email: "503meds@gmail.com", homeDirectory: "/tmp/acct3", isCurrent: false, status: "ready",
            windows: [LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.10, resetsAt: now.addingTimeInterval(3600))]
        )
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 1.0, resetsAt: now.addingTimeInterval(1200))]
        )
        let acct5 = AntigravityAccount(
            slot: "agy5", index: 5, email: "ascendlifeinsurance@gmail.com", homeDirectory: "/tmp/acct5", isCurrent: false, status: "ready",
            windows: [LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.20, resetsAt: now.addingTimeInterval(4800))]
        )
        let acct6 = AntigravityAccount(
            slot: "agy6", index: 6, email: "powerevllc@gmail.com", homeDirectory: "/tmp/acct6", isCurrent: false, status: "ready",
            windows: [LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.05, resetsAt: now.addingTimeInterval(7200))]
        )

        // Rotation order: agy, agy6, agy3, agy2, agy4, agy5, agy7
        // Starting after agy4 (index 4), the next ready candidate is agy5 (index 5)!
        let nextAfterAgy4 = AntigravityAccounts.recommendedNextSlot(accounts: [acct3, acct4, acct5, acct6], startingAfter: "agy4", forModelFamily: "claude")
        #expect(nextAfterAgy4?.slot == "agy5")

        // Starting after agy5 (index 5) with only [acct3, acct4, acct6], candidates are agy7, agy, agy6 -> agy6!
        let nextAfterAgy5 = AntigravityAccounts.recommendedNextSlot(accounts: [acct3, acct4, acct6], startingAfter: "agy5", forModelFamily: "claude")
        #expect(nextAfterAgy5?.slot == "agy6")
    }

    @Test func antigravityProactiveSessionClosingAdvice() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.80, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let acct5 = AntigravityAccount(
            slot: "agy5", index: 5, email: "ascendlifeinsurance@gmail.com", homeDirectory: "/tmp/acct5", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4, acct5])
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases, now: now)
        let advice = Advisor.johnRouting(context)
        #expect(advice.contains { $0.id == "john/antigravity-session-closing" })
    }

    @Test func chatgptHeavyEnvironmentOverrideEnablesInstallation() {
        let provider = ChatGPTProvider(home: URL(fileURLWithPath: "/tmp/nonexistent-home"),
                                       applications: URL(fileURLWithPath: "/tmp/nonexistent-apps"))
        setenv("NOTCHMETER_CHATGPT_USAGE", "0.2,0.4,0.0,0.0", 1)
        defer { unsetenv("NOTCHMETER_CHATGPT_USAGE") }
        #expect(provider.isInstalled())

        let windows = provider.loadWindows()
        #expect(windows.count == 4)
        #expect(windows[0].usedFraction == 0.2)
        #expect(windows[1].usedFraction == 0.4)
    }

    @Test func chatgptHeavyResetHoursOverride() {
        let provider = ChatGPTProvider()
        setenv("NOTCHMETER_CHATGPT_USAGE", "0.1,0.0,0.0,0.0", 1)
        setenv("NOTCHMETER_CHATGPT_RESET_HOURS", "12,24,36,48", 1)
        defer {
            unsetenv("NOTCHMETER_CHATGPT_USAGE")
            unsetenv("NOTCHMETER_CHATGPT_RESET_HOURS")
        }
        let now = Date()
        let windows = provider.loadWindows(now: now)
        #expect(windows.count == 4)
        if let reset1 = windows[0].resetsAt {
            let hours = reset1.timeIntervalSince(now) / 3600.0
            #expect(abs(hours - 12.0) < 0.1)
        }
    }

    @Test func antigravityReportRichFieldsAndResetsInSeconds() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.10, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.25, resetsAt: now.addingTimeInterval(1800))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4])
        let report = UsageReport(tools: [.antigravity: .ready(reading)], order: [.antigravity], cost: nil, advice: [], now: now)
        let object = report.object

        guard let agyAccounts = object["antigravityAccounts"] as? [String: Any] else {
            Issue.record("antigravityAccounts missing in report object")
            return
        }
        #expect(agyAccounts["activeSlot"] as? String == "agy4")
        #expect(agyAccounts["activeEmail"] as? String == "ascendlifesc@gmail.com")
        #expect(agyAccounts["activeHasClaudeRoom"] as? Bool == true)
        #expect(agyAccounts["activeHasGeminiRoom"] as? Bool == true)
        #expect(agyAccounts["earliestClaudeResetsInSeconds"] as? Int == 3600)
        #expect(agyAccounts["earliestGeminiResetsInSeconds"] as? Int == 1800)
        #expect(agyAccounts["rotationAdvice"] as? String != nil)

        guard let tools = object["tools"] as? [[String: Any]], let agyTool = tools.first(where: { $0["tool"] as? String == "antigravity" }) else {
            Issue.record("antigravity tool object missing")
            return
        }
        #expect(agyTool["activeSlot"] as? String == "agy4")
        #expect(agyTool["activeEmail"] as? String == "ascendlifesc@gmail.com")
        #expect(agyTool["earliestClaudeResetsInSeconds"] as? Int == 3600)
    }

    @Test func antigravityGeminiRotationAdvice() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 1.0, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let acct5 = AntigravityAccount(
            slot: "agy5", index: 5, email: "ascendlifeinsurance@gmail.com", homeDirectory: "/tmp/acct5", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(7200)),
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.1, resetsAt: now.addingTimeInterval(5400))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4, acct5])
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases, now: now)
        let advice = Advisor.johnRouting(context)
        #expect(advice.contains { $0.id == "john/antigravity-rotate-gemini" })

        // Proactive session closing advice for Gemini at >= 75%
        let acct4Near = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.80, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let readingNear = UsageReading(tool: .antigravity, windows: acct4Near.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4Near, acct5])
        let contextNear = Advisor.Context(readings: [readingNear], toolOrder: ToolID.allCases, now: now)
        let adviceNear = Advisor.johnRouting(contextNear)
        #expect(adviceNear.contains { $0.id == "john/antigravity-gemini-session-closing" })
    }

    @Test func antigravityReportGeminiRotationFields() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.05, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 1.0, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let acct5 = AntigravityAccount(
            slot: "agy5", index: 5, email: "ascendlifeinsurance@gmail.com", homeDirectory: "/tmp/acct5", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(7200)),
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.1, resetsAt: now.addingTimeInterval(5400))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4, acct5])
        let report = UsageReport(tools: [.antigravity: .ready(reading)], order: [.antigravity], cost: nil, advice: [], now: now)
        let object = report.object

        guard let agyAccounts = object["antigravityAccounts"] as? [String: Any] else {
            Issue.record("antigravityAccounts missing in report object")
            return
        }
        #expect(agyAccounts["recommendedNextGeminiSlot"] as? String == "agy5")
        #expect(agyAccounts["recommendedNextGeminiEmail"] as? String == "ascendlifeinsurance@gmail.com")
        #expect(agyAccounts["claudeRotationAdvice"] as? String != nil)
        #expect(agyAccounts["geminiRotationAdvice"] as? String != nil)
        #expect(agyAccounts["activeGeminiSessionResetsInSeconds"] as? Int == 1200)
        #expect(agyAccounts["activeClaudeSessionResetsInSeconds"] as? Int == 3600)

        guard let tools = object["tools"] as? [[String: Any]], let agyTool = tools.first(where: { $0["tool"] as? String == "antigravity" }) else {
            Issue.record("antigravity tool object missing")
            return
        }
        #expect(agyTool["recommendedNextGeminiSlot"] as? String == "agy5")
        #expect(agyTool["geminiRotationAdvice"] as? String != nil)
        #expect(agyTool["activeGeminiSessionResetsInSeconds"] as? Int == 1200)
    }

    @Test func chatgptHeavyDetailedWindowsInReport() {
        let now = Date()
        let windows = [
            LimitWindow(id: "chatgpt_week_1", label: "Weekly reset 1", usedFraction: 0.10, resetsAt: now.addingTimeInterval(86400)),
            LimitWindow(id: "chatgpt_week_2", label: "Weekly reset 2", usedFraction: 0.50, resetsAt: now.addingTimeInterval(86400 * 2)),
            LimitWindow(id: "chatgpt_week_3", label: "Weekly reset 3", usedFraction: 0.90, resetsAt: now.addingTimeInterval(86400 * 3)),
            LimitWindow(id: "chatgpt_week_4", label: "Weekly reset 4", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 4))
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus/Pro (4 weekly resets)", fetchedAt: now, observedAt: nil)
        let report = UsageReport(tools: [.chatgpt: .ready(reading)], order: [.chatgpt], cost: nil, advice: [], now: now)
        let object = report.object

        guard let chatgptHeavy = object["chatgptHeavy"] as? [String: Any] else {
            Issue.record("chatgptHeavy missing in report object")
            return
        }
        #expect(chatgptHeavy["activeWindowID"] as? String == "chatgpt_week_1")
        #expect(chatgptHeavy["activeWindowUsedFraction"] as? Double == 0.10)
        #expect(chatgptHeavy["activeWindowResetsInSeconds"] as? Int == 86400)
        guard let winList = chatgptHeavy["windows"] as? [[String: Any]] else {
            Issue.record("windows list missing in chatgptHeavy")
            return
        }
        #expect(winList.count == 4)
        #expect(winList[0]["status"] as? String == "empty")
        #expect(winList[1]["status"] as? String == "inProgress")
        #expect(winList[2]["status"] as? String == "burned")
        #expect(winList[3]["status"] as? String == "empty")

        guard let tools = object["tools"] as? [[String: Any]], let chatgptTool = tools.first(where: { $0["tool"] as? String == "chatgpt" }) else {
            Issue.record("chatgpt tool object missing")
            return
        }
        #expect(chatgptTool["activeWindowResetsInSeconds"] as? Int == 86400)
        #expect(chatgptTool["activeWindowUsedFraction"] as? Double == 0.10)
        guard let toolResets = chatgptTool["resets"] as? [[String: Any]] else {
            Issue.record("resets array missing in chatgpt tool object")
            return
        }
        #expect(toolResets.count == 4)
    }

    @Test func commandLineToolFormattingIncludesSessionResets() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.36, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.00, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4])
        let report = UsageReport(tools: [.antigravity: .ready(reading)], order: [.antigravity], cost: nil, advice: [], now: now)
        let text = CommandLineTool.describe(report.object)

        #expect(text.contains("[agy4] ascendlifesc@gmail.com (current)"))
        #expect(text.contains("Gemini Session: 36%"))
        #expect(text.contains("resets in"))
    }

    @Test func commandLineToolSubcommandsParsed() {
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "accounts"]) == .accounts)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "--accounts"]) == .accounts)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "rotation"]) == .rotation)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "--rotation"]) == .rotation)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "chatgpt-heavy"]) == .chatgptHeavy)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "chatgpt_heavy"]) == .chatgptHeavy)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "--chatgpt-heavy"]) == .chatgptHeavy)
        #expect(CommandLineTool.subcommand(in: ["notchmeter", "claude"]) == nil)
        #expect(CommandLineTool.subcommand(in: ["notchmeter"]) == nil)
    }

    @Test func commandLineToolParsedSubcommandAccountsAndRotation() throws {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.85, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.00, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let acct5 = AntigravityAccount(
            slot: "agy5", index: 5, email: "ascendlifeinsurance@gmail.com", homeDirectory: "/tmp/acct5", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.10, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.00, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4, acct5])
        let report = UsageReport(tools: [.antigravity: .ready(reading)], order: [.antigravity], cost: nil, advice: [], now: now)

        let parsedAccts = CommandLineTool.parsedSubcommand(report.json, subcommand: .accounts)
        #expect(parsedAccts.exitCode == 0)
        #expect(parsedAccts.text.contains("Antigravity Accounts: 2 configured (2 ready)"))
        #expect(parsedAccts.text.contains("[agy4] ascendlifesc@gmail.com (current)"))
        #expect(parsedAccts.text.contains("[agy5] ascendlifeinsurance@gmail.com"))
        let acctObj = try JSONSerialization.jsonObject(with: parsedAccts.data) as? [String: Any]
        #expect(acctObj?["signedIn"] as? Int == 2)

        let parsedRotation = CommandLineTool.parsedSubcommand(report.json, subcommand: .rotation)
        #expect(parsedRotation.exitCode == 0)
        #expect(parsedRotation.text.contains("Antigravity Rotation:"))
        #expect(parsedRotation.text.contains("Active slot: [agy4] (ascendlifesc@gmail.com)"))
        #expect(parsedRotation.text.contains("Next Gemini slot: [agy5]"))
        let rotObj = try JSONSerialization.jsonObject(with: parsedRotation.data) as? [String: Any]
        #expect(rotObj?["activeSlot"] as? String == "agy4")
        #expect(rotObj?["recommendedNextGeminiSlot"] as? String == "agy5")
    }

    @Test func commandLineToolParsedSubcommandChatGPTHeavy() throws {
        let now = Date()
        let windows = [
            LimitWindow(id: "chatgpt_week_1", label: "Weekly reset 1", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400)),
            LimitWindow(id: "chatgpt_week_2", label: "Weekly reset 2", usedFraction: 0.50, resetsAt: now.addingTimeInterval(86400 * 2)),
            LimitWindow(id: "chatgpt_week_3", label: "Weekly reset 3", usedFraction: 0.95, resetsAt: now.addingTimeInterval(86400 * 3)),
            LimitWindow(id: "chatgpt_week_4", label: "Weekly reset 4", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 4)),
        ]
        let reading = UsageReading(tool: .chatgpt, windows: windows, plan: "Plus", fetchedAt: now, observedAt: nil)
        let report = UsageReport(tools: [.chatgpt: .ready(reading)], order: [.chatgpt], cost: nil, advice: [], now: now)

        let parsed = CommandLineTool.parsedSubcommand(report.json, subcommand: .chatgptHeavy)
        #expect(parsed.exitCode == 0)
        #expect(parsed.text.contains("ChatGPT-Heavy Burn Routing (Priority 1):"))
        #expect(parsed.text.contains("Available weekly resets: 2 of 4"))
        #expect(parsed.text.contains("Active reset: Weekly reset 1"))
        #expect(parsed.text.contains("Weekly reset 1: 0% used, 100% headroom (empty"))
        #expect(parsed.text.contains("Weekly reset 3: 95% used, 5% headroom (burned"))

        let cgtObj = try JSONSerialization.jsonObject(with: parsed.data) as? [String: Any]
        #expect(cgtObj?["totalResets"] as? Int == 4)
        #expect(cgtObj?["emptyResets"] as? Int == 2)
    }

    @MainActor @Test func localAPIServesAccountsRotationAndChatGPTHeavy() throws {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "gemini_session", label: "Gemini Session", usedFraction: 0.50, resetsAt: now.addingTimeInterval(3600)),
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.00, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let agyReading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4])
        let cgtWindows = [
            LimitWindow(id: "chatgpt_week_1", label: "Weekly reset 1", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400)),
            LimitWindow(id: "chatgpt_week_2", label: "Weekly reset 2", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 2)),
            LimitWindow(id: "chatgpt_week_3", label: "Weekly reset 3", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 3)),
            LimitWindow(id: "chatgpt_week_4", label: "Weekly reset 4", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 4)),
        ]
        let cgtReading = UsageReading(tool: .chatgpt, windows: cgtWindows, plan: "Plus", fetchedAt: now, observedAt: nil)
        let report = UsageReport(tools: [.antigravity: .ready(agyReading), .chatgpt: .ready(cgtReading)], order: [.antigravity, .chatgpt], cost: nil, advice: [], now: now)

        let api = LocalAPI(port: 6737, allowedOrigins: { [] }, report: { report })

        let acctsResp = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/accounts", headers: ["host": "127.0.0.1:6737"], body: Data())), as: UTF8.self)
        #expect(acctsResp.hasPrefix("HTTP/1.1 200 OK"))
        #expect(acctsResp.contains("\"ascendlifesc@gmail.com\""))

        let rotResp = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/rotation", headers: ["host": "127.0.0.1:6737"], body: Data())), as: UTF8.self)
        #expect(rotResp.hasPrefix("HTTP/1.1 200 OK"))
        #expect(rotResp.contains("\"activeSlot\" : \"agy4\""))

        let cgtResp = String(decoding: api.respond(to: LocalAPI.Request(method: "GET", path: "/v1/chatgpt-heavy", headers: ["host": "127.0.0.1:6737"], body: Data())), as: UTF8.self)
        #expect(cgtResp.hasPrefix("HTTP/1.1 200 OK"))
        #expect(cgtResp.contains("\"burnPriority\" : 1"))
    }

    @Test func usageReportLimitedCleansUpJohnFieldsForUnrelatedTools() throws {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.10, resetsAt: now.addingTimeInterval(3600))
            ]
        )
        let agyReading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4])
        let cgtWindows = [
            LimitWindow(id: "chatgpt_week_1", label: "Weekly reset 1", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400)),
            LimitWindow(id: "chatgpt_week_2", label: "Weekly reset 2", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 2)),
            LimitWindow(id: "chatgpt_week_3", label: "Weekly reset 3", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 3)),
            LimitWindow(id: "chatgpt_week_4", label: "Weekly reset 4", usedFraction: 0.00, resetsAt: now.addingTimeInterval(86400 * 4)),
        ]
        let cgtReading = UsageReading(tool: .chatgpt, windows: cgtWindows, plan: "Plus", fetchedAt: now, observedAt: nil)
        let full = UsageReport(tools: [.antigravity: .ready(agyReading), .chatgpt: .ready(cgtReading)], order: [.antigravity, .chatgpt], cost: nil, advice: [], now: now)

        let decoded = try #require(UsageReport.decode(full.json))

        let claudeLimited = decoded.limited(to: .claude)
        #expect(claudeLimited.object["antigravityAccounts"] == nil)
        #expect(claudeLimited.object["chatgptHeavy"] == nil)

        let agyLimited = decoded.limited(to: .antigravity)
        #expect(agyLimited.object["antigravityAccounts"] != nil)
        #expect(agyLimited.object["chatgptHeavy"] == nil)

        let cgtLimited = decoded.limited(to: .chatgpt)
        #expect(cgtLimited.object["antigravityAccounts"] == nil)
        #expect(cgtLimited.object["chatgptHeavy"] != nil)
    }

    @Test func antigravityProactiveSessionClosingContainsCountdown() {
        let now = Date()
        let acct4 = AntigravityAccount(
            slot: "agy4", index: 4, email: "ascendlifesc@gmail.com", homeDirectory: "/tmp/acct4", isCurrent: true, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.80, resetsAt: now.addingTimeInterval(1200))
            ]
        )
        let acct5 = AntigravityAccount(
            slot: "agy5", index: 5, email: "ascendlifeinsurance@gmail.com", homeDirectory: "/tmp/acct5", isCurrent: false, status: "ready",
            windows: [
                LimitWindow(id: "claude_and_gpt_session", label: "Claude Session", usedFraction: 0.0, resetsAt: now.addingTimeInterval(7200))
            ]
        )
        let reading = UsageReading(tool: .antigravity, windows: acct4.windows, plan: "Pro", fetchedAt: now, observedAt: nil, accounts: [acct4, acct5])
        let context = Advisor.Context(readings: [reading], toolOrder: ToolID.allCases, now: now)
        let advice = Advisor.johnRouting(context)
        let closing = advice.first { $0.id == "john/antigravity-session-closing" }
        #expect(closing != nil)
        #expect(closing?.text.contains("resets in 20m") == true)
    }
}
