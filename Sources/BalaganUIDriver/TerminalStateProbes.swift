import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    func visibleTextURL(surfaceID: String) -> URL {
        artifactDirectory.appendingPathComponent("libghostty-terminal-visible-text-\(surfaceID.safeArtifactComponent).txt")
    }

    func waitForVisibleText(surfaceID: String, containing token: String, timeout: TimeInterval) throws {
        let url = visibleTextURL(surfaceID: surfaceID)
        try waitUntil(
            timeout: timeout,
            timeoutMessage: "visible terminal text \(url.path) to contain \(token)"
        ) { () -> Bool? in
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(token) else {
                return nil
            }
            return true
        }
    }

    func readVisibleText(surfaceID: String) throws -> String {
        let url = visibleTextURL(surfaceID: surfaceID)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DriverError.artifactWriteFailed(error)
        }
    }

    func waitForCleanPrompt(surfaceID: String, timeout: TimeInterval) throws {
        let text = try waitUntil(
            timeout: timeout,
            timeoutMessage: "clean prompt visible terminal text for \(surfaceID)"
        ) { () -> String? in
            guard let text = try? readVisibleText(surfaceID: surfaceID), text.isEmpty == false else {
                return nil
            }
            return text
        }
        try assertNoSessionSuffixPromptLeak(text, surfaceID: surfaceID)
    }

    private func assertNoSessionSuffixPromptLeak(_ text: String, surfaceID: String) throws {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let promptLeakPattern = #"[#%>$]\s+s\d{3}\b"#
        let leakedLines = lines.filter {
            $0.range(of: promptLeakPattern, options: .regularExpression) != nil
        }

        guard leakedLines.isEmpty else {
            throw DriverError.staleRenderedPixels(
                "session suffix leaked into reopened terminal prompt for \(surfaceID): \(leakedLines.joined(separator: " | "))"
            )
        }
    }

    private func extractShellProbe(_ probe: String, from text: String) throws -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let line = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(probe) }) else {
            throw DriverError.timeout("shell probe \(probe)")
        }

        let suffix = line.components(separatedBy: probe).dropFirst().joined(separator: probe)
        let shell = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shell.isEmpty == false else {
            throw DriverError.timeout("shell probe output after \(probe)")
        }
        return shell
    }

    func waitForShellProbeOutput(_ probe: String, surfaceID: String, timeout: TimeInterval) throws -> String {
        try waitUntil(timeout: timeout, timeoutMessage: "shell probe output \(probe) for \(surfaceID)") {
            guard let text = try? readVisibleText(surfaceID: surfaceID),
                  let shell = try? extractShellProbe(probe, from: text)
            else {
                return nil
            }
            return shell
        }
    }

    func waitForFile(_ url: URL, timeout: TimeInterval) throws {
        try waitUntil(timeout: timeout, timeoutMessage: url.path) { () -> Bool? in
            FileManager.default.fileExists(atPath: url.path) ? true : nil
        }
    }

    func waitForResumeRequest(
        surfaceID: String,
        expectedCommand: String,
        timeout: TimeInterval
    ) throws {
        let url = artifactDirectory.appendingPathComponent("resume-request.json")
        try waitUntil(timeout: timeout, timeoutMessage: "resume request \(surfaceID) \(expectedCommand)") { () -> Bool? in
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  payload["surfaceID"] as? String == surfaceID,
                  payload["displayCommand"] as? String == expectedCommand
            else {
                return nil
            }
            return true
        }
    }

    func terminalIdentifiers(surfaceID: String) -> [String] {
        [
            "libghostty-terminal-\(surfaceID)",
            "terminal-pane-\(surfaceID)",
        ]
    }

    func liveTerminalIdentifiers(forTaskID taskID: String) -> [String] {
        terminalIdentifiers(surfaceID: "surface-\(taskID)-main")
    }

    /// A per-run token (seconds since epoch + pid) used to keep typed markers unique across runs.
    func uniqueToken() -> String {
        "\(Int(Date().timeIntervalSince1970))\(ProcessInfo.processInfo.processIdentifier)"
    }

    func waitForTerminalHostMounted(surfaceID: String) throws {
        try waitForFile(
            artifactDirectory.appendingPathComponent("libghostty-terminal-\(surfaceID).json"),
            timeout: 10
        )
    }
}
