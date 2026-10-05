import AppKit
import BalaganCore

extension BalaganApplication {
    // MARK: - Terminal menu (keyboard tab + split-pane navigation)

    /// Adds a "Terminal" menu whose key equivalents drive tab/split navigation. Menu key equivalents are
    /// matched by AppKit *before* the keystroke reaches the focused libghostty surface, so these win
    /// over the terminal (the embedded view-level handler was unreliable). Items target the app delegate
    /// (which owns the view model) and are gated by `validateMenuItem` so they don't steal shortcuts on
    /// the kanban board or while editing a text field.
    @MainActor
    func installTerminalMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Idempotent: drop a previously installed Terminal menu so rebuilds (after a shortcut change)
        // don't stack duplicates.
        if let existing = mainMenu.items.first(where: { $0.submenu?.title == "Terminal" }) {
            mainMenu.removeItem(existing)
        }

        let shortcuts = viewModel?.keyboardShortcuts ?? KeyboardShortcutSettings()
        let terminalMenuItem = NSMenuItem()
        let menu = NSMenu(title: "Terminal")
        terminalMenuItem.submenu = menu

        func add(_ title: String, _ action: Selector, _ key: String, _ mask: NSEvent.ModifierFlags, tag: Int = 0) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            item.tag = tag
        }

        // The user-configurable shortcuts pull their key equivalent from the saved settings.
        func add(_ title: String, _ action: Selector, _ shortcut: ShortcutAction) {
            let chord = shortcuts.chord(for: shortcut)
            add(title, action, chord.keyEquivalent, chord.modifierFlags)
        }

        add("Command Palette…", #selector(menuShowCommandPalette(_:)), .commandPalette)
        add("New Task…", #selector(menuNewTask(_:)), .newTask)
        add("Toggle Reader Mode", #selector(menuToggleReaderMode(_:)), .toggleReaderMode)
        add("Review Changes", #selector(menuToggleChangesView(_:)), .toggleChangesView)
        add("Speak Last Response", #selector(menuSpeakLastResponse(_:)), .speakLastResponse)
        add("Next Agent Needing You", #selector(menuNextAgentNeedingYou(_:)), .nextAgentNeedingYou)
        menu.addItem(.separator())
        add("New Tab", #selector(menuNewTab(_:)), .newTab)
        add("New Agent Pane", #selector(menuNewAgentTab(_:)), .newAgentTab)
        add("Split Right", #selector(menuSplitRight(_:)), .splitRight)
        add("Split Down", #selector(menuSplitDown(_:)), .splitDown)
        add("Zoom / Unzoom Pane", #selector(menuZoomPane(_:)), .zoomPane)
        add("Close Tab", #selector(menuCloseTab(_:)), .closeTab)
        menu.addItem(.separator())
        add("Find…", #selector(menuFindInTerminal(_:)), .findInTerminal)
        menu.addItem(.separator())
        add("Select Next Tab", #selector(menuSelectNextTab(_:)), .nextTab)
        add("Select Previous Tab", #selector(menuSelectPreviousTab(_:)), .previousTab)
        for number in 1...8 {
            add("Select Tab \(number)", #selector(menuSelectTabByNumber(_:)), "\(number)", [.command], tag: number)
        }
        add("Select Last Tab", #selector(menuSelectTabByNumber(_:)), "9", [.command], tag: 9)
        menu.addItem(.separator())
        add("Focus Pane Left", #selector(menuFocusSplitLeft(_:)), .focusLeft)
        add("Focus Pane Right", #selector(menuFocusSplitRight(_:)), .focusRight)
        add("Focus Pane Up", #selector(menuFocusSplitUp(_:)), .focusUp)
        add("Focus Pane Down", #selector(menuFocusSplitDown(_:)), .focusDown)

        mainMenu.addItem(terminalMenuItem)
    }

    /// The task whose terminal workspace is currently shown (nil on the kanban board / no selection).
    private var activeTerminalTaskID: TaskItem.ID? {
        viewModel?.selectedTaskID
    }

    @MainActor
    private func runTerminalWorkspaceAction(_ action: (BoardViewModel, TaskItem.ID) -> Void) {
        guard let viewModel, let taskID = activeTerminalTaskID else { return }
        action(viewModel, taskID)
    }

    @objc @MainActor private func menuShowCommandPalette(_ sender: Any?) {
        viewModel?.showingCommandPalette = true
    }

    @objc @MainActor private func menuToggleReaderMode(_ sender: Any?) {
        viewModel?.toggleReaderMode()
    }

    @objc @MainActor private func menuToggleChangesView(_ sender: Any?) {
        viewModel?.toggleChangesView()
    }


    /// Toggle semantics (the VS Code pattern): pressing the shortcut while speaking stops it.
    @objc @MainActor private func menuSpeakLastResponse(_ sender: Any?) {
        if SpeechController.shared.isActive {
            SpeechController.shared.stop()
            return
        }
        guard let viewModel, let surface = viewModel.selectedTaskActiveSurface else { return }
        guard let source = viewModel.readerTranscriptSource(for: surface) else {
            SpeechController.shared.showNotice("No agent response to speak")
            return
        }
        SpeechController.shared.speakLastResponse(transcriptPath: source.path, format: source.format)
    }

    /// Works from the board too (it's how you get *to* a task), so it isn't in `terminalActions`.
    @objc @MainActor private func menuNextAgentNeedingYou(_ sender: Any?) {
        if viewModel?.jumpToNextAgentNeedingYou() != true {
            NSSound.beep()
        }
    }

    @objc @MainActor private func menuNewTask(_ sender: Any?) {
        viewModel?.requestNewTask()
    }

    @objc @MainActor private func menuNewTab(_ sender: Any?) {
        runTerminalWorkspaceAction { $0.createDefaultSurface(taskID: $1) }
    }

    @objc @MainActor private func menuNewAgentTab(_ sender: Any?) {
        runTerminalWorkspaceAction { $0.createAgentSurface(taskID: $1) }
    }

    @objc @MainActor private func menuCloseTab(_ sender: Any?) {
        viewModel?.closeSelectedSurface()
    }

    /// ⌘F: the find bar on the focused pane. Only meaningful inside a task's terminal workspace.
    @objc @MainActor private func menuFindInTerminal(_ sender: Any?) {
        guard activeTerminalTaskID != nil else { NSSound.beep(); return }
        guard let host = TerminalHostRegistry.shared.activeHost() else { NSSound.beep(); return }
        host.startSearch()
    }

    @objc @MainActor private func menuZoomPane(_ sender: Any?) {
        viewModel?.toggleZoomForSelectedSurface()
    }

    @objc @MainActor private func menuSplitRight(_ sender: Any?) {
        runTerminalWorkspaceAction { $0.splitSurface(taskID: $1, axis: .horizontal) }
    }

    @objc @MainActor private func menuSplitDown(_ sender: Any?) {
        runTerminalWorkspaceAction { $0.splitSurface(taskID: $1, axis: .vertical) }
    }

    @objc @MainActor private func menuSelectNextTab(_ sender: Any?) {
        runTerminalWorkspaceAction { $0.selectNextSurface(taskID: $1) }
    }

    @objc @MainActor private func menuSelectPreviousTab(_ sender: Any?) {
        runTerminalWorkspaceAction { $0.selectPreviousSurface(taskID: $1) }
    }

    @objc @MainActor private func menuSelectTabByNumber(_ sender: NSMenuItem) {
        let tag = sender.tag
        runTerminalWorkspaceAction { viewModel, taskID in
            if tag >= 9 {
                viewModel.selectLastSurface(taskID: taskID)
            } else {
                viewModel.selectSurface(taskID: taskID, tabIndex: tag - 1)
            }
        }
    }

    @objc @MainActor private func menuFocusSplitLeft(_ sender: Any?) { focusSplit(.left) }
    @objc @MainActor private func menuFocusSplitRight(_ sender: Any?) { focusSplit(.right) }
    @objc @MainActor private func menuFocusSplitUp(_ sender: Any?) { focusSplit(.up) }
    @objc @MainActor private func menuFocusSplitDown(_ sender: Any?) { focusSplit(.down) }

    @MainActor
    private func focusSplit(_ direction: SplitFocusDirection) {
        runTerminalWorkspaceAction { $0.focusAdjacentSurface(taskID: $1, direction: direction) }
    }

    @objc @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // `menuNewTask` is intentionally absent — it works from the board too, so it's never gated.
        let terminalActions: Set<Selector> = [
            #selector(menuToggleReaderMode(_:)), #selector(menuToggleChangesView(_:)),
            #selector(menuSpeakLastResponse(_:)),
            #selector(menuNewTab(_:)), #selector(menuNewAgentTab(_:)),
            #selector(menuSplitRight(_:)), #selector(menuSplitDown(_:)),
            #selector(menuCloseTab(_:)), #selector(menuZoomPane(_:)),
            #selector(menuSelectNextTab(_:)), #selector(menuSelectPreviousTab(_:)),
            #selector(menuSelectTabByNumber(_:)),
            #selector(menuFocusSplitLeft(_:)), #selector(menuFocusSplitRight(_:)),
            #selector(menuFocusSplitUp(_:)), #selector(menuFocusSplitDown(_:)),
        ]
        guard let action = menuItem.action, terminalActions.contains(action) else {
            return true
        }
        // Speaking survives navigating away from the task, so its stop-toggle must too.
        if action == #selector(menuSpeakLastResponse(_:)), SpeechController.shared.isActive {
            return true
        }
        // Don't steal these while a text field is being edited (its field editor is the first responder).
        if NSApp.keyWindow?.firstResponder is NSText {
            return false
        }
        return activeTerminalTaskID != nil
    }
}
