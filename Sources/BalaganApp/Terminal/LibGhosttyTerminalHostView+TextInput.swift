import AppKit
import BalaganCore

// AppKit text-input conformance for the unified key pipeline: `interpretKeyEvents` drives these so the
// IME/dead-key/accent composition machinery works, with committed text accumulated during a keyDown and
// in-progress composition mirrored to libghostty's preedit overlay.
extension LibGhosttyTerminalHostView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }
        unmarkText()
        guard chars.isEmpty == false else { return }
        if keyTextAccumulator != nil {
            // Inside a keyDown: hand the committed text back to forwardKeyDown to send as a key event.
            keyTextAccumulator?.append(chars)
            return
        }
        // Outside a keyDown (e.g. dictation): send straight to the terminal.
        surfaceHandle?.sendText(chars)
        requestRenderFrame()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        let length = markedText.length
        if selectedRange.location != NSNotFound, selectedRange.location <= length {
            markedSelectedRange = NSRange(
                location: selectedRange.location,
                length: min(selectedRange.length, length - selectedRange.location)
            )
        } else {
            markedSelectedRange = NSRange(location: length, length: 0)
        }
        // If composition changed outside a keyDown (e.g. layout switch), reflect it immediately.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        syncPreedit()
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        markedText.length > 0 ? markedSelectedRange : NSRange(location: NSNotFound, length: 0)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard markedText.length > 0 else { return nil }
        let clamped = NSRange(location: 0, length: markedText.length)
        actualRange?.pointee = clamped
        return markedText
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        var x = 0.0, y = 0.0, width = imeCellWidth, height = imeCellHeight
        if let point = surfaceHandle?.imePoint() {
            x = point.x; y = point.y; width = point.width; height = point.height
        }
        // Ghostty reports a top-left origin; AppKit's IME candidate window expects bottom-left.
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: max(height, imeCellHeight))
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    override func doCommand(by selector: Selector) {
        // Intentionally empty: keeps AppKit from beeping on keys that map to no-op commands (e.g.
        // insertNewline:/deleteBackward:). Those keys are forwarded as libghostty key events in
        // forwardKeyDown, not via the command path.
    }
}
