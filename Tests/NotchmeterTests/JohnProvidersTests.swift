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
}
