import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    static func physicalVirtualKey(for character: Character) -> CGKeyCode? {
        switch character {
        case "a": return 0
        case "s": return 1
        case "d": return 2
        case "f": return 3
        case "h": return 4
        case "g": return 5
        case "z": return 6
        case "x": return 7
        case "c": return 8
        case "v": return 9
        case "b": return 11
        case "q": return 12
        case "w": return 13
        case "e": return 14
        case "r": return 15
        case "y": return 16
        case "t": return 17
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "6": return 22
        case "5": return 23
        case "9": return 25
        case "7": return 26
        case "8": return 28
        case "0": return 29
        case "o": return 31
        case "u": return 32
        case "i": return 34
        case "p": return 35
        case "l": return 37
        case "j": return 38
        case "k": return 40
        case "n": return 45
        case "m": return 46
        case "/": return 44
        case "-": return 27
        case " ": return 49
        default: return nil
        }
    }

    func postCommandKey(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags = CGEventFlags.maskCommand
        CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)?.post(tap: .cghidEventTap)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)?.post(tap: .cghidEventTap)
        sleep(milliseconds: 40)
    }

    func postModifiedKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        releaseModifierKeys()
        let source = CGEventSource(stateID: .combinedSessionState)
        let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
            (.maskCommand, 55),
            (.maskShift, 56),
            (.maskAlternate, 58),
            (.maskControl, 59),
        ]

        for (flag, key) in modifierKeys where flags.contains(flag) {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)

        for (flag, key) in modifierKeys.reversed() where flags.contains(flag) {
            CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        }
        sleep(milliseconds: 250)
    }

    func postKey(virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?.post(tap: .cghidEventTap)
    }

    func releaseModifierKeys() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for virtualKey in [CGKeyCode(55), 54, 56, 60, 58, 61, 59, 62] {
            CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?.post(tap: .cghidEventTap)
        }
        sleep(milliseconds: 40)
    }

    func postUnicode(_ value: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let characters = Array(value.utf16)
        guard characters.isEmpty == false else {
            return
        }

        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        characters.withUnsafeBufferPointer { buffer in
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func postRightClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)?
            .post(tap: .cghidEventTap)
    }

    func postLeftClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func postDoubleClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for clickState in 1...2 {
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up?.post(tap: .cghidEventTap)
            sleep(milliseconds: 80)
        }
    }

    func postDrag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        sleep(milliseconds: 250)

        let liftPoint = CGPoint(x: start.x + 8, y: start.y + 8)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: liftPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        sleep(milliseconds: 450)

        for step in 1...36 {
            let progress = CGFloat(step) / 36
            let point = CGPoint(
                x: liftPoint.x + (end.x - liftPoint.x) * progress,
                y: liftPoint.y + (end.y - liftPoint.y) * progress
            )
            CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            sleep(milliseconds: 20)
        }
        sleep(milliseconds: 200)

        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        sleep(milliseconds: 400)
    }
}
