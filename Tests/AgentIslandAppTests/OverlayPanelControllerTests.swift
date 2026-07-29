import AppKit
import Testing
@testable import AgentIslandApp
import AgentIslandCore

struct OverlayPanelControllerTests {
    @Test
    func closedPresentationVisibilityModesRemainDistinct() {
        #expect(!IslandClosedPresentation.ghost.showsClosedSurface(hasActivity: true, menuBarVisible: true))
        #expect(!IslandClosedPresentation.activityOnly.showsClosedSurface(hasActivity: false, menuBarVisible: true))
        #expect(IslandClosedPresentation.activityOnly.showsClosedSurface(hasActivity: true, menuBarVisible: false))
        #expect(!IslandClosedPresentation.menuBarOnly.showsClosedSurface(hasActivity: true, menuBarVisible: false))
        #expect(IslandClosedPresentation.menuBarOnly.showsClosedSurface(hasActivity: false, menuBarVisible: true))
        #expect(IslandClosedPresentation.minimal.showsClosedSurface(hasActivity: false, menuBarVisible: false))
        #expect(IslandClosedPresentation.alwaysVisible.showsClosedSurface(hasActivity: false, menuBarVisible: false))
        #expect(!IslandClosedPresentation.hidden.showsClosedSurface(hasActivity: true, menuBarVisible: true))
        #expect(!IslandClosedPresentation.hidden.allowsHoverOpen)
    }

    @Test @MainActor
    func closedIslandHoverUsesBalancedDwell() {
        #expect(AppModel.hoverOpenDelay == 1.0)
    }

    @Test @MainActor
    func hoverDwellDoesNotFireBeforeDelay() {
        var scheduledDelay: TimeInterval?
        var scheduledWorkItem: DispatchWorkItem?
        let timer = HoverDwellTimer { delay, workItem in
            scheduledDelay = delay
            scheduledWorkItem = workItem
        }
        var fired = false

        timer.schedule(after: 1.0) {
            fired = true
        }

        #expect(scheduledDelay == 1.0)
        #expect(!fired)
        #expect(timer.isPending)

        scheduledWorkItem?.perform()

        #expect(fired)
        #expect(!timer.isPending)
    }

    @Test @MainActor
    func leavingHoverRegionCancelsPendingDwell() {
        var scheduledWorkItem: DispatchWorkItem?
        let timer = HoverDwellTimer { _, workItem in
            scheduledWorkItem = workItem
        }
        var fired = false

        timer.schedule(after: 1.0) {
            fired = true
        }
        timer.cancel()
        scheduledWorkItem?.perform()

        #expect(!fired)
        #expect(!timer.isPending)
    }

    @Test
    func closedSurfaceRectCentersOnNotch() {
        let notchRect = NSRect(x: 200, y: 900, width: 200, height: 38)
        let closedWidth: CGFloat = 320

        let rect = OverlayPanelController.closedSurfaceRect(
            notchRect: notchRect,
            closedWidth: closedWidth
        )

        // Centered on notch midX (300), width 320
        #expect(rect.minX == 140)
        #expect(rect.minY == 900)
        #expect(rect.width == 320)
        #expect(rect.height == 38)
    }

    @Test
    func closedSurfaceRectHitTestingBoundary() {
        let notchRect = NSRect(x: 400, y: 1_000, width: 200, height: 38)
        let closedWidth: CGFloat = 420

        let rect = OverlayPanelController.closedSurfaceRect(
            notchRect: notchRect,
            closedWidth: closedWidth
        )

        #expect(rect.contains(NSPoint(x: rect.minX + 2, y: rect.midY)))
        #expect(rect.contains(NSPoint(x: rect.maxX - 2, y: rect.midY)))
        #expect(!rect.contains(NSPoint(x: rect.minX - 1, y: rect.midY)))
        #expect(!rect.contains(NSPoint(x: rect.maxX + 1, y: rect.midY)))
    }

    @Test
    func edgeInclusiveHitTestingTreatsMaxBoundaryAsInside() {
        let rect = NSRect(x: 100, y: 200, width: 224, height: 8)
        #expect(OverlayPanelController.rectContainsIncludingEdges(rect, point: NSPoint(x: 150, y: 208)))
        #expect(OverlayPanelController.rectContainsIncludingEdges(rect, point: NSPoint(x: 324, y: 205)))
        #expect(!OverlayPanelController.rectContainsIncludingEdges(rect, point: NSPoint(x: 325, y: 205)))
        #expect(!OverlayPanelController.rectContainsIncludingEdges(rect, point: NSPoint(x: 150, y: 209)))
    }

    @Test
    func notchedDisplayClosedWidthWrapsPhysicalNotchWithFixedReserve() {
        // v6 MacBook layout: outer width = 44 + physical notch + 44.
        let width = OverlayPanelController.closedPanelWidth(
            notchWidth: 224,
            isNotchedDisplay: true,
            notchStatus: .closed
        )
        #expect(width == CGFloat(224 + 88))
    }

    @Test
    func externalDisplayClosedWidthUsesFixedHitArea() {
        // v6 external layout: fluid in SwiftUI, but the controller uses a
        // generous fixed hit-area so hover/click works without knowing the
        // live content width.
        let width = OverlayPanelController.closedPanelWidth(
            notchWidth: 0,
            isNotchedDisplay: false,
            notchStatus: .closed
        )
        #expect(width == CGFloat(360))
    }

    @Test
    func poppingStatusAddsHoverBudget() {
        let width = OverlayPanelController.closedPanelWidth(
            notchWidth: 224,
            isNotchedDisplay: true,
            notchStatus: .popping
        )
        #expect(width == CGFloat(224 + 88 + 18))
    }

    @Test
    func clickOpensActivateThePanel() {
        #expect(OverlayPanelController.shouldActivatePanel(for: .click))
    }

    @Test
    func passiveOpensDoNotActivateThePanel() {
        #expect(!OverlayPanelController.shouldActivatePanel(for: .hover))
        #expect(!OverlayPanelController.shouldActivatePanel(for: .notification))
        #expect(!OverlayPanelController.shouldActivatePanel(for: .boot))
        #expect(!OverlayPanelController.shouldActivatePanel(for: nil))
    }

    @Test @MainActor
    func selectedCollapsedSessionDoesNotReserveExpandedDetailHeight() {
        let now = Date()
        let sessionID = "selected-collapsed-panel-sizing"
        let model = AppModel()
        model.state = SessionState(
            sessions: [
                AgentSession(
                    id: sessionID,
                    title: "Completed task",
                    tool: .codex,
                    phase: .completed,
                    summary: "A detailed completion response.",
                    updatedAt: now,
                    codexMetadata: CodexSessionMetadata(
                        lastAssistantMessage: String(
                            repeating: "Detailed completion line. ",
                            count: 30
                        )
                    )
                ),
            ]
        )
        model.notchOpenReason = .click
        model.islandSurface = .sessionList()

        let controller = OverlayPanelController()
        let ordinaryListHeight = controller.openedContentHeight(
            for: model,
            at: now
        )

        model.islandSurface = .sessionList(
            actionableSessionID: sessionID
        )
        model.setSessionDetailExpanded(false, for: sessionID)
        let selectedCollapsedHeight = controller.openedContentHeight(
            for: model,
            at: now
        )

        model.setSessionDetailExpanded(true, for: sessionID)
        let selectedExpandedHeight = controller.openedContentHeight(
            for: model,
            at: now
        )

        #expect(selectedCollapsedHeight == ordinaryListHeight)
        #expect(selectedExpandedHeight > selectedCollapsedHeight)
    }

    // MARK: - islandClosedHeight

    @Test
    func islandClosedHeightClampsToNotchHeightWhenSmallerThanMenuBar() {
        // Simulates MacBook Air M2: physical notch ≈ 34 pt, menu bar reserved ≈ 37 pt.
        // Must return 34 (the smaller value) so the island sits flush with the notch.
        let height = NSScreen.computeIslandClosedHeight(safeAreaInsetsTop: 34, topStatusBarHeight: 37)
        #expect(height == 34)
    }

    @Test
    func islandClosedHeightUsesNotchHeightEvenWhenMenuBarIsShorter() {
        // When menu bar reserved < notch (e.g. auto-hide menu bar), the island must
        // still match the physical notch height to avoid a visible gap.
        let height = NSScreen.computeIslandClosedHeight(safeAreaInsetsTop: 37, topStatusBarHeight: 34)
        #expect(height == 37)
    }

    @Test
    func islandClosedHeightFallsBackToMenuBarHeightOnNonNotchScreen() {
        // Non-notch screen: safeAreaInsets.top == 0, fall back to topStatusBarHeight.
        let height = NSScreen.computeIslandClosedHeight(safeAreaInsetsTop: 0, topStatusBarHeight: 24)
        #expect(height == 24)
    }
}
