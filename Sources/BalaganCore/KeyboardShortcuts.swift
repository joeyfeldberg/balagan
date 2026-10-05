import Foundation

/// A keyboard modifier, in Apple's display order (⌃⌥⇧⌘).
public enum KeyModifier: String, Codable, Hashable, Sendable, CaseIterable {
    case control
    case option
    case shift
    case command

    public var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }
}

/// A key combination: a base key (a character like "p"/"]" or a named key like "arrowLeft") plus
/// modifiers. Pure (no AppKit) so it lives in Core; the app layer bridges it to NSEvent / menu keys.
public struct KeyChord: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: Set<KeyModifier>

    public init(key: String, modifiers: Set<KeyModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    /// e.g. "⇧⌘P", "⌥⌘←" (modifiers in Apple's ⌃⌥⇧⌘ order).
    public var displayString: String {
        let mods = KeyModifier.allCases.filter { modifiers.contains($0) }.map(\.glyph).joined()
        return mods + KeyChord.keyGlyph(for: key)
    }

    /// A binding must carry ⌘, ⌃, or ⌥ so it can't shadow plain typing in a terminal.
    public var isValid: Bool {
        modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
    }

    public static func keyGlyph(for key: String) -> String {
        switch key {
        case "arrowLeft": return "←"
        case "arrowRight": return "→"
        case "arrowUp": return "↑"
        case "arrowDown": return "↓"
        case "return": return "⏎"
        case "tab": return "⇥"
        case "space": return "␣"
        default: return key.uppercased()
        }
    }
}

/// The app-level commands whose keyboard shortcut is user-configurable (all live in the Terminal menu).
public enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case commandPalette
    case newTask
    case newTab
    case newAgentTab
    case splitRight
    case splitDown
    case closeTab
    case zoomPane
    case nextTab
    case previousTab
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case nextAgentNeedingYou
    case toggleReaderMode
    case toggleChangesView
    case speakLastResponse
    case findInTerminal

    public var id: String { rawValue }

    /// The section this action is grouped under in the Settings shortcuts list.
    public enum Group: String, CaseIterable, Sendable {
        case general = "General"
        case panesAndTabs = "Panes & Tabs"
        case navigation = "Navigation"
        case session = "Session"
    }

    public var group: Group {
        switch self {
        case .commandPalette, .newTask:
            return .general
        case .newTab, .newAgentTab, .splitRight, .splitDown, .closeTab, .zoomPane:
            return .panesAndTabs
        case .nextTab, .previousTab, .focusLeft, .focusRight, .focusUp, .focusDown, .nextAgentNeedingYou, .findInTerminal:
            return .navigation
        case .toggleReaderMode, .toggleChangesView, .speakLastResponse:
            return .session
        }
    }

    public var displayName: String {
        switch self {
        case .commandPalette: return "Command Palette"
        case .newTask: return "New Task"
        case .newTab: return "New Tab"
        case .newAgentTab: return "New Agent Pane"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .closeTab: return "Close Tab"
        case .zoomPane: return "Zoom / Unzoom Pane"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .focusLeft: return "Focus Pane Left"
        case .focusRight: return "Focus Pane Right"
        case .focusUp: return "Focus Pane Up"
        case .focusDown: return "Focus Pane Down"
        case .nextAgentNeedingYou: return "Next Agent Needing You"
        case .toggleReaderMode: return "Toggle Reader Mode"
        case .toggleChangesView: return "Review Changes"
        case .speakLastResponse: return "Speak Last Response"
        case .findInTerminal: return "Find in Terminal"
        }
    }

    public var defaultChord: KeyChord {
        switch self {
        case .commandPalette: return KeyChord(key: "p", modifiers: [.command, .shift])
        case .newTask: return KeyChord(key: "n", modifiers: [.command])
        case .newTab: return KeyChord(key: "t", modifiers: [.command])
        case .newAgentTab: return KeyChord(key: "t", modifiers: [.command, .shift])
        case .splitRight: return KeyChord(key: "d", modifiers: [.command])
        case .splitDown: return KeyChord(key: "d", modifiers: [.command, .shift])
        case .closeTab: return KeyChord(key: "w", modifiers: [.command])
        case .zoomPane: return KeyChord(key: "return", modifiers: [.command, .shift])
        case .nextTab: return KeyChord(key: "]", modifiers: [.command, .shift])
        case .previousTab: return KeyChord(key: "[", modifiers: [.command, .shift])
        case .focusLeft: return KeyChord(key: "arrowLeft", modifiers: [.command, .option])
        case .focusRight: return KeyChord(key: "arrowRight", modifiers: [.command, .option])
        case .focusUp: return KeyChord(key: "arrowUp", modifiers: [.command, .option])
        case .focusDown: return KeyChord(key: "arrowDown", modifiers: [.command, .option])
        case .nextAgentNeedingYou: return KeyChord(key: "j", modifiers: [.command])
        case .toggleReaderMode: return KeyChord(key: "r", modifiers: [.command, .shift])
        case .toggleChangesView: return KeyChord(key: "g", modifiers: [.command, .shift])
        case .speakLastResponse: return KeyChord(key: "s", modifiers: [.command, .shift])
        case .findInTerminal: return KeyChord(key: "f", modifiers: [.command])
        }
    }
}

/// User keyboard-shortcut overrides. Absent actions use their `defaultChord`. Keyed by raw action name
/// so it encodes as a plain JSON object (and decodes from older boards that have no key).
public struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    public var overrides: [String: KeyChord]

    public init(overrides: [String: KeyChord] = [:]) {
        self.overrides = overrides
    }

    public func chord(for action: ShortcutAction) -> KeyChord {
        overrides[action.rawValue] ?? action.defaultChord
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// The action currently bound to `target`, if any (for conflict detection in the editor).
    public func action(boundTo target: KeyChord, excluding excluded: ShortcutAction? = nil) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != excluded && chord(for: $0) == target }
    }

    public mutating func setChord(_ chord: KeyChord, for action: ShortcutAction) {
        // Store only genuine overrides; clearing back to the default drops the entry.
        if chord == action.defaultChord {
            overrides[action.rawValue] = nil
        } else {
            overrides[action.rawValue] = chord
        }
    }

    public mutating func reset(_ action: ShortcutAction) {
        overrides[action.rawValue] = nil
    }

    public mutating func resetAll() {
        overrides = [:]
    }
}
