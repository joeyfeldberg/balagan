import Foundation

/// Installs (or refreshes) a symlink to the bundled `balagan` CLI in a PATH directory, so users can
/// run `balagan` after launching the app — the way cmux installs its CLI. Best-effort and
/// idempotent: re-running is a no-op when the link is already correct, and a stale link (e.g. the app
/// moved) is updated. **Never** clobbers a real (non-symlink) file of the same name.
public enum ControlCLIInstaller {
    public enum Outcome: Equatable, Sendable {
        /// Created our symlink, or replaced a stale one of ours.
        case installed
        /// The symlink already points at `cliPath` — nothing to do.
        case alreadyCurrent
        /// The directory doesn't exist (caller should try the next candidate).
        case directoryMissing
        /// The directory exists but isn't writable (caller should try the next candidate).
        case notWritable
        /// A real file/binary of the same name lives here — left untouched (try the next candidate).
        case realFilePresent
        /// An unexpected filesystem error.
        case failed(String)
    }

    /// Attempt to install `cliPath` as `<directory>/<linkName>`.
    public static func installLink(
        cliPath: String,
        directory: String,
        linkName: String = "balagan",
        fileManager: FileManager = .default
    ) -> Outcome {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .directoryMissing
        }

        let linkPath = directory + "/" + linkName

        // Already pointing where we want? (also handles the common re-launch no-op)
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath), destination == cliPath {
            return .alreadyCurrent
        }

        // Inspect any existing entry at the link path. attributesOfItem lstat's (doesn't follow links),
        // so a dangling/stale symlink still reports as .typeSymbolicLink.
        if let type = (try? fileManager.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType {
            switch type {
            case .typeSymbolicLink:
                guard fileManager.isWritableFile(atPath: directory) else { return .notWritable }
                do {
                    try fileManager.removeItem(atPath: linkPath)
                } catch {
                    return .failed("could not replace stale symlink: \(error)")
                }
            default:
                // A real file/binary we didn't create (the user's own tool, a Homebrew binary, …).
                return .realFilePresent
            }
        }

        guard fileManager.isWritableFile(atPath: directory) else { return .notWritable }
        do {
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: cliPath)
            return .installed
        } catch {
            return .failed("\(error)")
        }
    }
}
