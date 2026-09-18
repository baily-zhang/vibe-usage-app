import AppKit
import Testing
@testable import VibeUsage

/// The quota tooltip renders in the popover's topmost layer (outside the card
/// scroller and the dashboard `ScrollView`) so nothing can crop it. These are
/// the placement rules that keep it whole once it is out there — plain
/// arithmetic, like `MenuBarPanelGeometry`.
struct QuotaTooltipPlacementTests {
    private let panel = CGSize(width: 520, height: 620)
    private let tooltip = CGSize(width: 220, height: 66)

    /// The ordinary case is unchanged from when the card drew the tooltip
    /// itself: card leading edge, 6pt under the hovered row.
    @Test func hangsBelowTheHoveredRow() {
        let origin = QuotaTooltipPlacement.origin(
            rowRect: CGRect(x: 28, y: 100, width: 200, height: 16),
            tooltipSize: tooltip,
            containerSize: panel
        )

        #expect(origin.x == 28)
        #expect(origin.y == 122)
    }

    /// A row low enough that the tooltip would cross the panel's bottom edge —
    /// and be cut there — flips the tooltip above the row instead.
    @Test func flipsAboveARowWithNoRoomBelow() {
        let origin = QuotaTooltipPlacement.origin(
            rowRect: CGRect(x: 28, y: 580, width: 200, height: 16),
            tooltipSize: tooltip,
            containerSize: panel
        )

        #expect(origin.y == 580 - QuotaTooltipPlacement.gap - tooltip.height)
        #expect(origin.y + tooltip.height <= panel.height - QuotaTooltipPlacement.edgeInset)
    }

    /// Scrolled far enough that the hovered row has left the panel's top: the
    /// tooltip clamps to the edge inset rather than following the row off the
    /// panel, so it is never half-drawn.
    @Test func clampsARowScrolledPastTheTopEdge() {
        let origin = QuotaTooltipPlacement.origin(
            rowRect: CGRect(x: 28, y: -40, width: 200, height: 16),
            tooltipSize: tooltip,
            containerSize: panel
        )

        #expect(origin.y == QuotaTooltipPlacement.edgeInset)
        #expect(origin.y + tooltip.height <= panel.height)
    }

    /// A card scrolled part-way out of the row on either side still gets a
    /// whole tooltip: the leading edge is pulled back to the inset when it
    /// would start off-panel, and the trailing edge stops at the inset when the
    /// card has scrolled off to the right.
    @Test func keepsFullWidthInsideThePanelEdges() {
        let scrolledLeft = QuotaTooltipPlacement.origin(
            rowRect: CGRect(x: -60, y: 100, width: 200, height: 16),
            tooltipSize: tooltip,
            containerSize: panel
        )
        let scrolledRight = QuotaTooltipPlacement.origin(
            rowRect: CGRect(x: 512, y: 100, width: 200, height: 16),
            tooltipSize: tooltip,
            containerSize: panel
        )

        #expect(scrolledLeft.x == QuotaTooltipPlacement.edgeInset)
        #expect(scrolledRight.x + tooltip.width == panel.width - QuotaTooltipPlacement.edgeInset)
    }
}
