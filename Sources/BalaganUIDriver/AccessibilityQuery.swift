import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func findElement(identifier: String) -> AXUIElement? {
        findElement(matching: { element in
            stringAttribute(element, kAXIdentifierAttribute as CFString) == identifier
        })
    }

    func findElement(titled title: String) -> AXUIElement? {
        findElement(matching: { element in
            elementMatchesLabel(element, title)
        })
    }

    func elementMatchesLabel(_ element: AXUIElement, _ label: String) -> Bool {
        stringAttribute(element, kAXTitleAttribute as CFString) == label
            || stringAttribute(element, kAXValueAttribute as CFString) == label
            || stringAttribute(element, kAXDescriptionAttribute as CFString) == label
    }

    private func findElement(matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        for root in accessibilitySearchRoots() {
            if let match = findElement(in: root, depth: 0, matching: predicate) {
                return match
            }
        }

        return nil
    }

    func findElement(
        in element: AXUIElement,
        depth: Int,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard depth < 40 else {
            return nil
        }

        if predicate(element) {
            return element
        }

        for child in children(of: element, attributes: [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
        ]) {
            if let match = findElement(in: child, depth: depth + 1, matching: predicate) {
                return match
            }
        }

        return nil
    }

    func children(of element: AXUIElement, attributes: [CFString]) -> [AXUIElement] {
        var result: [AXUIElement] = []

        for attribute in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
                  let elements = value as? [AXUIElement]
            else {
                continue
            }
            result.append(contentsOf: elements)
        }

        return result
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    func accessibilitySearchRoots() -> [AXUIElement] {
        var roots = children(of: app, attributes: [
            kAXWindowsAttribute as CFString,
            kAXChildrenAttribute as CFString,
        ])
        roots.append(app)

        let systemWide = AXUIElementCreateSystemWide()
        for attribute in [
            kAXFocusedUIElementAttribute as CFString,
            kAXFocusedWindowAttribute as CFString,
            kAXMenuBarAttribute as CFString,
        ] {
            if let element = elementAttribute(systemWide, attribute) {
                roots.append(element)
            }
        }

        if let focusedApp = elementAttribute(systemWide, kAXFocusedApplicationAttribute as CFString) {
            roots.append(contentsOf: children(of: focusedApp, attributes: [
                kAXWindowsAttribute as CFString,
                kAXChildrenAttribute as CFString,
            ]))
        }

        return roots
    }

    func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? Bool
    }

    func center(of element: AXUIElement) throws -> CGPoint {
        let frame = try frame(of: element)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func pointNearTrailingEdge(of element: AXUIElement) throws -> CGPoint {
        let frame = try frame(of: element)
        return CGPoint(x: frame.minX + 190, y: frame.midY)
    }

    func frame(of element: AXUIElement) throws -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            throw DriverError.missingElement("position/size for element")
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            throw DriverError.missingElement("position/size value for element")
        }

        return CGRect(origin: position, size: size)
    }

}
