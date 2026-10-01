import AppKit
import ApplicationServices
import Darwin
import Foundation
import BalaganCore

extension NativeFlowDriver {
    // Single driver instance per process run on one thread; the shared formatter is only ever
    // read via `.string(from:)`, so the unchecked static is safe.
    nonisolated(unsafe) static let recordedAtFormatter = ISO8601DateFormatter()

    /// Shared flow epilogue: writes the final accessibility dump, then the driver JSON with the
    /// common `schemaVersion`/`flow`/`status`/`recordedAt` keys plus any flow-specific `extra` keys.
    func finishFlow(_ extra: [String: Any] = [:]) throws {
        try writeAccessibilityDump(fileName: flow.finalDumpName)

        var payload: [String: Any] = [
            "schemaVersion": 1,
            "flow": flow.name,
            "status": "completed",
            "recordedAt": Self.recordedAtFormatter.string(from: Date()),
        ]
        for (key, value) in extra {
            payload[key] = value
        }

        try writeJSONArtifact(fileName: flow.driverArtifactName, payload: payload)
    }

    private func writeJSONArtifact(fileName: String, payload: [String: Any]) throws {
        do {
            try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: artifactDirectory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            throw DriverError.artifactWriteFailed(error)
        }
    }

    static func writeArtifact(artifactDirectory: URL, fileName: String, text: String) throws {
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        try text.write(to: artifactDirectory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }
}

extension String {
    var safeArtifactComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        })
    }

    var accessibilitySlug: String {
        let scalars = trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let slug = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? "item" : slug
    }
}
