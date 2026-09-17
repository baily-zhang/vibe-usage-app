import Foundation
import XCTest
@testable import VibeUsage

/// Opt-in checks for the local acceptance session. Ordinary CI never reads
/// real credentials or writes Keychain items. Output contains no secrets.
final class LocalAcceptanceTests: XCTestCase {
    func testLiveCodexQuota() async throws {
        guard ProcessInfo.processInfo.environment["VIBE_USAGE_LIVE_CODEX"] == "1" else {
            throw XCTSkip("Requires an explicitly selected, logged-in Codex account")
        }
        let snapshot = try await CodexUsageAPI.fetch()
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertNotNil(snapshot.dataAsOf)
        XCTAssertTrue(snapshot.fiveHour != nil || snapshot.sevenDay != nil || snapshot.fiveHourNotEnforced)
        for window in [snapshot.fiveHour, snapshot.sevenDay].compactMap({ $0 }) {
            XCTAssertTrue(window.utilization.isFinite)
            XCTAssertTrue((0...100).contains(window.utilization))
        }
        print("[acceptance] Codex live quota decoded successfully")
    }

    func testLiveKimiAndGrokThroughMacBridge() async throws {
        guard ProcessInfo.processInfo.environment["VIBE_USAGE_LIVE_KIMI_GROK"] == "1",
              ProcessInfo.processInfo.environment["VIBE_USAGE_CLI_PACKAGE"] != nil else {
            throw XCTSkip("Requires selected Kimi/Grok accounts and the reviewed local CLI")
        }
        let snapshots = try await QuotaCLIBridge.fetch(providers: [.kimiCode, .grok], zCodeAPIKey: nil)
        XCTAssertEqual(snapshots.map(\.provider), [.kimiCode, .grok])
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.status, .ok)
            XCTAssertFalse(snapshot.meters.isEmpty)
            XCTAssertNotNil(snapshot.dataAsOf)
        }
        print("[acceptance] Kimi and Grok live/local quotas decoded through Mac CLI bridge")
    }

    func testIsolatedKeychainCreateUpdateRegionalSeparationAndDelete() throws {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["VIBE_USAGE_LIVE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Requires explicit local Keychain acceptance")
        }
        let store = KeychainZCodeAPIKeyStore(environment: [
            "VIBE_USAGE_TEST_KEYCHAIN_SERVICE": "ai.vibecafe.vibe-usage.acceptance.\(UUID().uuidString)",
        ])
        // These are fixture strings, never API credentials and never sent.
        defer {
            try? store.store(nil, for: .bigModel)
            try? store.store(nil, for: .zAI)
        }
        XCTAssertNil(try store.load(for: .bigModel))
        XCTAssertNil(try store.load(for: .zAI))
        try store.store("acceptance-domestic-fixture", for: .bigModel)
        try store.store("acceptance-overseas-fixture", for: .zAI)
        XCTAssertEqual(try store.load(for: .bigModel), "acceptance-domestic-fixture")
        XCTAssertEqual(try store.load(for: .zAI), "acceptance-overseas-fixture")
        try store.store("acceptance-updated-fixture", for: .bigModel)
        XCTAssertEqual(try store.load(for: .bigModel), "acceptance-updated-fixture")
        XCTAssertEqual(try store.load(for: .zAI), "acceptance-overseas-fixture")
        try store.store(nil, for: .bigModel)
        try store.store(nil, for: .zAI)
        XCTAssertNil(try store.load(for: .bigModel))
        XCTAssertNil(try store.load(for: .zAI))
        #else
        throw XCTSkip("Keychain fixtures require Debug's isolated test namespace")
        #endif
    }
}
