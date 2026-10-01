import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    var minimumRenderedPixelChange: Int {
        1_500
    }

    private static let minimumFontZoomPixelChange = 500

    enum FontZoomDirection {
        case increase
        case decrease
        case reset
    }

    struct FontZoomEvidence {
        var evidenceName: String
        var action: String
        var handled: Bool
        var beforeCellHeight: Int
        var afterCellHeight: Int
        var beforeCellWidth: Int
        var afterCellWidth: Int
        var changedPixels: Int
        var beforeScreenshotPath: String
        var afterScreenshotPath: String
        var changedSurfaceIDs: [String]
        var appFontSize: Double?

        var artifactPayload: [String: Any] {
            [
                "evidenceName": evidenceName,
                "action": action,
                "handled": handled,
                "beforeCellHeightPx": beforeCellHeight,
                "afterCellHeightPx": afterCellHeight,
                "beforeCellWidthPx": beforeCellWidth,
                "afterCellWidthPx": afterCellWidth,
                "changedPixels": changedPixels,
                "minimumChangedPixels": NativeFlowDriver.minimumFontZoomPixelChange,
                "beforeScreenshotPath": beforeScreenshotPath,
                "afterScreenshotPath": afterScreenshotPath,
                "changedSurfaceIDs": changedSurfaceIDs,
                "appFontSize": appFontSize as Any? ?? NSNull(),
            ]
        }
    }

    func removeFontZoomEvidence(surfaceID: String, evidenceName: String) {
        let url = artifactDirectory.appendingPathComponent(
            "libghostty-terminal-font-zoom-\(surfaceID.safeArtifactComponent)-\(evidenceName).json"
        )
        try? FileManager.default.removeItem(at: url)
    }

    private struct DecodedFontZoomArtifact {
        let payload: [String: Any]
        let action: String
        let handled: Bool
        let beforeCellHeight: Int
        let afterCellHeight: Int
        let beforeCellWidth: Int
        let afterCellWidth: Int
        let beforePath: String
        let afterPath: String
    }

    private func decodeFontZoomArtifact(at url: URL) throws -> DecodedFontZoomArtifact {
        let data = try Data(contentsOf: url)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = payload["action"] as? String,
              let handled = payload["handled"] as? Bool,
              let beforeSize = payload["beforeSize"] as? [String: Any],
              let afterSize = payload["afterSize"] as? [String: Any],
              let beforeCellHeight = beforeSize["cellHeightPx"] as? Int,
              let afterCellHeight = afterSize["cellHeightPx"] as? Int,
              let beforeCellWidth = beforeSize["cellWidthPx"] as? Int,
              let afterCellWidth = afterSize["cellWidthPx"] as? Int,
              let beforePath = payload["beforeScreenshotPath"] as? String,
              let afterPath = payload["afterScreenshotPath"] as? String
        else {
            throw DriverError.artifactWriteFailed(
                NSError(domain: "BalaganUIDriver", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "invalid font zoom evidence artifact \(url.path)",
                ])
            )
        }

        return DecodedFontZoomArtifact(
            payload: payload,
            action: action,
            handled: handled,
            beforeCellHeight: beforeCellHeight,
            afterCellHeight: afterCellHeight,
            beforeCellWidth: beforeCellWidth,
            afterCellWidth: afterCellWidth,
            beforePath: beforePath,
            afterPath: afterPath
        )
    }

    func waitForFontZoomEvidence(
        surfaceID: String,
        evidenceName: String,
        expectedDirection: FontZoomDirection,
        expectedChangedSurfaceIDs: [String] = []
    ) throws -> FontZoomEvidence {
        let url = artifactDirectory.appendingPathComponent(
            "libghostty-terminal-font-zoom-\(surfaceID.safeArtifactComponent)-\(evidenceName).json"
        )
        try waitForFile(url, timeout: 5)

        let decoded = try decodeFontZoomArtifact(at: url)

        guard decoded.handled else {
            throw DriverError.staleRenderedPixels("\(evidenceName) Ghostty binding action was not handled")
        }

        let hostResults = decoded.payload["hostResults"] as? [[String: Any]] ?? []
        let changedSurfaceIDs = try changedFontZoomSurfaceIDs(
            hostResults: hostResults,
            expectedDirection: expectedDirection
        )
        for expectedSurfaceID in expectedChangedSurfaceIDs {
            guard changedSurfaceIDs.contains(expectedSurfaceID) else {
                throw DriverError.staleRenderedPixels(
                    "\(evidenceName) did not change expected mounted surface \(expectedSurfaceID); changed=\(changedSurfaceIDs)"
                )
            }
        }

        switch expectedDirection {
        case .increase:
            guard decoded.afterCellHeight > decoded.beforeCellHeight else {
                throw DriverError.staleRenderedPixels(
                    "\(evidenceName) cell height did not increase: before=\(decoded.beforeCellHeight) after=\(decoded.afterCellHeight)"
                )
            }
        case .decrease, .reset:
            guard decoded.afterCellHeight < decoded.beforeCellHeight else {
                throw DriverError.staleRenderedPixels(
                    "\(evidenceName) cell height did not decrease: before=\(decoded.beforeCellHeight) after=\(decoded.afterCellHeight)"
                )
            }
        }

        let beforeImage = try waitForRenderedSnapshot(url: URL(fileURLWithPath: decoded.beforePath), timeout: 1)
        let afterImage = try waitForRenderedSnapshot(url: URL(fileURLWithPath: decoded.afterPath), timeout: 1)
        let diff = try renderedPixelDifference(before: beforeImage, after: afterImage)
        guard diff.changedPixels >= Self.minimumFontZoomPixelChange else {
            throw DriverError.staleRenderedPixels(
                "\(evidenceName) changed \(diff.changedPixels) pixels after font zoom, expected at least 500"
            )
        }

        return FontZoomEvidence(
            evidenceName: evidenceName,
            action: decoded.action,
            handled: decoded.handled,
            beforeCellHeight: decoded.beforeCellHeight,
            afterCellHeight: decoded.afterCellHeight,
            beforeCellWidth: decoded.beforeCellWidth,
            afterCellWidth: decoded.afterCellWidth,
            changedPixels: diff.changedPixels,
            beforeScreenshotPath: decoded.beforePath,
            afterScreenshotPath: decoded.afterPath,
            changedSurfaceIDs: changedSurfaceIDs,
            appFontSize: decoded.payload["appFontSize"] as? Double
        )
    }

    private func changedFontZoomSurfaceIDs(
        hostResults: [[String: Any]],
        expectedDirection: FontZoomDirection
    ) throws -> [String] {
        try hostResults.compactMap { result in
            guard let surfaceID = result["surfaceID"] as? String,
                  let handled = result["handled"] as? Bool,
                  let beforeSize = result["beforeSize"] as? [String: Any],
                  let afterSize = result["afterSize"] as? [String: Any],
                  let beforeCellHeight = beforeSize["cellHeightPx"] as? Int,
                  let afterCellHeight = afterSize["cellHeightPx"] as? Int
            else {
                return nil
            }

            guard handled else {
                throw DriverError.staleRenderedPixels("\(surfaceID) Ghostty binding action was not handled")
            }

            switch expectedDirection {
            case .increase:
                return afterCellHeight > beforeCellHeight ? surfaceID : nil
            case .decrease, .reset:
                return afterCellHeight < beforeCellHeight ? surfaceID : nil
            }
        }
    }

    func waitForTerminalHostFontSize(
        surfaceID: String,
        expectedFontSize: Double,
        timeout: TimeInterval
    ) throws -> Double {
        let url = artifactDirectory.appendingPathComponent("libghostty-terminal-\(surfaceID).json")
        return try waitUntil(
            timeout: timeout,
            timeoutMessage: "terminal host \(surfaceID) font size \(expectedFontSize)"
        ) {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fontSize = payload["fontSize"] as? Double,
                  fontSize == expectedFontSize
            else {
                return nil
            }
            return fontSize
        }
    }

    func renderedPixelDifference(before: CGImage, after: CGImage) throws -> (changedPixels: Int, width: Int, height: Int) {
        let width = min(before.width, after.width)
        let height = min(before.height, after.height)
        guard width > 0, height > 0 else {
            throw DriverError.screenshotFailed("captured screenshots have empty dimensions")
        }

        let beforePixels = try rgbaPixels(from: before, width: width, height: height)
        let afterPixels = try rgbaPixels(from: after, width: width, height: height)
        var changedPixels = 0
        for index in stride(from: 0, to: beforePixels.count, by: 4) {
            let redDelta = abs(Int(beforePixels[index]) - Int(afterPixels[index]))
            let greenDelta = abs(Int(beforePixels[index + 1]) - Int(afterPixels[index + 1]))
            let blueDelta = abs(Int(beforePixels[index + 2]) - Int(afterPixels[index + 2]))
            if redDelta > 12 || greenDelta > 12 || blueDelta > 12 {
                changedPixels += 1
            }
        }
        return (changedPixels, width, height)
    }

    private func rgbaPixels(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DriverError.screenshotFailed("could not create RGBA bitmap context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    func renderedSnapshotURL(surfaceID: String, phase: String) -> URL {
        artifactDirectory.appendingPathComponent(
            "libghostty-terminal-rendered-view-\(surfaceID.safeArtifactComponent)-\(phase).png"
        )
    }

    func waitForRenderedSnapshot(url: URL, timeout: TimeInterval) throws -> CGImage {
        guard let image = poll(timeout: timeout, interval: 50, { () -> CGImage? in
            guard FileManager.default.fileExists(atPath: url.path),
                  let nsImage = NSImage(contentsOf: url),
                  let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                return nil
            }
            return image
        }) else {
            throw DriverError.timeout("rendered terminal snapshot \(url.path)")
        }

        return image
    }
}
