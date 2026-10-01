import SwiftUI
import BalaganCore

struct LibGhosttyTerminalView: NSViewRepresentable {
    let taskID: TaskItem.ID
    let surface: Surface
    let runtime: TerminalRuntimeOptions
    let terminalAppearance: TerminalAppearanceSettings
    let artifactDirectory: URL?
    let isActive: Bool
    let shortcuts: TerminalShortcutContext
    let onActivate: () -> Void
    let onEndedProcessSurface: (TaskItem.ID, Surface.ID) -> Void

    func makeNSView(context: Context) -> LibGhosttyTerminalHostView {
        let key = TerminalHostKey(taskID: taskID, surfaceID: surface.id)
        let view = TerminalHostRegistry.shared.host(for: key)
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ nsView: LibGhosttyTerminalHostView, context: Context) {
        apply(to: nsView, context: context)
    }

    private func apply(to view: LibGhosttyTerminalHostView, context: Context) {
        view.setActive(isActive)
        view.shortcutContext = shortcuts
        view.onActivate = onActivate
        view.onEndedProcessSurface = onEndedProcessSurface
        view.configure(TerminalSessionConfig(
            taskID: taskID,
            surface: surface,
            runtime: runtime,
            terminalAppearance: terminalAppearance,
            artifactDirectory: artifactDirectory
        ))
    }
}
