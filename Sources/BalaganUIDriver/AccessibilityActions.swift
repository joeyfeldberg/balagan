import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func focusApplication() throws {
        let error = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard error == .success else {
            throw DriverError.actionFailed("application-frontmost", error)
        }
        sleep(milliseconds: 300)
    }

    func press(identifier: String) throws {
        let element = try waitForElement(identifier: identifier, timeout: 5)
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            throw DriverError.actionFailed(identifier, error)
        }
        sleep(milliseconds: 250)
    }

    func click(identifier: String) throws {
        let element = try waitForElement(identifier: identifier, timeout: 10)
        let point = try center(of: element)
        postLeftClick(at: point)
        sleep(milliseconds: 300)
    }

    func clickTrailingEdge(identifier: String) throws {
        let element = try waitForElement(identifier: identifier, timeout: 10)
        let point = try pointNearTrailingEdge(of: element)
        postLeftClick(at: point)
        sleep(milliseconds: 300)
    }

    func doubleClick(identifier: String) throws {
        let element = try waitForElement(identifier: identifier, timeout: 10)
        let point = try center(of: element)
        postDoubleClick(at: point)
        sleep(milliseconds: 300)
    }

    func clickAny(identifiers: [String]) throws {
        let element = try waitForAnyElement(identifiers: identifiers, timeout: 10)
        let point = try center(of: element)
        postLeftClick(at: point)
        sleep(milliseconds: 300)
    }

    func pressAny(identifiers: [String], titles: [String]) throws {
        for identifier in identifiers {
            if let element = findElement(identifier: identifier) {
                let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
                guard error == .success else {
                    throw DriverError.actionFailed(identifier, error)
                }
                sleep(milliseconds: 250)
                return
            }
        }

        for title in titles {
            if let element = findElement(titled: title) {
                let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
                guard error == .success else {
                    throw DriverError.actionFailed(title, error)
                }
                sleep(milliseconds: 250)
                return
            }
        }

        try? writeAccessibilityDump(fileName: flow.lookupDumpName)
        throw DriverError.missingElement("one of identifiers \(identifiers.joined(separator: ", ")) or titles \(titles.joined(separator: ", "))")
    }

    func showContextMenu(identifier: String, expectedTitles: [String] = ["Edit Task", "Delete Task"]) throws {
        let element = try waitForElement(identifier: identifier, timeout: 5)
        let menuError = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
        if menuError == .success {
            sleep(milliseconds: 150)
        } else {
            let point = try center(of: element)
            postRightClick(at: point)
            sleep(milliseconds: 250)
        }

        if expectedTitles.contains(where: { findElement(titled: $0) != nil }) == false {
            let point = try center(of: element)
            postRightClick(at: point)
            sleep(milliseconds: 250)
        }
    }

    func dragElement(identifier: String, toIdentifier targetIdentifier: String) throws {
        let source = try waitForElement(identifier: identifier, timeout: 5)
        let target = try waitForElement(identifier: targetIdentifier, timeout: 5)
        let start = try center(of: source)
        let end = try center(of: target)
        postDrag(from: start, to: end)
        sleep(milliseconds: 500)
    }

    func setTextIfPresent(identifier: String, value: String) throws {
        guard findElement(identifier: identifier) != nil else {
            return
        }
        try setText(identifier: identifier, value: value)
    }

    func setText(identifier: String, value: String) throws {
        let element = try waitForElement(identifier: identifier, timeout: 5)
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if error == .success {
            sleep(milliseconds: 100)
            return
        }

        let focusError = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focusError == .success else {
            throw DriverError.textEntryFailed(identifier, error)
        }

        paste(value)
        sleep(milliseconds: 150)
    }

    func selectPicker(identifier: String, value: String) throws {
        let element = try waitForElement(identifier: identifier, timeout: 5)

        if let item = findElement(in: element, depth: 0, matching: { elementMatchesLabel($0, value) }) {
            let itemError = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if itemError == .success {
                sleep(milliseconds: 250)
                return
            }
        }

        let setError = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        if setError == .success {
            return
        }

        let pressError = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard pressError == .success else {
            throw DriverError.actionFailed(identifier, pressError)
        }
        sleep(milliseconds: 250)

        if let item = findElement(in: element, depth: 0, matching: { elementMatchesLabel($0, value) }) {
            let itemError = AXUIElementPerformAction(item, kAXPressAction as CFString)
            if itemError == .success {
                return
            }
        }

        // Deterministic fallback for the status picker when the task starts in Todo.
        for _ in 0..<4 {
            postKey(virtualKey: 125)
            sleep(milliseconds: 50)
        }
        postKey(virtualKey: 36)
        sleep(milliseconds: 250)

        if let currentValue = stringAttribute(element, kAXValueAttribute as CFString),
           currentValue.contains(value) {
            return
        }

        throw DriverError.pickerSelectionFailed(identifier, value)
    }

}
