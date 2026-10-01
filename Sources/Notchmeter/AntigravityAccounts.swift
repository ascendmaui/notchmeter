import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "antigravity-accounts")

/// Represents one Antigravity account slot on this Mac (e.g. `agy`, `agy2` ... `agy7`).
///
/// Antigravity stores Google OAuth tokens per slot using HOME overrides (~/.agy-accounts/acctN)
/// or the default home (~/.gemini/antigravity-cli/antigravity-oauth-token).
struct AntigravityAccount: Codable, Equatable, Sendable {
    let slot: String
    let index: Int
    let email: String
    let homeDirectory: String
    let isCurrent: Bool
    let status: String
    let problem: String?
    let plan: String?
    let windows: [LimitWindow]
    let lastActive: Date?

    init(slot: String,
         index: Int,
         email: String,
         homeDirectory: String,
         isCurrent: Bool,
         status: String,
         problem: String? = nil,
         plan: String? = nil,
         windows: [LimitWindow] = [],
         lastActive: Date? = nil) {
        self.slot = slot
        self.index = index
        self.email = email
        self.homeDirectory = homeDirectory
        self.isCurrent = isCurrent
        self.status = status
        self.problem = problem
        self.plan = plan
        self.windows = windows
        self.lastActive = lastActive
    }

    var geminiSessionWindow: LimitWindow? {
        windows.first { $0.id == "gemini_session" } ?? windows.first { $0.id.contains("gemini") && $0.id.contains("session") }
    }

    var geminiWeeklyWindow: LimitWindow? {
        windows.first { $0.id == "gemini_weekly" } ?? windows.first { $0.id.contains("gemini") && $0.id.contains("weekly") }
    }

    var claudeSessionWindow: LimitWindow? {
        windows.first { $0.id == "claude_and_gpt_session" } ?? windows.first { $0.id.contains("claude") && $0.id.contains("session") }
    }

    var claudeWeeklyWindow: LimitWindow? {
        windows.first { $0.id == "claude_and_gpt_weekly" } ?? windows.first { $0.id.contains("claude") && $0.id.contains("weekly") }
    }

    var hasClaudeSessionRoom: Bool {
        guard status == "ready" else { return false }
        guard let used = claudeSessionWindow?.usedFraction else { return false }
        return used < 0.95
    }

    var hasGeminiSessionRoom: Bool {
        guard status == "ready" else { return false }
        guard let used = geminiSessionWindow?.usedFraction else { return false }
        return used < 0.95
    }
}

/// Discovers and probes multi-account Antigravity configurations.
enum AntigravityAccounts {
    struct DiscoveredSlot: Equatable, Sendable {
        let slot: String
        let index: Int
        let homeURL: URL
        let email: String
        let tokenURL: URL
        let isCurrent: Bool
    }

    /// Rotation order per ~/.agy-accounts/README.md:
    /// agy, agy6, agy3, agy2, agy4, agy5, agy7
    static let rotationOrder = ["agy", "agy6", "agy3", "agy2", "agy4", "agy5", "agy7"]

    /// Finds the `.agy-accounts` root directory if one exists on this Mac.
    static func agyAccountsDirectory(currentHome: URL = Paths.home) -> URL? {
        let fm = FileManager.default
        let direct = currentHome.appendingPathComponent(".agy-accounts")
        if fm.fileExists(atPath: direct.path) { return direct }
        let parent = currentHome.deletingLastPathComponent()
        if parent.lastPathComponent == ".agy-accounts" && fm.fileExists(atPath: parent.path) {
            return parent
        }
        let userAgy = URL(fileURLWithPath: "/Users/\(NSUserName())/.agy-accounts")
        if fm.fileExists(atPath: userAgy.path) { return userAgy }
        return nil
    }

    /// Finds the primary home directory (e.g. `/Users/john` even if current HOME is inside a slot).
    static func primaryHomeDirectory(currentHome: URL = Paths.home) -> URL {
        if let envReal = ProcessInfo.processInfo.environment["AGY_REAL_HOME"], !envReal.isEmpty {
            return URL(fileURLWithPath: envReal)
        }
        if let agyDir = agyAccountsDirectory(currentHome: currentHome) {
            return agyDir.deletingLastPathComponent()
        }
        return Paths.home
    }

    /// Finds the currently active HOME directory (e.g. `/Users/john/.agy-accounts/acct4`).
    static func currentHomeDirectory() -> URL {
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty {
            return URL(fileURLWithPath: envHome)
        }
        return Paths.home
    }

    /// Finds the currently active slot name (e.g. `agy4` if AGY_ACCOUNT_SLOT=acct4).
    static func currentSlotName() -> String? {
        if let slot = ProcessInfo.processInfo.environment["AGY_ACCOUNT_SLOT"], !slot.isEmpty {
            if slot.hasPrefix("acct") {
                return "agy\(slot.dropFirst(4))"
            }
            return slot
        }
        return nil
    }

    /// Recommends the next ready slot to rotate to according to rotation order.
    static func recommendedNextSlot(accounts: [AntigravityAccount], forModelFamily: String = "claude") -> AntigravityAccount? {
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.slot, $0) })
        for slotName in rotationOrder {
            guard let account = accountMap[slotName], account.status == "ready" else { continue }
            if forModelFamily == "gemini" {
                if account.hasGeminiSessionRoom { return account }
            } else {
                if account.hasClaudeSessionRoom { return account }
            }
        }
        return nil
    }

    /// Returns the earliest session reset date and slot across ready accounts.
    static func earliestSessionReset(accounts: [AntigravityAccount], forModelFamily: String = "claude") -> (slot: String, resetsAt: Date)? {
        let candidates = accounts.compactMap { acct -> (slot: String, resetsAt: Date)? in
            guard acct.status == "ready" else { return nil }
            let win = (forModelFamily == "gemini") ? acct.geminiSessionWindow : acct.claudeSessionWindow
            guard let reset = win?.resetsAt else { return nil }
            return (slot: acct.slot, resetsAt: reset)
        }
        return candidates.min(by: { $0.resetsAt < $1.resetsAt })
    }

    /// Discovers all configured Antigravity account slots on this Mac.
    static func discoverSlots(currentHome: URL = Paths.home, fm: FileManager = .default) -> [DiscoveredSlot] {
        let primaryHome = primaryHomeDirectory(currentHome: currentHome)
        let activeHome = currentHomeDirectory()
        let activeSlot = currentSlotName()
        var slots: [DiscoveredSlot] = []

        // Slot 1: default HOME (agy)
        let slot1TokenURL = primaryHome.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let slot1Email = readEmail(in: primaryHome, tokenURL: slot1TokenURL) ?? "johnmatveyev@gmail.com"
        let isSlot1Current = (activeSlot == "agy") || (activeSlot == nil && (activeHome.standardizedFileURL.path == primaryHome.standardizedFileURL.path || currentHome.standardizedFileURL.path == primaryHome.standardizedFileURL.path))
        slots.append(DiscoveredSlot(slot: "agy",
                                    index: 1,
                                    homeURL: primaryHome,
                                    email: slot1Email,
                                    tokenURL: slot1TokenURL,
                                    isCurrent: isSlot1Current))

        // Slots 2..N: in .agy-accounts/acctN
        if let agyDir = agyAccountsDirectory(currentHome: currentHome),
           let contents = try? fm.contentsOfDirectory(atPath: agyDir.path) {
            for name in contents.sorted() where name.hasPrefix("acct") {
                let numStr = String(name.dropFirst(4))
                guard let num = Int(numStr), num > 1 else { continue }
                let slotURL = agyDir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: slotURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

                let tokenURL = slotURL.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
                let email = readEmail(in: slotURL, tokenURL: tokenURL) ?? "account\(num)@unknown"
                let isCurrent = (activeSlot == "agy\(num)") || (activeHome.standardizedFileURL.path == slotURL.standardizedFileURL.path || currentHome.standardizedFileURL.path == slotURL.standardizedFileURL.path)
                slots.append(DiscoveredSlot(slot: "agy\(num)",
                                            index: num,
                                            homeURL: slotURL,
                                            email: email,
                                            tokenURL: tokenURL,
                                            isCurrent: isCurrent))
            }
        }

        return slots.sorted { $0.index < $1.index }
    }

    /// Reads an email from ACCOUNT_EMAIL or id_token JWT in antigravity-oauth-token.
    static func readEmail(in dir: URL, tokenURL: URL) -> String? {
        let emailFile = dir.appendingPathComponent("ACCOUNT_EMAIL")
        if let data = try? Data(contentsOf: emailFile),
           let email = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        if let tokenData = try? Data(contentsOf: tokenURL),
           let root = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
           let idToken = root["id_token"] as? String,
           let email = extractEmailFromJWT(idToken) {
            return email
        }
        return nil
    }

    /// Decodes the email claim from an unencrypted Google id_token JWT payload.
    static func extractEmailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }

    /// Probes all discovered Antigravity slots concurrently.
    static func probeAll(currentHome: URL = Paths.home,
                         session: URLSession = NetworkSession.shared,
                         now: Date = Date(),
                         timeout: TimeInterval = 6) async -> [AntigravityAccount] {
        let slots = discoverSlots(currentHome: currentHome)
        return await withTaskGroup(of: AntigravityAccount.self) { group in
            for slot in slots {
                group.addTask {
                    await probeSlot(slot, session: session, now: now, timeout: timeout)
                }
            }
            var results: [AntigravityAccount] = []
            for await account in group {
                results.append(account)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    /// Probes a single slot's token and quota.
    static func probeSlot(_ slot: DiscoveredSlot,
                          session: URLSession,
                          now: Date = Date(),
                          timeout: TimeInterval = 6) async -> AntigravityAccount {
        let fm = FileManager.default
        let lastActive = newestActivity(in: slot.homeURL)
        guard fm.fileExists(atPath: slot.tokenURL.path) else {
            return AntigravityAccount(slot: slot.slot,
                                      index: slot.index,
                                      email: slot.email,
                                      homeDirectory: slot.homeURL.path,
                                      isCurrent: slot.isCurrent,
                                      status: "needsSignIn",
                                      problem: L("Not signed in; run %1$@ to sign in", slot.slot),
                                      plan: nil,
                                      windows: [],
                                      lastActive: lastActive)
        }

        guard let tokenData = try? Data(contentsOf: slot.tokenURL),
              let credentials = try? CodeAssistProvider.parseCredentials(tokenData) else {
            return AntigravityAccount(slot: slot.slot,
                                      index: slot.index,
                                      email: slot.email,
                                      homeDirectory: slot.homeURL.path,
                                      isCurrent: slot.isCurrent,
                                      status: "needsSignIn",
                                      problem: L("Invalid credentials file in %1$@", slot.slot),
                                      plan: nil,
                                      windows: [],
                                      lastActive: lastActive)
        }

        if let expiresAt = credentials.expiresAt, expiresAt < now.addingTimeInterval(30) {
            return AntigravityAccount(slot: slot.slot,
                                      index: slot.index,
                                      email: slot.email,
                                      homeDirectory: slot.homeURL.path,
                                      isCurrent: slot.isCurrent,
                                      status: "tokenExpired",
                                      problem: L("Token expired; run %1$@ to re-authenticate", slot.slot),
                                      plan: nil,
                                      windows: [],
                                      lastActive: lastActive)
        }

        // Try reading quota summary from cloudcode-pa
        for host in [CodeAssistProvider.productionHost, CodeAssistProvider.dailyHost] {
            var request = URLRequest(url: CodeAssistProvider.url(host: host, method: "retrieveUserQuotaSummary"))
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(CodeAssistProvider.antigravityUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(CodeAssistProvider.antigravityClientMetadata, forHTTPHeaderField: "Client-Metadata")

            do {
                let (data, response) = try await session.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 200,
                   let reading = try? CodeAssistProvider.parseQuotaSummary(data, plan: "Pro", tool: .antigravity, now: now) {
                    return AntigravityAccount(slot: slot.slot,
                                              index: slot.index,
                                              email: slot.email,
                                              homeDirectory: slot.homeURL.path,
                                              isCurrent: slot.isCurrent,
                                              status: "ready",
                                              problem: nil,
                                              plan: "Pro",
                                              windows: reading.windows,
                                              lastActive: lastActive)
                } else if statusCode == 401 {
                    return AntigravityAccount(slot: slot.slot,
                                              index: slot.index,
                                              email: slot.email,
                                              homeDirectory: slot.homeURL.path,
                                              isCurrent: slot.isCurrent,
                                              status: "tokenExpired",
                                              problem: L("Token rejected (401); run %1$@ to re-authenticate", slot.slot),
                                              plan: nil,
                                              windows: [],
                                              lastActive: lastActive)
                } else if statusCode == 403 {
                    return AntigravityAccount(slot: slot.slot,
                                              index: slot.index,
                                              email: slot.email,
                                              homeDirectory: slot.homeURL.path,
                                              isCurrent: slot.isCurrent,
                                              status: "emptyQuota",
                                              problem: L("Quota exhausted or license invalid (403)", slot.slot),
                                              plan: nil,
                                              windows: [],
                                              lastActive: lastActive)
                }
            } catch {
                // Try next host
                continue
            }
        }

        return AntigravityAccount(slot: slot.slot,
                                  index: slot.index,
                                  email: slot.email,
                                  homeDirectory: slot.homeURL.path,
                                  isCurrent: slot.isCurrent,
                                  status: "offline",
                                  problem: L("Unable to reach Google Code Assist endpoint"),
                                  plan: nil,
                                  windows: [],
                                  lastActive: lastActive)
    }

    /// Finds the newest modification date in conversations or cli.log.
    static func newestActivity(in home: URL, fm: FileManager = .default) -> Date? {
        let cliHome = home.appendingPathComponent(".gemini/antigravity-cli")
        let cliLog = cliHome.appendingPathComponent("cli.log")
        var newest: Date? = (try? fm.attributesOfItem(atPath: cliLog.path))?[.modificationDate] as? Date

        let convDir = cliHome.appendingPathComponent("conversations")
        if let entries = try? fm.contentsOfDirectory(atPath: convDir.path) {
            for entry in entries {
                let file = convDir.appendingPathComponent(entry)
                if let mod = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date {
                    if newest == nil || mod > newest! { newest = mod }
                }
            }
        }
        return newest
    }
}
