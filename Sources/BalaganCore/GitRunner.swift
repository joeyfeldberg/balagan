import Foundation

/// Runs `/usr/bin/git` and collects its stdout. It reads the pipe *before* waiting for git to exit:
/// waiting first deadlocks once the output fills the pipe buffer (~64 KB), since git then blocks
/// writing while we block waiting. Stderr is discarded for the same reason.
enum GitRunner {
    struct Output {
        var text: String
        /// Stdout went past `limit` and the rest was dropped.
        var truncated: Bool
    }

    /// Stdout of a successful (exit 0) run, or nil when git can't launch or fails.
    static func run(
        _ arguments: [String],
        in directory: String,
        environment: [String: String]? = nil,
        limit: Int = .max
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        if let environment { process.environment = environment }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        var data = Data()
        var truncated = false
        let handle = stdout.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 64 * 1024), chunk.isEmpty == false {
            if data.count < limit {
                data.append(chunk.prefix(limit - data.count))
            } else {
                truncated = true
            }
        }
        if data.count >= limit { truncated = true }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Output(text: String(decoding: data, as: UTF8.self), truncated: truncated)
    }
}
