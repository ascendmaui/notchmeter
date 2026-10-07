import Foundation

/// Best-model routing targets John wants once those tools exist as ToolIDs / providers.
/// Sol 5.6, Astra and Luna are not ToolIDs yet — this enum is the stub the Advisor consults.
enum PreferredModels: String, CaseIterable, Sendable {
    case sol56 = "sol56"
    case astra = "astra"
    case luna = "luna"

    var displayName: String {
        switch self {
        case .sol56: "Sol 5.6"
        case .astra: "Astra"
        case .luna: "Luna"
        }
    }

    /// Future: map to ToolID when those assistants ship. Today always empty.
    var tool: ToolID? { nil }

    /// Models that currently have a reading with headroom in the Advisor context.
    static func available(in context: Advisor.Context) -> [PreferredModels] {
        allCases.filter { model in
            guard let tool = model.tool else { return false }
            guard let reading = context.readings.first(where: { $0.tool == tool }) else { return false }
            let used = reading.windows.first?.usedFraction ?? 1
            return used < (1 - Advisor.routingHeadroom)
        }
    }
}
