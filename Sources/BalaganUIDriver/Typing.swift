import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func paste(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        postCommandKey(virtualKey: 0)
        postCommandKey(virtualKey: 9)
    }

    func pasteOnly(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        postCommandKey(virtualKey: 9)
        sleep(milliseconds: 250)
    }

    func typeOnly(_ value: String) {
        for character in value {
            if character == "\n" {
                postKey(virtualKey: 36)
            } else {
                postUnicode(String(character))
            }
            sleep(milliseconds: 6)
        }
        sleep(milliseconds: 250)
    }

    @discardableResult
    func typeTouchCommand(basename: String, terminalIdentifiers: [String]) throws -> URL {
        try clickAny(identifiers: terminalIdentifiers)
        let markerURL = artifactDirectory.appendingPathComponent(basename)
        let artifactLinkURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("tb\(ProcessInfo.processInfo.processIdentifier)")
        if FileManager.default.fileExists(atPath: artifactLinkURL.path) == false {
            try FileManager.default.createSymbolicLink(at: artifactLinkURL, withDestinationURL: artifactDirectory)
        }
        try typePhysicalOnly("touch \(artifactLinkURL.appendingPathComponent(basename).path)\n")
        try waitForFile(markerURL, timeout: 10)
        return markerURL
    }

    @discardableResult
    func typeVisibleToken(
        token: String,
        surfaceID: String,
        terminalIdentifiers: [String],
        evidenceName: String,
        renderEvidence: inout [[String: Any]]
    ) throws -> String {
        try clickAny(identifiers: terminalIdentifiers)
        sleep(milliseconds: 150)
        let beforeURL = renderedSnapshotURL(surfaceID: surfaceID, phase: "before")
        let afterURL = renderedSnapshotURL(surfaceID: surfaceID, phase: "after")
        try? FileManager.default.removeItem(at: beforeURL)
        try? FileManager.default.removeItem(at: afterURL)

        try typePhysicalOnly(token)
        let beforeImage = try waitForRenderedSnapshot(url: beforeURL, timeout: 5)
        let afterImage = try waitForRenderedSnapshot(url: afterURL, timeout: 5)
        let diff = try renderedPixelDifference(before: beforeImage, after: afterImage)
        let evidenceBeforeURL = artifactDirectory.appendingPathComponent(
            "terminal-visible-typing-\(evidenceName)-rendered-before.png"
        )
        let evidenceAfterURL = artifactDirectory.appendingPathComponent(
            "terminal-visible-typing-\(evidenceName)-rendered-after.png"
        )
        try? FileManager.default.removeItem(at: evidenceBeforeURL)
        try? FileManager.default.removeItem(at: evidenceAfterURL)
        try FileManager.default.copyItem(at: beforeURL, to: evidenceBeforeURL)
        try FileManager.default.copyItem(at: afterURL, to: evidenceAfterURL)
        guard diff.changedPixels >= minimumRenderedPixelChange else {
            throw DriverError.staleRenderedPixels(
                "\(evidenceName) changed \(diff.changedPixels) pixels, expected at least \(minimumRenderedPixelChange). before=\(evidenceBeforeURL.path) after=\(evidenceAfterURL.path)"
            )
        }

        renderEvidence.append([
            "name": evidenceName,
            "beforeScreenshotPath": evidenceBeforeURL.path,
            "afterScreenshotPath": evidenceAfterURL.path,
            "changedPixels": diff.changedPixels,
            "width": diff.width,
            "height": diff.height,
            "minimumChangedPixels": minimumRenderedPixelChange,
        ])
        try waitForVisibleText(surfaceID: surfaceID, containing: token, timeout: 10)
        return token
    }

    func typePhysicalOnly(_ value: String) throws {
        releaseModifierKeys()
        for character in value {
            if character == "\n" {
                postKey(virtualKey: 36)
            } else if let virtualKey = Self.physicalVirtualKey(for: character) {
                postKey(virtualKey: virtualKey)
            } else {
                throw DriverError.unsupportedPhysicalKey(character)
            }
            sleep(milliseconds: 18)
        }
        sleep(milliseconds: 250)
    }
}
