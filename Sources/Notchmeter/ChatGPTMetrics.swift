import Foundation

/// ChatGPT Plus/Pro chat usage metrics across the four weekly reset windows.
///
/// John / ascendmaui fork leans SUPER heavy on ChatGPT: ChatGPT chat has four weekly usage resets
/// (`ChatGPTProvider.weeklyWindowIDs`). This metrics model analyzes the four slots, tracks aggregate capacity,
/// determines slot utilization states (empty, active, exhausted), computes equivalent weeks remaining, and identifies
/// the active target window to burn first (preferring empty weeks resetting soonest).
struct ChatGPTHeavyMetrics: Equatable, Sendable {
    /// The four canonical weekly window IDs.
    static let expectedSlotsCount = 4

    enum SlotState: String, Codable, Sendable {
        /// Below 15% used — untouched or fresh quota to burn first.
        case empty
        /// Between 15% and 90% used — in-flight burn.
        case active
        /// At or above 90% used — exhausted for this cycle.
        case exhausted
        /// No utilization published yet (e.g. initial stub).
        case unmetered
    }

    struct WindowSlot: Equatable, Sendable {
        let id: String
        let index: Int
        let label: String
        let usedFraction: Double?
        let resetsAt: Date?
        let periodDuration: TimeInterval?
        let source: WindowSource
        let state: SlotState

        var headroom: Double {
            max(0, 1.0 - (usedFraction ?? 0.0))
        }

        var isBehindPace: Bool {
            false
        }
    }

    enum Recommendation: Equatable, Sendable {
        case burnChatGPT(slotId: String, index: Int, headroom: Double, reason: String)
        case cycleExhausted(nextResetAt: Date?, reason: String)
        case unmetered(reason: String)
        case noWindows

        var isBurnTarget: Bool {
            if case .burnChatGPT = self { return true }
            return false
        }
    }

    let slots: [WindowSlot]
    let plan: String?
    let fetchedAt: Date
    let now: Date

    init(reading: UsageReading, now: Date = Date()) {
        self.plan = reading.plan
        self.fetchedAt = reading.fetchedAt
        self.now = now

        let weeklyIDs = ChatGPTProvider.weeklyWindowIDs
        var parsedSlots: [WindowSlot] = []

        for (idx, id) in weeklyIDs.enumerated() {
            let index = idx + 1
            if let window = reading.windows.first(where: { $0.id == id }) {
                let state: SlotState
                if let used = window.usedFraction {
                    if used < 0.15 {
                        state = .empty
                    } else if used >= 0.90 {
                        state = .exhausted
                    } else {
                        state = .active
                    }
                } else {
                    state = .unmetered
                }
                parsedSlots.append(WindowSlot(
                    id: window.id,
                    index: index,
                    label: window.label,
                    usedFraction: window.usedFraction,
                    resetsAt: window.resetsAt,
                    periodDuration: window.periodDuration,
                    source: window.source,
                    state: state
                ))
            } else {
                // If a window is missing, record as unmetered stub slot
                parsedSlots.append(WindowSlot(
                    id: id,
                    index: index,
                    label: "Weekly reset \(index)",
                    usedFraction: nil,
                    resetsAt: nil,
                    periodDuration: Period.week,
                    source: .localEstimate,
                    state: .unmetered
                ))
            }
        }
        self.slots = parsedSlots
    }

    // MARK: - Computed Properties

    var emptySlots: [WindowSlot] {
        slots.filter { $0.state == .empty }
    }

    var activeSlots: [WindowSlot] {
        slots.filter { $0.state == .active }
    }

    var exhaustedSlots: [WindowSlot] {
        slots.filter { $0.state == .exhausted }
    }

    var unmeteredSlots: [WindowSlot] {
        slots.filter { $0.state == .unmetered }
    }

    /// Average used fraction across metered slots (0.0 to 1.0).
    var averageUsedFraction: Double? {
        let metered = slots.compactMap(\.usedFraction)
        guard !metered.isEmpty else { return nil }
        return metered.reduce(0.0, +) / Double(metered.count)
    }

    /// Total available capacity fraction across the 4 weeks (0.0 to 1.0).
    var totalAvailableFraction: Double? {
        guard let avg = averageUsedFraction else { return nil }
        return max(0, 1.0 - avg)
    }

    /// Total equivalent full weeks remaining (e.g. 4.0 = completely unused, 0.0 = completely spent).
    var equivalentWeeksRemaining: Double {
        slots.reduce(0.0) { $0 + $1.headroom }
    }

    /// Earliest reset date among slots that have a known reset time.
    var earliestReset: Date? {
        slots.compactMap(\.resetsAt).min()
    }

    /// Next reset date among exhausted slots (when quota will begin recovering).
    var nextExhaustedReset: Date? {
        exhaustedSlots.compactMap(\.resetsAt).min()
    }

    /// The recommended slot to burn right now.
    /// Priority order:
    /// 1. Empty slots (<15% used), ordered by earliest resetsAt (burn before reset clears unused allowance!).
    /// 2. Active slots (15-90% used), ordered by highest headroom then earliest resetsAt.
    /// 3. If all are exhausted, nil.
    var activeBurnTarget: WindowSlot? {
        if !emptySlots.isEmpty {
            return emptySlots.min { a, b in
                let resetA = a.resetsAt ?? .distantFuture
                let resetB = b.resetsAt ?? .distantFuture
                if resetA != resetB { return resetA < resetB }
                return a.index < b.index
            }
        }
        if !activeSlots.isEmpty {
            return activeSlots.min { a, b in
                if a.headroom != b.headroom { return a.headroom > b.headroom }
                let resetA = a.resetsAt ?? .distantFuture
                let resetB = b.resetsAt ?? .distantFuture
                return resetA < resetB
            }
        }
        return nil
    }

    /// High-level routing recommendation for the ChatGPT heavy burn workflow.
    var recommendation: Recommendation {
        if unmeteredSlots.count == slots.count {
            return .unmetered(reason: "ChatGPT four weekly resets are not readable yet.")
        }
        if let target = activeBurnTarget {
            let pct = Int((target.headroom * 100).rounded())
            let reason: String
            if target.state == .empty {
                reason = "Weekly reset \(target.index) has \(pct)% room — burn this slot before reset."
            } else {
                reason = "Weekly reset \(target.index) is active with \(pct)% room."
            }
            return .burnChatGPT(slotId: target.id, index: target.index, headroom: target.headroom, reason: reason)
        }
        if exhaustedSlots.count == slots.count {
            return .cycleExhausted(nextResetAt: nextExhaustedReset, reason: "All four weekly resets are exhausted (>=90%). Route to other platforms until reset.")
        }
        return .noWindows
    }

    // MARK: - Output & Diagnostics

    /// Concise one-line status for CLI / logs.
    var summaryText: String {
        let meteredCount = slots.count - unmeteredSlots.count
        if meteredCount == 0 {
            return "ChatGPT: 4 weekly reset slots reserved (usage not readable yet)."
        }
        let openCount = emptySlots.count + activeSlots.count
        let avgPct = averageUsedFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
        let weeksFormatted = String(format: "%.1f", equivalentWeeksRemaining)

        var text = "ChatGPT: \(openCount)/4 weeks available (avg \(avgPct) used, ~\(weeksFormatted)w remaining)."
        if let target = activeBurnTarget {
            let targetPct = Int((target.headroom * 100).rounded())
            text += " Active target: Weekly reset \(target.index) (\(targetPct)% room)."
        } else if !exhaustedSlots.isEmpty {
            text += " All resets exhausted; route elsewhere."
        }
        return text
    }

    /// Dictionary representation for JSON export or diagnostic reports.
    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "totalSlots": slots.count,
            "emptySlots": emptySlots.count,
            "activeSlots": activeSlots.count,
            "exhaustedSlots": exhaustedSlots.count,
            "unmeteredSlots": unmeteredSlots.count,
            "equivalentWeeksRemaining": equivalentWeeksRemaining,
            "slots": slots.map { slot in
                var sDict: [String: Any] = [
                    "id": slot.id,
                    "index": slot.index,
                    "label": slot.label,
                    "state": slot.state.rawValue,
                    "headroom": slot.headroom,
                ]
                if let used = slot.usedFraction { sDict["usedFraction"] = used }
                if let reset = slot.resetsAt { sDict["resetsAt"] = Oracle.timestamp(reset) }
                return sDict
            }
        ]
        if let avg = averageUsedFraction { dict["averageUsedFraction"] = avg }
        if let avail = totalAvailableFraction { dict["totalAvailableFraction"] = avail }
        if let target = activeBurnTarget {
            dict["activeBurnTarget"] = [
                "id": target.id,
                "index": target.index,
                "headroom": target.headroom
            ]
        }
        return dict
    }
}

extension UsageReading {
    /// ChatGPT-heavy multi-window metrics when this reading is for ChatGPT.
    var chatGPTHeavyMetrics: ChatGPTHeavyMetrics? {
        guard tool == .chatgpt else { return nil }
        return ChatGPTHeavyMetrics(reading: self)
    }
}
