import Foundation
import Testing
@testable import VibeUsage

@MainActor
struct RateLimitCardViewTests {
    private func snapshot(
        provider: ProviderRateLimit.Provider,
        status: ProviderRateLimit.Status
    ) -> ProviderRateLimit {
        ProviderRateLimit(provider: provider, status: status)
    }

    /// Regression for the Settings mismatch: Claude is enabled, but its
    /// settled `.noData` result used to make the card disappear whenever Codex
    /// had data, leaving the dashboard looking Codex-only.
    @Test
    func enabledClaudeRemainsVisibleBesideAvailableCodex() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.codex, .claudeCode],
            snapshots: [
                snapshot(provider: .codex, status: .ok),
                snapshot(provider: .claudeCode, status: .noData),
            ],
            refreshing: []
        )

        #expect(visible == [.codex, .claudeCode])
    }

    /// Preserve the intentionally compact empty state when neither provider
    /// has anything useful to show.
    @Test
    func twoSettledEmptyProvidersUseTheNoticeBar() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.codex, .claudeCode],
            snapshots: [
                snapshot(provider: .codex, status: .noData),
                snapshot(provider: .claudeCode, status: .noData),
            ],
            refreshing: []
        )

        #expect(visible.isEmpty)
    }

    @Test
    func onlyEnabledProviderIsVisible() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.claudeCode],
            snapshots: [
                snapshot(provider: .codex, status: .ok),
                snapshot(provider: .claudeCode, status: .ok),
            ],
            refreshing: []
        )

        #expect(visible == [.claudeCode])
    }

    @Test
    func refreshingClaudeKeepsBothEnabledProvidersVisible() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.codex, .claudeCode],
            snapshots: [
                snapshot(provider: .codex, status: .noData),
                snapshot(provider: .claudeCode, status: .noData),
            ],
            refreshing: [.claudeCode]
        )

        #expect(visible == [.codex, .claudeCode])
    }

    @Test
    func disabledRefreshingProviderIsNotVisible() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.codex],
            snapshots: [
                snapshot(provider: .codex, status: .ok),
                snapshot(provider: .claudeCode, status: .noData),
            ],
            refreshing: [.claudeCode]
        )

        #expect(visible == [.codex])
    }

    @Test
    func selectedCursorKeepsItsPendingCardVisibleBesideGrok() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.grok, .cursor],
            snapshots: [
                snapshot(provider: .grok, status: .ok),
                snapshot(provider: .cursor, status: .noData),
            ],
            refreshing: []
        )

        #expect(visible == [.grok, .cursor])
    }

    @Test
    func cursorPendingStateIsVisibleWhenSelectedAlone() {
        let visible = RateLimitCardView.visibleProviders(
            selected: [.cursor],
            snapshots: [snapshot(provider: .cursor, status: .noData)],
            refreshing: []
        )

        #expect(visible == [.cursor])
    }
}
