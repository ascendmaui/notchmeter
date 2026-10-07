import Foundation
import os

private let log = Logger(subsystem: "com.amirhackett.notchmeter", category: "hermes")

/// Hermes desktop agent — local Application Support only so far.
struct HermesProvider: UsageProvider {
    let tool: ToolID = .hermes
    let refreshInterval: TimeInterval = 300
    let home: URL

    init(home: URL = Paths.home) {
        self.home = home
    }

    var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/Hermes") }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: supportDirectory.path)
    }

    func fetch() async throws -> UsageReading {
        DiagnosticLog.request(log, "hermes-stub", status: 0, bytes: 0)
        throw ProviderError.nothingYet(L("Hermes is on this Mac, but its usage store is not mapped yet. See docs/john-providers.md."))
    }
}
