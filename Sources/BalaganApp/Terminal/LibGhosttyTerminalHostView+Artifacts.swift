import AppKit
import BalaganCore

extension LibGhosttyTerminalHostView {
    /// Terminal text for the persistence overlay. `fresh` reads from libghostty (expensive: each
    /// read leaks ~3 KB inside libghostty 1.3.1 — see `recordVisibleTextIfNeeded`); `fresh: false`
    /// returns the cache, which the autosaver's periodic fresh capture keeps at most one floor
    /// interval (30 s) stale.
    func visibleTextSnapshot(fresh: Bool) -> String? {
        if fresh, let text = try? readVisibleTextCachingIfPresent(), text.isEmpty == false {
            return text
        }

        return lastVisibleText
    }

    /// Reads the surface's current visible text and, on a non-empty read, refreshes the
    /// `lastVisibleText` cache. Throwing so the throttled recorder can log a read failure; the snapshot
    /// accessor swallows via `try?` and falls back to the cache. Returns the freshly read text
    /// (empty string when there's no surface).
    private func readVisibleTextCachingIfPresent() throws -> String {
        let text = try surfaceHandle?.readVisibleText() ?? ""
        if text.isEmpty == false {
            lastVisibleText = text
        }
        return text
    }

    @MainActor
    func performFontZoomBindingAction(action: String) -> (handled: Bool, beforeSize: LibGhosttySurfaceSize?, afterSize: LibGhosttySurfaceSize?)? {
        guard let surfaceHandle else {
            return nil
        }

        if isActive {
            ensureSurfaceFocusedForInput()
        }
        let beforeSize = surfaceHandle.size()
        let handled = surfaceHandle.performBindingAction(action)
        resizeSurface()
        surfaceHandle.refresh()
        requestRenderFrame()
        let afterSize = surfaceHandle.size()
        return (handled: handled, beforeSize: beforeSize, afterSize: afterSize)
    }

    @MainActor
    func recordSharedFontZoomEvidence(
        evidenceName: String,
        action: String,
        appFontSize: Float,
        beforeURL: URL?,
        afterURL: URL?,
        hostResults: [TerminalFontZoomHostResult]
    ) {
        let activeResult = currentSurfaceID.flatMap { surfaceID in
            hostResults.first { $0.surfaceID == surfaceID }
        }
        recordFontZoomEvidence(
            evidenceName: evidenceName,
            action: action,
            handled: activeResult?.handled ?? false,
            beforeSize: activeResult?.beforeSize,
            afterSize: activeResult?.afterSize,
            beforeURL: beforeURL,
            afterURL: afterURL,
            appFontSize: appFontSize,
            hostResults: hostResults
        )
    }

    @MainActor
    func recordFontZoomSnapshot(evidenceName: String, phase: String) -> URL? {
        guard let url = renderedFontZoomSnapshotURL(evidenceName: evidenceName, phase: phase) else {
            return nil
        }

        try? FileManager.default.removeItem(at: url)
        recordRenderedInputSnapshot(to: url)
        return url
    }

    private func renderedFontZoomSnapshotURL(evidenceName: String, phase: String) -> URL? {
        guard let artifactDirectory = currentArtifactDirectory,
              let surfaceID = currentSurfaceID
        else {
            return nil
        }

        return artifactDirectory.appendingPathComponent(
            "libghostty-terminal-font-zoom-\(safeArtifactComponent(surfaceID))-\(evidenceName)-\(phase).png"
        )
    }

    private func recordFontZoomEvidence(
        evidenceName: String,
        action: String,
        handled: Bool,
        beforeSize: LibGhosttySurfaceSize?,
        afterSize: LibGhosttySurfaceSize?,
        beforeURL: URL?,
        afterURL: URL?,
        appFontSize: Float,
        hostResults: [TerminalFontZoomHostResult]
    ) {
        guard let artifactDirectory = currentArtifactDirectory,
              let surfaceID = currentSurfaceID
        else {
            return
        }

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "surfaceID": surfaceID,
            "evidenceName": evidenceName,
            "action": action,
            "handled": handled,
            "beforeSize": beforeSize?.artifactPayload ?? NSNull(),
            "afterSize": afterSize?.artifactPayload ?? NSNull(),
            "beforeScreenshotPath": beforeURL?.path as Any? ?? NSNull(),
            "afterScreenshotPath": afterURL?.path as Any? ?? NSNull(),
            "appFontSize": appFontSize,
            "hostResults": hostResults.map(\.artifactPayload),
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: "libghostty-terminal-font-zoom-\(safeArtifactComponent(surfaceID))-\(evidenceName).json",
            errorLog: "libghostty-terminal-font-zoom-error.log",
            failureMessage: "Failed to record terminal font zoom evidence"
        )
    }

    func recordRenderedInputSnapshotBeforeIfNeeded() {
        guard let url = renderedInputSnapshotURL(phase: "before"),
              FileManager.default.fileExists(atPath: url.path) == false
        else {
            return
        }

        recordRenderedInputSnapshot(to: url)
    }

    func recordRenderedInputSnapshotAfter() {
        guard let url = renderedInputSnapshotURL(phase: "after") else {
            return
        }

        recordRenderedInputSnapshot(to: url)
    }

    private func renderedInputSnapshotURL(phase: String) -> URL? {
        guard let artifactDirectory = currentArtifactDirectory,
              let surfaceID = currentSurfaceID
        else {
            return nil
        }

        return artifactDirectory.appendingPathComponent(
            "libghostty-terminal-rendered-view-\(safeArtifactComponent(surfaceID))-\(phase).png"
        )
    }

    private func recordRenderedInputSnapshot(to url: URL) {
        guard bounds.width > 1, bounds.height > 1,
              let representation = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return
        }

        cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            let message = "Failed to record rendered terminal snapshot: \(error)\n"
            try? message.write(
                to: url.deletingLastPathComponent().appendingPathComponent("libghostty-terminal-rendered-view-error.log"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func recordVisibleTextIfNeeded() {
        guard isActive,
              surfaceHandle != nil,
              let surfaceID = currentSurfaceID
        else {
            return
        }

        // Reading visible text is NOT free: ghostty_surface_read_text leaks ~3 KB inside
        // libghostty 1.3.1 on every call (leaks-verified; free_text doesn't release it), and at the
        // render loop's 0.15 s cadence that compounded to a 28 GB footprint in a day. Only read when
        // the text is actually consumed: watching for the ended-process prompt after the child
        // exited, or recording harness artifacts. Autosave reads its own snapshot at save time.
        let watchingForEndedPrompt = autoCloseAfterEndedProcessPrompt
            && processExitDetected
            && didRequestEndedProcessAutoClose == false
        guard watchingForEndedPrompt || currentArtifactDirectory != nil else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastVisibleTextWrite) >= 0.15 else {
            return
        }
        lastVisibleTextWrite = now

        do {
            let previous = lastVisibleText
            let text = try readVisibleTextCachingIfPresent()
            if shouldAutoClose(forVisibleText: text) {
                requestEndedProcessAutoClose()
                return
            }
            guard text != previous else {
                return
            }
            // Cache unconditionally (including an empty read), unlike the snapshot accessor which
            // only caches non-empty text.
            lastVisibleText = text

            guard let artifactDirectory = currentArtifactDirectory else {
                return
            }

            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            try text.write(
                to: artifactDirectory.appendingPathComponent("libghostty-terminal-visible-text-\(safeArtifactComponent(surfaceID)).txt"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            guard didRecordVisibleTextReadFailure == false else {
                return
            }
            didRecordVisibleTextReadFailure = true

            let message = "Failed to read libghostty visible text for \(surfaceID): \(error)\n"
            guard let artifactDirectory = currentArtifactDirectory else {
                return
            }
            try? FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            try? message.write(
                to: artifactDirectory.appendingPathComponent("libghostty-terminal-visible-text-\(safeArtifactComponent(surfaceID))-error.log"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    private func shouldAutoClose(forVisibleText text: String) -> Bool {
        guard autoCloseAfterEndedProcessPrompt else {
            return false
        }

        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let hasPressAnyKeyPrompt = normalized.contains("press any key")
        let hasCloseTerminalText = normalized.contains("close terminal")
            || normalized.contains("close the terminal")
            || normalized.contains("close window")
            || normalized.contains("close the window")
        let hasEndedProcessText = normalized.contains("process ended")
            || normalized.contains("process exited")

        return hasPressAnyKeyPrompt && (hasCloseTerminalText || hasEndedProcessText)
    }

    func writeEndedProcessAutoCloseArtifact(sessionKey: TerminalHostKey) {
        guard let artifactDirectory = currentArtifactDirectory else {
            return
        }

        let payload: [String: Any] = [
            "schemaVersion": 1,
            "taskID": sessionKey.taskID,
            "surfaceID": sessionKey.surfaceID,
            "status": "auto-closed",
            "reason": "ended-process-prompt",
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: "libghostty-terminal-ended-process-autoclose-\(safeArtifactComponent(sessionKey.surfaceID)).json",
            errorLog: "libghostty-terminal-ended-process-autoclose-error.log",
            failureMessage: "Failed to record ended-process auto-close evidence"
        )
    }

    func showMessage(_ text: String) {
        stopTerminal()

        let label: NSTextField
        if let messageLabel {
            label = messageLabel
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            ])
            messageLabel = label
        }

        label.stringValue = text
        label.isHidden = false
    }

    func hideMessage() {
        messageLabel?.isHidden = true
    }

    func writeHostArtifact(
        artifactDirectory: URL?,
        surface: Surface,
        status: String,
        message: String,
        command: String?,
        fontSize: Float
    ) {
        guard let artifactDirectory else {
            return
        }

        let payload: [String: Any] = [
            "surfaceId": surface.id,
            "status": status,
            "message": message,
            "cwd": surface.cwd,
            "command": command.map { $0 as Any } ?? NSNull(),
            "fontSize": fontSize,
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        ArtifactWriter.writeJSON(
            payload,
            to: artifactDirectory,
            as: "libghostty-terminal-\(surface.id).json",
            errorLog: "libghostty-terminal-error.log",
            failureMessage: "Failed to record libghostty host artifact"
        )
    }
}
