import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "grok")

/// Standalone xAI / Grok (Grok Bot.app / SuperGrok), not Cursor's in-editor "Grok Bot" weekly seat window.
///
/// Detection: `/Applications/Grok Bot.app` and `~/Library/Application Support/Grok Bot`. Usage endpoint / local
/// store still undocumented — stub returns nothingYet when installed.
struct GrokProvider: UsageProvider {
    let tool: ToolID = .grok
    let refreshInterval: TimeInterval = 300
    let home: URL
    let applications: URL

    init(home: URL = Paths.home, applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.home = home
        self.applications = applications
    }

    var appBundle: URL { applications.appendingPathComponent("Grok Bot.app") }
    var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/Grok Bot") }
    var buildSupport: URL { home.appendingPathComponent("Library/Application Support/Grok Build Desktop") }

    func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: appBundle.path)
            || fm.fileExists(atPath: supportDirectory.path)
            || fm.fileExists(atPath: buildSupport.path)
    }

    func fetch() async throws -> UsageReading {
        DiagnosticLog.request(log, "grok-stub", status: 0, bytes: 0)
        throw ProviderError.nothingYet(L("Grok / xAI is on this Mac, but standalone plan usage is not readable yet (Cursor's Grok Bot seat is already on the Cursor ring). See docs/john-providers.md."))
    }
}
