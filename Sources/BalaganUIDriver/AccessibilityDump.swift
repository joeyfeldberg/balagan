import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func writeAccessibilityDump(fileName: String) throws {
        var lines: [String] = []
        for root in accessibilitySearchRoots() {
            appendDumpLines(for: root, depth: 0, lines: &lines)
        }

        try Self.writeArtifact(
            artifactDirectory: artifactDirectory,
            fileName: fileName,
            text: lines.joined(separator: "\n") + "\n"
        )
    }

    private func appendDumpLines(for element: AXUIElement, depth: Int, lines: inout [String]) {
        guard depth < 12 else {
            return
        }

        let indent = String(repeating: "  ", count: depth)
        let attributes = [
            ("role", kAXRoleAttribute as CFString),
            ("subrole", kAXSubroleAttribute as CFString),
            ("identifier", kAXIdentifierAttribute as CFString),
            ("title", kAXTitleAttribute as CFString),
            ("value", kAXValueAttribute as CFString),
            ("description", kAXDescriptionAttribute as CFString),
        ].compactMap { label, attribute -> String? in
            guard let value = stringAttribute(element, attribute),
                  !value.isEmpty
            else {
                return nil
            }
            return "\(label)=\(value)"
        }
        var renderedAttributes = attributes
        if let focused = boolAttribute(element, kAXFocusedAttribute as CFString), focused {
            renderedAttributes.append("focused=true")
        }

        lines.append("\(indent)\(renderedAttributes.joined(separator: " "))")

        for child in children(of: element, attributes: [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
        ]) {
            appendDumpLines(for: child, depth: depth + 1, lines: &lines)
        }
    }

}
