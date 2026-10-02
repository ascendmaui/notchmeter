import Foundation

/// The machine-readable picture of everything the app knows, for `--probe --json`, the local API, the command-line
/// tool, the MCP server and the Claude Code skill: one versioned object with sorted keys and no token anywhere.
/// Additive keys since the first version: `source` per window (WindowSource), `runOut` (the interval's two edges),
/// `hiddenByDefault`, `rawUsedPercent`, `amountUSD`; `agents`, `branch`, `pr`, `permissionMode`, `host` and
/// `source` (SessionSource: `hook`; `storage` for a row read from OpenCode's database; `detected` or `statusline` for one found without the hook; `coworkLog` for a Claude Cowork task) per session; the five `tokenBuckets` and `cacheWrite1hShare` per cost range, `metering`, `cursor` in the cost
/// object; `history` (the daily rows) when asked; `pid`, the writing process; `promptCache` (today's misses,
/// requests, miss share, rewritten tokens and their price, the last cause, the sessions counted). Exit codes mirror
/// Claude-Code-Usage-Monitor's: 0 fine, 10 near a limit, 11 a limit hit, 20 no session (nothing used), 30 no data.
struct UsageReport {
    static let schema = "notchmeter.limits.v1"

    enum ExitCode: Int32 {
        case ok = 0
        case nearLimit = 10
        case limitHit = 11
        case noSession = 20
        case noData = 30
    }

    let tools: [ToolID: ToolStatus]
    let order: [ToolID]
    let cost: CostSummary?
    let advice: [Advice]
    let drains: [DrainLog.Key: Drain]
    let runOuts: [DrainLog.Key: RunOutInterval]
    let sessions: [AgentSession]
    let history: [Date: CostHistory.Record]?
    /// Today's prompt-cache figures from Claude Code's status line (0.7.0): `promptCache` in the object.
    let promptCache: PromptCacheSummary?
    let now: Date
    /// A report read back from its JSON (the report file, the local API), served verbatim.
    let raw: [String: Any]?

    init(tools: [ToolID: ToolStatus], order: [ToolID] = ToolID.allCases, cost: CostSummary?, advice: [Advice],
         drains: [DrainLog.Key: Drain] = [:], runOuts: [DrainLog.Key: RunOutInterval] = [:], sessions: [AgentSession] = [],
         history: [Date: CostHistory.Record]? = nil, promptCache: PromptCacheSummary? = nil, now: Date = Date()) {
        self.tools = tools
        self.order = order
        self.cost = cost
        self.advice = advice
        self.drains = drains
        self.runOuts = runOuts
        self.sessions = sessions
        self.history = history
        self.promptCache = promptCache
        self.now = now
        self.raw = nil
    }

    init(raw: [String: Any]) {
        self.tools = [:]
        self.order = []
        self.cost = nil
        self.advice = []
        self.drains = [:]
        self.runOuts = [:]
        self.sessions = []
        self.history = nil
        self.promptCache = nil
        self.now = (raw["generatedAt"] as? String).flatMap(DateParsing.iso8601) ?? Date()
        self.raw = raw
    }

    /// The same report narrowed to one tool: its sessions come with it (each carries its tool), while the cost and
    /// the history are Claude's alone.
    func limited(to tool: ToolID) -> UsageReport {
        if var raw {
            raw["tools"] = (raw["tools"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            raw["advice"] = (raw["advice"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            raw["sessions"] = (raw["sessions"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            if tool != .claude {
                raw["cost"] = nil
                raw["history"] = nil
            }
            return UsageReport(raw: raw)
        }
        return UsageReport(tools: tools.filter { $0.key == tool }, order: [tool], cost: tool == .claude ? cost : nil,
                           advice: advice.filter { $0.tool == tool }, drains: drains, runOuts: runOuts, sessions: sessions.filter { $0.tool == tool },
                           history: tool == .claude ? history : nil, now: now)
    }

    /// Near: any limited window at 80 % or behind pace; hit: any at 100 %; no session: readings with nothing used.
    var exitCode: ExitCode {
        if let raw { return ExitCode(rawValue: Int32(JSON.number(raw["exitCode"]) ?? 30)) ?? .noData }
        let readings = order.compactMap { tools[$0]?.reading }
        let windows = readings.flatMap(\.windows).filter { $0.usedFraction != nil }
        guard !windows.isEmpty else { return .noData }
        if windows.contains(where: { ($0.usedFraction ?? 0) >= 1 }) { return .limitHit }
        if windows.contains(where: { ($0.usedFraction ?? 0) >= 0.8 || Pace.status(for: $0, now: now) == .behind }) { return .nearLimit }
        if windows.allSatisfy({ ($0.usedFraction ?? 0) == 0 }) { return .noSession }
        return .ok
    }

    var object: [String: Any] {
        if let raw { return raw }
        var root: [String: Any] = [
            "schema": Self.schema,
            "generatedAt": Oracle.timestamp(now),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "exitCode": Int(exitCode.rawValue),
            "tools": order.compactMap { tool -> [String: Any]? in
                guard let status = tools[tool] else { return nil }
                return toolObject(tool, status)
            },
            "advice": advice.map { ["id": $0.id, "priority": String(describing: $0.priority), "tool": $0.tool?.rawValue as Any, "text": $0.text, "url": $0.url?.absoluteString as Any] },
            "sessions": sessions.map { session -> [String: Any] in
                ["id": session.id, "tool": session.tool.rawValue, "project": session.project as Any, "state": Self.stateName(session.state),
                 "stateSeconds": session.stateDuration(now: now).map { Int($0) } as Any, "agents": session.agents.count,
                 "branch": session.branch as Any, "pr": session.prLink?.absoluteString as Any, "permissionMode": session.permissionMode as Any, "host": session.host as Any,
                 "source": session.source.rawValue]
            },
        ]
        if let cost { root["cost"] = costObject(cost) }
        if let history { root["history"] = Self.historyRows(history) }
        if let promptCache {
            root["promptCache"] = ["misses": promptCache.misses, "requests": promptCache.requests, "missShare": promptCache.missShare.map(Oracle.fraction) as Any,
                                   "rewrittenTokens": promptCache.rewrittenTokens, "rewrittenUSD": promptCache.rewrittenUSD.map(Self.money) as Any,
                                   "lastCause": promptCache.lastCause as Any, "sessions": promptCache.sessions]
        }
        if let antigravityReading = order.compactMap({ tools[$0]?.reading }).first(where: { $0.tool == .antigravity }),
           let accounts = antigravityReading.accounts, !accounts.isEmpty {
            let readyAccounts = accounts.filter { $0.status == "ready" }
            let claudeAvailable = readyAccounts.filter(\.hasClaudeSessionRoom)
            let geminiAvailable = readyAccounts.filter(\.hasGeminiSessionRoom)
            let current = accounts.first(where: \.isCurrent) ?? accounts.first
            let nextClaudeSlot = AntigravityAccounts.recommendedNextSlot(accounts: accounts, startingAfter: current?.slot, forModelFamily: "claude")
            let nextGeminiSlot = AntigravityAccounts.recommendedNextSlot(accounts: accounts, startingAfter: current?.slot, forModelFamily: "gemini")
            let earliestClaudeReset = AntigravityAccounts.earliestSessionReset(accounts: accounts, forModelFamily: "claude")
            let earliestGeminiReset = AntigravityAccounts.earliestSessionReset(accounts: accounts, forModelFamily: "gemini")

            let activeHasClaudeRoom = current?.hasClaudeSessionRoom ?? false
            let activeHasGeminiRoom = current?.hasGeminiSessionRoom ?? false
            let activeClaudeUsed = current?.claudeSessionWindow?.usedFraction
            let activeGeminiUsed = current?.geminiSessionWindow?.usedFraction

            let adviceTuple = Self.accountRotationAdvice(current: current,
                                                         accounts: accounts,
                                                         nextClaudeSlot: nextClaudeSlot,
                                                         nextGeminiSlot: nextGeminiSlot,
                                                         earliestClaudeReset: earliestClaudeReset,
                                                         earliestGeminiReset: earliestGeminiReset,
                                                         now: now)
            let rotationAdvice = adviceTuple.overall
            let claudeRotationAdvice = adviceTuple.claude
            let geminiRotationAdvice = adviceTuple.gemini

            var agySummary: [String: Any] = [
                "total": accounts.count,
                "signedIn": readyAccounts.count,
                "currentSlot": current?.slot as Any,
                "currentEmail": current?.email as Any,
                "activeSlot": current?.slot as Any,
                "activeEmail": current?.email as Any,
                "activeHasClaudeRoom": activeHasClaudeRoom,
                "activeHasGeminiRoom": activeHasGeminiRoom,
                "rotationOrder": AntigravityAccounts.rotationOrder,
                "claudeAvailableCount": claudeAvailable.count,
                "geminiAvailableCount": geminiAvailable.count,
                "recommendedNextSlot": nextClaudeSlot?.slot as Any,
                "recommendedNextEmail": nextClaudeSlot?.email as Any,
                "recommendedNextClaudeSlot": nextClaudeSlot?.slot as Any,
                "recommendedNextClaudeEmail": nextClaudeSlot?.email as Any,
                "recommendedNextGeminiSlot": nextGeminiSlot?.slot as Any,
                "recommendedNextGeminiEmail": nextGeminiSlot?.email as Any,
                "rotationAdvice": rotationAdvice,
                "claudeRotationAdvice": claudeRotationAdvice,
                "geminiRotationAdvice": geminiRotationAdvice,
                "slots": accounts.map { acct -> [String: Any] in
                    var slotDict: [String: Any] = [
                        "slot": acct.slot,
                        "email": acct.email,
                        "status": acct.status,
                        "isCurrent": acct.isCurrent,
                        "hasClaudeRoom": acct.hasClaudeSessionRoom,
                        "hasGeminiRoom": acct.hasGeminiSessionRoom,
                    ]
                    if let room = acct.claudeSessionRoomFraction { slotDict["claudeSessionRoom"] = Oracle.fraction(room) }
                    if let room = acct.geminiSessionRoomFraction { slotDict["geminiSessionRoom"] = Oracle.fraction(room) }
                    if let win = acct.claudeSessionWindow {
                        if let used = win.usedFraction { slotDict["claudeSessionUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt {
                            slotDict["claudeSessionResetsAt"] = Oracle.timestamp(reset)
                            slotDict["claudeSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
                        }
                    }
                    if let win = acct.geminiSessionWindow {
                        if let used = win.usedFraction { slotDict["geminiSessionUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt {
                            slotDict["geminiSessionResetsAt"] = Oracle.timestamp(reset)
                            slotDict["geminiSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
                        }
                    }
                    if let win = acct.claudeWeeklyWindow {
                        if let used = win.usedFraction { slotDict["claudeWeeklyUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt { slotDict["claudeWeeklyResetsAt"] = Oracle.timestamp(reset) }
                    }
                    if let win = acct.geminiWeeklyWindow {
                        if let used = win.usedFraction { slotDict["geminiWeeklyUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt { slotDict["geminiWeeklyResetsAt"] = Oracle.timestamp(reset) }
                    }
                    return slotDict
                }
            ]
            if let used = activeClaudeUsed { agySummary["activeClaudeSessionUsed"] = Oracle.fraction(used) }
            if let reset = current?.claudeSessionWindow?.resetsAt {
                agySummary["activeClaudeSessionResetsAt"] = Oracle.timestamp(reset)
                agySummary["activeClaudeSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
            }
            if let used = activeGeminiUsed { agySummary["activeGeminiSessionUsed"] = Oracle.fraction(used) }
            if let reset = current?.geminiSessionWindow?.resetsAt {
                agySummary["activeGeminiSessionResetsAt"] = Oracle.timestamp(reset)
                agySummary["activeGeminiSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
            }
            if let reset = earliestClaudeReset {
                agySummary["earliestClaudeResetSlot"] = reset.slot
                agySummary["earliestClaudeResetAt"] = Oracle.timestamp(reset.resetsAt)
                agySummary["earliestClaudeResetsInSeconds"] = max(0, Int(reset.resetsAt.timeIntervalSince(now)))
            }
            if let reset = earliestGeminiReset {
                agySummary["earliestGeminiResetSlot"] = reset.slot
                agySummary["earliestGeminiResetAt"] = Oracle.timestamp(reset.resetsAt)
                agySummary["earliestGeminiResetsInSeconds"] = max(0, Int(reset.resetsAt.timeIntervalSince(now)))
            }
            root["antigravityAccounts"] = agySummary
        }
        if let chatgptReading = order.compactMap({ tools[$0]?.reading }).first(where: { $0.tool == .chatgpt }) {
            let weeklyResets = chatgptReading.windows.filter { ChatGPTProvider.weeklyWindowIDs.contains($0.id) }
            let emptyWeeks = weeklyResets.filter { ($0.usedFraction ?? 1) < 0.15 }
            let burnedWeeks = weeklyResets.filter { ($0.usedFraction ?? 0) >= 0.85 }
            let inProgressWeeks = weeklyResets.filter {
                let u = $0.usedFraction ?? 0
                return u >= 0.15 && u < 0.85
            }
            let earliestReset = weeklyResets.compactMap(\.resetsAt).min()
            let activeWindow = weeklyResets.first(where: { ($0.usedFraction ?? 0) < 0.85 }) ?? weeklyResets.first
            let activeLabel = activeWindow?.label ?? "Weekly reset 1"
            let firstEmptyLabel = emptyWeeks.first?.label ?? "Weekly reset 1"
            let burnAdvice = emptyWeeks.isEmpty
                ? "All weekly resets burned or in use"
                : "Burn \(firstEmptyLabel) (empty, priority 1)"

            let activeUsed = activeWindow?.usedFraction
            let activeReset = activeWindow?.resetsAt
            let windowsDetails: [[String: Any]] = weeklyResets.map { w in
                let u = w.usedFraction ?? 0
                let statusStr = u < 0.15 ? "empty" : (u >= 0.85 ? "burned" : "inProgress")
                var d: [String: Any] = [
                    "id": w.id,
                    "label": w.label,
                    "usedFraction": Oracle.fraction(u),
                    "headroomFraction": Oracle.fraction(max(0, 1.0 - u)),
                    "status": statusStr
                ]
                if let r = w.resetsAt {
                    d["resetsAt"] = Oracle.timestamp(r)
                    d["resetsInSeconds"] = max(0, Int(r.timeIntervalSince(now)))
                }
                return d
            }

            root["chatgptHeavy"] = [
                "active": true,
                "burnPriority": 1,
                "totalResets": weeklyResets.count,
                "emptyResets": emptyWeeks.count,
                "burnedResets": burnedWeeks.count,
                "inProgressResets": inProgressWeeks.count,
                "preferBurn": !emptyWeeks.isEmpty,
                "activeWindowID": activeWindow?.id as Any,
                "activeWindowLabel": activeLabel,
                "activeWindowResetsAt": activeReset.map(Oracle.timestamp) as Any,
                "activeWindowResetsInSeconds": activeReset.map { max(0, Int($0.timeIntervalSince(now))) } as Any,
                "activeWindowUsedFraction": activeUsed.map(Oracle.fraction) as Any,
                "nextResetAt": earliestReset.map(Oracle.timestamp) as Any,
                "nextResetInSeconds": earliestReset.map { max(0, Int($0.timeIntervalSince(now))) } as Any,
                "emptyWindowIDs": emptyWeeks.map(\.id),
                "headroomFractions": weeklyResets.map { Oracle.fraction(max(0, 1.0 - ($0.usedFraction ?? 0))) },
                "windows": windowsDetails,
                "burnAdvice": burnAdvice
            ]
        }
        return root
    }

    var json: Data {
        (try? JSONSerialization.data(withJSONObject: Oracle.scrub(object, home: Paths.home.path), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func stateName(_ state: AgentSession.State) -> String {
        switch state {
        case .idle: "idle"
        case .working: "working"
        case .waiting: "waiting"
        }
    }

    static func accountRotationAdvice(current: AntigravityAccount?,
                                      accounts: [AntigravityAccount],
                                      nextClaudeSlot: AntigravityAccount?,
                                      nextGeminiSlot: AntigravityAccount?,
                                      earliestClaudeReset: (slot: String, resetsAt: Date)?,
                                      earliestGeminiReset: (slot: String, resetsAt: Date)?,
                                      now: Date) -> (overall: String, claude: String, gemini: String) {
        guard let cur = current else {
            return ("No active slot detected.", "No active slot detected.", "No active slot detected.")
        }
        let activeHasClaudeRoom = cur.hasClaudeSessionRoom
        let activeHasGeminiRoom = cur.hasGeminiSessionRoom
        let activeClaudeUsed = cur.claudeSessionWindow?.usedFraction
        let activeGeminiUsed = cur.geminiSessionWindow?.usedFraction

        let claudeAdvice: String
        if !activeHasClaudeRoom {
            if let next = nextClaudeSlot {
                claudeAdvice = "Active slot [\(cur.slot)] Claude session exhausted. Rotate to [\(next.slot)] (\(next.email))."
            } else if let reset = earliestClaudeReset {
                let duration = RelativeTime.resets(reset.resetsAt, hasLimit: true, now: now)
                claudeAdvice = "All Antigravity Claude sessions exhausted. Earliest [\(reset.slot)] \(duration)."
            } else {
                claudeAdvice = "All Antigravity Claude sessions exhausted."
            }
        } else if let used = activeClaudeUsed, used >= 0.75 {
            if let next = nextClaudeSlot {
                claudeAdvice = "Active slot [\(cur.slot)] Claude session at \(Int((used * 100).rounded()))%. Next in rotation: [\(next.slot)]."
            } else {
                claudeAdvice = "Active slot [\(cur.slot)] Claude session at \(Int((used * 100).rounded()))%."
            }
        } else {
            let roomPercent = Int(((1.0 - (activeClaudeUsed ?? 0)) * 100).rounded())
            if let next = nextClaudeSlot {
                claudeAdvice = "Active slot [\(cur.slot)] has \(roomPercent)% Claude session room. Next in rotation: [\(next.slot)] (\(next.email))."
            } else {
                claudeAdvice = "Active slot [\(cur.slot)] has \(roomPercent)% Claude session room."
            }
        }

        let geminiAdvice: String
        if !activeHasGeminiRoom {
            if let next = nextGeminiSlot {
                geminiAdvice = "Active slot [\(cur.slot)] Gemini session exhausted. Rotate to [\(next.slot)] (\(next.email))."
            } else if let reset = earliestGeminiReset {
                let duration = RelativeTime.resets(reset.resetsAt, hasLimit: true, now: now)
                geminiAdvice = "All Antigravity Gemini sessions exhausted. Earliest [\(reset.slot)] \(duration)."
            } else {
                geminiAdvice = "All Antigravity Gemini sessions exhausted."
            }
        } else if let used = activeGeminiUsed, used >= 0.75 {
            if let next = nextGeminiSlot {
                geminiAdvice = "Active slot [\(cur.slot)] Gemini session at \(Int((used * 100).rounded()))%. Next in rotation: [\(next.slot)]."
            } else {
                geminiAdvice = "Active slot [\(cur.slot)] Gemini session at \(Int((used * 100).rounded()))%."
            }
        } else {
            let roomPercent = Int(((1.0 - (activeGeminiUsed ?? 0)) * 100).rounded())
            if let next = nextGeminiSlot {
                geminiAdvice = "Active slot [\(cur.slot)] has \(roomPercent)% Gemini session room. Next in rotation: [\(next.slot)] (\(next.email))."
            } else {
                geminiAdvice = "Active slot [\(cur.slot)] has \(roomPercent)% Gemini session room."
            }
        }

        let overallAdvice: String
        if !activeHasClaudeRoom && !activeHasGeminiRoom {
            if let next = nextClaudeSlot ?? nextGeminiSlot {
                overallAdvice = "Active slot [\(cur.slot)] Claude and Gemini sessions exhausted. Rotate to [\(next.slot)] (\(next.email))."
            } else if let reset = earliestClaudeReset ?? earliestGeminiReset {
                let duration = RelativeTime.resets(reset.resetsAt, hasLimit: true, now: now)
                overallAdvice = "All Antigravity sessions exhausted. Earliest [\(reset.slot)] \(duration)."
            } else {
                overallAdvice = "All Antigravity sessions exhausted."
            }
        } else if !activeHasClaudeRoom {
            overallAdvice = claudeAdvice
        } else if !activeHasGeminiRoom {
            overallAdvice = geminiAdvice
        } else if let cUsed = activeClaudeUsed, cUsed >= 0.75 {
            overallAdvice = claudeAdvice
        } else if let gUsed = activeGeminiUsed, gUsed >= 0.75 {
            overallAdvice = geminiAdvice
        } else {
            let cRoom = Int(((1.0 - (activeClaudeUsed ?? 0)) * 100).rounded())
            let gRoom = Int(((1.0 - (activeGeminiUsed ?? 0)) * 100).rounded())
            if let next = nextClaudeSlot ?? nextGeminiSlot {
                overallAdvice = "Active slot [\(cur.slot)] has \(cRoom)% Claude room, \(gRoom)% Gemini room. Next in rotation: [\(next.slot)] (\(next.email))."
            } else {
                overallAdvice = "Active slot [\(cur.slot)] has \(cRoom)% Claude room, \(gRoom)% Gemini room."
            }
        }

        return (overallAdvice, claudeAdvice, geminiAdvice)
    }

    private func toolObject(_ tool: ToolID, _ status: ToolStatus) -> [String: Any] {
        var object: [String: Any] = ["tool": tool.rawValue, "name": tool.displayName, "status": Oracle.kind(status), "problem": status.problem as Any]
        if case .idle(let message) = status { object["note"] = message }
        if let reading = status.reading {
            object["plan"] = reading.plan as Any
            object["fetchedAt"] = Oracle.timestamp(reading.fetchedAt)
            object["stale"] = status.staleReading != nil
            if tool == .antigravity, let accounts = reading.accounts, !accounts.isEmpty {
                let readyAccounts = accounts.filter { $0.status == "ready" }
                let claudeAvailable = readyAccounts.filter(\.hasClaudeSessionRoom)
                let geminiAvailable = readyAccounts.filter(\.hasGeminiSessionRoom)
                let current = accounts.first(where: \.isCurrent) ?? accounts.first
                let nextClaudeSlot = AntigravityAccounts.recommendedNextSlot(accounts: accounts, startingAfter: current?.slot, forModelFamily: "claude")
                let nextGeminiSlot = AntigravityAccounts.recommendedNextSlot(accounts: accounts, startingAfter: current?.slot, forModelFamily: "gemini")
                let earliestClaudeReset = AntigravityAccounts.earliestSessionReset(accounts: accounts, forModelFamily: "claude")
                let earliestGeminiReset = AntigravityAccounts.earliestSessionReset(accounts: accounts, forModelFamily: "gemini")

                let activeClaudeUsed = current?.claudeSessionWindow?.usedFraction
                let activeGeminiUsed = current?.geminiSessionWindow?.usedFraction

                object["accounts"] = accounts.map { acct -> [String: Any] in
                    var acctObj: [String: Any] = [
                        "slot": acct.slot,
                        "index": acct.index,
                        "email": acct.email,
                        "home": acct.homeDirectory,
                        "isCurrent": acct.isCurrent,
                        "status": acct.status,
                        "hasClaudeRoom": acct.hasClaudeSessionRoom,
                        "hasGeminiRoom": acct.hasGeminiSessionRoom,
                        "windows": acct.windows.map { w in
                            var winObj: [String: Any] = [
                                "id": w.id,
                                "label": w.label,
                            ]
                            if let used = w.usedFraction { winObj["usedFraction"] = Oracle.fraction(used) }
                            if let resets = w.resetsAt { winObj["resetsAt"] = Oracle.timestamp(resets) }
                            if let period = w.periodDuration { winObj["periodDuration"] = Int(period) }
                            return winObj
                        }
                    ]
                    if let room = acct.claudeSessionRoomFraction { acctObj["claudeSessionRoom"] = Oracle.fraction(room) }
                    if let room = acct.geminiSessionRoomFraction { acctObj["geminiSessionRoom"] = Oracle.fraction(room) }
                    if let win = acct.claudeSessionWindow {
                        if let used = win.usedFraction { acctObj["claudeSessionUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt {
                            acctObj["claudeSessionResetsAt"] = Oracle.timestamp(reset)
                            acctObj["claudeSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
                        }
                    }
                    if let win = acct.geminiSessionWindow {
                        if let used = win.usedFraction { acctObj["geminiSessionUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt {
                            acctObj["geminiSessionResetsAt"] = Oracle.timestamp(reset)
                            acctObj["geminiSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
                        }
                    }
                    if let win = acct.claudeWeeklyWindow {
                        if let used = win.usedFraction { acctObj["claudeWeeklyUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt { acctObj["claudeWeeklyResetsAt"] = Oracle.timestamp(reset) }
                    }
                    if let win = acct.geminiWeeklyWindow {
                        if let used = win.usedFraction { acctObj["geminiWeeklyUsed"] = Oracle.fraction(used) }
                        if let reset = win.resetsAt { acctObj["geminiWeeklyResetsAt"] = Oracle.timestamp(reset) }
                    }
                    if let plan = acct.plan { acctObj["plan"] = plan }
                    if let problem = acct.problem { acctObj["problem"] = problem }
                    if let lastActive = acct.lastActive { acctObj["lastActive"] = Oracle.timestamp(lastActive) }
                    return acctObj
                }
                object["accountCount"] = accounts.count
                object["signedInCount"] = readyAccounts.count
                object["claudeAvailableCount"] = claudeAvailable.count
                object["geminiAvailableCount"] = geminiAvailable.count
                object["recommendedNextSlot"] = nextClaudeSlot?.slot as Any
                object["recommendedNextEmail"] = nextClaudeSlot?.email as Any
                object["recommendedNextClaudeSlot"] = nextClaudeSlot?.slot as Any
                object["recommendedNextClaudeEmail"] = nextClaudeSlot?.email as Any
                object["recommendedNextGeminiSlot"] = nextGeminiSlot?.slot as Any
                object["recommendedNextGeminiEmail"] = nextGeminiSlot?.email as Any

                let adviceTuple = Self.accountRotationAdvice(current: current,
                                                             accounts: accounts,
                                                             nextClaudeSlot: nextClaudeSlot,
                                                             nextGeminiSlot: nextGeminiSlot,
                                                             earliestClaudeReset: earliestClaudeReset,
                                                             earliestGeminiReset: earliestGeminiReset,
                                                             now: now)
                object["rotationAdvice"] = adviceTuple.overall
                object["claudeRotationAdvice"] = adviceTuple.claude
                object["geminiRotationAdvice"] = adviceTuple.gemini

                object["activeSlot"] = current?.slot as Any
                object["activeEmail"] = current?.email as Any
                object["activeHasClaudeRoom"] = current?.hasClaudeSessionRoom ?? false
                object["activeHasGeminiRoom"] = current?.hasGeminiSessionRoom ?? false
                if let used = activeClaudeUsed { object["activeClaudeSessionUsed"] = Oracle.fraction(used) }
                if let reset = current?.claudeSessionWindow?.resetsAt {
                    object["activeClaudeSessionResetsAt"] = Oracle.timestamp(reset)
                    object["activeClaudeSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
                }
                if let used = activeGeminiUsed { object["activeGeminiSessionUsed"] = Oracle.fraction(used) }
                if let reset = current?.geminiSessionWindow?.resetsAt {
                    object["activeGeminiSessionResetsAt"] = Oracle.timestamp(reset)
                    object["activeGeminiSessionResetsInSeconds"] = max(0, Int(reset.timeIntervalSince(now)))
                }
                if let reset = earliestClaudeReset {
                    object["earliestClaudeResetSlot"] = reset.slot
                    object["earliestClaudeResetAt"] = Oracle.timestamp(reset.resetsAt)
                    object["earliestClaudeResetsInSeconds"] = max(0, Int(reset.resetsAt.timeIntervalSince(now)))
                }
                if let reset = earliestGeminiReset {
                    object["earliestGeminiResetSlot"] = reset.slot
                    object["earliestGeminiResetAt"] = Oracle.timestamp(reset.resetsAt)
                    object["earliestGeminiResetsInSeconds"] = max(0, Int(reset.resetsAt.timeIntervalSince(now)))
                }
                if let cur = current {
                    object["currentSlot"] = cur.slot
                    object["currentEmail"] = cur.email
                }
            }
            if tool == .chatgpt {
                object["chatgptHeavy"] = true
                let weeklyResets = reading.windows.filter { ChatGPTProvider.weeklyWindowIDs.contains($0.id) }
                let emptyWeeks = weeklyResets.filter { ($0.usedFraction ?? 1) < 0.15 }
                let burnedWeeks = weeklyResets.filter { ($0.usedFraction ?? 0) >= 0.85 }
                let inProgressWeeks = weeklyResets.filter {
                    let u = $0.usedFraction ?? 0
                    return u >= 0.15 && u < 0.85
                }
                let earliestReset = weeklyResets.compactMap(\.resetsAt).min()
                let activeWindow = weeklyResets.first(where: { ($0.usedFraction ?? 0) < 0.85 }) ?? weeklyResets.first
                let activeLabel = activeWindow?.label ?? "Weekly reset 1"
                let firstEmptyLabel = emptyWeeks.first?.label ?? "Weekly reset 1"

                object["weeklyResetsCount"] = weeklyResets.count
                object["emptyResetsCount"] = emptyWeeks.count
                object["burnedResetsCount"] = burnedWeeks.count
                object["inProgressResetsCount"] = inProgressWeeks.count
                object["burnPriority"] = 1
                object["burnAdvice"] = emptyWeeks.isEmpty ? "All weekly resets burned or in use" : "Burn \(firstEmptyLabel) (empty, priority 1)"
                if let earliest = earliestReset {
                    object["earliestResetAt"] = Oracle.timestamp(earliest)
                    object["earliestResetInSeconds"] = max(0, Int(earliest.timeIntervalSince(now)))
                }
                if let active = activeWindow {
                    object["activeWindowID"] = active.id
                    object["activeWindowLabel"] = activeLabel
                    if let r = active.resetsAt {
                        object["activeWindowResetsAt"] = Oracle.timestamp(r)
                        object["activeWindowResetsInSeconds"] = max(0, Int(r.timeIntervalSince(now)))
                    }
                    if let u = active.usedFraction {
                        object["activeWindowUsedFraction"] = Oracle.fraction(u)
                    }
                }
                let windowsDetails: [[String: Any]] = weeklyResets.map { w in
                    let u = w.usedFraction ?? 0
                    let statusStr = u < 0.15 ? "empty" : (u >= 0.85 ? "burned" : "inProgress")
                    var d: [String: Any] = [
                        "id": w.id,
                        "label": w.label,
                        "usedFraction": Oracle.fraction(u),
                        "headroomFraction": Oracle.fraction(max(0, 1.0 - u)),
                        "status": statusStr
                    ]
                    if let r = w.resetsAt {
                        d["resetsAt"] = Oracle.timestamp(r)
                        d["resetsInSeconds"] = max(0, Int(r.timeIntervalSince(now)))
                    }
                    return d
                }
                object["resets"] = windowsDetails
            }
            object["windows"] = reading.windows.map { window -> [String: Any] in
                let key = DrainLog.Key(tool: tool, window: window.id)
                let drain = drains[key]
                let runOut = runOuts[key]
                return [
                    "id": window.id, "label": window.label, "usedFraction": window.usedFraction.map(Oracle.fraction) as Any,
                    "resetsAt": window.resetsAt.map(Oracle.timestamp) as Any, "periodDuration": window.periodDuration.map { Int($0) } as Any,
                    "pace": Pace.status(for: window, now: now).map { String(describing: $0) } as Any,
                    "projectedFraction": projected(window).map(Oracle.fraction) as Any,
                    "model": window.model as Any, "note": window.note as Any, "source": window.source.rawValue,
                    "hiddenByDefault": window.hiddenByDefault, "rawUsedPercent": window.rawUsedPercent as Any, "amountUSD": window.amountUSD.map(Self.money) as Any,
                    "recentPerHour": window.recentRate.map(Oracle.fraction) as Any,
                    "drainLastHour": drain.map { ["from": Oracle.fraction($0.from), "to": Oracle.fraction($0.to), "perHour": $0.perHour.map(Oracle.fraction) as Any] } as Any,
                    "runOut": runOut.map { ["earliestAt": Oracle.timestamp(now.addingTimeInterval($0.earliest)), "latestAt": Oracle.timestamp(now.addingTimeInterval($0.latest)),
                                            "samples": $0.sampleCount] } as Any,
                ]
            }
        }
        return object
    }

    private func projected(_ window: LimitWindow) -> Double? {
        Pace.evaluate(window, now: now)?.projectedFraction
    }

    static func buckets(_ tokens: TokenBreakdown) -> [String: Any] {
        ["input": tokens.input, "output": tokens.output, "cacheWrite5m": tokens.cacheWrite5m, "cacheWrite1h": tokens.cacheWrite1h, "cacheRead": tokens.cacheRead]
    }

    private func costObject(_ cost: CostSummary) -> [String: Any] {
        func shares(_ list: [CostShare]) -> [[String: Any]] {
            list.map { ["name": $0.name, "cost": Self.money($0.cost)] }
        }
        // `priceSources` is the range's own (PriceSource.key): the tables that priced the lines inside it.
        func range(_ totals: RangeTotals) -> [String: Any] {
            ["cost": Self.money(totals.cost), "tokens": totals.tokens.total, "cacheReadShare": totals.tokens.cacheReadShare.map(Oracle.fraction) as Any,
             "tokenBuckets": Self.buckets(totals.tokens), "cacheWrite1hShare": CacheTTL.oneHourShare(totals.tokens).map(Oracle.fraction) as Any,
             "costPerMillionTokens": totals.costPerMillionTokens.map(Self.money) as Any,
             "byModel": shares(totals.models), "byProject": shares(totals.projects), "priceSources": totals.priceSources.map(\.key).sorted()]
        }
        var object: [String: Any] = [
            "currency": "USD",
            "today": Self.money(cost.today), "yesterday": Self.money(cost.yesterday), "last30Days": Self.money(cost.last30Days),
            "last90Days": Self.money(cost.totals(.last90Days).cost), "month": Self.money(cost.totals(.month).cost),
            "lastHour": Self.money(cost.lastHour), "typicalHourly": Self.money(cost.typicalHourly),
            "burnMultiple": cost.burnMultiple.map { Oracle.fraction($0) } as Any,
            "unpricedModels": cost.unpricedModels.sorted(),
            // The 30-day window's, the span the headline figures cover; each range below carries its own.
            "priceSources": cost.totals(.last30Days).priceSources.map(\.key).sorted(),
            "sinceFirstUse": Self.money(cost.sinceFirstUse), "firstUse": cost.firstUse.map(Oracle.timestamp) as Any,
            "ranges": ["today": range(cost.totals(.today)), "yesterday": range(cost.totals(.yesterday)), "week": range(cost.totals(.week)),
                       "month": range(cost.totals(.month)), "last30Days": range(cost.totals(.last30Days)), "last90Days": range(cost.totals(.last90Days))],
        ]
        if let week = cost.week {
            object["week"] = ["start": Oracle.timestamp(week.start), "cost": Self.money(week.cost), "perPercentOfWeekly": week.perPercent.map(Self.money) as Any]
        }
        if let block = cost.block {
            object["block"] = ["start": Oracle.timestamp(block.start), "end": Oracle.timestamp(block.end), "cost": Self.money(block.cost),
                               "tokens": block.tokens.total, "tokenBuckets": Self.buckets(block.tokens), "tokensPerMinute": block.tokensPerMinute.map { Int($0.rounded()) } as Any]
        }
        if let metering = cost.sessionMetering {
            object["metering"] = ["tokensPerPercentOfSession": Int(metering.tokensPerPercent.rounded()), "median30Days": metering.median.map { Int($0.rounded()) } as Any,
                                  "heavierBy": metering.multiple.map(Oracle.fraction) as Any]
        }
        if !cost.providers.isEmpty {
            object["providers"] = cost.providers.map { provider -> [String: Any] in
                var entry: [String: Any] = [
                    "tool": provider.tool.rawValue, "source": provider.source.rawValue, "scannedAt": Oracle.timestamp(provider.scannedAt),
                    "today": Self.money(provider.totals(.today).cost), "yesterday": Self.money(provider.totals(.yesterday).cost),
                    "week": Self.money(provider.totals(.week).cost), "month": Self.money(provider.totals(.month).cost),
                    "last30Days": Self.money(provider.totals(.last30Days).cost), "last90Days": Self.money(provider.totals(.last90Days).cost),
                    "byModel": shares(provider.totals(.last30Days).models), "unpricedModels": provider.unpricedModels.sorted(),
                    "priceSources": provider.totals(.last30Days).priceSources.map(\.key).sorted(),
                ]
                if let lastHour = provider.lastHour { entry["lastHour"] = Self.money(lastHour) }
                if let typical = provider.typicalHourly { entry["typicalHourly"] = Self.money(typical) }
                if let burn = provider.burnMultiple { entry["burnMultiple"] = Oracle.fraction(burn) }
                if let problem = provider.problem { entry["problem"] = problem }
                return entry
            }
        }
        return object
    }

    /// One row per day, oldest first: day, cost, the five token buckets, the top model, per-model and per-project cost.
    static func historyRows(_ history: [Date: CostHistory.Record], calendar: Calendar = .current) -> [[String: Any]] {
        history.sorted { $0.key < $1.key }.map { day, record in
            ["day": CostHistory.key(day, calendar: calendar), "cost": money(record.cost), "tokenBuckets": buckets(record.tokens), "tokens": record.tokens.total,
             "topModel": record.topModel as Any, "byModel": record.byModel.mapValues(money), "byProject": record.byProject.mapValues(money),
             "sessionTokensPerPercent": record.sessionTokensPerPercent.map { Int($0.rounded()) } as Any]
        }
    }

    static func money(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.4f", value), locale: Locale(identifier: "en_US_POSIX"))
    }
}
