import Foundation
import Testing
@testable import VibeUsage

struct RateLimitCoordinatorTests {
    private final class MemoryZCodeKeyStore: ZCodeAPIKeyStoring {
        var values: [ZCodeQuotaRegion: String] = [:]
        init(value: String? = nil) { values[.bigModel] = value }
        func load(for region: ZCodeQuotaRegion) throws -> String? { values[region] }
        func store(_ value: String?, for region: ZCodeQuotaRegion) throws {
            values[region] = value
        }
    }

    @MainActor
    private func selectedAppState(
        _ providers: [ProviderRateLimit.Provider],
        zCodeAPIKey: String? = nil
    ) -> (AppState, UserDefaults, String) {
        let suite = "RateLimitCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: QuotaSelectionPreferences.initializedKey)
        defaults.set(providers.map(\.rawValue), forKey: QuotaSelectionPreferences.selectedIDsKey)
        let appState = AppState(
            quotaDefaults: defaults,
            zCodeAPIKeyStore: MemoryZCodeKeyStore(value: zCodeAPIKey),
            quotaProductDiscoverer: {
                QuotaProductRegistry.catalog.map { provider, availability in
                    QuotaProduct(
                        provider: provider,
                        availability: availability,
                        isDetected: providers.contains(provider)
                    )
                }
            }
        )
        appState.initializeQuotaProducts()
        return (appState, defaults, suite)
    }

    private func snapshot(
        utilization: Double,
        dataAsOf: Date?,
        fetchedAt: Date? = nil,
        status: ProviderRateLimit.Status = .ok
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .codex,
            sevenDay: RateLimitWindow(utilization: utilization),
            status: status,
            fetchedAt: fetchedAt,
            dataAsOf: dataAsOf
        )
    }

    @Test
    func newerFallbackMayReplaceCurrentSnapshot() {
        let current = snapshot(
            utilization: 40,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let fallback = snapshot(
            utilization: 50,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )

        #expect(RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func olderFallbackCannotMakeDisplayedDataGoBackwards() {
        let current = snapshot(
            utilization: 50,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )
        let fallback = snapshot(
            utilization: 40,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )

        #expect(!RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func fetchedAtIsUsedOnlyWhenDataAsOfIsUnavailable() {
        let current = snapshot(
            utilization: 40,
            dataAsOf: nil,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )
        let fallback = snapshot(
            utilization: 50,
            dataAsOf: nil,
            fetchedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(RateLimitCoordinator.isNewerSnapshot(fallback, than: current))
    }

    @Test
    func nonOkFallbackNeverReplacesCurrentData() {
        let fallback = snapshot(
            utilization: 0,
            dataAsOf: Date(timeIntervalSince1970: 200),
            status: .noData
        )

        #expect(!RateLimitCoordinator.isNewerSnapshot(fallback, than: nil))
    }

    @Test @MainActor
    func concurrentCodexRefreshesShareOneLiveRequest() async {
        let appState = AppState()
        var fetchCount = 0
        let producedAt = Date(timeIntervalSince1970: 200)
        let live = snapshot(utilization: 50, dataAsOf: producedAt)
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                fetchCount += 1
                try await Task.sleep(for: .milliseconds(50))
                return live
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        let first = Task { @MainActor in await coordinator.refreshCodex() }
        let second = Task { @MainActor in await coordinator.refreshCodex() }
        await first.value
        await second.value

        #expect(fetchCount == 1)
        #expect(appState.rateLimits.first(where: { $0.provider == .codex }) == live)
        #expect(!appState.isCodexRateLimitRefreshing)
    }

    @Test @MainActor
    func closingPanelCancelsCodexRefreshWithoutPublishingLateData() async {
        let appState = AppState()
        var requestStarted = false
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                requestStarted = true
                try await Task.sleep(for: .seconds(30))
                return self.snapshot(
                    utilization: 99,
                    dataAsOf: Date(timeIntervalSince1970: 300)
                )
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        let refresh = Task { @MainActor in await coordinator.refreshCodex() }
        while !requestStarted { await Task.yield() }
        #expect(appState.isCodexRateLimitRefreshing)

        coordinator.panelVisibilityChanged(visible: false)
        await refresh.value

        #expect(!appState.isCodexRateLimitRefreshing)
        #expect(appState.rateLimits.first(where: { $0.provider == .codex }) == nil)
    }

    /// A genuine endpoint failure with no usable fallback must remain visible;
    /// treating it as `.noData` hides the card and makes retry unreachable.
    @Test @MainActor
    func codexTransportFailureWithoutFallbackSurfacesRetryableError() async {
        let appState = AppState()
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                throw CodexUsageAPI.FetchError.transport(URLError(.notConnectedToInternet))
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        await coordinator.refreshCodex()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .codex })?.status
                == .retryableError
        )
    }

    /// A machine with no Codex OAuth login and no sessions is an absent feature,
    /// not a noisy network error; preserve the compact `.noData` treatment.
    @Test @MainActor
    func missingCodexLoginWithoutFallbackStaysQuiet() async {
        let appState = AppState()
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: { throw CodexUsageAPI.FetchError.notLoggedIn },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        await coordinator.refreshCodex()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .codex })?.status == .noData
        )
    }

    @Test @MainActor
    func unselectedProviderDoesNotStartItsFetcher() async {
        let suite = "RateLimitCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(quotaDefaults: defaults)
        appState.codexRateLimitEnabled = false
        var fetchCount = 0
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCodexLive: {
                fetchCount += 1
                return self.snapshot(utilization: 1, dataAsOf: Date())
            },
            loadCodexCache: { nil },
            readCodexFallback: {
                ProviderRateLimit(provider: .codex, status: .noData)
            }
        )

        await coordinator.refreshCodex()

        #expect(fetchCount == 0)
        #expect(appState.rateLimits.allSatisfy { $0.provider != .codex })
    }

    @Test @MainActor
    func unselectedCLIProviderDoesNotStartItsFetcher() async {
        let (appState, defaults, suite) = selectedAppState([.codex])
        defer { defaults.removePersistentDomain(forName: suite) }
        var fetchCount = 0
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCLIQuotas: { _, _, _ in
                fetchCount += 1
                return []
            }
        )

        await coordinator.refreshCLIProviders([.kimiCode])

        #expect(fetchCount == 0)
        #expect(appState.rateLimits.allSatisfy { $0.provider != .kimiCode })
    }

    @Test @MainActor
    func cliProviderFailureDoesNotReplaceAnotherProvidersSuccess() async {
        let (appState, defaults, suite) = selectedAppState(
            [.kimiCode, .zCode],
            zCodeAPIKey: "fixture-key"
        )
        defer { defaults.removePersistentDomain(forName: suite) }
        let kimi = ProviderRateLimit(
            provider: .kimiCode,
            meters: [RateLimitMeter(
                id: "weekly",
                label: "7d",
                window: RateLimitWindow(utilization: 40)
            )],
            status: .ok,
            fetchedAt: Date(),
            dataAsOf: Date()
        )
        let zCode = ProviderRateLimit(
            provider: .zCode,
            status: .retryableError,
            fetchedAt: Date()
        )
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCLIQuotas: { providers, key, region in
                #expect(providers == [.kimiCode, .zCode])
                #expect(key == "fixture-key")
                #expect(region == .bigModel)
                return [kimi, zCode]
            }
        )

        await coordinator.refreshCLIProviders([.kimiCode, .zCode])

        #expect(appState.rateLimits.first(where: { $0.provider == .kimiCode }) == kimi)
        #expect(
            appState.rateLimits.first(where: { $0.provider == .zCode })?.status
                == .retryableError
        )
        #expect(appState.cliQuotaRefreshingProviders.isEmpty)
    }

    @Test @MainActor
    func closingPanelDoesNotRestartAQueuedCLIRequest() async {
        let (appState, defaults, suite) = selectedAppState([.kimiCode, .zCode])
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [[ProviderRateLimit.Provider]] = []
        var firstRequestStarted = false
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchCLIQuotas: { providers, _, _ in
                calls.append(providers)
                firstRequestStarted = true
                try await Task.sleep(for: .seconds(30))
                return []
            }
        )

        let active = Task { @MainActor in
            await coordinator.refreshCLIProviders([.kimiCode])
        }
        while !firstRequestStarted { await Task.yield() }
        let queued = Task { @MainActor in
            await coordinator.refreshCLIProviders([.zCode])
        }
        try? await Task.sleep(for: .milliseconds(10))

        coordinator.panelVisibilityChanged(visible: false)
        await active.value
        await queued.value

        #expect(calls == [[.kimiCode]])
        #expect(appState.cliQuotaRefreshingProviders.isEmpty)
    }

    private func claudeSnapshot(
        utilization: Double,
        dataAsOf: Date?
    ) -> ProviderRateLimit {
        ProviderRateLimit(
            provider: .claudeCode,
            fiveHour: RateLimitWindow(utilization: utilization),
            status: .ok,
            fetchedAt: dataAsOf,
            dataAsOf: dataAsOf
        )
    }

    /// The cold-open contract: the on-disk cache paints first so the card is
    /// never blank during the probe's ~2.5s round trip, then the live reading
    /// replaces it.
    @Test @MainActor
    func claudeCachePaintsBeforeLiveProbeReplacesIt() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        var paintedWhileProbing: ProviderRateLimit?

        let cached = claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )
        let live = claudeSnapshot(
            utilization: 42,
            dataAsOf: Date(timeIntervalSince1970: 200)
        )

        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: {
                paintedWhileProbing = appState.rateLimits.first { $0.provider == .claudeCode }
                return live
            },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(paintedWhileProbing == cached)
        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == live)
        #expect(!appState.isClaudeRateLimitRefreshing)
    }

    /// A failing probe must not blank a card the cache already filled — the
    /// 「数据截至」 footer states the age honestly instead.
    @Test @MainActor
    func claudeProbeFailureKeepsCachedSnapshot() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let cached = claudeSnapshot(
            utilization: 10,
            dataAsOf: Date(timeIntervalSince1970: 100)
        )

        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.noBinary },
            loadClaudeCache: { cached }
        )

        await coordinator.refreshClaude()

        #expect(appState.rateLimits.first { $0.provider == .claudeCode } == cached)
    }

    /// If a Claude executable exists but the live probe fails and no cache can
    /// paint, surface the retryable card instead of collapsing it as no data.
    @Test @MainActor
    func claudeProbeFailureWithoutCacheSurfacesRetryableError() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.timedOut },
            loadClaudeCache: { nil }
        )

        await coordinator.refreshClaude()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .claudeCode })?.status
                == .retryableError
        )
    }

    /// Not having Claude installed is expected on many Macs and should retain
    /// the quiet capability notice rather than looking like an app failure.
    @Test @MainActor
    func missingClaudeInstallationWithoutCacheStaysQuiet() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.noBinary },
            loadClaudeCache: { nil }
        )

        await coordinator.refreshClaude()

        #expect(
            appState.rateLimits.first(where: { $0.provider == .claudeCode })?.status == .noData
        )
    }

    /// An API-key / Bedrock session has no plan quota at all. That is a
    /// permanent answer, so the card collapses rather than showing stale
    /// percentages or implying a retry would help.
    @Test @MainActor
    func claudeAccountWithoutPlanLimitsCollapsesTheCard() async {
        let appState = AppState()
        appState.claudeRateLimitEnabled = true
        let coordinator = RateLimitCoordinator(
            appState: appState,
            fetchClaudeLive: { throw ClaudeUsageProbe.ProbeError.limitsNotApplicable },
            loadClaudeCache: {
                self.claudeSnapshot(
                    utilization: 10,
                    dataAsOf: Date(timeIntervalSince1970: 100)
                )
            }
        )

        await coordinator.refreshClaude()

        #expect(appState.rateLimits.first { $0.provider == .claudeCode }?.status == .noData)
    }
}
