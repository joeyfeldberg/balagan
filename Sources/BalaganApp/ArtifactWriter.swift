import Foundation

/// Shared writer for the app's on-disk artifacts. Encapsulates the recurring boilerplate:
/// create the directory → serialize → write atomically → on any failure append a human-readable
/// line to a sibling error log.
///
/// Artifact filenames and payload keys are contract strings (the smoke harness and UI driver match
/// on them), so callers pass the filename, error-log name, and failure-message prefix explicitly —
/// this helper only owns the mechanical write + error-log dance, never the naming.
enum ArtifactWriter {
    /// Writes a `JSONSerialization`-compatible dictionary as pretty-printed, key-sorted JSON.
    static func writeJSON(
        _ object: [String: Any],
        to directory: URL,
        as filename: String,
        errorLog: String,
        failureMessage: String
    ) {
        write(directory: directory, filename: filename, errorLog: errorLog, failureMessage: failureMessage) {
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        }
    }

    /// Writes an `Encodable` value as pretty-printed, key-sorted JSON.
    static func writeJSON(
        _ value: some Encodable,
        to directory: URL,
        as filename: String,
        errorLog: String,
        failureMessage: String
    ) {
        write(directory: directory, filename: filename, errorLog: errorLog, failureMessage: failureMessage) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(value)
        }
    }

    private static func write(
        directory: URL,
        filename: String,
        errorLog: String,
        failureMessage: String,
        makeData: () throws -> Data
    ) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try makeData()
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        } catch {
            let message = "\(failureMessage): \(error)\n"
            try? message.write(
                to: directory.appendingPathComponent(errorLog),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
