import AppKit
import SwiftUI
import BalaganCore

private struct TabFrameKey: PreferenceKey {
    static let defaultValue: [Surface.ID: CGRect] = [:]
    static func reduce(value: inout [Surface.ID: CGRect], nextValue: () -> [Surface.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Horizontal terminal-tab strip with drag-to-reorder. Tap selects; dragging a chip lifts a floating
/// copy and shows an accent insertion bar, then calls `onMove(fromOffset, toOffset)` on drop —
/// mirroring the sidebar project reorder, but on the horizontal axis.
struct WorkspaceTabStrip: View {
    let surfaces: [Surface]
    let selectedID: Surface.ID
    var attentionIDs: Set<Surface.ID> = []
    /// Surfaces whose agent is blocked on the user. Unlike the attention dot this shows on the
    /// *selected* tab too — inside a task, "which tab is asking me something" is exactly the question.
    var waitingIDs: Set<Surface.ID> = []
    var scale: CGFloat = 1
    let onSelect: (Surface.ID) -> Void
    let onMove: (Int, Int) -> Void
    /// Middle-click a tab to close it (cmux-style).
    var onClose: (Surface.ID) -> Void = { _ in }
    /// Right-click → Rename Tab… (nil hides it).
    var onRename: ((Surface) -> Void)? = nil
    /// Right-click → Restart Agent, offered on agent tabs only (nil hides it everywhere).
    var onRestartAgent: ((Surface.ID) -> Void)? = nil
    /// Right-click → Sessions ▸ <earlier session>: resume that session in this tab.
    var onResumeSession: ((Surface.ID, SessionRecord.ID) -> Void)? = nil

    @State private var frames: [Surface.ID: CGRect] = [:]
    @State private var dragID: Surface.ID?
    @State private var dragStartFrame: CGRect = .zero
    @State private var dropIndex: Int?
    @GestureState private var dragTranslation: CGSize = .zero
    private let space = "workspace-tabs"

    var body: some View {
        HStack(spacing: 4 * scale) {
            ForEach(surfaces) { surface in
                chip(surface)
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(TabFrameKey.self) { frames = $0 }
        .overlay(alignment: .topLeading) { insertionLine }
        .overlay(alignment: .topLeading) { dragPreview }
        .accessibilityIdentifier("terminal-tab-picker")
    }

    private func label(_ title: String, selected: Bool, glyph: AgentStatusGlyph? = nil) -> some View {
        HStack(spacing: 5 * scale) {
            // Inside the chip, before the title: on the corner it overlapped the edge and was easy to miss.
            if let glyph {
                AgentStatusIndicator(glyph: glyph, size: Theme.TextSize.small * scale)
            }
            Text(title)
                .font(.system(size: Theme.TextSize.title * scale, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 5 * scale)
            .background(
                // Every tab is a bounded chip so adjacent tabs (and the flat breadcrumb title) read as
                // distinct: the active tab is accent-highlighted (clearly the current one), inactive
                // tabs are "recessed" (darker than the bar) with a hairline edge.
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .fill(selected ? Theme.accentSoft : Theme.bgWindow)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .stroke(selected ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1)
            )
    }

    /// "Oct 5, 13:31 · Add passkey login" (the date it started, then its first prompt).
    static func sessionLabel(_ record: SessionRecord) -> String {
        let date = record.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return [date, record.title].compactMap { $0 }.joined(separator: " · ")
    }

    /// A tab is an agent tab when it has an agent session or an agent launch command.
    private func isAgentTab(_ surface: Surface) -> Bool {
        surface.resumeBinding?.kind == .agent || surface.agentKind != nil
    }

    @ViewBuilder
    private func tabMenu(_ surface: Surface) -> some View {
        if let onRestartAgent, isAgentTab(surface) {
            Button {
                onRestartAgent(surface.id)
            } label: {
                Label("Restart Agent", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("tab-restart-agent-button")
            if let onResumeSession, let sessions = surface.previousSessions, sessions.isEmpty == false {
                Menu("Earlier Sessions") {
                    ForEach(sessions) { record in
                        Button(Self.sessionLabel(record)) { onResumeSession(surface.id, record.id) }
                    }
                }
                .accessibilityIdentifier("tab-sessions-menu")
            }
            Divider()
        }
        if let onRename {
            Button {
                onRename(surface)
            } label: {
                Label("Rename Tab…", systemImage: "pencil")
            }
        }
        Button(role: .destructive) {
            onClose(surface.id)
        } label: {
            Label("Close Tab", systemImage: "xmark")
        }
    }

    @ViewBuilder
    private func chip(_ surface: Surface) -> some View {
        label(surface.title, selected: surface.id == selectedID, glyph: AgentStatusGlyph.resolve(
            isRunning: false,
            isWaiting: waitingIDs.contains(surface.id),
            needsAttention: attentionIDs.contains(surface.id) && surface.id != selectedID
        ))
            .opacity(dragID == surface.id ? 0 : 1)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TabFrameKey.self,
                        value: [surface.id: proxy.frame(in: .named(space))]
                    )
                }
            )
            .contentShape(Rectangle())
            .overlay { MiddleClickCatcher { onClose(surface.id) } }
            .onTapGesture { onSelect(surface.id) }
            .contextMenu { tabMenu(surface) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onChanged { value in
                        if dragID == nil {
                            dragID = surface.id
                            dragStartFrame = frames[surface.id] ?? .zero
                            onSelect(surface.id)
                        }
                        dropIndex = computeDropIndex(dragged: surface.id, dx: value.translation.width)
                    }
                    .onEnded { _ in
                        if let target = dropIndex,
                           let from = surfaces.firstIndex(where: { $0.id == surface.id }) {
                            withAnimation(.easeOut(duration: 0.16)) { onMove(from, target) }
                        }
                        dragID = nil
                        dropIndex = nil
                    }
            )
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let id = dragID, let surface = surfaces.first(where: { $0.id == id }) {
            label(surface.title, selected: true)
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 3)
                .offset(x: dragStartFrame.minX + dragTranslation.width,
                        y: dragStartFrame.minY + dragTranslation.height)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var insertionLine: some View {
        if dragID != nil, let dropIndex, let x = insertionX(dropIndex: dropIndex) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: max(0, dragStartFrame.height - 4 * scale))
                .offset(x: x - 1, y: dragStartFrame.minY + 2 * scale)
                .allowsHitTesting(false)
        }
    }

    /// Insertion index among the *other* tabs, from the dragged chip's current center x.
    private func computeDropIndex(dragged: Surface.ID, dx: CGFloat) -> Int {
        let center = dragStartFrame.midX + dx
        var index = 0
        for surface in surfaces where surface.id != dragged {
            if let frame = frames[surface.id], frame.midX < center {
                index += 1
            }
        }
        return index
    }

    private func insertionX(dropIndex: Int) -> CGFloat? {
        guard let id = dragID else { return nil }
        let others = surfaces.filter { $0.id != id }.compactMap { frames[$0.id] }
        guard others.isEmpty == false else { return dragStartFrame.minX }
        if dropIndex <= 0 { return others[0].minX - 2 * scale }
        if dropIndex >= others.count { return others[others.count - 1].maxX + 2 * scale }
        return (others[dropIndex - 1].maxX + others[dropIndex].minX) / 2
    }
}

/// Transparent overlay that fires `onMiddleClick` on a middle-mouse (button 2) release, while letting
/// left/right clicks and drags pass straight through to the SwiftUI views beneath it. The `hitTest`
/// only claims the event when the *current* event is a middle-button press/release, so tap-to-select
/// and drag-to-reorder still work.
private struct MiddleClickCatcher: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> NSView { MiddleClickNSView(onMiddleClick: onMiddleClick) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MiddleClickNSView)?.onMiddleClick = onMiddleClick
    }
}

private final class MiddleClickNSView: NSView {
    var onMiddleClick: () -> Void
    init(onMiddleClick: @escaping () -> Void) {
        self.onMiddleClick = onMiddleClick
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        switch NSApp.currentEvent?.type {
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return super.hitTest(point)   // claim middle-button events only
        default:
            return nil                    // transparent to left/right clicks + SwiftUI gestures
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick() } else { super.otherMouseUp(with: event) }
    }
}
