import Foundation

/// Ghostty settings Balagan layers on top of the user's own config.
///
/// Today that's one: **force shell integration for the user's shell.** Ghostty decides whether to
/// inject integration from the command it launches, and a plain shell reopened with saved
/// scrollback launches as `/bin/sh <replay-script>` (which then `exec`s the login shell). Ghostty
/// sees `sh`, skips integration, and that shell gets no prompt marks. Without prompt marks Ghostty
/// can't tell "at the prompt" from "running something", so auto-sleep would treat every reopened
/// shell as busy, and the shell also misses integration's cwd and title reporting.
///
/// Forcing it is safe only for shells whose injection is purely environment-based, because the
/// variables survive the replay script's `exec`: zsh (`ZDOTDIR`), fish and elvish (`XDG_DATA_DIRS`).
/// Bash's injection rewrites the command line itself, so forcing it onto the replay script would
/// break the launch. A user who set `shell-integration` themselves is left alone.
public enum GhosttyConfigOverrides {
    static let envInjectedShells: Set<String> = ["zsh", "fish", "elvish"]

    /// The override lines for this user, or none.
    public static func lines(userShell: String, userConfigText: String) -> [String] {
        let shell = (userShell as NSString).lastPathComponent
        guard envInjectedShells.contains(shell) else { return [] }
        if setsShellIntegration(userConfigText) { return [] }
        return ["shell-integration = \(shell)"]
    }

    /// Whether any non-comment line of the user's config sets `shell-integration`.
    static func setsShellIntegration(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") == false, let equals = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces) == "shell-integration"
        }
    }

    /// Where Ghostty reads the user's config on macOS.
    public static func userConfigPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
        ]
    }

    /// Writes the overrides file and points the shim at it (`BALAGAN_GHOSTTY_CONFIG_OVERRIDES`).
    /// Must run before the Ghostty app is created. Clears the variable when there's nothing to add.
    public static func install(directory: String = NSTemporaryDirectory()) {
        let userConfig = userConfigPaths()
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let overrides = lines(userShell: UserShell.defaultShellPath(), userConfigText: userConfig)
        guard overrides.isEmpty == false else {
            unsetenv("BALAGAN_GHOSTTY_CONFIG_OVERRIDES")
            return
        }
        let path = (directory as NSString).appendingPathComponent("balagan-ghostty-overrides.conf")
        do {
            try (overrides.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            setenv("BALAGAN_GHOSTTY_CONFIG_OVERRIDES", path, 1)
        } catch {
            unsetenv("BALAGAN_GHOSTTY_CONFIG_OVERRIDES")
        }
    }
}
