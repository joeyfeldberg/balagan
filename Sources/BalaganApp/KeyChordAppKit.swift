import AppKit
import BalaganCore

extension KeyModifier {
    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        }
    }
}

extension KeyChord {
    /// The modifier mask for an `NSMenuItem.keyEquivalentModifierMask`.
    var modifierFlags: NSEvent.ModifierFlags {
        modifiers.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.eventFlag) }
    }

    /// The string AppKit expects as an `NSMenuItem.keyEquivalent`.
    var keyEquivalent: String {
        switch key {
        case "arrowLeft": return UnicodeScalar(NSLeftArrowFunctionKey).map { String($0) } ?? ""
        case "arrowRight": return UnicodeScalar(NSRightArrowFunctionKey).map { String($0) } ?? ""
        case "arrowUp": return UnicodeScalar(NSUpArrowFunctionKey).map { String($0) } ?? ""
        case "arrowDown": return UnicodeScalar(NSDownArrowFunctionKey).map { String($0) } ?? ""
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        default: return key.lowercased()
        }
    }

    /// Build a chord from a recorded `keyDown` event. Returns nil for keys we can't represent
    /// (e.g. a bare modifier, Escape, or anything that isn't a usable shortcut key).
    static func from(event: NSEvent) -> KeyChord? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<KeyModifier> = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        let key: String
        switch event.keyCode {
        case 123: key = "arrowLeft"
        case 124: key = "arrowRight"
        case 125: key = "arrowDown"
        case 126: key = "arrowUp"
        case 36, 76: key = "return"
        case 48: key = "tab"
        case 49: key = "space"
        case 53: return nil // Escape — used to cancel recording, never a binding.
        default:
            guard let raw = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            let base = KeyChord.unshift(raw)
            // Accept letters, digits, and the common US-layout punctuation keys.
            guard base.isLetter || base.isNumber || "[]\\;'`,./-=".contains(base) else { return nil }
            key = String(base)
        }
        return KeyChord(key: key, modifiers: modifiers)
    }

    /// Map a shifted US-keyboard symbol back to its base key, so ⇧] and ] record as the same key.
    private static func unshift(_ character: Character) -> Character {
        switch character {
        case "}": return "]"
        case "{": return "["
        case "|": return "\\"
        case ":": return ";"
        case "\"": return "'"
        case "<": return ","
        case ">": return "."
        case "?": return "/"
        case "~": return "`"
        case "_": return "-"
        case "+": return "="
        case "!": return "1"
        case "@": return "2"
        case "#": return "3"
        case "$": return "4"
        case "%": return "5"
        case "^": return "6"
        case "&": return "7"
        case "*": return "8"
        case "(": return "9"
        case ")": return "0"
        default: return character
        }
    }
}
