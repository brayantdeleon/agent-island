import AppKit
import SwiftUI
@preconcurrency import MarkdownUI
import AgentIslandCore

private struct NotificationContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SessionRowsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Auto-height container: renders content directly (auto-sizing).
/// When content exceeds maxHeight, wraps in ScrollView at fixed maxHeight.
private struct AutoHeightScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    private var isScrollable: Bool { contentHeight > maxHeight }

    var body: some View {
        // Always use ScrollView so the content gets unconstrained vertical
        // space for measurement.  Without this, a tight parent window can
        // cap the GeometryReader measurement, making long content appear
        // truncated instead of scrollable.
        ScrollView(.vertical) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(ContentHeightKey.self) { height in
                    if height > 0 { contentHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(isScrollable ? .automatic : .hidden)
        .frame(height: contentHeight > 0 ? min(contentHeight, maxHeight) : nil)
    }
}

// MARK: - Row Height Estimation

extension AgentSession {
    /// Estimated row height matching `IslandSessionRow` layout for viewport sizing.
    func estimatedIslandRowHeight(at date: Date) -> CGFloat {
        let presence = islandPresence(at: date)
        // v8 list rows are full-width scan rows, not rounded cards.
        // Base: vertical padding (22) + headline (~17) + divider rounding.
        var height: CGFloat = 40
        guard presence != .inactive else { return height }
        if spotlightPromptLineText != nil { height += 17 }
        if spotlightActivityLineText != nil { height += 20 }
        if let subagents = claudeMetadata?.activeSubagents, !subagents.isEmpty {
            height += 18
            height += CGFloat(subagents.count) * 18  // each subagent row (spacing 4 + text 14)
        }
        if let tasks = claudeMetadata?.activeTasks, !tasks.isEmpty {
            height += 17
            height += CGFloat(tasks.count) * 16  // each task row (spacing 3 + text 13)
        }
        return height
    }
}

// MARK: - Animations

private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
private let closeAnimation = Animation.smooth(duration: 0.3)
private let popAnimation = Animation.spring(response: 0.3, dampingFraction: 0.5)
private let openedSurfaceUnmountDelay: TimeInterval = 0.36

private struct ConditionalDrawingGroup: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.drawingGroup()
        } else {
            content
        }
    }
}

// MARK: - Main island view

struct IslandPanelView: View {
    private static let headerControlButtonSize: CGFloat = 22
    private static let headerControlSpacing: CGFloat = 8
    private static let headerHorizontalPadding: CGFloat = 18
    private static let headerTopPadding: CGFloat = 2
    private static let notchHeaderHorizontalPadding: CGFloat = 46
    private static let notchLaneSafetyInset: CGFloat = 12
    private static let minimumRightUsageLaneWidth: CGFloat = 58

    var model: AppModel
    private var lang: LanguageManager { model.lang }

    @State private var isHovering = false
    @State private var keepsOpenedSurfaceMounted = false
    @State private var openedSurfaceMountGeneration: UInt64 = 0

    private var isOpened: Bool {
        model.notchStatus == .opened
    }

    private var usesOpenedVisualState: Bool {
        isOpened
    }

    private var shouldRenderOpenedSurface: Bool {
        usesOpenedVisualState || keepsOpenedSurfaceMounted
    }

    private var isPopping: Bool {
        model.notchStatus == .popping
    }

    /// Single animation selection based on the current notch status.
    private var notchTransitionAnimation: Animation {
        switch model.notchStatus {
        case .opened:  return openAnimation
        case .closed:  return closeAnimation
        case .popping: return popAnimation
        }
    }

    private var targetOverlayScreen: NSScreen? {
        if let targetScreenID = model.overlayPlacementDiagnostics?.targetScreenID,
           let screen = NSScreen.screens.first(where: { OverlayDisplayResolver.screenID(for: $0) == targetScreenID }) {
            return screen
        }

        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    private var usesNotchAwareOpenedHeader: Bool {
        model.overlayPlacementDiagnostics?.mode == .notch
            || targetOverlayScreen?.safeAreaInsets.top ?? 0 > 0
    }

    /// True when the closed island sits on an external (non-notched) display.
    /// The central black rectangle is otherwise aligned with the physical
    /// notch, so center content is only useful here.
    private var isExternalDisplayPlacement: Bool {
        if let mode = model.overlayPlacementDiagnostics?.mode {
            return mode == .topBar
        }
        // Fallback when diagnostics haven't been populated yet.
        return (targetOverlayScreen?.safeAreaInsets.top ?? 0) == 0
    }

    private var openedHeaderButtonsWidth: CGFloat {
        (Self.headerControlButtonSize * 3) + (Self.headerControlSpacing * 2)
    }

    private var openedHeaderHorizontalPadding: CGFloat {
        usesNotchAwareOpenedHeader ? Self.notchHeaderHorizontalPadding : Self.headerHorizontalPadding
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.clear

                notchContent(availableSize: geometry.size)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .alert(
            model.lang.t("island.quit.confirmTitle"),
            isPresented: Binding(
                get: { model.isQuitConfirmationPresented },
                set: { model.isQuitConfirmationPresented = $0 }
            )
        ) {
            Button(model.lang.t("island.quit.confirmAction"), role: .destructive) {
                model.quitApplication()
            }
            Button(model.lang.t("settings.general.cancel"), role: .cancel) {}
        } message: {
            Text(model.lang.t("island.quit.confirmMessage"))
        }
        .onAppear {
            syncOpenedSurfaceMount(with: model.notchStatus, immediate: true)
        }
        .onChange(of: model.notchStatus) { _, status in
            syncOpenedSurfaceMount(with: status)
        }
    }

    @ViewBuilder
    private func notchContent(availableSize: CGSize) -> some View {
        // Window is always at opened size — use opened insets unconditionally.
        let panelShadowHorizontalInset = IslandChromeMetrics.openedShadowHorizontalInset
        let panelShadowBottomInset = IslandChromeMetrics.openedShadowBottomInset
        let layoutWidth = max(0, availableSize.width - (panelShadowHorizontalInset * 2))
        let layoutHeight = max(0, availableSize.height - panelShadowBottomInset)

        let outerHorizontalPadding: CGFloat = 0
        let outerBottomPadding: CGFloat = 0
        let openedWidth = max(0, layoutWidth - outerHorizontalPadding)
        let openedHeight = max(closedNotchHeight, layoutHeight - outerBottomPadding)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if shouldRenderOpenedSurface {
                    openedSurface(width: openedWidth, height: openedHeight)
                        .opacity(usesOpenedVisualState ? 1 : 0)
                        .allowsHitTesting(usesOpenedVisualState)
                }

                v6ClosedSurface()
                    .opacity(usesOpenedVisualState ? 0 : 1)
                    .allowsHitTesting(!usesOpenedVisualState)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scaleEffect(usesOpenedVisualState ? 1 : (isHovering ? IslandChromeMetrics.closedHoverScale : 1), anchor: .top)
        .padding(.horizontal, panelShadowHorizontalInset)
        .padding(.bottom, panelShadowBottomInset)
        .animation(notchTransitionAnimation, value: model.notchStatus)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }

    private func syncOpenedSurfaceMount(with status: NotchStatus, immediate: Bool = false) {
        openedSurfaceMountGeneration &+= 1
        let generation = openedSurfaceMountGeneration

        switch status {
        case .opened:
            keepsOpenedSurfaceMounted = true
        case .closed, .popping:
            guard !immediate else {
                keepsOpenedSurfaceMounted = false
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + openedSurfaceUnmountDelay) {
                guard openedSurfaceMountGeneration == generation,
                      model.notchStatus != .opened else {
                    return
                }
                keepsOpenedSurfaceMounted = false
            }
        }
    }

    // MARK: - v6 closed surface

    /// Closed island per v6 spec. Renders the flat-top pill with the
    /// UnifiedBars glyph, respecting the user's right-slot / center-label
    /// preferences. AppModel is @Observable so any change to sessions /
    /// preferences re-renders this automatically; UnifiedBars runs its own
    /// TimelineView internally for bar animation.
    @ViewBuilder
    private func v6ClosedSurface() -> some View {
        if model.islandClosedPresentation == .menuBarOnly {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                closedPresentationSurface(menuBarVisible: NSMenu.menuBarVisible())
            }
        } else {
            closedPresentationSurface(menuBarVisible: true)
        }
    }

    @ViewBuilder
    private func closedPresentationSurface(menuBarVisible: Bool) -> some View {
        let presentation = model.islandClosedPresentation
        let layout: V6ClosedLayout = isExternalDisplayPlacement ? .external : .macbook
        let physicalNotchWidth: CGFloat = targetOverlayScreen?.notchSize.width ?? 180

        if presentation.showsClosedSurface(
            hasActivity: model.hasClosedIslandActivity,
            menuBarVisible: menuBarVisible
        ) {
            if presentation == .minimal {
                Capsule(style: .continuous)
                    .fill(model.islandClosedMode == .waiting ? IslandDesignPalette.Status.waitingAggregate : V6Palette.paper.opacity(0.65))
                    .frame(width: 38, height: 3)
                    .frame(height: closedNotchHeight, alignment: .bottom)
                    .padding(.bottom, 2)
            } else {
                V6ClosedPill(
                    mode: model.islandClosedMode,
                    label: layout == .external ? model.islandClosedLabel() : nil,
                    rightSlot: model.islandClosedRightSlotContent(),
                    layout: layout,
                    activePets: model.islandClosedActivePets,
                    height: closedNotchHeight,
                    physicalNotchWidth: layout == .macbook ? physicalNotchWidth : 0,
                    minWidth: 70
                )
                .scaleEffect(isPopping ? 1.04 : 1, anchor: .top)
                .animation(popAnimation, value: isPopping)
            }
        }
    }

    // MARK: - Opened surface

    @ViewBuilder
    private func openedSurface(width openedWidth: CGFloat, height openedHeight: CGFloat) -> some View {
        let horizontalInset = 0.0
        let bottomInset = 0.0
        let surfaceWidth = openedWidth + (horizontalInset * 2)
        let surfaceHeight = openedHeight + bottomInset
        let surfaceShape = OpenedIslandSurfaceShape(
            topProfile: usesNotchAwareOpenedHeader ? .notch : .topBar
        )

        ZStack(alignment: .top) {
            surfaceShape
                .fill(V6Palette.ink)
                .frame(width: surfaceWidth, height: surfaceHeight)

            VStack(spacing: 0) {
                openedHeaderContent
                    .frame(height: closedNotchHeight)

                openedContent
                    .frame(width: openedWidth)
                    .frame(maxHeight: max(0, openedHeight - closedNotchHeight), alignment: .top)
                    .clipped()
            }
            .frame(width: openedWidth, height: openedHeight, alignment: .top)
            .padding(.horizontal, horizontalInset)
            .padding(.bottom, bottomInset)
            .clipShape(surfaceShape)
            .overlay {
                surfaceShape
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            }
        }
        .frame(width: surfaceWidth, height: surfaceHeight, alignment: .top)
    }

    // MARK: - Closed state

    private var closedNotchWidth: CGFloat {
        (targetOverlayScreen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }))?.notchSize.width ?? NSScreen.externalDisplayNotchWidth
    }

    private var closedNotchHeight: CGFloat {
        (targetOverlayScreen ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }))?.islandClosedHeight ?? 24
    }

    @ViewBuilder
    private var openedHeaderContent: some View {
        if usesNotchAwareOpenedHeader {
            GeometryReader { geometry in
                let providers = openedUsageProviders
                let providerGroups = splitUsageProviders(providers)
                let metrics = openedHeaderMetrics(for: geometry.size.width)

                HStack(spacing: 0) {
                    usageLaneView(providerGroups.left, alignment: .leading)
                        .frame(width: metrics.leftUsageWidth, alignment: .leading)

                    Color.clear
                        .frame(width: metrics.centerGapWidth)

                    HStack(spacing: Self.headerControlSpacing) {
                        if metrics.rightUsageWidth > 0, !providerGroups.right.isEmpty {
                            usageLaneView(providerGroups.right, alignment: .trailing)
                                .frame(width: metrics.rightUsageWidth, alignment: .trailing)
                        }
                        openedHeaderButtons
                    }
                    .frame(width: metrics.rightLaneWidth, alignment: .trailing)
                }
                .padding(.horizontal, openedHeaderHorizontalPadding)
                .padding(.top, Self.headerTopPadding)
            }
        } else {
            HStack(spacing: 12) {
                openedUsageSummary
                    .frame(maxWidth: .infinity, alignment: .leading)

                openedHeaderButtons
            }
            .padding(.leading, openedHeaderHorizontalPadding)
            .padding(.trailing, openedHeaderHorizontalPadding)
            .padding(.top, Self.headerTopPadding)
        }
    }

    private var openedHeaderButtons: some View {
        HStack(spacing: Self.headerControlSpacing) {
            headerIconButton(
                systemName: "arrow.clockwise",
                tint: .white.opacity(0.62),
                accessibilityLabel: "Refresh sessions"
            ) {
                model.refreshSessionsManually()
            }
            .disabled(model.isSessionRefreshInProgress)

            headerIconButton(systemName: "gearshape.fill", tint: .white.opacity(0.62)) {
                model.showSettings()
            }

            headerIconButton(
                systemName: "power",
                tint: .white.opacity(0.62),
                accessibilityLabel: model.lang.t("island.quit.confirmTitle")
            ) {
                model.isQuitConfirmationPresented = true
            }
        }
    }

    private func headerIconButton(
        systemName: String,
        tint: Color,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.headerControlButtonSize, height: Self.headerControlButtonSize)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? systemName)
    }

    @ViewBuilder
    private var openedContent: some View {
        if model.islandSurface.isExpanded {
            expandedSessionSurface
        } else {
            VStack(spacing: 8) {
                if !model.hasAnyInstalledAgent {
                    installHooksHint
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                }

                if model.shouldShowSessionBootstrapPlaceholder {
                    sessionBootstrapPlaceholder
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                } else if model.islandListSessions.isEmpty {
                    emptyState
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                } else {
                    sessionList
                }
            }
            .padding(.bottom, 0)
        }
    }

    private var expandedSessionSurface: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GeometryReader { geometry in
                let widths = Self.expandedPaneWidths(
                    availableWidth: geometry.size.width
                )

                HStack(spacing: 0) {
                    expandedTaskNavigation(referenceDate: context.date)
                        .frame(width: widths.navigation)

                    Rectangle()
                        .fill(.white.opacity(0.07))
                        .frame(width: widths.separator)

                    Group {
                        if let session = model.expandedSelectedSession {
                            expandedTaskDetail(
                                session,
                                referenceDate: context.date
                            )
                        } else {
                            emptyState
                                .padding(24)
                        }
                    }
                    .frame(width: widths.detail)
                    .frame(maxHeight: .infinity)
                    .clipped()
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .leading
                )
                .clipped()
            }
        }
    }

    nonisolated static func expandedPaneWidths(
        availableWidth: CGFloat
    ) -> (
        navigation: CGFloat,
        separator: CGFloat,
        detail: CGFloat
    ) {
        let totalWidth = max(0, availableWidth)
        let separatorWidth = min(1, totalWidth)
        let contentWidth = max(0, totalWidth - separatorWidth)
        let navigationWidth = min(300, max(0, contentWidth - 360))

        return (
            navigation: navigationWidth,
            separator: separatorWidth,
            detail: contentWidth - navigationWidth
        )
    }

    private func expandedTaskNavigation(
        referenceDate: Date
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("TASKS")
                    .font(
                        .system(
                            size: 11,
                            weight: .semibold,
                            design: .monospaced
                        )
                    )
                    .tracking(1.2)
                    .foregroundStyle(V6Palette.paper.opacity(0.58))
                Spacer()
                Text("\(model.islandListSessions.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(V6Palette.paper.opacity(0.34))
            }
            .padding(.horizontal, 16)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 1)
            }

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        model.expandedIslandSessionSections(
                            at: referenceDate
                        )
                    ) { section in
                        expandedSectionHeader(section)
                        ForEach(section.sessions) { session in
                            expandedTaskNavigationRow(
                                session,
                                referenceDate: referenceDate
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.white.opacity(0.012))
    }

    private func expandedSectionHeader(
        _ section: IslandSessionSection
    ) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(sectionTint(for: section))
                .frame(width: 6, height: 6)
            Text(sessionSectionTitle(for: section).uppercased())
                .font(
                    .system(
                        size: 9.5,
                        weight: .semibold,
                        design: .monospaced
                    )
                )
                .tracking(0.4)
                .foregroundStyle(sectionLabelColor(for: section))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func expandedTaskNavigationRow(
        _ session: AgentSession,
        referenceDate: Date
    ) -> some View {
        let isSelected = model.expandedSelectedSession?.id == session.id
        let tint = IslandDesignPalette.Status.tint(for: session.phase)
        let slot = model.agentControlHardwareBadgeLabel(
            for: session.id,
            at: referenceDate
        )

        return Button {
            model.selectExpandedSession(session.id)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(V6Palette.paper.opacity(0.9))
                        .lineLimit(1)
                    Text(session.spotlightStatusLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(V6Palette.paper.opacity(0.42))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if let slot {
                    Text(slot)
                        .font(
                            .system(
                                size: 9,
                                weight: .semibold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(V6Palette.paper.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(
                isSelected
                    ? Color.white.opacity(0.085)
                    : Color.clear
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(tint)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func expandedTaskDetail(
        _ session: AgentSession,
        referenceDate: Date
    ) -> some View {
        let history = session.providerHistoryMetadata

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(V6Palette.paper.opacity(0.96))
                        Text(
                            "\(session.tool.displayName) · \(session.phase.displayName) · \(session.spotlightAgeBadge(at: referenceDate))"
                        )
                        .font(
                            .system(
                                size: 10.5,
                                weight: .medium,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(
                            IslandDesignPalette.Status.tint(
                                for: session.phase
                            ).opacity(0.84)
                        )
                    }
                    Spacer()
                    Text("READ ONLY")
                        .font(
                            .system(
                                size: 9,
                                weight: .bold,
                                design: .monospaced
                            )
                        )
                        .tracking(0.8)
                        .foregroundStyle(V6Palette.paper.opacity(0.42))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Color.white.opacity(0.06),
                            in: Capsule()
                        )
                }

                expandedMetadataGrid(session)
                expandedActionableState(session)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CONVERSATION / TASK HISTORY")
                            .font(
                                .system(
                                    size: 10.5,
                                    weight: .semibold,
                                    design: .monospaced
                                )
                            )
                            .tracking(0.5)
                            .foregroundStyle(V6Palette.paper.opacity(0.62))
                        Spacer()
                        Text(history.coverage.label.uppercased())
                            .font(
                                .system(
                                    size: 9,
                                    weight: .bold,
                                    design: .monospaced
                                )
                            )
                            .foregroundStyle(
                                history.coverage == .partial
                                    ? IslandDesignPalette.Status.waitingForAnswer
                                    : V6Palette.paper.opacity(0.34)
                            )
                    }

                    Text(history.sourceDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(V6Palette.paper.opacity(0.46))
                        .fixedSize(horizontal: false, vertical: true)

                    if history.entries.isEmpty {
                        Text(
                            "No provider-backed conversation turns are available for this task."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(V6Palette.paper.opacity(0.42))
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(
                            Color.white.opacity(0.025),
                            in: RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous
                            )
                        )
                    } else {
                        ForEach(history.entries) { entry in
                            expandedHistoryEntry(entry)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func expandedMetadataGrid(
        _ session: AgentSession
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            expandedMetadataRow(
                label: "Workspace",
                value: session.jumpTarget?.workspaceName
                    ?? "Not reported"
            )
            expandedMetadataRow(
                label: "Terminal",
                value: session.jumpTarget?.terminalApp
                    ?? "Not attached"
            )
            expandedMetadataRow(
                label: "Tracking",
                value: session.spotlightTrackingLabel
                    ?? "No transcript identifier"
            )
            if let tool = session.spotlightCurrentToolLabel {
                expandedMetadataRow(label: "Current tool", value: tool)
            }
        }
        .padding(14)
        .background(
            Color.white.opacity(0.028),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func expandedMetadataRow(
        label: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(
                    .system(
                        size: 9,
                        weight: .semibold,
                        design: .monospaced
                    )
                )
                .foregroundStyle(V6Palette.paper.opacity(0.34))
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(V6Palette.paper.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func expandedActionableState(
        _ session: AgentSession
    ) -> some View {
        if let request = session.permissionRequest {
            expandedReadOnlyCallout(
                title: "APPROVAL WAITING",
                tint: IslandDesignPalette.Status.waitingForApproval
            ) {
                Text(request.summary)
                if !request.affectedPath.isEmpty {
                    Text(request.affectedPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(V6Palette.paper.opacity(0.48))
                        .textSelection(.enabled)
                }
            }
        } else if let prompt = session.questionPrompt {
            expandedReadOnlyCallout(
                title: "ANSWER WAITING",
                tint: IslandDesignPalette.Status.waitingForAnswer
            ) {
                Text(prompt.title)
                let options = prompt.questions.flatMap(\.options).map(\.label)
                    + prompt.options
                if !options.isEmpty {
                    Text(options.joined(separator: "  ·  "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(V6Palette.paper.opacity(0.5))
                }
            }
        }
    }

    private func expandedReadOnlyCallout<Content: View>(
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(
                    .system(
                        size: 9.5,
                        weight: .bold,
                        design: .monospaced
                    )
                )
                .tracking(0.5)
                .foregroundStyle(tint.opacity(0.9))
            content()
                .font(.system(size: 12))
                .foregroundStyle(V6Palette.paper.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        }
    }

    private func expandedHistoryEntry(
        _ entry: ProviderHistoryEntry
    ) -> some View {
        let tint: Color = switch entry.kind {
        case .user:
            IslandDesignPalette.Status.running
        case .assistant:
            IslandDesignPalette.Status.completed
        case .activity:
            IslandDesignPalette.Status.waitingForAnswer
        }

        return VStack(alignment: .leading, spacing: 7) {
            Text(entry.label.uppercased())
                .font(
                    .system(
                        size: 9.5,
                        weight: .semibold,
                        design: .monospaced
                    )
                )
                .foregroundStyle(tint.opacity(0.82))
            Text(entry.text)
                .font(.system(size: 12))
                .foregroundStyle(V6Palette.paper.opacity(0.78))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    /// Persistent hint at the top of the expanded island while no agent
    /// hooks are installed. Decoupled from session presence — process
    /// discovery routinely surfaces sessions even on a freshly cleaned
    /// install, so the empty-state branch alone never reaches users who
    /// already run an agent.
    private var installHooksHint: some View {
        Button {
            model.showOnboarding()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(model.lang.t("island.hint.installHooks"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var sessionBootstrapPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.7))
                .scaleEffect(0.8)
            Text(model.lang.t("island.checkingTerminals"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            Text(model.lang.t("island.terminalOwnership"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.28))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(model.lang.t("island.noTerminals"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            Text(model.recentSessions.isEmpty
                ? model.lang.t("island.startAgent")
                : model.lang.t("island.recentSessions"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var actionableSessionID: String? {
        model.islandSurface.sessionID
    }

    private func agentControlDetailPresentationRequest(
        for sessionID: String
    ) -> AgentControlDetailPresentationRequest? {
        model.agentControlDetailPresentationRequests[sessionID]
    }

    /// Whether the panel was opened by a notification.
    private var isNotificationMode: Bool {
        model.islandSurface.isNotificationCard
    }

    /// Minimal keyboard presentation and notifications both render one
    /// identity-bound task, but only notifications offer the "show all"
    /// transition and auto-collapse behavior.
    private var isFocusedCardMode: Bool {
        isNotificationMode || model.islandSurface.isSingleTask
    }

    private static let maxSessionListHeight: CGFloat = 560

    private var sessionListSideInset: CGFloat {
        usesNotchAwareOpenedHeader ? 46 : 16
    }

    private var sessionList: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let referenceDate = context.date

            if isFocusedCardMode {
                // Focused-card mode: NO ScrollView — content sizes naturally
                sessionListContent(referenceDate: referenceDate)
                    .padding(.vertical, 2)
                    .onHover { hovering in
                        if hovering {
                            model.notePointerInsideIslandSurface()
                        } else {
                            model.handlePointerExitedIslandSurface()
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: NotificationContentHeightKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .onPreferenceChange(NotificationContentHeightKey.self) { height in
                        if height > 0 {
                            model.measuredNotificationContentHeight = height
                        }
                    }
            } else {
                VStack(spacing: 0) {
                    sessionPanelHeader(referenceDate: referenceDate)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            sessionRowsContent(referenceDate: referenceDate)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: SessionRowsContentHeightKey
                                                .self,
                                            value: geometry.size.height
                                        )
                                    }
                                )
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .onAppear {
                            scrollToActionableSession(using: proxy)
                        }
                        .onChange(of: actionableSessionID) {
                            scrollToActionableSession(using: proxy)
                        }
                        .onPreferenceChange(
                            SessionRowsContentHeightKey.self
                        ) { height in
                            if height > 0 {
                                model.measuredSessionRowsContentHeight =
                                    height
                            }
                        }
                    }

                    sessionPanelFooter
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func sessionListContent(referenceDate: Date) -> some View {
        VStack(spacing: 0) {
            if !isFocusedCardMode {
                sessionPanelHeader(referenceDate: referenceDate)
            }

            if isFocusedCardMode, let session = model.activeIslandCardSession {
                IslandSessionRow(
                    session: session,
                    referenceDate: referenceDate,
                    hardwareSlotBadge: model.agentControlHardwareBadgeLabel(
                        for: session.id,
                        at: referenceDate
                    ),
                    stateIndicator: model.islandSessionStateIndicator,
                    completedStaleThreshold: model.completedStaleThreshold.seconds,
                    isActionable: true,
                    isHardwareSelected:
                        model.agentControlKeyboardModeActive
                            && session.id
                                == model.agentControlSelectedSessionID,
                    detailPresentationRequest:
                        agentControlDetailPresentationRequest(
                            for: session.id
                        ),
                    questionDraft: questionInteractionBinding(for: session),
                    useDrawingGroup: model.notchStatus == .opened,
                    isInteractive: model.notchStatus == .opened,
                    presentation: .notification,
                    sideInset: sessionListSideInset,
                    lang: model.lang,
                    onDetailPresentationChange: {
                        model.setSessionDetailExpanded(
                            $0,
                            for: session.id
                        )
                    },
                    onApprove: { model.approvePermission(for: session.id, action: $0) },
                    onAnswer: {
                        guard let promptID = session.questionPrompt?.id else { return }
                        model.answerQuestion(
                            for: session.id,
                            promptID: promptID,
                            answer: $0
                        )
                    },
                    onReply: TerminalTextSender.canReply(to: session, enabled: model.completionReplyEnabled)
                        ? { model.replyToSession(session, text: $0) } : nil,
                    onJump: { model.expandNotificationToSessionList() },
                    onHide: model.isSessionHidden(session)
                        ? nil : { model.hideSession(session) },
                    onUnhide: model.isSessionHidden(session)
                        ? { model.unhideSession(session) } : nil
                )
                .id(notificationCardIdentity(for: session))

                let visibleSessionCount = model.islandListSessions.count
                if isNotificationMode, visibleSessionCount > 1 {
                    Button {
                        model.expandNotificationToSessionList()
                    } label: {
                        Text(model.lang.t("island.showAll", visibleSessionCount))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.36))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, sessionListSideInset)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(model.islandSessionSections(at: referenceDate)) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        if model.islandSessionGroup != .none {
                            sessionSectionHeader(section)
                        }

                        ForEach(section.sessions) { session in
                            IslandSessionRow(
                                session: session,
                                referenceDate: referenceDate,
                                hardwareSlotBadge: model.agentControlHardwareBadgeLabel(
                                    for: session.id,
                                    at: referenceDate
                                ),
                                stateIndicator: model.islandSessionStateIndicator,
                                completedStaleThreshold: model.completedStaleThreshold.seconds,
                                isActionable: session.phase.requiresAttention || session.id == actionableSessionID,
                                isHardwareSelected:
                                    model.agentControlKeyboardModeActive
                                        && session.id
                                            == model.agentControlSelectedSessionID,
                                detailPresentationRequest:
                                    agentControlDetailPresentationRequest(
                                        for: session.id
                                    ),
                                questionDraft: questionInteractionBinding(for: session),
                                useDrawingGroup: model.notchStatus == .opened,
                                isInteractive: model.notchStatus == .opened,
                                sideInset: sessionListSideInset,
                                lang: model.lang,
                                onDetailPresentationChange: {
                                    model.setSessionDetailExpanded(
                                        $0,
                                        for: session.id
                                    )
                                },
                                onApprove: { model.approvePermission(for: session.id, action: $0) },
                                onAnswer: {
                                    guard let promptID = session.questionPrompt?.id else { return }
                                    model.answerQuestion(
                                        for: session.id,
                                        promptID: promptID,
                                        answer: $0
                                    )
                                },
                                onReply: TerminalTextSender.canReply(to: session, enabled: model.completionReplyEnabled)
                                    ? { model.replyToSession(session, text: $0) } : nil,
                                onJump: { model.jumpToSession(session) },
                                onDismiss: session.isRemote ? { model.dismissSession(session.id) } : nil,
                                onHide: model.isSessionHidden(session)
                                    ? nil : { model.hideSession(session) },
                                onUnhide: model.isSessionHidden(session)
                                    ? { model.unhideSession(session) } : nil
                            )
                        }
                }
            }

                hiddenSessionsSection(referenceDate: referenceDate)
            }

            if !isFocusedCardMode {
                sessionPanelFooter
            }
        }
    }

    private func notificationCardIdentity(for session: AgentSession) -> String {
        switch session.phase {
        case .waitingForApproval:
            return "\(session.id)|approval|\(session.permissionRequest?.id.uuidString ?? "none")"
        case .waitingForAnswer:
            return "\(session.id)|question|\(session.questionPrompt?.id.uuidString ?? "none")"
        case .completed:
            return "\(session.id)|completed|\(session.updatedAt.timeIntervalSinceReferenceDate)"
        case .running:
            return "\(session.id)|running"
        }
    }

    @ViewBuilder
    private func sessionRowsContent(referenceDate: Date) -> some View {
        ForEach(model.islandSessionSections(at: referenceDate)) { section in
            VStack(alignment: .leading, spacing: 0) {
                if model.islandSessionGroup != .none {
                    sessionSectionHeader(section)
                }

                ForEach(section.sessions) { session in
                    IslandSessionRow(
                        session: session,
                        referenceDate: referenceDate,
                        hardwareSlotBadge: model.agentControlHardwareBadgeLabel(
                            for: session.id,
                            at: referenceDate
                        ),
                        stateIndicator: model.islandSessionStateIndicator,
                        completedStaleThreshold: model.completedStaleThreshold.seconds,
                        isActionable: session.phase.requiresAttention || session.id == actionableSessionID,
                        isHardwareSelected:
                            model.agentControlKeyboardModeActive
                                && session.id
                                    == model.agentControlSelectedSessionID,
                        detailPresentationRequest:
                            agentControlDetailPresentationRequest(
                                for: session.id
                            ),
                        questionDraft: questionInteractionBinding(for: session),
                        useDrawingGroup: model.notchStatus == .opened,
                        isInteractive: model.notchStatus == .opened,
                        sideInset: sessionListSideInset,
                        lang: model.lang,
                        onDetailPresentationChange: {
                            model.setSessionDetailExpanded(
                                $0,
                                for: session.id
                            )
                        },
                        onApprove: { model.approvePermission(for: session.id, action: $0) },
                        onAnswer: {
                            guard let promptID = session.questionPrompt?.id else { return }
                            model.answerQuestion(
                                for: session.id,
                                promptID: promptID,
                                answer: $0
                            )
                        },
                        onReply: TerminalTextSender.canReply(to: session, enabled: model.completionReplyEnabled)
                            ? { model.replyToSession(session, text: $0) } : nil,
                        onJump: { model.jumpToSession(session) },
                        onDismiss: session.isRemote ? { model.dismissSession(session.id) } : nil,
                        onHide: model.isSessionHidden(session)
                            ? nil : { model.hideSession(session) },
                        onUnhide: model.isSessionHidden(session)
                            ? { model.unhideSession(session) } : nil
                    )
                    .id(session.id)
                }
            }
        }

        hiddenSessionsSection(referenceDate: referenceDate)
    }

    private func scrollToActionableSession(
        using proxy: ScrollViewProxy
    ) {
        guard let actionableSessionID else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(actionableSessionID, anchor: .center)
        }
    }

    private func questionInteractionBinding(
        for session: AgentSession
    ) -> Binding<QuestionInteractionDraft>? {
        guard let prompt = session.questionPrompt else { return nil }
        return Binding(
            get: {
                model.questionInteractionDraft(
                    for: session.id,
                    prompt: prompt
                )
            },
            set: {
                model.updateQuestionInteractionDraft(
                    $0,
                    for: session.id,
                    promptID: prompt.id
                )
            }
        )
    }

    @ViewBuilder
    private func hiddenSessionsSection(referenceDate: Date) -> some View {
        let sessions = model.hiddenIslandSessions
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    model.toggleHiddenSessionSection()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 10)
                        Text(lang.t("island.section.hidden").uppercased())
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .tracking(0.4)
                        Text("\(sessions.count)")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(V6Palette.paper.opacity(0.4))
                        Spacer(minLength: 0)
                        Image(systemName: model.isHiddenSessionSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(V6Palette.paper.opacity(0.62))
                    .padding(.leading, sessionListSideInset)
                    .padding(.trailing, sessionListSideInset)
                    .padding(.top, 10)
                    .padding(.bottom, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if model.isHiddenSessionSectionExpanded {
                    ForEach(sessions) { session in
                        IslandSessionRow(
                            session: session,
                            referenceDate: referenceDate,
                            hardwareSlotBadge: model.agentControlHardwareBadgeLabel(
                                for: session.id,
                                at: referenceDate
                            ),
                            stateIndicator: model.islandSessionStateIndicator,
                            completedStaleThreshold: model.completedStaleThreshold.seconds,
                            isHardwareSelected:
                                model.agentControlKeyboardModeActive
                                    && session.id
                                        == model.agentControlSelectedSessionID,
                            detailPresentationRequest:
                                agentControlDetailPresentationRequest(
                                    for: session.id
                                ),
                            useDrawingGroup: model.notchStatus == .opened,
                            isInteractive: model.notchStatus == .opened,
                            sideInset: sessionListSideInset,
                            lang: model.lang,
                            onDetailPresentationChange: {
                                model.setSessionDetailExpanded(
                                    $0,
                                    for: session.id
                                )
                            },
                            onJump: { model.jumpToSession(session) },
                            onUnhide: { model.unhideSession(session) }
                        )
                    }
                }
            }
            .background(Color.white.opacity(0.008))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(0.055))
                    .frame(height: 1)
            }
        }
    }

    private func sessionPanelHeader(referenceDate: Date) -> some View {
        let overview = sessionOverviewItems(referenceDate: referenceDate)

        return HStack(spacing: 8) {
            Text(lang.t("island.sessionList.title").uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(V6Palette.paper.opacity(0.55))

            ViewThatFits(in: .horizontal) {
                sessionOverviewView(overview, compact: false)
                sessionOverviewView(overview, compact: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, sessionListSideInset)
        .padding(.trailing, sessionListSideInset)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    private var sessionPanelFooter: some View {
        Color.clear
            .frame(height: 10)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    private func sessionOverviewItems(referenceDate: Date) -> [SessionOverviewItem] {
        let counts = model.islandSessionOverviewCounts(at: referenceDate)
        guard counts.total > 0 else { return [] }

        return [
            SessionOverviewItem(id: "total", title: lang.t("island.sessionOverview.total"), compactTitle: "", count: counts.total, tint: nil),
            SessionOverviewItem(id: "waiting", title: lang.t("island.sessionOverview.waiting"), compactTitle: lang.t("island.sessionOverview.waitingCompact"), count: counts.waiting, tint: IslandDesignPalette.Status.waitingAggregate),
            SessionOverviewItem(id: "running", title: lang.t("island.sessionOverview.running"), compactTitle: lang.t("island.sessionOverview.runningCompact"), count: counts.running, tint: IslandDesignPalette.Status.running),
            SessionOverviewItem(id: "done", title: lang.t("island.sessionOverview.done"), compactTitle: lang.t("island.sessionOverview.done"), count: counts.done, tint: IslandDesignPalette.Status.completed),
            SessionOverviewItem(id: "idle", title: lang.t("island.sessionOverview.idle"), compactTitle: lang.t("island.sessionOverview.idle"), count: counts.idle, tint: IslandDesignPalette.Status.idle),
        ].filter { $0.id == "total" || $0.count > 0 }
    }

    private func sessionOverviewView(_ items: [SessionOverviewItem], compact: Bool) -> some View {
        HStack(spacing: compact ? 7 : 9) {
            ForEach(items) { item in
                sessionOverviewMetric(item, compact: compact)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sessionOverviewMetric(_ item: SessionOverviewItem, compact: Bool) -> some View {
        HStack(spacing: 4) {
            if let tint = item.tint {
                Circle()
                    .fill(tint)
                    .frame(width: 5.5, height: 5.5)
            }

            Text(sessionOverviewMetricTitle(item, compact: compact))
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(item.tint == nil ? V6Palette.paper.opacity(0.34) : V6Palette.paper.opacity(0.48))
        }
    }

    private func sessionOverviewMetricTitle(_ item: SessionOverviewItem, compact: Bool) -> String {
        if item.id == "total" {
            return compact ? "\(item.count)" : "\(item.count) \(item.title)"
        }

        return "\(item.count) \(compact ? item.compactTitle : item.title)"
    }

    private func sessionSectionHeader(_ section: IslandSessionSection) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(sectionTint(for: section))
                .frame(width: 7, height: 7)
            Text(sessionSectionTitle(for: section).uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(sectionLabelColor(for: section))
            Text("\(section.sessions.count)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(V6Palette.paper.opacity(0.4))
            Spacer(minLength: 0)
        }
        .padding(.leading, sessionListSideInset)
        .padding(.trailing, sessionListSideInset)
        .padding(.top, 10)
        .padding(.bottom, 7)
        .background(Color.white.opacity(0.008))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(height: 1)
        }
    }

    private func sectionTint(for section: IslandSessionSection) -> Color {
        guard let first = section.sessions.first else { return IslandDesignPalette.Status.idle }
        if section.id == "state-idle" { return IslandDesignPalette.Status.idle }
        return IslandDesignPalette.Status.tint(for: first.phase)
    }

    private func sessionSectionTitle(for section: IslandSessionSection) -> String {
        if section.title.hasPrefix("island.") {
            return lang.t(section.title)
        }
        return section.title
    }

    private func sectionLabelColor(for section: IslandSessionSection) -> Color {
        switch section.id {
        case "state-approval":
            return IslandDesignPalette.Status.waitingForApproval.opacity(0.86)
        case "state-answer":
            return IslandDesignPalette.Status.waitingForAnswer.opacity(0.86)
        default:
            return V6Palette.paper.opacity(0.7)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var openedUsageSummary: some View {
        let providers = openedUsageProviders

        if providers.isEmpty == false {
            compactUsageSummaryView(providers)
        } else {
            Color.clear
        }
    }

    private var openedUsageProviders: [UsageProviderPresentation] {
        guard model.islandUsageDisplay == .compact else {
            return []
        }

        var providers: [UsageProviderPresentation] = []

        if model.showCodexUsage,
           let snapshot = model.codexUsageSnapshot,
           snapshot.isEmpty == false {
            let windows = snapshot.windows.map { window in
                UsageWindowPresentation(
                    id: "codex-\(window.key)",
                    label: window.label,
                    usedPercentage: window.usedPercentage,
                    resetsAt: window.resetsAt
                )
            }

            if windows.isEmpty == false {
                providers.append(
                    UsageProviderPresentation(
                        id: "codex",
                        title: "Codex",
                        windows: windows
                    )
                )
            }
        }

        let claudeFiveHour = model.claudeUsageSnapshot?.fiveHour
        if model.claudeUsageInstalled || claudeFiveHour != nil {
            providers.append(.claudeFiveHour(claudeFiveHour))
        }

        return providers
    }

    func splitUsageProviders(
        _ providers: [UsageProviderPresentation]
    ) -> (left: [UsageProviderPresentation], right: [UsageProviderPresentation]) {
        switch providers.count {
        case 0:
            return ([], [])
        case 1:
            return ([providers[0]], [])
        case 2:
            // Pet-based chips are compact enough to remain together in the
            // left auxiliary area. Keeping both here prevents the second
            // provider from disappearing when the right notch lane collapses.
            return (providers, [])
        default:
            let splitIndex = Int(ceil(Double(providers.count) / 2.0))
            return (
                Array(providers.prefix(splitIndex)),
                Array(providers.dropFirst(splitIndex))
            )
        }
    }

    @ViewBuilder
    private func usageLaneView(
        _ providers: [UsageProviderPresentation],
        alignment: Alignment
    ) -> some View {
        if providers.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity)
        } else {
            compactUsageSummaryView(providers)
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private func openedHeaderMetrics(for totalWidth: CGFloat) -> OpenedHeaderMetrics {
        let horizontalPadding = openedHeaderHorizontalPadding
        let contentWidth = max(0, totalWidth - (horizontalPadding * 2))
        guard usesNotchAwareOpenedHeader,
              let screen = targetOverlayScreen else {
            let rightLaneWidth = min(contentWidth, openedHeaderButtonsWidth + (contentWidth / 2))
            let leftUsageWidth = max(0, contentWidth - rightLaneWidth)
            return OpenedHeaderMetrics(
                leftUsageWidth: leftUsageWidth,
                centerGapWidth: 0,
                rightUsageWidth: max(0, rightLaneWidth - openedHeaderButtonsWidth - Self.headerControlSpacing),
                rightLaneWidth: rightLaneWidth
            )
        }

        let panelMinX = screen.frame.midX - (totalWidth / 2)
        let panelMaxX = panelMinX + totalWidth
        let contentMinX = panelMinX + horizontalPadding
        let contentMaxX = panelMaxX - horizontalPadding

        let fallbackNotchHalfWidth = screen.notchSize.width / 2
        let notchLeftEdge = screen.frame.midX - fallbackNotchHalfWidth
        let notchRightEdge = screen.frame.midX + fallbackNotchHalfWidth
        let leftVisibleMaxX = screen.auxiliaryTopLeftArea?.maxX ?? notchLeftEdge
        let rightVisibleMinX = screen.auxiliaryTopRightArea?.minX ?? notchRightEdge

        let rawLeftWidth = max(0, min(contentMaxX, leftVisibleMaxX) - contentMinX)
        let rawRightWidth = max(0, contentMaxX - max(contentMinX, rightVisibleMinX))

        let leftUsageWidth = max(0, rawLeftWidth - Self.notchLaneSafetyInset)
        let rightAvailableWidth = max(0, rawRightWidth - Self.notchLaneSafetyInset)
        let proposedRightUsageWidth = max(
            0,
            rightAvailableWidth - openedHeaderButtonsWidth - Self.headerControlSpacing
        )
        let rightUsageWidth = proposedRightUsageWidth >= Self.minimumRightUsageLaneWidth
            ? proposedRightUsageWidth
            : 0
        let rightLaneWidth = min(
            contentWidth,
            openedHeaderButtonsWidth
                + (rightUsageWidth > 0 ? Self.headerControlSpacing + rightUsageWidth : 0)
        )
        let centerGapWidth = max(0, contentWidth - leftUsageWidth - rightLaneWidth)

        return OpenedHeaderMetrics(
            leftUsageWidth: leftUsageWidth,
            centerGapWidth: centerGapWidth,
            rightUsageWidth: rightUsageWidth,
            rightLaneWidth: rightLaneWidth
        )
    }

    private func compactUsageSummaryView(_ providers: [UsageProviderPresentation]) -> some View {
        HStack(spacing: 7) {
            ForEach(providers) { provider in
                compactUsageChip(provider)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func compactUsageChip(_ provider: UsageProviderPresentation) -> some View {
        HStack(spacing: 5) {
            UsageProviderPetIcon(providerID: provider.id, providerName: provider.title)
                .frame(width: 18, height: 17)

            Text(provider.peakWindowLabel)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))

            Text(provider.peakUsageText)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(
                    provider.peakUsedPercentage.map { usageColor(for: $0) }
                        ?? .white.opacity(0.34)
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.055), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .help(usageHelpText(for: provider))
    }

    private func usageHelpText(for provider: UsageProviderPresentation) -> String {
        provider.windows.map { window in
            guard let roundedUsedPercentage = window.roundedUsedPercentage else {
                return "\(window.label) usage unavailable — run a Claude Code turn to refresh"
            }

            var parts = ["\(window.label) \(roundedUsedPercentage)% used"]
            if let resetsAt = window.resetsAt,
               let remaining = remainingDurationString(until: resetsAt) {
                parts.append(remaining)
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: " · ")
    }

    private func headerPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private func usageColor(for percentage: Double) -> Color {
        switch percentage {
        case 90...:
            .red.opacity(0.95)
        case 70..<90:
            .orange.opacity(0.95)
        default:
            .green.opacity(0.95)
        }
    }

    private func remainingDurationString(until date: Date) -> String? {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else {
            return nil
        }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated

        if interval >= 86_400 {
            formatter.allowedUnits = [.day]
            formatter.maximumUnitCount = 1
        } else if interval >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
            formatter.maximumUnitCount = 2
        } else {
            formatter.allowedUnits = [.minute]
            formatter.maximumUnitCount = 1
        }

        return formatter.string(from: interval)
    }
}

struct UsageProviderPresentation: Identifiable {
    let id: String
    let title: String
    let windows: [UsageWindowPresentation]

    var peakWindow: UsageWindowPresentation? {
        windows
            .filter { $0.usedPercentage != nil }
            .max { lhs, rhs in
                (lhs.usedPercentage ?? 0) < (rhs.usedPercentage ?? 0)
            } ?? windows.first
    }

    var peakWindowLabel: String {
        peakWindow?.label ?? ""
    }

    var peakUsedPercentage: Double? {
        peakWindow?.usedPercentage
    }

    var peakUsageText: String {
        guard let percentage = peakWindow?.roundedUsedPercentage else { return "—" }
        return "\(percentage)%"
    }

    static func claudeFiveHour(_ window: ClaudeUsageWindow?) -> Self {
        Self(
            id: "claude",
            title: "Claude",
            windows: [
                UsageWindowPresentation(
                    id: "claude-5h",
                    label: "5h",
                    usedPercentage: window?.usedPercentage,
                    resetsAt: window?.resetsAt
                )
            ]
        )
    }
}

struct UsageWindowPresentation: Identifiable {
    let id: String
    let label: String
    let usedPercentage: Double?
    let resetsAt: Date?

    var roundedUsedPercentage: Int? {
        usedPercentage.map { Int($0.rounded()) }
    }
}

private struct UsageProviderPetIcon: View {
    let providerID: String
    let providerName: String

    private static let codexImage = PetdexPetLoader.selectedRunningFrames().first
    private static let clawdImage: CGImage? = {
        guard
            let url = Bundle.appResources.url(forResource: "clawd-menubar", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    @ViewBuilder
    var body: some View {
        Group {
            switch providerID {
            case "codex":
                if let image = Self.codexImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .scaleEffect(1.25)
                } else {
                    Text("Cx")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
            case "claude":
                if let image = Self.clawdImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    Text("Cl")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
            default:
                Text(String(providerName.prefix(2)))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
        }
        .foregroundStyle(.white.opacity(0.74))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(providerName)
    }
}

private struct OpenedHeaderMetrics {
    let leftUsageWidth: CGFloat
    let centerGapWidth: CGFloat
    let rightUsageWidth: CGFloat
    let rightLaneWidth: CGFloat
}

private struct SessionOverviewItem: Identifiable {
    let id: String
    let title: String
    let compactTitle: String
    let count: Int
    let tint: Color?
}

// MARK: - Session row (opened state)

private enum IslandSessionRowPresentation {
    case list
    case notification
}

enum IslandSessionEmbeddedDetailPolicy {
    static func shouldShow(
        phase: SessionPhase,
        completionHasExpandedBody: Bool,
        runningDetailAvailable: Bool
    ) -> Bool {
        switch phase {
        case .waitingForApproval, .waitingForAnswer:
            true
        case .completed:
            completionHasExpandedBody
        case .running:
            runningDetailAvailable
        }
    }
}

enum IslandSessionDrawingGroupPolicy {
    static func isEnabled(
        requested: Bool,
        isActionable: Bool,
        showsDetail: Bool
    ) -> Bool {
        requested && !isActionable && !showsDetail
    }
}

private struct IslandSessionRow: View {
    let session: AgentSession
    let referenceDate: Date
    var hardwareSlotBadge: String?
    var stateIndicator: IslandSessionStateIndicator = .animatedDot
    var completedStaleThreshold: TimeInterval = AgentSession.staleCompletedDisplayThreshold
    var isActionable: Bool = false
    var isHardwareSelected: Bool = false
    var detailPresentationRequest: AgentControlDetailPresentationRequest?
    var questionDraft: Binding<QuestionInteractionDraft>?
    var useDrawingGroup: Bool = true
    var isInteractive: Bool = true
    var presentation: IslandSessionRowPresentation = .list
    var sideInset: CGFloat = 16
    var lang: LanguageManager = .shared
    var onDetailPresentationChange: ((Bool) -> Void)?
    var onApprove: ((ApprovalAction) -> Void)?
    var onAnswer: ((QuestionPromptResponse) -> Void)?
    var onReply: ((String) -> Void)?
    let onJump: () -> Void
    var onDismiss: (() -> Void)?
    var onHide: (() -> Void)?
    var onUnhide: (() -> Void)?

    @State private var isHighlighted = false
    @State private var detailOverride: Bool?
    @State private var replyText: String = ""

    var body: some View {
        rowBody(referenceDate: referenceDate)
    }

    private func rowBody(referenceDate: Date) -> some View {
        let rawPresence = session.islandPresence(at: referenceDate)
        let isStaleCompleted = session.isIdleForIsland(
            at: referenceDate,
            completedStaleThreshold: completedStaleThreshold
        )
        let defaultShowsDetail = !isStaleCompleted
            && presentation == .notification
            && session.defaultsToExpandedNotificationDetails(isActionable: isActionable)
        let showsDetail = detailOverride ?? defaultShowsDetail
        let presence = isStaleCompleted
            ? .inactive
            : ((showsDetail && rawPresence == .inactive) ? .active : rawPresence)
        return VStack(alignment: .leading, spacing: 0) {
            rowSummary(presence: presence, showsDetail: showsDetail)

            if showsDetail {
                rowAuxiliaryDetails(presence: presence)

                if shouldShowEmbeddedDetailBody {
                    embeddedDetailBody
                        .padding(.leading, detailLeadingInset)
                        .padding(.trailing, sideInset)
                        .padding(.bottom, 13)
                }
            }
        }
        .background(rowFillColor(for: presence))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.045))
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            if showsLeadingStatusBar {
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(statusTint(for: presence))
                    .frame(width: 3)
                    .padding(.vertical, showsDetail ? 10 : 8)
                    .padding(.leading, 14)
            }
        }
        .overlay {
            if isHardwareSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        .white.opacity(0.72),
                        style: StrokeStyle(
                            lineWidth: 1,
                            lineCap: .round,
                            dash: [4, 3]
                        )
                    )
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isStaleCompleted ? 0.7 : 1)
        .modifier(
            ConditionalDrawingGroup(
                enabled: IslandSessionDrawingGroupPolicy.isEnabled(
                    requested: useDrawingGroup,
                    isActionable: isActionable,
                    showsDetail: showsDetail
                )
            )
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
        .onTapGesture(perform: handlePrimaryTap)
        .onHover { hovering in
            guard isInteractive, allowsRowHoverHighlight else { return }
            isHighlighted = hovering
        }
        .onChange(of: isInteractive) { _, interactive in
            if !interactive {
                detailOverride = nil
            }
        }
        .onAppear {
            applyDetailPresentationRequest(
                detailPresentationRequest,
                animated: false
            )
        }
        .onChange(of: detailPresentationRequest) { _, request in
            applyDetailPresentationRequest(
                request,
                animated: true
            )
        }
        .contextMenu {
            if let onHide {
                Button {
                    onHide()
                } label: {
                    Label(lang.t("island.session.hide"), systemImage: "eye.slash")
                }
            }
            if let onUnhide {
                Button {
                    onUnhide()
                } label: {
                    Label(lang.t("island.session.unhide"), systemImage: "eye")
                }
            }
        }
    }

    private func rowSummary(presence: IslandSessionPresence, showsDetail: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if showsLeadingStatusIndicator {
                statusIndicator(for: presence)
                    .frame(width: 20, alignment: .top)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(summaryHeadlineText)
                    .font(summaryTitleFont)
                    .foregroundStyle(titleColor(for: presence))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if showsDetail,
                   let promptLine = summaryPromptLineText {
                    Text(promptLine)
                        .font(.system(size: 11.2, weight: .medium))
                        .foregroundStyle(summaryPromptColor(for: presence))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                if let hardwareSlotBadge {
                    sideBadge(hardwareSlotBadge)
                }
                agentBadge
                if session.isRemote {
                    sideBadge("SSH")
                }
                if let runtimeSurfaceBadge = session.spotlightRuntimeSurfaceBadge {
                    sideBadge(runtimeSurfaceBadge)
                }
                Text(session.spotlightAgeBadge)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(summaryAgeColor(for: presence))
                    .frame(minWidth: 30, alignment: .trailing)
                detailToggleButton(isOpen: showsDetail)
                if let onDismiss {
                    DismissButton(action: onDismiss)
                }
            }
        }
        .padding(.leading, rowLeadingInset)
        .padding(.trailing, sideInset)
        .padding(.top, 11)
        .padding(.bottom, showsDetail ? 8 : 11)
    }

    @ViewBuilder
    private func rowAuxiliaryDetails(presence: IslandSessionPresence) -> some View {
        if !shouldShowEmbeddedDetailBody,
           let activityLine = session.spotlightActivityLineText ?? expandedActivityLineText {
            Text(activityLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(activityColor(for: presence).opacity(0.94))
                .lineLimit(2)
                .padding(.leading, detailLeadingInset)
                .padding(.trailing, sideInset)
                .padding(.bottom, 10)
        }

        if let subagents = session.claudeMetadata?.activeSubagents,
           !subagents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .medium))
                    Text(lang.t("subagents.title", subagents.count))
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.cyan.opacity(0.8))

                ForEach(subagents, id: \.agentID) { sub in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sub.summary != nil
                                ? IslandDesignPalette.Status.completed
                                : IslandDesignPalette.Status.running)
                            .frame(width: 6, height: 6)
                        Text(sub.agentType ?? sub.agentID)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                        if let desc = sub.taskDescription {
                            Text("(\(desc))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if sub.summary != nil {
                            Text(lang.t("subagents.completed"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        } else if let started = sub.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(subagentElapsed(since: started, at: timeline.date))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                }
            }
            .padding(.leading, detailLeadingInset)
            .padding(.trailing, sideInset)
            .padding(.bottom, 10)
        }

        if let tasks = session.claudeMetadata?.activeTasks,
           !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(taskSummary(tasks))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(tasks) { task in
                    HStack(spacing: 5) {
                        taskStatusIcon(task.status)
                        Text(task.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(task.status == .completed
                                ? .white.opacity(0.4)
                                : .white.opacity(0.7))
                            .strikethrough(task.status == .completed)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, detailLeadingInset)
            .padding(.trailing, sideInset)
            .padding(.bottom, 10)
        }
    }

    private var agentBadge: some View {
        let tint = Color(hex: session.tool.brandColorHex) ?? V6Palette.paper
        return Text(agentBadgeTitle)
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint.opacity(notificationChromeOpacity))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(notificationBadgeFillOpacity), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(notificationBadgeStrokeOpacity), lineWidth: 1))
    }

    private func sideBadge(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(V6Palette.paper.opacity(presentation == .notification ? 0.52 : 0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(presentation == .notification ? 0.045 : 0.06), in: Capsule())
    }

    private var summaryPromptLineText: String? {
        if presentation == .notification {
            if session.phase == .completed {
                return notificationCompletedPromptLineText
            }
            return session.notificationHeaderPromptLineText
        }

        return session.spotlightPromptLineText ?? expandedPromptLineText
    }

    private var summaryHeadlineText: String {
        presentation == .notification
            ? session.notificationHeadlineText
            : session.spotlightHeadlineText
    }

    private var notificationCompletedPromptLineText: String? {
        if let prompt = session.latestUserPromptText?.trimmedForNotificationCard, !prompt.isEmpty {
            return "You: \(prompt)"
        }

        if let prompt = session.initialUserPromptText?.trimmedForNotificationCard, !prompt.isEmpty {
            return "You: \(prompt)"
        }

        return nil
    }

    private var agentBadgeTitle: String {
        switch session.tool {
        case .claudeCode:
            "claude"
        case .geminiCLI:
            "gemini"
        case .qwenCode:
            "qwen"
        case .kimiCLI:
            "kimi"
        default:
            session.tool.shortName.lowercased()
        }
    }

    private var rowLeadingInset: CGFloat {
        if presentation == .notification {
            return sideInset
        }

        return switch stateIndicator {
        case .bar:
            max(28, sideInset)
        case .tint:
            sideInset
        case .animatedDot, .glyph:
            sideInset
        }
    }

    private var detailLeadingInset: CGFloat {
        if presentation == .notification {
            return sideInset
        }

        return switch stateIndicator {
        case .bar:
            max(28, sideInset)
        case .tint:
            sideInset
        case .animatedDot, .glyph:
            sideInset + 30
        }
    }

    private var showsLeadingStatusIndicator: Bool {
        presentation == .list && stateIndicator != .tint && stateIndicator != .bar
    }

    private var showsLeadingStatusBar: Bool {
        presentation == .list && stateIndicator == .bar
    }

    private var summaryTitleFont: Font {
        .system(size: presentation == .notification ? 13.2 : (isActionable ? 13.8 : 13.2), weight: .semibold)
    }

    private func summaryPromptColor(for presence: IslandSessionPresence) -> Color {
        if presentation == .notification {
            return V6Palette.paper.opacity(session.phase == .completed ? 0.38 : 0.46)
        }

        return V6Palette.paper.opacity(presence == .inactive ? 0.34 : 0.52)
    }

    private func summaryAgeColor(for presence: IslandSessionPresence) -> Color {
        if presentation == .notification {
            return V6Palette.paper.opacity(0.36)
        }

        return V6Palette.paper.opacity(presence == .inactive ? 0.32 : 0.45)
    }

    private var notificationChromeOpacity: Double {
        presentation == .notification ? 0.82 : 1
    }

    private var notificationBadgeFillOpacity: Double {
        presentation == .notification ? 0.08 : 0.13
    }

    private var notificationBadgeStrokeOpacity: Double {
        presentation == .notification ? 0.24 : 0.35
    }

    private func titleColor(for presence: IslandSessionPresence) -> Color {
        if stateIndicator == .tint && presence != .inactive {
            if let colorHex = session.spotlightActiveTitleColorHex,
               let providerColor = Color(hex: colorHex) {
                return providerColor
            }
            return statusTint(for: presence)
        }

        if presentation == .notification, session.phase == .completed {
            return .white.opacity(0.78)
        }

        return headlineColor(for: presence)
    }

    private var actionableBorderColor: Color {
        if isActionable {
            return actionableStatusTint.opacity(isHighlighted ? 0.45 : 0.28)
        }
        return isHighlighted ? .white.opacity(0.24) : .white.opacity(0.04)
    }

    private var actionableStatusTint: Color {
        IslandDesignPalette.Status.tint(for: session.phase)
    }

    @ViewBuilder
    private var actionableBody: some View {
        switch session.phase {
        case .waitingForApproval:
            approvalActionBody
        case .waitingForAnswer:
            questionActionBody
        case .completed:
            completionActionBody
        case .running:
            EmptyView()
        }
    }

    private var shouldShowEmbeddedDetailBody: Bool {
        IslandSessionEmbeddedDetailPolicy.shouldShow(
            phase: session.phase,
            completionHasExpandedBody: completionHasExpandedBody,
            runningDetailAvailable: runningDetailText != nil
        )
    }

    private var completionHasExpandedBody: Bool {
        !completionMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || onReply != nil
    }

    @ViewBuilder
    private var embeddedDetailBody: some View {
        switch session.phase {
        case .waitingForApproval, .waitingForAnswer, .completed:
            actionableBody
        case .running:
            runningDetailBody
        }
    }

    private var runningDetailBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let runningDetailText {
                Text(runningDetailText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(0.06))
                    )
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Approval action area

    private var approvalActionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lang.t("approval.toolPermissionRequested"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(V6Palette.paper.opacity(0.86))

            AutoHeightScrollView(maxHeight: 220) {
                Text(verbatim: permissionMessageText)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(V6Palette.paper.opacity(0.78))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )

            HStack(spacing: 8) {
                Button(session.permissionRequest?.secondaryActionTitle ?? lang.t("approval.deny")) { onApprove?(.deny) }
                    .buttonStyle(IslandActionButtonStyle(kind: .secondary, expands: true))
                Button(session.permissionRequest?.primaryActionTitle ?? lang.t("approval.allowOnce")) { onApprove?(.allowOnce) }
                    .buttonStyle(IslandActionButtonStyle(kind: .success, expands: true))
                if session.supportsPersistentPermissionApproval,
                   let toolName = session.permissionRequest?.toolName {
                    Button(lang.t("approval.alwaysAllow", toolName)) {
                        let rule = ClaudePermissionRuleValue(toolName: toolName)
                        let update = ClaudePermissionUpdate.addRules(
                            destination: .session,
                            rules: [rule],
                            behavior: .allow
                        )
                        onApprove?(.allowWithUpdates([update]))
                    }
                    .buttonStyle(IslandActionButtonStyle(
                        kind: .primary,
                        expands: true,
                        labelLineLimit: nil
                    ))
                }
            }
        }
    }

    // MARK: - Question action area

    private var questionActionBody: some View {
        StructuredQuestionPromptView(
            prompt: session.questionPrompt,
            sharedDraft: questionDraft,
            lang: lang,
            onAnswer: { onAnswer?($0) }
        )
    }

    // MARK: - Completion action area

    private var completionActionBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !completionMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AutoHeightScrollView(maxHeight: 160) {
                    CompletionMessageView(text: completionMessageText)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
            } else {
                completionEmptyState
            }

            if onReply != nil {
                Rectangle()
                    .fill(.white.opacity(completionDividerOpacity))
                    .frame(height: 1)

                completionReplyInput
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(completionCardFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(completionCardStrokeOpacity))
        )
    }

    private var completionDoneOpacity: Double {
        presentation == .notification ? 0.82 : 0.96
    }

    private var completionDividerOpacity: Double {
        presentation == .notification ? 0.035 : 0.04
    }

    private var completionCardFillOpacity: Double {
        presentation == .notification ? 0.035 : 0.045
    }

    private var completionCardStrokeOpacity: Double {
        presentation == .notification ? 0.06 : 0.08
    }

    private var completionEmptyState: some View {
        HStack {
            Text(lang.t("completion.done"))
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(IslandDesignPalette.Status.completed.opacity(completionDoneOpacity))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var completionReplyInput: some View {
        HStack(spacing: 8) {
            ReplyTextField(
                placeholder: lang.t("completion.replyPlaceholder", session.completionReplyRecipientName),
                text: $replyText,
                onSubmit: { submitReply() }
            )
            .frame(height: 32)

            Button {
                submitReply()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(replyText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func submitReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        onReply?(text)
    }

    // MARK: - Actionable helpers

    private var completionMessageText: String {
        if let source = session.completionAssistantMessageText {
            let text = CompletionMessageSanitizer.textForDisplay(source).trimmedForNotificationCard
            if !text.isEmpty {
                return text
            }
        }
        let summary = CompletionMessageSanitizer.textForDisplay(
            session.summary
        ).trimmedForNotificationCard
        if summary == SessionPhase.completed.displayName {
            return ""
        }
        return summary
    }

    private var commandLabel: String {
        switch session.currentToolName {
        case "exec_command", "Bash": return "Bash"
        case "AskUserQuestion": return "Question"
        case "ExitPlanMode": return "Plan"
        case "apply_patch": return "Patch"
        case "write_stdin": return "Input"
        case let value?: return AgentSession.currentToolDisplayName(for: value)
        case nil: return "Command"
        }
    }

    private var permissionMessageText: String {
        if let detail = session.permissionRequest?.detail?.trimmedForNotificationCard,
           !detail.isEmpty {
            return detail
        }

        if let affectedPath = session.permissionRequest?.affectedPath.trimmedForNotificationCard,
           !affectedPath.isEmpty {
            return affectedPath
        }

        let preview = session.currentCommandPreviewText?.trimmedForNotificationCard
        if let preview, !preview.isEmpty {
            return preview
        }
        return session.permissionRequest?.summary.trimmedForNotificationCard ?? session.summary.trimmedForNotificationCard
    }

    private var runningDetailText: String? {
        if let preview = session.currentCommandPreviewText?.trimmedForNotificationCard,
           !preview.isEmpty {
            return "$ \(preview)"
        }

        if let activity = session.spotlightActivityLineText?.trimmedForNotificationCard,
           !activity.isEmpty {
            return activity
        }

        let summary = session.summary.trimmedForNotificationCard
        return summary.isEmpty ? nil : summary
    }

    private func subagentElapsed(since start: Date, at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        return "\(minutes)m \(secs)s"
    }

    private func taskSummary(_ tasks: [ClaudeTaskInfo]) -> String {
        let done = tasks.filter { $0.status == .completed }.count
        let prog = tasks.filter { $0.status == .inProgress }.count
        let pend = tasks.filter { $0.status == .pending }.count
        return lang.t("tasks.summary", done, prog, pend)
    }

    @ViewBuilder
    private func taskStatusIcon(_ status: ClaudeTaskInfo.Status) -> some View {
        switch status {
        case .completed:
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        case .inProgress:
            Circle()
                .fill(IslandDesignPalette.Status.running)
                .frame(width: 6, height: 6)
        case .pending:
            Circle()
                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private func statusIndicator(for presence: IslandSessionPresence) -> some View {
        let tint = statusTint(for: presence)
        switch stateIndicator {
        case .animatedDot:
            if let interval = stateIndicator.timelineInterval(presence: presence, isActionable: isActionable) {
                TimelineView(.periodic(from: .now, by: interval)) { context in
                    let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
                    statusDot(tint: tint, presence: presence, pulse: pulse)
                }
                .frame(width: 10, height: 24, alignment: .top)
            } else {
                statusDot(tint: tint, presence: presence, pulse: 0)
                    .frame(width: 10, height: 24, alignment: .top)
            }
        case .bar:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(tint)
                .frame(width: 4, height: isActionable ? 34 : 28)
                .padding(.top, 2)
        case .glyph:
            Image(systemName: statusGlyphName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 20)
                .padding(.top, 1)
        case .tint:
            Circle()
                .fill(tint.opacity(presence == .inactive ? 0.54 : 0.92))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
        }
    }

    private func statusDot(tint: Color, presence: IslandSessionPresence, pulse: Double) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
            .scaleEffect(1 + (pulse * 0.18))
            .shadow(color: tint.opacity(presence == .inactive ? 0 : 0.36 + (pulse * 0.26)), radius: 4 + (pulse * 3))
            .padding(.top, 6)
    }

    private func rowFillColor(for presence: IslandSessionPresence) -> Color {
        if presentation == .notification {
            return Color.clear
        }

        let base = isHighlighted ? Color.white.opacity(isActionable ? 0.06 : 0.04) : Color.clear
        guard stateIndicator == .tint else { return base }

        let tintOpacity: Double
        if isHighlighted {
            tintOpacity = isActionable ? 0.16 : 0.11
        } else {
            tintOpacity = presence == .inactive ? 0.035 : 0.075
        }
        return statusTint(for: presence).opacity(tintOpacity)
    }

    private var statusGlyphName: String {
        switch session.phase {
        case .waitingForApproval:
            "exclamationmark.triangle.fill"
        case .waitingForAnswer:
            "questionmark.circle.fill"
        case .running:
            "circle.dashed"
        case .completed:
            "checkmark.circle.fill"
        }
    }

    private var allowsRowHoverHighlight: Bool {
        presentation != .notification
    }

    /// Prompt line for manually expanded inactive rows (bypasses time-based filter).
    private var expandedPromptLineText: String? {
        guard detailOverride == true, let prompt = session.spotlightPromptText else { return nil }
        return "You: \(prompt)"
    }

    /// Activity line for manually expanded inactive rows (bypasses time-based filter).
    private var expandedActivityLineText: String? {
        guard detailOverride == true else { return nil }
        let trimmed = session.lastAssistantMessageText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let assistantMessage = trimmed, !assistantMessage.isEmpty {
            return assistantMessage
        }
        return session.jumpTarget != nil ? "Ready" : "Completed"
    }

    private func handlePrimaryTap() {
        guard isInteractive else { return }
        onJump()
    }

    private func applyDetailPresentationRequest(
        _ request: AgentControlDetailPresentationRequest?,
        animated: Bool
    ) {
        guard let request else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                detailOverride = request.isExpanded
            }
        } else {
            detailOverride = request.isExpanded
        }
    }

    private func detailToggleButton(isOpen: Bool) -> some View {
        Button {
            guard isInteractive else { return }
            let isExpanded = !isOpen
            if let onDetailPresentationChange {
                onDetailPresentationChange(isExpanded)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    detailOverride = isExpanded
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOpen || isHighlighted ? .white.opacity(0.68) : .white.opacity(0.42))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.white.opacity(detailToggleFillOpacity(isOpen: isOpen)))
                )
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Collapse session detail" : "Expand session detail")
    }

    private func detailToggleFillOpacity(isOpen: Bool) -> Double {
        if isHighlighted {
            return isOpen ? 0.075 : 0.055
        }

        return isOpen ? 0.045 : 0.02
    }

    private func compactBadge(
        _ title: String,
        presence: IslandSessionPresence,
        icon: String? = nil
    ) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 7.5, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(badgeTextColor(for: presence))
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Color(red: 0.14, green: 0.14, blue: 0.15), in: Capsule())
    }

    private func headlineColor(for presence: IslandSessionPresence) -> Color {
        presence == .inactive ? .white.opacity(0.78) : .white
    }

    private func badgeTextColor(for presence: IslandSessionPresence) -> Color {
        presence == .inactive ? .white.opacity(0.42) : .white.opacity(0.56)
    }

    private func statusTint(for presence: IslandSessionPresence) -> Color {
        IslandDesignPalette.Status.tint(for: session.phase, presence: presence)
    }

    private func activityColor(for presence: IslandSessionPresence) -> Color {
        switch session.spotlightActivityTone {
        case .attention:
            IslandDesignPalette.Status.tint(for: session.phase)
        case .live:
            statusTint(for: presence)
        case .idle:
            .white.opacity(0.46)
        case .ready:
            presence == .inactive ? .white.opacity(0.46) : statusTint(for: presence)
        }
    }
}

private struct StructuredQuestionPromptView: View {
    let prompt: QuestionPrompt?
    var sharedDraft: Binding<QuestionInteractionDraft>?
    var lang: LanguageManager = .shared
    let onAnswer: (QuestionPromptResponse) -> Void

    @State private var localDraft: QuestionInteractionDraft
    @State private var hoveredOptionKey: String?

    init(
        prompt: QuestionPrompt?,
        sharedDraft: Binding<QuestionInteractionDraft>? = nil,
        lang: LanguageManager = .shared,
        onAnswer: @escaping (QuestionPromptResponse) -> Void
    ) {
        self.prompt = prompt
        self.sharedDraft = sharedDraft
        self.lang = lang
        self.onAnswer = onAnswer
        _localDraft = State(
            initialValue: QuestionInteractionDraft(
                promptID: prompt?.id ?? UUID()
            )
        )
    }

    private var draft: Binding<QuestionInteractionDraft> {
        sharedDraft ?? $localDraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsPromptTitle {
                Text(promptTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandDesignPalette.Status.waitingForAnswer)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if structuredQuestions.isEmpty {
                freeformAnswerBody
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(
                        Array(structuredQuestions.enumerated()),
                        id: \.offset
                    ) { questionIndex, question in
                        questionRow(question, questionIndex: questionIndex)
                    }
                }

                quickReplyField

                Button(submitButtonTitle) {
                    submitAnswer()
                }
                .buttonStyle(IslandActionButtonStyle(kind: canSubmit ? .primary : .secondary, expands: true))
                .disabled(!canSubmit)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.05))
        )
    }

    // MARK: - Per-question row

    /// Renders a single question with its header, text, and vertical option list.
    @ViewBuilder
    private func questionRow(
        _ question: QuestionPromptItem,
        questionIndex: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if structuredQuestions.count > 1 {
                Text(question.header)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Text(question.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    optionRow(
                        option,
                        optionIndex: index,
                        question: question,
                        questionIndex: questionIndex
                    )
                }
            }
        }
    }

    // MARK: - Option row (vertical, CLI-style)

    @ViewBuilder
    private func optionRow(
        _ option: QuestionOption,
        optionIndex: Int,
        question: QuestionPromptItem,
        questionIndex: Int
    ) -> some View {
        let isSelected = draft.wrappedValue
            .selections[questionIndex, default: []]
            .contains(option.id)
        let key = optionKey(for: question, option: option)
        let isHovered = hoveredOptionKey == key
        let isKeyboardFocused =
            draft.wrappedValue.focusedQuestionIndex == questionIndex
            && draft.wrappedValue.focusedOptionIndex == optionIndex
        let showsFreeform = option.allowsFreeform && isSelected
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(
                    option: option,
                    optionIndex: optionIndex,
                    question: question,
                    questionIndex: questionIndex
                )
            } label: {
                HStack(spacing: 10) {
                    Text("\(optionIndex + 1)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? .black.opacity(0.82) : V6Palette.paper.opacity(0.42))
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? V6Palette.paper.opacity(0.88) : Color.white.opacity(0.045))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(.white.opacity(isSelected ? 0 : 0.08))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 12.2, weight: .medium))
                            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.78))

                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(isHovered || isSelected ? 0.48 : 0.38))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(IslandDesignPalette.Status.completed)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
                .padding(.horizontal, 11)
            }
            .buttonStyle(.plain)

            if showsFreeform {
                Divider()
                    .overlay(Color.white.opacity(0.08))
                freeformField(
                    for: option,
                    question: question,
                    questionIndex: questionIndex
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(optionFillColor(isSelected: isSelected, isHovered: isHovered))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isKeyboardFocused
                        ? IslandDesignPalette.Status.waitingForAnswer
                        : optionStrokeColor(
                            isSelected: isSelected,
                            isHovered: isHovered
                        ),
                    lineWidth: isKeyboardFocused ? 2 : 1
                )
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredOptionKey = hovering ? key : (hoveredOptionKey == key ? nil : hoveredOptionKey)
            }
        }
    }

    @ViewBuilder
    private func freeformField(
        for option: QuestionOption,
        question: QuestionPromptItem,
        questionIndex: Int
    ) -> some View {
        ReplyTextField(
            placeholder: lang.t("question.otherPlaceholder"),
            text: Binding(
                get: { draft.wrappedValue.freeformTexts[option.id] ?? "" },
                set: {
                    var value = draft.wrappedValue
                    value.freeformTexts[option.id] = $0
                    draft.wrappedValue = value
                }
            ),
            shouldFocus:
                draft.wrappedValue.focusedFreeformOptionID == option.id,
            onSubmit: {
                if let response = resolvedResponse {
                    onAnswer(response)
                }
            }
        )
        .frame(height: 22)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private var freeformAnswerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            quickReplyField

            Button(lang.t("question.submit")) {
                submitAnswer()
            }
            .buttonStyle(IslandActionButtonStyle(kind: canSubmit ? .primary : .secondary, expands: true))
            .disabled(!canSubmit)
        }
    }

    @ViewBuilder
    private var quickReplyField: some View {
        if showsGlobalReplyField {
            HStack(spacing: 6) {
                ReplyTextField(
                    placeholder: lang.t("question.otherPlaceholder"),
                    text: Binding(
                        get: { draft.wrappedValue.typedReply },
                        set: {
                            var value = draft.wrappedValue
                            value.typedReply = $0
                            draft.wrappedValue = value
                        }
                    ),
                    shouldFocus: draft.wrappedValue.focusesOpenEndedText,
                    onSubmit: {
                        if canSubmit {
                            submitAnswer()
                        }
                    }
                )
                .frame(height: 30)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.055))
            )
        }
    }

    // MARK: - Helpers

    private var structuredQuestions: [QuestionPromptItem] {
        if let questions = prompt?.questions, !questions.isEmpty {
            return questions
        }

        guard let prompt, !prompt.options.isEmpty else {
            return []
        }

        let identityDraft = QuestionInteractionDraft(promptID: prompt.id)
        return [
            QuestionPromptItem(
                question: prompt.title,
                header: lang.t("question.answerNeeded"),
                options: prompt.options.enumerated().map { index, label in
                    QuestionOption(
                        id: identityDraft.legacyOptionID(
                            promptID: prompt.id,
                            index: index
                        ),
                        label: label
                    )
                }
            ),
        ]
    }

    private var promptTitle: String {
        prompt?.title.trimmedForNotificationCard ?? lang.t("question.answerNeeded")
    }

    private var showsPromptTitle: Bool {
        guard !promptTitle.isEmpty else {
            return false
        }

        guard structuredQuestions.count == 1,
              let questionTitle = structuredQuestions.first?.question.trimmedForNotificationCard else {
            return true
        }

        return questionTitle.caseInsensitiveCompare(promptTitle) != .orderedSame
    }

    private var trimmedReply: String {
        draft.wrappedValue.typedReply
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsGlobalReplyField: Bool {
        structuredQuestions.isEmpty || !structuredQuestions.contains { question in
            question.options.contains { $0.allowsFreeform }
        }
    }

    private var primarySelectedAnswer: String? {
        resolvedResponse?.rawAnswer
    }

    private var canSubmit: Bool {
        resolvedResponse != nil
    }

    private var submitButtonTitle: String {
        if !trimmedReply.isEmpty {
            return lang.t("question.sendReply")
        }

        if let primarySelectedAnswer, !primarySelectedAnswer.isEmpty {
            return lang.t("question.sendAnswer")
        }

        return lang.t("question.submit")
    }

    private func submitAnswer() {
        guard let response = resolvedResponse else { return }
        onAnswer(response)
    }

    private var resolvedResponse: QuestionPromptResponse? {
        guard let prompt else { return nil }
        return draft.wrappedValue.response(for: prompt)
    }

    private func optionKey(for question: QuestionPromptItem, option: QuestionOption) -> String {
        "\(question.question)|\(option.label)"
    }

    private func optionFillColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return V6Palette.paper.opacity(0.10)
        }
        if isHovered {
            return Color.white.opacity(0.065)
        }
        return Color.white.opacity(0.028)
    }

    private func optionStrokeColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return V6Palette.paper.opacity(0.36)
        }
        if isHovered {
            return .white.opacity(0.13)
        }
        return .white.opacity(0.045)
    }

    private func toggle(
        option: QuestionOption,
        optionIndex: Int,
        question: QuestionPromptItem,
        questionIndex: Int
    ) {
        var value = draft.wrappedValue
        var selected = value.selections[questionIndex, default: []]
        if question.multiSelect {
            if selected.contains(option.id) {
                selected.remove(option.id)
            } else {
                selected.insert(option.id)
            }
        } else {
            selected = [option.id]
        }

        value.focusedQuestionIndex = questionIndex
        value.focusedOptionIndex = optionIndex
        value.focusedFreeformOptionID =
            option.allowsFreeform && selected.contains(option.id)
                ? option.id
                : nil
        value.focusesOpenEndedText = false
        value.typedReply = ""
        value.selections[questionIndex] = selected
        draft.wrappedValue = value
    }
}

// MARK: - Reply TextField (NSTextField wrapper for IME-safe Enter handling)

/// NSTextField wrapper that fires `onSubmit` only when the IME composition
/// is finished — pressing Enter during Chinese/Japanese IME composition
/// confirms the candidate instead of submitting.
private struct ReplyTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var shouldFocus = false
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.35),
                .font: NSFont.systemFont(ofSize: 13),
            ]
        )
        field.delegate = context.coordinator
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit
        if shouldFocus, nsView.window?.firstResponder !== nsView.currentEditor() {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Let AppKit handle Enter during IME composition (e.g. confirming
                // a Chinese/Japanese candidate). Only submit when no marked text.
                guard !textView.hasMarkedText() else { return false }
                onSubmit()
                return true
            }
            return false
        }
    }
}

private extension String {
    var trimmedForNotificationCard: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Compact button style

private struct IslandCompactButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint == .secondary ? .white.opacity(0.7) : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (tint == .secondary ? Color.white.opacity(0.08) : tint.opacity(0.15)),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct IslandActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case success
    }

    let kind: Kind
    var expands = false
    var labelLineLimit: Int? = 1

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.8, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .lineLimit(labelLineLimit)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: labelLineLimit != 1)
            .frame(minHeight: labelLineLimit == 1 ? nil : 30)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(backgroundColor(configuration.isPressed), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foregroundColor: Color {
        guard isEnabled else {
            return V6Palette.paper.opacity(0.42)
        }

        switch kind {
        case .primary:
            return .black.opacity(0.88)
        case .success:
            return .black.opacity(0.82)
        case .secondary:
            return V6Palette.paper.opacity(0.78)
        }
    }

    private var strokeColor: Color {
        guard isEnabled else {
            return .white.opacity(0.07)
        }

        switch kind {
        case .primary:
            return V6Palette.paper.opacity(0.86)
        case .success:
            return Color(red: 0.66, green: 0.91, blue: 0.70).opacity(0.7)
        case .secondary:
            return .white.opacity(0.07)
        }
    }

    private func backgroundColor(_ isPressed: Bool) -> Color {
        guard isEnabled else {
            return Color.white.opacity(0.055)
        }

        let pressedFactor: Double = isPressed ? 0.78 : 1
        switch kind {
        case .primary:
            return V6Palette.paper.opacity(pressedFactor)
        case .success:
            return Color(red: 0.66, green: 0.91, blue: 0.70).opacity(pressedFactor)
        case .secondary:
            return Color.white.opacity(isPressed ? 0.11 : 0.065)
        }
    }
}

// MARK: - Menu bar content (unchanged)

// MARK: - MarkdownUI Theme

extension MarkdownUI.Theme {
    @MainActor static let completionCard = Theme()
        .text {
            ForegroundColor(.white.opacity(0.88))
            FontSize(13.5)
            FontWeight(.medium)
        }
        .link {
            ForegroundColor(.blue)
        }
        .strong {
            FontWeight(.bold)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(12.5)
            ForegroundColor(.white.opacity(0.88))
            BackgroundColor(.white.opacity(0.08))
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(12.5)
                    ForegroundColor(.white.opacity(0.88))
                }
                .padding(10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(16)
                    FontWeight(.bold)
                    ForegroundColor(.white.opacity(0.88))
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(15)
                    FontWeight(.bold)
                    ForegroundColor(.white.opacity(0.88))
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(14)
                    FontWeight(.semibold)
                    ForegroundColor(.white.opacity(0.88))
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .blockquote { configuration in
            configuration.label
                .markdownTextStyle {
                    ForegroundColor(.white.opacity(0.6))
                    FontSize(13.5)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 3)
                }
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.allBorders, color: .white.opacity(0.15), strokeStyle: .init(lineWidth: 1)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(Color.white.opacity(0.04), Color.white.opacity(0.08))
                )
                .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .relativeLineSpacing(.em(0.25))
        }
}

private struct DismissButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(isHovered ? 0.8 : 0.4))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
