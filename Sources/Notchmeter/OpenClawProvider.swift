import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "openclaw")

/// OpenClaw + OpenClaw Dashboard — local Application Support / app presence.
struct OpenClawProvider: UsageProvider {
    let tool: ToolID = .openclaw
    let refreshInterval: TimeInterval = 300
    let home: URL
    let applications: URL

    init(home: URL = Paths.home, applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
        self.home = home
        self.applications = applications
    }

    var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/OpenClaw") }
    var dashboardSupport: URL { home.appendingPathComponent("Library/Application Support/openclaw-dashboard") }
    var dashboardApp: URL { applications.appendingPathComponent("OpenClaw Dashboard.app") }

    func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: supportDirectory.path)
            || fm.fileExists(atPath: dashboardSupport.path)
            || fm.fileExists(atPath: dashboardApp.path)
    }

    func fetch() async throws -> UsageReading {
        DiagnosticLog.request(log, "openclaw-stub", status: 0, bytes: 0)
        throw ProviderError.nothingYet(L("OpenClaw is on this Mac, but its usage store is not mapped yet. See docs/john-providers.md."))
    }
}
