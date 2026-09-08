import Foundation
import Testing
@testable import VibeUsage

struct QuotaProductTests {
    private final class MemoryZCodeKeyStore: ZCodeAPIKeyStoring {
        var value: String?
        func load() throws -> String? { value }
        func store(_ value: String?) throws { self.value = value }
    }

    private func defaults() -> (UserDefaults, String) {
        let suite = "QuotaProductTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func products(
        detected: Set<ProviderRateLimit.Provider>
    ) -> [QuotaProduct] {
        QuotaProductRegistry.catalog.map { provider, availability in
            QuotaProduct(
                provider: provider,
                availability: availability,
                isDetected: detected.contains(provider)
            )
        }
    }

    @Test
    func firstLaunchSelectsDetectedReadyProductsOnly() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.codex, .kimiCode, .cursorGrok])
        )

        #expect(selection == [.codex, .kimiCode])
        #expect(defaults.bool(forKey: QuotaSelectionPreferences.initializedKey))
    }

    @Test
    func initializedEmptySelectionStaysEmpty() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set([], forKey: QuotaSelectionPreferences.selectedIDsKey)

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.codex, .claudeCode])
        )

        #expect(selection.isEmpty)
    }

    @Test
    func legacySelectionIsMigratedWithoutChangingTheChoice() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "codexRateLimitEnabled")
        defaults.set(true, forKey: "claudeRateLimitEnabled")

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [.codex, .claudeCode])
        )

        #expect(selection == [.claudeCode])
    }

    @Test
    func storedSelectionIsDeduplicatedAndCappedAtTwo() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(
            ["kimi-code", "kimi-code", "codex", "claude-code"],
            forKey: QuotaSelectionPreferences.selectedIDsKey
        )

        let selection = QuotaSelectionPreferences.resolve(
            defaults: defaults,
            products: products(detected: [])
        )

        #expect(selection == [.kimiCode, .codex])
    }

    @Test
    func discoveryUsesOnlyLocalPresenceSignals() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("QuotaProductTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: home.appendingPathComponent(".kimi", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: applications.appendingPathComponent("Cursor.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let discovered = QuotaProductRegistry.discover(
            fileManager: fileManager,
            environment: .init(
                homeDirectory: home,
                applicationDirectories: [applications],
                executableDirectories: [bin]
            )
        )
        let byProvider = Dictionary(uniqueKeysWithValues: discovered.map { ($0.provider, $0) })

        #expect(byProvider[.codex]?.isDetected == true)
        #expect(byProvider[.kimiCode]?.isDetected == true)
        #expect(byProvider[.cursorGrok]?.isDetected == true)
        #expect(byProvider[.zCode]?.isDetected == false)
        #expect(byProvider[.kimiCode]?.isSelectable == true)
    }

    @Test @MainActor
    func zCodeRequiresAnExplicitAppOwnedKeyBeforeSelection() throws {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyStore = MemoryZCodeKeyStore()
        let appState = AppState(quotaDefaults: defaults, zCodeAPIKeyStore: keyStore)
        let product = QuotaProduct(provider: .zCode, availability: .ready, isDetected: true)

        #expect(appState.quotaProductStatusText(product) == "需配置 Z.ai API Key")
        try appState.storeZCodeAPIKey("  fixture-key  ")
        #expect(keyStore.value == "fixture-key")
        #expect(appState.zCodeAPIKeyForQuotaFetch() == "fixture-key")
        #expect(appState.quotaProductStatusText(product) == "已检测 · API Key 已配置")

        try appState.storeZCodeAPIKey(nil)
        #expect(keyStore.value == nil)
        #expect(!appState.zCodeAPIKeyConfigured)
    }
}
