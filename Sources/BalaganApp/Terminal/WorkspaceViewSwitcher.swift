import SwiftUI

/// The task's three views of the same work.
enum WorkspaceView: CaseIterable {
    case terminal, reader, changes

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .reader: return "Reader"
        case .changes: return "Changes"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .reader: return "text.book.closed"
        case .changes: return "plus.forwardslash.minus"
        }
    }

    var shortcutHint: String {
        switch self {
        case .terminal: return "Esc from Reader or Changes"
        case .reader: return "⇧⌘R"
        case .changes: return "⇧⌘G"
        }
    }
}

/// "Terminal | Reader | Changes" — a compact segmented switch in the header's own style (the stock
/// segmented Picker doesn't follow the UI scale and reads heavier than the rest of the bar).
struct WorkspaceViewSwitcher: View {
    let selection: WorkspaceView
    let showsReader: Bool
    let showsChanges: Bool
    let scale: CGFloat
    let onSelect: (WorkspaceView) -> Void

    private var views: [WorkspaceView] {
        WorkspaceView.allCases.filter { view in
            switch view {
            case .terminal: return true
            case .reader: return showsReader
            case .changes: return showsChanges
            }
        }
    }

    var body: some View {
        // Labels when they fit; icon-only segments (names in the tooltips) when the header is tight,
        // e.g. on a narrow window. Never wrap a label.
        ViewThatFits(in: .horizontal) {
            segments(showsLabels: true)
            segments(showsLabels: false)
        }
        .layoutPriority(1)
    }

    private func segments(showsLabels: Bool) -> some View {
        HStack(spacing: 2 * scale) {
            ForEach(views, id: \.self) { view in
                segment(view, showsLabel: showsLabels)
            }
        }
        .fixedSize()
        .padding(2 * scale)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                .fill(Theme.bgWindow)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusButton, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-view-switcher")
    }

    private func segment(_ view: WorkspaceView, showsLabel: Bool) -> some View {
        let isSelected = view == selection
        return Button {
            onSelect(view)
        } label: {
            HStack(spacing: 5 * scale) {
                Image(systemName: view.symbol)
                    .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
                if showsLabel {
                    Text(view.title)
                        .font(.system(size: Theme.TextSize.body * scale, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 9 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusButton - 1, style: .continuous)
                    .fill(isSelected ? Theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(view.title) (\(view.shortcutHint))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace-view-\(view.title.lowercased())")
    }
}
