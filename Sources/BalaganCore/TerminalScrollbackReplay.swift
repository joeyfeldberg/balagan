import Foundation

/// Replays a plain-shell surface's captured scrollback when it's reopened (e.g. after relaunch), so
/// the terminal comes back showing where you left off instead of blank — cmux's trick, adapted.
///
/// libghostty owns the PTY and runs a single `command`; we can't paint the screen directly. So we
/// generate a tiny launcher script that prints the saved scrollback, then `exec`s the real shell,
/// and point the surface at `/bin/sh <launcher>`. Our scrollback is already plaintext (the captured
/// visible screen), so there are no escape sequences to strip.
public enum TerminalScrollbackReplay {
    private static var baseDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("balagan-scrollback", isDirectory: true)
    }

    /// Clears stale launcher/scrollback files at app launch. The authoritative scrollback lives in
    /// the persisted board snapshot; these temp files are regenerated per session on demand.
    public static func reset() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    /// Builds a launcher that replays `scrollback` then execs `shellPath`, returning the libghostty
    /// `command` string (`/bin/sh <launcher>`). Returns nil (caller falls back to a plain shell) if
    /// the scrollback is empty or the temp files can't be written.
    public static func launchCommand(surfaceID: Surface.ID, scrollback: String, shellPath: String) -> String? {
        let trimmed = scrollback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let safeName = safeComponent(surfaceID)
        let scrollbackURL = baseDirectory.appendingPathComponent("\(safeName).scrollback")
        let launcherURL = baseDirectory.appendingPathComponent("\(safeName).sh")

        // Keep paths space-free (temp dir + sanitized id) so libghostty tokenizes `/bin/sh <path>`
        // into two args regardless of how it parses the command string.
        guard scrollbackURL.path.contains(" ") == false, launcherURL.path.contains(" ") == false else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            try scrollback.write(to: scrollbackURL, atomically: true, encoding: .utf8)
            // exec the shell as a LOGIN shell (-l) so it sources ~/.zprofile etc. — otherwise PATH
            // setup like Homebrew's `eval "$(brew shellenv)"` is skipped and ~/.zshrc errors with
            // "command not found: brew / starship / …" on the restored terminal.
            let script = """
            #!/bin/sh
            cat \(scrollbackURL.path.shellQuoted) 2>/dev/null
            rm -f \(scrollbackURL.path.shellQuoted)
            exec \(shellPath.shellQuoted) -l
            """
            try script.write(to: launcherURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        return "/bin/sh \(launcherURL.path)"
    }

    private static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(mapped)
        return result.isEmpty ? "surface" : result
    }
}
