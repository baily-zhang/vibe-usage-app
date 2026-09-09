#if DEBUG
import Foundation
import Testing
@testable import VibeUsage

struct TestDiagnosticLogTests {
    @Test
    func exportedLogContainsStructuredCodesButNoRawFailureText() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TestDiagnosticLogTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let exported = root.appendingPathComponent("export.jsonl")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        TestDiagnosticLog.recordQuotaRefreshStarted(
            [.kimiCode, .zCode],
            directoryURL: logs,
            now: Date(timeIntervalSince1970: 1_000)
        )
        TestDiagnosticLog.recordQuotaProductsDiscovered(
            [.kimiCode, .zCode, .grok],
            directoryURL: logs,
            now: Date(timeIntervalSince1970: 1_000.25)
        )
        TestDiagnosticLog.recordQuotaSelectionInitialized(
            [.codex, .claudeCode],
            directoryURL: logs,
            now: Date(timeIntervalSince1970: 1_000.5)
        )
        TestDiagnosticLog.recordQuotaSelectionChanged(
            [.zCode, .grok],
            directoryURL: logs,
            now: Date(timeIntervalSince1970: 1_000.75)
        )
        TestDiagnosticLog.recordQuotaFailure(
            [.zCode],
            error: CLIBridge.CLIError.processFailure(
                "Bearer super-secret from /Users/example/private.json"
            ),
            directoryURL: logs,
            now: Date(timeIntervalSince1970: 1_001)
        )
        TestDiagnosticLog.recordQuotaResult(
            ProviderRateLimit(
                provider: .kimiCode,
                meters: [RateLimitMeter(
                    id: "weekly",
                    label: "7d",
                    window: RateLimitWindow(utilization: 25)
                )],
                status: .ok
            ),
            directoryURL: logs,
            now: Date(timeIntervalSince1970: 1_002)
        )
        try TestDiagnosticLog.export(to: exported, directoryURL: logs)

        let text = try String(contentsOf: exported, encoding: .utf8)
        #expect(text.contains("quota_refresh_started"))
        #expect(text.contains("quota_products_discovered"))
        #expect(text.contains("quota_selection_initialized"))
        #expect(text.contains("quota_selection_changed"))
        #expect(text.contains("cli_process_failure"))
        #expect(text.contains("\"providers\":[\"kimi-code\",\"zcode\"]"))
        #expect(text.contains("\"providers\":[\"zcode\",\"grok\"]"))
        #expect(text.contains("\"meterCount\":1"))
        #expect(text.contains("\"appBuild\":"))
        #expect(text.contains("\"buildKind\":"))
        #expect(text.contains("\"appCommit\":"))
        #expect(text.contains("\"cliVersion\":"))
        #expect(text.contains("\"cliCommit\":"))
        #expect(!text.contains("super-secret"))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("/Users/example"))

        let logPermissions = try #require(
            fileManager.attributesOfItem(
                atPath: logs.appendingPathComponent("diagnostics.jsonl").path
            )[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try #require(
            fileManager.attributesOfItem(atPath: logs.path)[.posixPermissions] as? NSNumber
        )
        let exportPermissions = try #require(
            fileManager.attributesOfItem(atPath: exported.path)[.posixPermissions] as? NSNumber
        )
        #expect(logPermissions.intValue & 0o777 == 0o600)
        #expect(directoryPermissions.intValue & 0o777 == 0o700)
        #expect(exportPermissions.intValue & 0o777 == 0o600)
    }
}
#endif
