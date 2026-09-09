import AppKit
import Testing
@testable import VibeUsage

struct MenuBarPanelGeometryTests {
    @Test func rightAlignsPanelBelowStatusItem() {
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: NSRect(x: 1_300, y: 877, width: 24, height: 23),
            panelSize: NSSize(width: 520, height: 620),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 877),
            topGap: 6,
            edgeInset: 8
        )

        #expect(point.x == 804)
        #expect(point.y == 871)
    }

    @Test func clampsPanelToLeftEdgeOfSecondaryDisplay() {
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: NSRect(x: -1_910, y: 1_057, width: 24, height: 23),
            panelSize: NSSize(width: 520, height: 620),
            visibleFrame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_057),
            topGap: 6,
            edgeInset: 8
        )

        #expect(point.x == -1_912)
        #expect(point.y == 1_051)
    }

    @Test func keepsPanelInsideShortVisibleFrame() {
        let point = MenuBarPanelGeometry.topLeftPoint(
            anchorFrame: NSRect(x: 990, y: 700, width: 24, height: 23),
            panelSize: NSSize(width: 520, height: 620),
            visibleFrame: NSRect(x: 0, y: 90, width: 1_000, height: 610),
            topGap: 6,
            edgeInset: 8
        )

        #expect(point.x == 472)
        #expect(point.y == 700)
    }
}
