import AppKit
import BalaganCore

/// Hardware key codes (`NSEvent.keyCode`, layout-independent) for the keys the terminal handles
/// directly — named so the shortcut and modifier switches read without magic numbers.
private enum TerminalKeyCode {
    static let tab = 48
    static let `return` = 36
    static let enter = 76
    static let equals = 24   // ⌘= / ⌘+ increase font size
    static let minus = 27    // ⌘- decrease font size
    static let zero = 29     // ⌘0 reset font size

    static let leftShift = 56
    static let rightShift = 60
    static let leftControl = 59
    static let rightControl = 62
    static let leftOption = 58
    static let rightOption = 61
    static let leftCommand = 54
    static let rightCommand = 55
    static let capsLock = 57
}

extension LibGhosttyTerminalHostView {
    override func keyDown(with event: NSEvent) {
        if let activeHostForForwarding {
            activeHostForForwarding.keyDown(with: event)
            return
        }

        guard isActive else {
            return
        }

        // The process is gone, so keystrokes have nowhere to go. ⏎ means "resume": an exited agent
        // tab offers exactly that (see BoardAgentExit); for anything else it's a no-op.
        if processExitDetected, event.keyCode == 36 || event.keyCode == 76,
           let sessionKey = currentSessionKey {
            TerminalHostRegistry.shared.exitedSurfaceReturnReporter?(sessionKey.taskID, sessionKey.surfaceID)
            return
        }

        if handleCommandShortcut(event) {
            return
        }

        guard let surfaceHandle else {
            super.keyDown(with: event)
            return
        }

        ensureSurfaceFocusedForInput()
        recordRenderedInputSnapshotBeforeIfNeeded()
        forwardKeyDown(event, surfaceHandle: surfaceHandle)
        requestRenderFrame()
        recordRenderedInputSnapshotAfter()
    }

    /// Unified key forwarding (modeled on cmux's `GhosttyTerminalView.keyDown`): build one libghostty
    /// key event carrying the full modifier set, and route text through AppKit's input system
    /// (`interpretKeyEvents` → `NSTextInputClient`) so IME, dead keys, and accents compose correctly.
    /// libghostty then encodes everything itself (legacy *and* kitty keyboard protocol) — so there's no
    /// per-key keycode `switch`, and Shift+Enter / Shift+Tab / Ctrl+arrows / option-as-alt all work.
    private func forwardKeyDown(_ event: NSEvent, surfaceHandle: LibGhosttySurfaceHandle) {
        let mods = ghosttyMods(from: event)
        let action: LibGhosttyKeyAction = event.isARepeat ? .repeatKey : .press
        let keyCode = UInt32(event.keyCode)
        let unshifted = unshiftedCodepoint(from: event)

        if sendControlFastPath(
            event, surfaceHandle: surfaceHandle,
            keyCode: keyCode, mods: mods, action: action, unshifted: unshifted
        ) {
            return
        }

        // Respect Ghostty keyboard config (e.g. macos-option-as-alt) when interpreting text.
        let translationEvent = translatedKeyEvent(for: event, surfaceHandle: surfaceHandle)

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = hasMarkedText()

        // Let the input system process the event (IME composition, dead keys); results arrive via
        // insertText (→ keyTextAccumulator) or setMarkedText (→ markedText).
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: markedBefore)

        let accumulated = keyTextAccumulator ?? []

        // IME consumed the key for composition (updated/cleared marked text, committed nothing) —
        // the preedit overlay already reflects it, so don't also forward the key to the shell.
        if accumulated.isEmpty, markedBefore || hasMarkedText() {
            return
        }

        let consumed = consumedMods(translationEvent.modifierFlags)

        func sendKey(consumedMods: UInt32, text: String?) {
            surfaceHandle.sendKeyEvent(
                keyCode: keyCode, mods: mods, consumedMods: consumedMods, action: action,
                unshiftedCodepoint: unshifted, composing: false, text: text
            )
        }

        if accumulated.isEmpty {
            // No IME text. Printable characters ride along as `text`; control/function/special keys
            // send `text == nil` so libghostty encodes them from keycode+mods (Enter, Tab, arrows,
            // Shift+Enter, …).
            let characters = translationEvent.characters
            if let characters, shouldSendText(characters) {
                sendKey(consumedMods: consumed, text: characters)
            } else {
                sendKey(consumedMods: 0, text: nil)
            }
        } else {
            // Committed IME text (CJK, accented characters): forward each chunk as a key event.
            for text in accumulated {
                sendKey(consumedMods: shouldSendText(text) ? consumed : 0, text: shouldSendText(text) ? text : nil)
            }
        }
    }

    /// Control fast-path: Ctrl-only input is terminal control (Ctrl+C/D/Z/…), not text composition, so
    /// bypass AppKit text interpretation and send a deterministic key event. Returns true when it
    /// handled (consumed) the event.
    private func sendControlFastPath(
        _ event: NSEvent,
        surfaceHandle: LibGhosttySurfaceHandle,
        keyCode: UInt32,
        mods: UInt32,
        action: LibGhosttyKeyAction,
        unshifted: UInt32
    ) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !hasMarkedText() else {
            return false
        }
        let text = event.charactersIgnoringModifiers ?? event.characters
        return surfaceHandle.sendKeyEvent(
            keyCode: keyCode, mods: mods, consumedMods: 0, action: action,
            unshiftedCodepoint: unshifted, composing: false,
            text: (text?.isEmpty == false) ? text : nil
        )
    }

    override func flagsChanged(with event: NSEvent) {
        // Report modifier press/release to libghostty so the kitty keyboard protocol can encode
        // modifier state (some TUIs rely on it). Skip while composing.
        if isActive, let surfaceHandle, !hasMarkedText(), let action = modifierKeyAction(event) {
            surfaceHandle.sendKeyEvent(
                keyCode: UInt32(event.keyCode), mods: ghosttyMods(from: event), consumedMods: 0,
                action: action, unshiftedCodepoint: 0, composing: false, text: nil
            )
            requestRenderFrame()
        }
        super.flagsChanged(with: event)
    }

    /// The base codepoint for a key, ignoring modifiers — used by libghostty's key encoder.
    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.charactersIgnoringModifiers ?? event.characters,
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    /// Modifiers that were "consumed" to produce text. Only shift/alt translate text; ctrl/cmd never
    /// do, so mask the shared ghostty bitmask down to the shift (1) and option (4) bits.
    private func consumedMods(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        ghosttyModifierBitmask(flags) & (1 | 4)
    }

    /// True when the text is real printable content (not a control char or an AppKit function-key
    /// private-use scalar like the arrow keys), i.e. safe to send as the key event's `text`.
    private func shouldSendText(_ text: String) -> Bool {
        guard text.isEmpty == false else { return false }
        if text.count == 1, let scalar = text.unicodeScalars.first {
            return !(scalar.value < 0x20 || scalar.value == 0x7F || (scalar.value >= 0xF700 && scalar.value <= 0xF8FF))
        }
        return true
    }

    /// Re-derives the event with Ghostty's translated modifier set (macos-option-as-alt etc.) so AppKit
    /// text interpretation matches the user's Ghostty config. Returns the original event when unchanged.
    private func translatedKeyEvent(for event: NSEvent, surfaceHandle: LibGhosttySurfaceHandle) -> NSEvent {
        let bits = surfaceHandle.keyTranslationMods(ghosttyMods(from: event))
        var flags = event.modifierFlags
        setModifier(&flags, .shift, bits & 1 != 0)
        setModifier(&flags, .control, bits & 2 != 0)
        setModifier(&flags, .option, bits & 4 != 0)
        setModifier(&flags, .command, bits & 8 != 0)
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) ?? event
    }

    private func setModifier(_ flags: inout NSEvent.ModifierFlags, _ flag: NSEvent.ModifierFlags, _ on: Bool) {
        if on { flags.insert(flag) } else { flags.remove(flag) }
    }

    /// Press/release classification for a modifier-only `flagsChanged` event (nil for non-modifier keys).
    private func modifierKeyAction(_ event: NSEvent) -> LibGhosttyKeyAction? {
        let flags = event.modifierFlags
        let isDown: Bool
        switch Int(event.keyCode) {
        case TerminalKeyCode.leftShift, TerminalKeyCode.rightShift: isDown = flags.contains(.shift)
        case TerminalKeyCode.leftControl, TerminalKeyCode.rightControl: isDown = flags.contains(.control)
        case TerminalKeyCode.leftOption, TerminalKeyCode.rightOption: isDown = flags.contains(.option)
        case TerminalKeyCode.leftCommand, TerminalKeyCode.rightCommand: isDown = flags.contains(.command)
        case TerminalKeyCode.capsLock: isDown = flags.contains(.capsLock)
        default: return nil
        }
        return isDown ? .press : .release
    }

    /// Pushes the current marked (composing) text to libghostty's preedit overlay, clearing it when
    /// composition ends.
    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surfaceHandle else { return }
        if markedText.length > 0 {
            surfaceHandle.setPreedit(markedText.string)
        } else if clearIfNeeded {
            surfaceHandle.setPreedit(nil)
        }
    }

    var imeCellWidth: Double {
        if let size = surfaceHandle?.size(), size.columns > 0 {
            return Double(size.widthPx) / Double(size.columns)
        }
        return 8
    }

    var imeCellHeight: Double {
        if let size = surfaceHandle?.size(), size.rows > 0 {
            return Double(size.heightPx) / Double(size.rows)
        }
        return 16
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Typing in the find bar: ⌘V/⌘A/⌘C belong to its field, not the terminal underneath.
        if let searchBar, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: searchBar) {
            return super.performKeyEquivalent(with: event)
        }
        if let activeHostForForwarding {
            return activeHostForForwarding.performKeyEquivalent(with: event)
        }

        guard isActive else {
            return false
        }

        if handleCommandShortcut(event) {
            return true
        }

        if sendControlCharacterIfNeeded(for: event) {
            requestRenderFrame()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        if let activeHostForForwarding {
            activeHostForForwarding.copy(sender)
            return
        }

        guard isActive else {
            return
        }

        guard let selection = surfaceHandle?.readSelection(), selection.isEmpty == false else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selection, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        if let activeHostForForwarding {
            activeHostForForwarding.paste(sender)
            return
        }

        guard isActive else {
            return
        }

        guard let text = NSPasteboard.general.string(forType: .string), text.isEmpty == false else {
            return
        }

        ensureSurfaceFocusedForInput()
        let paste = terminalPastePayload(text)
        if paste.text.isEmpty == false {
            surfaceHandle?.sendText(paste.text)
        }
        if paste.endsWithNewline {
            _ = surfaceHandle?.sendEnterKey()
        }
        requestRenderFrame()
    }

    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)
        let character = event.charactersIgnoringModifiers?.lowercased()

        if flags.contains(.control), keyCode == TerminalKeyCode.tab {
            if flags.contains(.shift) {
                shortcutContext?.previousTab()
            } else {
                shortcutContext?.nextTab()
            }
            return true
        }

        guard flags.contains(.command) else {
            return false
        }

        // Tab/split navigation and pane focus are owned by the configurable Terminal menu (whose key
        // equivalents AppKit matches before this handler runs), so they're intentionally not handled
        // here — otherwise a rebound shortcut's old key combo would keep firing the action.

        if handleFontZoomShortcut(flags: flags, keyCode: keyCode) {
            return true
        }

        return handleCommandCharacterShortcut(character, flags: flags)
    }

    /// ⌘⇧↩ toggle-zoom and the ⌘=/⌘-/⌘0 font-size shortcuts (matched by hardware key code so they
    /// fire on any keyboard layout). Returns false when the event isn't one of them.
    private func handleFontZoomShortcut(flags: NSEvent.ModifierFlags, keyCode: Int) -> Bool {
        if flags.contains(.shift), keyCode == TerminalKeyCode.return || keyCode == TerminalKeyCode.enter {
            shortcutContext?.toggleZoom()
            return true
        }

        switch keyCode {
        case TerminalKeyCode.equals:
            let evidenceName = flags.contains(.shift) ? "increase-shift-plus" : "increase-equals"
            shortcutContext?.increaseFontSize(evidenceName)
            return true
        case TerminalKeyCode.minus:
            shortcutContext?.decreaseFontSize("decrease-minus")
            return true
        case TerminalKeyCode.zero:
            shortcutContext?.resetFontSize("reset-zero")
            return true
        default:
            return false
        }
    }

    /// ⌘-character shortcuts owned by the terminal itself: close / split cycling / numeric tab
    /// selection / copy / paste / clear. Returns false for anything else — including ⌘⇧] and ⌘⇧[,
    /// which belong to the menu's Next/Previous Tab.
    private func handleCommandCharacterShortcut(_ character: String?, flags: NSEvent.ModifierFlags) -> Bool {
        switch character {
        case "w":
            shortcutContext?.closeCurrent()
            return true
        case "]":
            // ⌘] cycles splits within the current tab (not configurable; ⌘⇧] / Next Tab is the menu's).
            guard flags.contains(.shift) == false else { return false }
            shortcutContext?.nextSplit()
            return true
        case "[":
            guard flags.contains(.shift) == false else { return false }
            shortcutContext?.previousSplit()
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8":
            if let character,
               let index = Int(character) {
                shortcutContext?.selectTab(index - 1)
            }
            return true
        case "9":
            shortcutContext?.selectLastTab()
            return true
        case "c":
            copy(nil)
            return true
        case "v":
            paste(nil)
            return true
        case "k":
            clearScreen()
            return true
        default:
            return false
        }
    }

    private func sendControlCharacterIfNeeded(for event: NSEvent) -> Bool {
        guard let surfaceHandle else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let controlMapping = TerminalControlKeyMapping(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            hasControlModifier: flags.contains(.control),
            hasCommandModifier: flags.contains(.command),
            hasOptionModifier: flags.contains(.option)
        )
        guard let controlCharacter = controlMapping.controlCharacter,
              let controlKeyText = controlMapping.controlKeyText
        else {
            return false
        }

        ensureSurfaceFocusedForInput()
        let handled = surfaceHandle.sendControlKey(
            keyCode: UInt32(event.keyCode),
            text: controlKeyText
        )
        if handled == false {
            surfaceHandle.sendText(controlCharacter)
        }
        return true
    }

    private func clearScreen() {
        ensureSurfaceFocusedForInput()
        surfaceHandle?.sendText("\u{0c}")
        requestRenderFrame()
    }

    private func terminalPastePayload(_ text: String) -> (text: String, endsWithNewline: Bool) {
        if text.hasSuffix("\r\n") {
            return (String(text.dropLast(2)), true)
        }
        if text.hasSuffix("\n") || text.hasSuffix("\r") {
            return (String(text.dropLast()), true)
        }
        return (text, false)
    }
}
