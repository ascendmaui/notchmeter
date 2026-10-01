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
}
