import AppKit
import SwiftUI
import AgentIslandCore

/// Per-cell state for the closed-island agents grid. Drives tile rendering:
/// running = full color, idle = dim, waiting = opacity pulse.
enum AgentGridCellState: Equatable {
    case running
    case idle
    case waiting
}

/// One cell in the closed-island agents grid. `.session` carries the agent
/// tool's brand color and its current state. `.overflow` is a single trailing
/// cell shown when there are more sessions than the grid can display.
enum AgentGridCell: Equatable {
    case session(color: Color, state: AgentGridCellState)
    case overflow(Int)
}

/// Concrete payload for the closed island's right slot. The `AppModel`
/// computes one of these from live session state according to the user's
/// `islandRightSlot` preference; the view side is agnostic to which
/// setting produced it.
enum IslandRightSlotContent: Equatable {
    case count(Int)              // "×N" badge
    case agents([AgentGridCell]) // balanced grid, one tile per session
}

/// One mascot per actively running provider in the closed island's leading
/// slot. This is intentionally provider-level rather than session-level so
/// parallel tasks do not multiply the number of pets.
enum IslandLeadingPet: String, Equatable, Hashable {
    case codex
    case claude
}

// MARK: - Leading activity renderer

/// Replaces the waveform while Codex or Claude is actively running.
struct V6LeadingActivityView: View {
    let mode: UnifiedBars.Mode
    let pets: [IslandLeadingPet]

    static let clawdFrameDuration: TimeInterval = 0.14
    static let codexFrameDuration = clawdFrameDuration / 0.75
    static let clawdHopOffsets: [CGFloat] = [1.75, 0.75, -0.75, -1.75, -0.75, 0.75]

    static func intrinsicWidth(for pets: [IslandLeadingPet]) -> CGFloat {
        pets.count > 1 ? 52 : 24
    }

    static func macbookLeadingExtension(for pets: [IslandLeadingPet]) -> CGFloat {
        max(0, intrinsicWidth(for: pets) - 24)
    }

    @ViewBuilder
    var body: some View {
        if pets.isEmpty {
            UnifiedBars(mode: mode, size: 24)
                .frame(width: 24, height: 24)
        } else {
            HStack(spacing: pets.count > 1 ? 4 : 0) {
                ForEach(pets, id: \.self) { pet in
                    MiniSessionPet(pet: pet)
                        .frame(width: pets.count > 1 ? 24 : 20, height: 20)
                }
            }
            .frame(width: Self.intrinsicWidth(for: pets), height: 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var accessibilityLabel: String {
        switch pets {
        case [.codex]:
            return "Codex session running"
        case [.claude]:
            return "Clawd — Claude Code session running"
        default:
            return "Codex and Clawd — Claude Code sessions running"
        }
    }
}

private struct MiniSessionPet: View {
    let pet: IslandLeadingPet

    private static let installedCodexFrames = PetdexPetLoader.selectedRunningFrames()
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
        let frameDuration = pet == .codex
            ? V6LeadingActivityView.codexFrameDuration
            : V6LeadingActivityView.clawdFrameDuration

        TimelineView(.periodic(from: .now, by: frameDuration)) { context in
            let frame = Int(context.date.timeIntervalSinceReferenceDate / frameDuration)
            petFrame(frame: frame)
        }
    }

    @ViewBuilder
    private func petFrame(frame: Int) -> some View {
        switch pet {
        case .codex:
            if !Self.installedCodexFrames.isEmpty {
                let image = Self.installedCodexFrames[frame % Self.installedCodexFrames.count]
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .scaleEffect(1.4)
            } else {
                Canvas(rendersAsynchronously: false) { context, size in
                    drawCodexPet(in: context, size: size, frame: frame)
                }
            }
        case .claude:
            if let image = Self.clawdImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .offset(y: clawdHopOffset(frame: frame))
            }
        }
    }

    private func clawdHopOffset(frame: Int) -> CGFloat {
        let offsets = V6LeadingActivityView.clawdHopOffsets
        return offsets[frame % offsets.count]
    }

    private func drawCodexPet(in context: GraphicsContext, size: CGSize, frame: Int) {
        let scale = min(size.width / 20, size.height / 20)
        let x = (size.width - 20 * scale) / 2
        let animationFrame = frame % 2
        let bounce = CGFloat(animationFrame == 0 ? 1 : 0) * scale
        let mint = Color(red: 0.34, green: 0.91, blue: 0.67)
        let paper = V6Palette.paper
        let ink = V6Palette.ink

        func rect(_ px: CGFloat, _ py: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat = 0) -> Path {
            Path(roundedRect: CGRect(
                x: x + px * scale,
                y: py * scale - bounce,
                width: width * scale,
                height: height * scale
            ), cornerRadius: radius * scale)
        }

        // A tiny original Codex companion: antenna, ears, body, and terminal
        // cursor chest mark. Its two-frame hop reads clearly at notch scale.
        context.fill(rect(9, 1, 2, 3, radius: 1), with: .color(mint))
        context.fill(rect(4, 4, 12, 11, radius: 4), with: .color(paper))
        context.fill(rect(2.5, 5, 4, 5, radius: 2), with: .color(mint))
        context.fill(rect(13.5, 5, 4, 5, radius: 2), with: .color(mint))
        context.fill(rect(6, 8, 2, 2, radius: 1), with: .color(ink))
        context.fill(rect(12, 8, 2, 2, radius: 1), with: .color(ink))
        context.fill(rect(8, 12, 4, 1.5, radius: 0.75), with: .color(mint))
        context.fill(rect(animationFrame == 0 ? 4 : 5, 15, 4, 2, radius: 1), with: .color(paper))
        context.fill(rect(animationFrame == 0 ? 12 : 11, 15, 4, 2, radius: 1), with: .color(paper))
    }

}

// MARK: - Right-slot renderers

struct V6RightSlotView: View {
    let content: IslandRightSlotContent

    var body: some View {
        switch content {
        case .count(let n):
            Text("×\(n)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(V6Palette.paper.opacity(0.72))
        case .agents(let cells):
            AgentsGridBody(cells: cells)
        }
    }

    /// Intrinsic width used by the fluid-layout math. Values are slightly
    /// padded beyond the raw text measurement so the pill always reserves
    /// enough room for the `.fixedSize()` content to render on one line,
    /// without HStack compression forcing a wrap.
    static func intrinsicWidth(of content: IslandRightSlotContent) -> CGFloat {
        switch content {
        case .count(let n):
            let digits = Double(max(1, String(n).count))
            // "×" + digits at 11pt mono ≈ 7.2pt/char.
            return CGFloat(14.4 + max(0.0, digits - 1.0) * 7.2)
        case .agents(let cells):
            let n = cells.count
            guard n > 0 else { return 0 }
            let rows = balancedRows(n)
            let maxRow = rows.max() ?? 0
            let geom = cellGeometry(rowCount: rows.count)
            return CGFloat(maxRow) * geom.cell + CGFloat(max(0, maxRow - 1)) * geom.gap
        }
    }

    // MARK: Balanced layout algorithm
    //
    // For each n from 1 to 9, we hand-tune the per-row cell counts so the
    // matrix reads as a deliberate shape instead of a wrap-at-4-columns grid.
    // For n >= 10 the AppModel caps the list at 7 sessions + 1 overflow cell,
    // which lays out as [4,4] — so balancedRows(8) is what actually renders
    // for all high-count cases in production.
    static func balancedRows(_ n: Int) -> [Int] {
        switch n {
        case ..<1: return []
        case 1: return [1]
        case 2: return [2]
        case 3: return [3]
        case 4: return [2, 2]
        case 5: return [3, 2]
        case 6: return [3, 3]
        case 7: return [4, 3]
        case 8: return [4, 4]
        case 9: return [3, 3, 3]
        default: return [4, 4]
        }
    }

    /// Cell size shrinks when the matrix has 3 rows so total height still
    /// fits inside the pill's internal vertical budget (~20pt).
    static func cellGeometry(rowCount: Int) -> (cell: CGFloat, gap: CGFloat, radius: CGFloat) {
        if rowCount >= 3 { return (cell: 6, gap: 1.5, radius: 1.0) }
        return (cell: 8, gap: 2, radius: 1.5)
    }

    static func splitIntoRows(_ cells: [AgentGridCell], rowSizes: [Int]) -> [[AgentGridCell]] {
        var out: [[AgentGridCell]] = []
        var idx = 0
        for size in rowSizes {
            let end = min(idx + size, cells.count)
            out.append(Array(cells[idx..<end]))
            idx = end
            if idx >= cells.count { break }
        }
        return out
    }
}

// MARK: - Agents grid body

/// V1a Dense Grid renderer. 2D matrix of 8×8 rounded squares (6×6 when 3 rows),
/// each row horizontally centered around the widest row. Running = full color,
/// idle = 22% alpha, waiting = opacity 0.35 ↔ 1 breathing pulse.
private struct AgentsGridBody: View {
    let cells: [AgentGridCell]

    var body: some View {
        let rowSizes = V6RightSlotView.balancedRows(cells.count)
        let geom = V6RightSlotView.cellGeometry(rowCount: rowSizes.count)
        let rows = V6RightSlotView.splitIntoRows(cells, rowSizes: rowSizes)

        VStack(spacing: geom.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: geom.gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        AgentsGridTileView(cell: cell, size: geom.cell, radius: geom.radius)
                    }
                }
            }
        }
        .fixedSize()
    }
}

private struct AgentsGridTileView: View {
    let cell: AgentGridCell
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        switch cell {
        case .session(let color, let state):
            switch state {
            case .running:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color)
                    .frame(width: size, height: size)
            case .idle:
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(color.opacity(0.22))
                    .frame(width: size, height: size)
            case .waiting:
                AgentsGridWaitingTile(color: color, size: size, radius: radius)
            }
        case .overflow(let n):
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(V6Palette.paper.opacity(0.14))
                Text("+\(n)")
                    .font(.system(size: max(5, size * 0.55), weight: .bold, design: .monospaced))
                    .foregroundStyle(V6Palette.paper)
            }
            .frame(width: size, height: size)
        }
    }
}

private struct AgentsGridWaitingTile: View {
    let color: Color
    let size: CGFloat
    let radius: CGFloat
    @State private var pulse = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? 1.0 : 0.35)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Center label renderer

struct V6CenterLabelView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(V6Palette.paper)
    }

    static func intrinsicWidth(of text: String) -> CGFloat {
        CGFloat(Double(text.count) * 7.3 + 10)
    }
}

// MARK: - Closed-pill layouts

/// The canonical v6 closed-island pill rendered inside a fixed-height frame.
/// Pure view — takes all parameters explicitly so it can be reused for the
/// live settings preview and the real island.
struct V6ClosedPill: View {
    var mode: UnifiedBars.Mode
    var label: String?          // suppressed automatically in MacBook layout
    var rightSlot: IslandRightSlotContent?
    var layout: V6ClosedLayout
    var activePets: [IslandLeadingPet] = []
    var height: CGFloat = 32

    /// MacBook mode only — width of the physical notch cutout to wrap.
    var physicalNotchWidth: CGFloat = 0

    /// External mode only — minimum pill width (locked). Defaults to the
    /// width that fits just the glyph.
    var minWidth: CGFloat = 70

    var body: some View {
        switch layout {
        case .external: externalBody
        case .macbook:  macbookBody
        }
    }

    // Horizontal edge padding is identical left/right — canonical v6 pill
    // has r = h/2 semicircular bottoms, so edge inset = r keeps content
    // clear of the curve.
    private var pad: CGFloat { height / 2 }

    // Minimum breathing room between the center label (or glyph, when no
    // label) and the right-slot content so they never touch at small widths.
    private static let innerGap: CGFloat = 6

    // MARK: External (fluid)

    private var externalBody: some View {
        let glyphW = V6LeadingActivityView.intrinsicWidth(for: activePets)
        let labelW = label.map { V6CenterLabelView.intrinsicWidth(of: $0) } ?? 0
        let rightW = rightSlot.map { V6RightSlotView.intrinsicWidth(of: $0) } ?? 0

        let labelBlock = (label == nil ? 0 : 6 + labelW)
        let rightBlock = (rightSlot == nil ? 0 : Self.innerGap + rightW)
        let intrinsic = pad * 2 + glyphW + labelBlock + rightBlock
        let width = max(minWidth, intrinsic)

        return ZStack {
            V6ClosedPillShape()
                .fill(V6Palette.ink)

            HStack(spacing: 0) {
                V6LeadingActivityView(mode: mode, pets: activePets)
                    .frame(width: glyphW, height: 24)

                if let label {
                    V6CenterLabelView(text: label)
                        .padding(.leading, 6)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer(minLength: Self.innerGap)

                if let rightSlot {
                    V6RightSlotView(content: rightSlot)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, pad)
        }
        .frame(width: width, height: height)
        .animation(
            .timingCurve(0.4, 0, 0.2, 1, duration: 0.45),
            value: AnyHashable([
                AnyHashable(label ?? ""),
                AnyHashable(rightSlot.map(RightSlotKey.init) ?? .none),
                AnyHashable(mode),
                AnyHashable(activePets),
            ])
        )
    }

    // MARK: MacBook (outer width locked)

    private var macbookBody: some View {
        let halfReserve: CGFloat = 44
        let leadingExtension = V6LeadingActivityView.macbookLeadingExtension(for: activePets)
        let outer = halfReserve + leadingExtension + physicalNotchWidth + halfReserve

        return ZStack {
            V6ClosedPillShape()
                .fill(V6Palette.ink)

            HStack(spacing: 0) {
                V6LeadingActivityView(mode: mode, pets: activePets)
                    .frame(width: V6LeadingActivityView.intrinsicWidth(for: activePets), height: 24)

                Spacer(minLength: 0)

                if let rightSlot {
                    V6RightSlotView(content: rightSlot)
                }
            }
            .padding(.horizontal, pad)
        }
        .frame(width: outer, height: height)
        // The layout grows only toward the left so the hardware notch and
        // right-side session count remain locked to their existing positions.
        .offset(x: -leadingExtension / 2)
    }
}

enum V6ClosedLayout: Equatable {
    case external
    case macbook
}

private enum RightSlotKey: Hashable {
    case count(Int)
    case agents(Int)

    init(_ content: IslandRightSlotContent) {
        switch content {
        case .count(let n):    self = .count(n)
        case .agents(let cs):  self = .agents(cs.count)
        }
    }
}

// MARK: - Settings-tab live preview

/// Fixed-width pill that mimics the real island inside the settings-tab
/// preview stage. Parameters match what the tab exposes.
struct IslandPreviewPill: View {
    let mode: UnifiedBars.Mode
    let label: String?
    let rightSlot: IslandRightSlotContent?
    let layout: V6ClosedLayout
    let physicalNotchWidth: CGFloat
    let now: Date

    var body: some View {
        V6ClosedPill(
            mode: mode,
            label: label,
            rightSlot: rightSlot,
            layout: layout,
            activePets: mode == .running ? [.codex, .claude] : [],
            physicalNotchWidth: physicalNotchWidth
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
