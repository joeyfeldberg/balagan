import Foundation
import BalaganCore

/// Appearance mutations: terminal font size, UI scale, sidebar scale, and keyboard-shortcut
/// rebinding. Extracted from `BoardViewModel`. All mutate the `@Published` appearance/shortcut
/// settings, which persist via autosave and (for shortcuts) rebuild the Terminal menu.
extension BoardViewModel {
    func increaseTerminalFontSize() -> Float {
        updateTerminalFontSize(terminalAppearance.fontSize + 1)
    }

    func decreaseTerminalFontSize() -> Float {
        updateTerminalFontSize(terminalAppearance.fontSize - 1)
    }

    func resetTerminalFontSize() -> Float {
        updateTerminalFontSize(TerminalAppearanceSettings.defaultFontSize)
    }

    func increaseUIScale() {
        updateUIScale(uiAppearance.uiScale + UIAppearanceSettings.scaleStep)
    }

    func decreaseUIScale() {
        updateUIScale(uiAppearance.uiScale - UIAppearanceSettings.scaleStep)
    }

    func resetUIScale() {
        updateUIScale(UIAppearanceSettings.defaultScale)
    }

    @discardableResult
    func updateUIScale(_ uiScale: Double) -> Double {
        let boundedScale = UIAppearanceSettings.clampedScale(uiScale)
        uiAppearance.uiScale = (boundedScale * 100).rounded() / 100
        return uiAppearance.uiScale
    }

    func increaseSidebarScale() {
        updateSidebarScale(uiAppearance.effectiveSidebarScale + UIAppearanceSettings.scaleStep)
    }

    func decreaseSidebarScale() {
        updateSidebarScale(uiAppearance.effectiveSidebarScale - UIAppearanceSettings.scaleStep)
    }

    func resetSidebarScale() {
        updateSidebarScale(UIAppearanceSettings.defaultScale)
    }

    @discardableResult
    func updateSidebarScale(_ sidebarScale: Double) -> Double {
        let boundedScale = UIAppearanceSettings.clampedScale(sidebarScale)
        let rounded = (boundedScale * 100).rounded() / 100
        uiAppearance.sidebarScale = rounded
        return rounded
    }

    // MARK: Keyboard shortcuts

    /// Rebind `action` to `chord`. Mutating the @Published settings rebuilds the Terminal menu and
    /// persists. The editor blocks invalid chords (no ⌘/⌃/⌥), so we don't re-check here.
    func updateShortcut(_ action: ShortcutAction, to chord: KeyChord) {
        keyboardShortcuts.setChord(chord, for: action)
    }

    func resetShortcut(_ action: ShortcutAction) {
        keyboardShortcuts.reset(action)
    }

    func resetAllShortcuts() {
        keyboardShortcuts.resetAll()
    }

    @discardableResult
    private func updateTerminalFontSize(_ fontSize: Float) -> Float {
        let boundedFontSize = min(max(fontSize, 6), 72)
        terminalAppearance.fontSize = boundedFontSize
        return boundedFontSize
    }
}
