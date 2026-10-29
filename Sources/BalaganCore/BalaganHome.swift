import Foundation

/// Balagan's data folder: `$BALAGAN_HOME`, else `~/.balagan`. The app writes the agent integration,
/// and the wrapper inside each terminal reads it, so both must resolve it the same way. (The two
/// sockets and the hook log keep their own overrides.)
public enum BalaganHome {
    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        environment["BALAGAN_HOME"]?.nilIfBlank ?? (homeDirectory + "/.balagan")
    }
}
