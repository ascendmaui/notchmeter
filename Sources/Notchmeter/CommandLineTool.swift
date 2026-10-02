import Foundation
import os

/// `notchmeter [tool] [--force] [--json]`: the same report the panel shows, from the running app's cache rather than
/// a fresh read of every vendor. The cache is the local API when it is on, else the report file the app writes
/// beside its drain log while it runs; a live probe (one request per signed-in tool and a transcript scan) happens
/// only with `--force` or when the app is not running. "Install command line tool…" in Settings symlinks this
/// executable to ~/.local/bin/notchmeter (or /usr/local/bin when writable), so an update carries it along.
enum CommandLineTool {
    static let linkName = "notchmeter"
    /// A report older than this counts as the app not running.
    static let reportFreshFor: TimeInterval = 15 * 60

    enum Source: String {
        case localAPI = "local API"
        case reportFile = "report file"
        case probe = "live probe"
    }

    /// `--mcp` wins over the link name: the plugin starts the MCP server as `notchmeter --mcp`, through this same
    /// link, and taking that for the tool printed the report and exited before the server ever answered.
    static func isInvokedAsTool(arguments: [String]) -> Bool {
        guard !arguments.contains("--mcp") else { return false }
        return arguments.contains("--cli") || URL(fileURLWithPath: arguments[0]).lastPathComponent == linkName
    }

    /// The cached report and where it came from, or nil when the app is not running (or `force`).
    static func cachedReport(force: Bool, reportFile: URL = Paths.reportFile, now: Date = Date()) -> (data: Data, source: Source)? {
        guard !force else { return nil }
        if let data = LocalAPIClient.get("/v1/limits") { return (data, .localAPI) }
        guard let data = try? Data(contentsOf: reportFile), Self.isFresh(data, now: now) else { return nil }
        return (data, .reportFile)
    }

    /// The report file is the running app's when its `generatedAt` is recent and the `pid` it names is alive.
    static func isFresh(_ data: Data, now: Date, alive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generated = (root["generatedAt"] as? String).flatMap(DateParsing.iso8601), now.timeIntervalSince(generated) < reportFreshFor
        else { return false }
        if let pid = JSON.number(root["pid"]).map({ Int32($0) }) { return alive(pid) }
        return true
    }

    /// The tool named on the command line, when one is.
    static func tool(in arguments: [String]) -> ToolID? {
        arguments.dropFirst().lazy.filter { !$0.hasPrefix("-") }.compactMap { ToolID(rawValue: $0.lowercased()) }.first
    }

    enum Subcommand: String, CaseIterable {
        case accounts
        case rotation
        case chatgptHeavy = "chatgpt-heavy"
    }

    /// The subcommand named on the command line, when one is.
    static func subcommand(in arguments: [String]) -> Subcommand? {
        let args = arguments.dropFirst().lazy.filter { !$0.hasPrefix("-") }.map { $0.lowercased() }
        for arg in args {
            if let sub = Subcommand(rawValue: arg) { return sub }
            if arg == "chatgpt_heavy" || arg == "chatgptheavy" { return .chatgptHeavy }
        }
        if arguments.contains("--accounts") { return .accounts }
        if arguments.contains("--rotation") { return .rotation }
        if arguments.contains("--chatgpt-heavy") || arguments.contains("--chatgpt_heavy") { return .chatgptHeavy }
        return nil
    }

    /// The `--help` usage line, with the tools it takes read off the enum so it cannot fall behind it.
    static let usage = "usage: notchmeter [\(ToolID.allCases.map(\.rawValue).joined(separator: "|"))|accounts|rotation|chatgpt-heavy] [--force] [--json]"

    static func run(arguments: [String]) -> Never {
        if arguments.contains("--help") || arguments.contains("-h") {
            Probe.emit(usage)
            Probe.emit("  reads the running app's cached report; --force reads every vendor afresh")
            Probe.emit("  subcommands: accounts, rotation, chatgpt-heavy")
            Probe.emit("  exit codes: 0 fine, 10 near a limit, 11 limit hit, 20 nothing used, 30 no data")
            exit(0)
        }
        let json = arguments.contains("--json")
        let force = arguments.contains("--force")
        let tool = tool(in: arguments)
        let subcommand = subcommand(in: arguments)
        if let (data, source) = cachedReport(force: force) {
            if let subcommand {
                let parsed = Self.parsedSubcommand(data, subcommand: subcommand)
                if json {
                    FileHandle.standardOutput.write(parsed.data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    Probe.emit("\(AppInfo.name) (from the app's \(source.rawValue))")
                    Probe.emit(parsed.text)
                }
                exit(parsed.exitCode)
            }
            let report = Self.parsed(data, tool: tool)
            if json {
                FileHandle.standardOutput.write(report.data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                Probe.emit("\(AppInfo.name) (from the app's \(source.rawValue))")
                Probe.emit(report.text)
            }
            exit(report.exitCode)
        }
        Task.detached {
            let report = await Probe.gather()
            if let subcommand {
                let parsed = Self.parsedSubcommand(report.json, subcommand: subcommand)
                if json {
                    FileHandle.standardOutput.write(parsed.data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                } else {
                    Probe.emit("\(AppInfo.name) (live probe; the app is not running or --force was given)")
                    Probe.emit(parsed.text)
                }
                exit(parsed.exitCode)
            }
            let limited = tool.map { report.limited(to: $0) } ?? report
            if json {
                FileHandle.standardOutput.write(limited.json)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                Probe.emit("\(AppInfo.name) (live probe; the app is not running or --force was given)")
                Probe.emit(Probe.describe(limited))
            }
            exit(limited.exitCode.rawValue)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// A cached report, optionally narrowed to one tool, with its text rendering and exit code.
    static func parsed(_ data: Data, tool: ToolID?) -> (data: Data, text: String, exitCode: Int32) {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (data, String(decoding: data, as: UTF8.self), 30) }
        if let tool, let tools = root["tools"] as? [[String: Any]] {
            root["tools"] = tools.filter { $0["tool"] as? String == tool.rawValue }
            root["advice"] = (root["advice"] as? [[String: Any]])?.filter { $0["tool"] as? String == tool.rawValue } ?? []
            if tool != .claude { root["cost"] = nil }
            if tool != .antigravity { root["antigravityAccounts"] = nil }
            if tool != .chatgpt { root["chatgptHeavy"] = nil }
        }
        let encoded = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? data
        return (encoded, describe(root), Int32(JSON.number(root["exitCode"]) ?? 30))
    }

    /// Subcommand parsing: accounts, rotation, or chatgpt-heavy.
    static func parsedSubcommand(_ data: Data, subcommand: Subcommand) -> (data: Data, text: String, exitCode: Int32) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (data, String(decoding: data, as: UTF8.self), 30)
        }
        switch subcommand {
        case .accounts:
            guard let agy = root["antigravityAccounts"] as? [String: Any] else {
                let err: [String: Any] = ["error": "No Antigravity accounts configured"]
                let errData = (try? JSONSerialization.data(withJSONObject: err)) ?? data
                return (errData, "No Antigravity accounts configured.", 30)
            }
            let encoded = (try? JSONSerialization.data(withJSONObject: agy, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? data
            let exitCode: Int32 = (agy["signedIn"] as? Int ?? 0) > 0 ? 0 : 30
            return (encoded, describeAccounts(root), exitCode)
        case .rotation:
            guard let agy = root["antigravityAccounts"] as? [String: Any] else {
                let err: [String: Any] = ["error": "No Antigravity accounts configured"]
                let errData = (try? JSONSerialization.data(withJSONObject: err)) ?? data
                return (errData, "No Antigravity accounts configured.", 30)
            }
            var rotationObj: [String: Any] = [
                "activeSlot": agy["activeSlot"] as Any,
                "activeEmail": agy["activeEmail"] as Any,
                "currentSlot": agy["currentSlot"] as Any,
                "currentEmail": agy["currentEmail"] as Any,
                "activeHasClaudeRoom": agy["activeHasClaudeRoom"] as Any,
                "activeHasGeminiRoom": agy["activeHasGeminiRoom"] as Any,
                "recommendedNextSlot": agy["recommendedNextSlot"] as Any,
                "recommendedNextEmail": agy["recommendedNextEmail"] as Any,
                "recommendedNextClaudeSlot": agy["recommendedNextClaudeSlot"] as Any,
                "recommendedNextClaudeEmail": agy["recommendedNextClaudeEmail"] as Any,
                "recommendedNextGeminiSlot": agy["recommendedNextGeminiSlot"] as Any,
                "recommendedNextGeminiEmail": agy["recommendedNextGeminiEmail"] as Any,
                "rotationAdvice": agy["rotationAdvice"] as Any,
                "claudeRotationAdvice": agy["claudeRotationAdvice"] as Any,
                "geminiRotationAdvice": agy["geminiRotationAdvice"] as Any,
            ]
            if let v = agy["activeClaudeSessionUsed"] { rotationObj["activeClaudeSessionUsed"] = v }
            if let v = agy["activeClaudeSessionResetsAt"] { rotationObj["activeClaudeSessionResetsAt"] = v }
            if let v = agy["activeClaudeSessionResetsInSeconds"] { rotationObj["activeClaudeSessionResetsInSeconds"] = v }
            if let v = agy["activeGeminiSessionUsed"] { rotationObj["activeGeminiSessionUsed"] = v }
            if let v = agy["activeGeminiSessionResetsAt"] { rotationObj["activeGeminiSessionResetsAt"] = v }
            if let v = agy["activeGeminiSessionResetsInSeconds"] { rotationObj["activeGeminiSessionResetsInSeconds"] = v }
            if let v = agy["earliestClaudeResetSlot"] { rotationObj["earliestClaudeResetSlot"] = v }
            if let v = agy["earliestClaudeResetAt"] { rotationObj["earliestClaudeResetAt"] = v }
            if let v = agy["earliestClaudeResetsInSeconds"] { rotationObj["earliestClaudeResetsInSeconds"] = v }
            if let v = agy["earliestGeminiResetSlot"] { rotationObj["earliestGeminiResetSlot"] = v }
            if let v = agy["earliestGeminiResetAt"] { rotationObj["earliestGeminiResetAt"] = v }
            if let v = agy["earliestGeminiResetsInSeconds"] { rotationObj["earliestGeminiResetsInSeconds"] = v }
            let encoded = (try? JSONSerialization.data(withJSONObject: rotationObj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? data
            let exitCode: Int32 = (agy["signedIn"] as? Int ?? 0) > 0 ? 0 : 30
            return (encoded, describeRotation(root), exitCode)
        case .chatgptHeavy:
            guard let cgt = root["chatgptHeavy"] as? [String: Any] else {
                let err: [String: Any] = ["error": "ChatGPT-heavy provider not configured or no weekly resets found"]
                let errData = (try? JSONSerialization.data(withJSONObject: err)) ?? data
                return (errData, "ChatGPT-heavy provider not configured or no weekly resets found.", 30)
            }
            let encoded = (try? JSONSerialization.data(withJSONObject: cgt, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])) ?? data
            return (encoded, describeChatGPTHeavy(root), 0)
        }
    }

    static func describeAccounts(_ root: [String: Any]) -> String {
        guard let agy = root["antigravityAccounts"] as? [String: Any] else {
            return "No Antigravity accounts configured."
        }
        var lines: [String] = []
        let total = agy["total"] as? Int ?? 0
        let signedIn = agy["signedIn"] as? Int ?? 0
        lines.append("Antigravity Accounts: \(total) configured (\(signedIn) ready)")
        for slot in agy["slots"] as? [[String: Any]] ?? [] {
            let s = slot["slot"] as? String ?? "?"
            let email = slot["email"] as? String ?? "?"
            let currentTag = (slot["isCurrent"] as? Bool == true) ? " (current)" : ""
            let status = slot["status"] as? String ?? "?"
            if status == "ready" {
                var parts: [String] = []
                if let cUsed = JSON.number(slot["claudeSessionUsed"]) {
                    var cp = "Claude Session: \(Int((cUsed * 100).rounded()))%"
                    if let cSec = JSON.number(slot["claudeSessionResetsInSeconds"]), cSec > 0 {
                        cp += " (resets in \(ResetText.duration(TimeInterval(cSec))))"
                    }
                    parts.append(cp)
                }
                if let gUsed = JSON.number(slot["geminiSessionUsed"]) {
                    var gp = "Gemini Session: \(Int((gUsed * 100).rounded()))%"
                    if let gSec = JSON.number(slot["geminiSessionResetsInSeconds"]), gSec > 0 {
                        gp += " (resets in \(ResetText.duration(TimeInterval(gSec))))"
                    }
                    parts.append(gp)
                }
                let details = parts.isEmpty ? "ready" : parts.joined(separator: ", ")
                lines.append("  [\(s)] \(email)\(currentTag): \(details)")
            } else {
                lines.append("  [\(s)] \(email)\(currentTag): \(status)")
            }
        }
        if let advice = agy["rotationAdvice"] as? String {
            lines.append("Rotation: \(advice)")
        }
        return lines.joined(separator: "\n")
    }

    static func describeRotation(_ root: [String: Any]) -> String {
        guard let agy = root["antigravityAccounts"] as? [String: Any] else {
            return "No Antigravity accounts configured."
        }
        var lines: [String] = ["Antigravity Rotation:"]
        let curSlot = agy["currentSlot"] as? String ?? agy["activeSlot"] as? String ?? "?"
        let curEmail = agy["currentEmail"] as? String ?? agy["activeEmail"] as? String ?? ""
        lines.append("  Active slot: [\(curSlot)]" + (curEmail.isEmpty ? "" : " (\(curEmail))"))
        if let nextC = agy["recommendedNextClaudeSlot"] as? String {
            let nextCEmail = (agy["recommendedNextClaudeEmail"] as? String).map { " (\($0))" } ?? ""
            lines.append("  Next Claude slot: [\(nextC)]\(nextCEmail)")
        } else if let resetSlot = agy["earliestClaudeResetSlot"] as? String, let resetSec = JSON.number(agy["earliestClaudeResetsInSeconds"]) {
            lines.append("  Next Claude slot: all exhausted; earliest [\(resetSlot)] in \(ResetText.duration(TimeInterval(resetSec)))")
        }
        if let nextG = agy["recommendedNextGeminiSlot"] as? String {
            let nextGEmail = (agy["recommendedNextGeminiEmail"] as? String).map { " (\($0))" } ?? ""
            lines.append("  Next Gemini slot: [\(nextG)]\(nextGEmail)")
        } else if let resetSlot = agy["earliestGeminiResetSlot"] as? String, let resetSec = JSON.number(agy["earliestGeminiResetsInSeconds"]) {
            lines.append("  Next Gemini slot: all exhausted; earliest [\(resetSlot)] in \(ResetText.duration(TimeInterval(resetSec)))")
        }
        if let advice = agy["rotationAdvice"] as? String {
            lines.append("  Advice: \(advice)")
        }
        return lines.joined(separator: "\n")
    }

    static func describeChatGPTHeavy(_ root: [String: Any]) -> String {
        guard let cgt = root["chatgptHeavy"] as? [String: Any] else {
            return "ChatGPT-heavy provider not configured or no weekly resets found."
        }
        var lines: [String] = ["ChatGPT-Heavy Burn Routing (Priority 1):"]
        let total = cgt["totalResets"] as? Int ?? 4
        let empty = cgt["emptyResets"] as? Int ?? 0
        lines.append("  Available weekly resets: \(empty) of \(total)")
        if let activeLabel = cgt["activeWindowLabel"] as? String {
            var activeLine = "  Active reset: \(activeLabel)"
            if let sec = JSON.number(cgt["activeWindowResetsInSeconds"]), sec > 0 {
                activeLine += " (resets in \(ResetText.duration(TimeInterval(sec))))"
            }
            lines.append(activeLine)
        }
        if let advice = cgt["burnAdvice"] as? String {
            lines.append("  Advice: \(advice)")
        }
        if let windows = cgt["windows"] as? [[String: Any]], !windows.isEmpty {
            lines.append("  Windows:")
            for w in windows {
                let label = w["label"] as? String ?? w["id"] as? String ?? "?"
                let used = Int(((JSON.number(w["usedFraction"]) ?? 0) * 100).rounded())
                let room = Int(((JSON.number(w["headroomFraction"]) ?? 1.0) * 100).rounded())
                let status = w["status"] as? String ?? ""
                var wLine = "    \(label): \(used)% used, \(room)% headroom (\(status)"
                if let sec = JSON.number(w["resetsInSeconds"]), sec > 0 {
                    wLine += ", resets in \(ResetText.duration(TimeInterval(sec)))"
                }
                wLine += ")"
                lines.append(wLine)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ root: [String: Any]) -> String {
        var lines: [String] = []
        for tool in root["tools"] as? [[String: Any]] ?? [] {
            let name = tool["name"] as? String ?? "?"
            let status = tool["status"] as? String ?? "?"
            let plan = (tool["plan"] as? String).map { " (\($0))" } ?? ""
            var line = "\(name)\(plan): \(status)"
            if let problem = tool["problem"] as? String { line += " · \(problem)" }
            lines.append(line)
            for window in tool["windows"] as? [[String: Any]] ?? [] {
                let label = window["label"] as? String ?? window["id"] as? String ?? "?"
                if let used = JSON.number(window["usedFraction"]) {
                    var part = "  \(label): \(Int((used * 100).rounded()))%"
                    if let pace = window["pace"] as? String { part += " (\(pace))" }
                    if let source = window["source"] as? String, source != WindowSource.vendorEndpoint.rawValue { part += " [\(source)]" }
                    lines.append(part)
                } else {
                    lines.append("  \(label): no limit published")
                }
            }
            if let accounts = tool["accounts"] as? [[String: Any]], !accounts.isEmpty {
                let readyCount = accounts.filter { ($0["status"] as? String) == "ready" }.count
                lines.append("  accounts: \(accounts.count) configured (\(readyCount) ready)")
                for acct in accounts {
                    let slot = acct["slot"] as? String ?? "?"
                    let email = acct["email"] as? String ?? "?"
                    let currentTag = (acct["isCurrent"] as? Bool == true) ? " (current)" : ""
                    let acctStatus = acct["status"] as? String ?? "?"
                    if acctStatus == "ready", let wins = acct["windows"] as? [[String: Any]], !wins.isEmpty {
                        let winSummaries = wins.compactMap { w -> String? in
                            guard let label = w["label"] as? String, let used = JSON.number(w["usedFraction"]) else { return nil }
                            var part = "\(label): \(Int((used * 100).rounded()))%"
                            let wid = (w["id"] as? String) ?? ""
                            if let resetsStr = w["resetsAt"] as? String, let date = DateParsing.iso8601(resetsStr) {
                                if used >= 0.8 || wid.contains("session") || wid.contains("5h") {
                                    part += " (\(RelativeTime.resets(date, hasLimit: true)))"
                                }
                            }
                            return part
                        }.joined(separator: ", ")
                        lines.append("    [\(slot)] \(email)\(currentTag): \(winSummaries)")
                    } else {
                        lines.append("    [\(slot)] \(email)\(currentTag): \(acctStatus)")
                    }
                }
                if let advice = tool["rotationAdvice"] as? String {
                    lines.append("  rotation: \(advice)")
                } else if let nextSlot = tool["recommendedNextSlot"] as? String, let nextEmail = tool["recommendedNextEmail"] as? String {
                    lines.append("  rotation: next recommended slot is [\(nextSlot)] (\(nextEmail))")
                } else if let resetSlot = tool["earliestClaudeResetSlot"] as? String, let resetAtStr = tool["earliestClaudeResetAt"] as? String, let resetDate = DateParsing.iso8601(resetAtStr) {
                    lines.append("  rotation: all Claude sessions exhausted; earliest [\(resetSlot)] \(RelativeTime.resets(resetDate, hasLimit: true))")
                } else if let resetSlot = tool["earliestGeminiResetSlot"] as? String, let resetAtStr = tool["earliestGeminiResetAt"] as? String, let resetDate = DateParsing.iso8601(resetAtStr) {
                    lines.append("  rotation: all Gemini sessions exhausted; earliest [\(resetSlot)] \(RelativeTime.resets(resetDate, hasLimit: true))")
                }
            }
            if tool["tool"] as? String == "chatgpt", let empty = tool["emptyResetsCount"] as? Int, let total = tool["weeklyResetsCount"] as? Int {
                var cgtLine = "  chatgpt-heavy: \(empty) of \(total) weekly resets available for burn routing (priority 1)"
                if let activeLabel = tool["activeWindowLabel"] as? String {
                    cgtLine += " — active: \(activeLabel)"
                    if let resetStr = tool["activeWindowResetsAt"] as? String, let resetDate = DateParsing.iso8601(resetStr) {
                        cgtLine += " (\(RelativeTime.resets(resetDate, hasLimit: true)))"
                    }
                }
                lines.append(cgtLine)
                if let burnAdvice = tool["burnAdvice"] as? String {
                    lines.append("  burn-advice: \(burnAdvice)")
                }
            }
        }
        if let cost = root["cost"] as? [String: Any], let today = JSON.number(cost["today"]) {
            var line = "cost: today \(Money.dollars(today)) 30d \(Money.dollars(JSON.number(cost["last30Days"]) ?? 0))"
            // Which list prices did the pricing (PriceSource.key), so a figure can be checked against the right table.
            if let sources = cost["priceSources"] as? [String], !sources.isEmpty { line += " (prices: \(sources.joined(separator: ", ")))" }
            lines.append(line)
        }
        for advice in root["advice"] as? [[String: Any]] ?? [] {
            if let text = advice["text"] as? String { lines.append("advice: \(text)") }
        }
        if let code = JSON.number(root["exitCode"]) { lines.append("exit code \(Int(code))") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Installing the link

    /// ~/.local/bin when it exists or can be made, else /usr/local/bin when writable; nil when neither.
    static func linkDirectory(home: URL = Paths.home, fm: FileManager = .default) -> URL? {
        let local = home.appendingPathComponent(".local/bin")
        if fm.isWritableFile(atPath: local.path) || (try? fm.createDirectory(at: local, withIntermediateDirectories: true)) != nil { return local }
        let usr = URL(fileURLWithPath: "/usr/local/bin")
        return fm.isWritableFile(atPath: usr.path) ? usr : nil
    }

    /// Replaces any link of that name with one to `executable`; returns the link's path.
    @discardableResult
    static func install(executable: String, directory: URL? = linkDirectory()) throws -> URL {
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        let link = directory.appendingPathComponent(linkName)
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil || fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: executable))
        return link
    }

    /// Where the link points now, when one exists in either directory.
    static func installedLink(home: URL = Paths.home) -> (link: URL, destination: String)? {
        for directory in [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/usr/local/bin")] {
            let link = directory.appendingPathComponent(linkName)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) { return (link, destination) }
        }
        return nil
    }

    /// True when the directory is on the shell's PATH (the login shell's, via launchd, when the app was launched from the Finder).
    static func isOnPath(_ directory: URL, path: String? = ProcessEnvironment.value("PATH")) -> Bool {
        (path ?? "").split(separator: ":").map { ($0 as NSString).expandingTildeInPath }.contains(directory.path)
    }
}

/// A blocking GET against the loopback API, for the command-line tool and the status line: a quarter-second
/// connect budget, so an app without the API on costs nothing noticeable.
enum LocalAPIClient {
    static func get(_ path: String, port: UInt16 = LocalAPI.port, timeout: TimeInterval = 0.25) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 4
        let session = URLSession(configuration: configuration)
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let task = session.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { box.withLock { $0 = data } }
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + timeout * 4)
        return box.withLock { $0 }
    }
}
