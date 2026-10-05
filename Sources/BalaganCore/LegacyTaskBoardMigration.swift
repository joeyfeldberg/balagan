import Foundation

/// One-time carry-over from the app's previous name, TaskBoard. It copies, never moves, so the old
/// install keeps working until it's deleted, and each step is skipped once the Balagan side exists:
///
/// - the board database, `Application Support/TaskBoard/TaskBoard.sqlite` (+ `-wal`/`-shm`);
/// - custom agent profiles in `~/.taskboard/agents` (shims, the zsh chain and the integration files
///   are regenerated at launch, and the sockets and hook log start fresh);
/// - UserDefaults (default agent, auto-sleep, notification switches, speech), from the old bundle id's
///   domain, or the dev binary's `TaskBoardApp` domain.
public enum LegacyTaskBoardMigration {
    public static let legacyBundleIdentifier = "com.joeyfeldberg.TaskBoard"
    public static let legacyDevDefaultsDomain = "TaskBoardApp"
    /// Set in the new defaults once preferences were carried over (or found nothing to carry).
    public static let defaultsMigratedKey = "migratedFromTaskBoard"

    public struct Report: Equatable, Sendable {
        public var copiedDatabase = false
        public var copiedAgentProfiles = false
        public var copiedDefaultsKeys = 0
    }

    public static func run(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        defaults: UserDefaults = .standard,
        legacyDefaultsDomains: [String] = [legacyBundleIdentifier, legacyDevDefaultsDomain],
        fileManager: FileManager = .default
    ) -> Report {
        var report = Report()
        if let applicationSupport {
            report.copiedDatabase = copyDatabase(applicationSupport: applicationSupport, fileManager: fileManager)
        }
        report.copiedAgentProfiles = copyItemIfMissing(
            from: home.appendingPathComponent(".taskboard/agents"),
            to: home.appendingPathComponent(".balagan/agents"),
            fileManager: fileManager
        )
        report.copiedDefaultsKeys = copyDefaults(into: defaults, from: legacyDefaultsDomains)
        return report
    }

    static func copyDatabase(applicationSupport: URL, fileManager: FileManager) -> Bool {
        let oldDirectory = applicationSupport.appendingPathComponent("TaskBoard", isDirectory: true)
        let newDirectory = applicationSupport.appendingPathComponent("Balagan", isDirectory: true)
        let oldDatabase = oldDirectory.appendingPathComponent("TaskBoard.sqlite")
        let newDatabase = newDirectory.appendingPathComponent("Balagan.sqlite")
        guard fileManager.fileExists(atPath: oldDatabase.path),
              fileManager.fileExists(atPath: newDatabase.path) == false else {
            return false
        }
        do {
            try fileManager.createDirectory(at: newDirectory, withIntermediateDirectories: true)
            // The WAL and shared-memory files go along so a database left mid-checkpoint stays whole.
            // The main file is copied last, because its presence is what marks the copy as done.
            for suffix in ["-wal", "-shm"] {
                let old = URL(fileURLWithPath: oldDatabase.path + suffix)
                if fileManager.fileExists(atPath: old.path) {
                    try? fileManager.removeItem(atPath: newDatabase.path + suffix)
                    try fileManager.copyItem(at: old, to: URL(fileURLWithPath: newDatabase.path + suffix))
                }
            }
            try fileManager.copyItem(at: oldDatabase, to: newDatabase)
            return true
        } catch {
            return false
        }
    }

    static func copyItemIfMissing(from old: URL, to new: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: old.path), fileManager.fileExists(atPath: new.path) == false else {
            return false
        }
        do {
            try fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Board contents

    /// Old → new spellings inside a saved board: wrapper commands (`'/Applications/TaskBoard.app/
    /// Contents/MacOS/taskboard-agent' claude`, a project's `taskboard-agent codex`), the shims on a
    /// saved resume `PATH`, and `TASKBOARD_*` environment names, including in a project's setup script.
    static let boardReplacements: [(String, String)] = [
        ("/TaskBoard.app/", "/Balagan.app/"),
        ("taskboard-agent", "balagan-agent"),
        ("/.taskboard/", "/.balagan/"),
        ("TASKBOARD_", "BALAGAN_"),
    ]
    /// Free text the user wrote or the terminal printed: never rewritten.
    static let boardProseKeys: Set<String> = ["scrollbackSnapshot", "notes", "title", "name", "tags"]

    /// Rewrites a saved board's TaskBoard-era commands, paths and environment names, leaving prose
    /// alone. Returns `data` unchanged when there's nothing to rewrite (every load after the first
    /// save), so it's cheap to run on each load.
    public static func rewriteBoardJSON(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8),
              boardReplacements.contains(where: { text.contains($0.0) }),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data
        }
        let rewritten = rewrite(root)
        return (try? JSONSerialization.data(withJSONObject: rewritten, options: [.fragmentsAllowed])) ?? data
    }

    static func rewrite(_ string: String) -> String {
        boardReplacements.reduce(string) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func rewrite(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return rewrite(string)
        case let array as [Any]:
            return array.map(rewrite)
        case let object as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in object {
                let newKey = rewrite(key)
                // An environment that somehow has both spellings keeps the new one.
                if newKey != key, object[newKey] != nil { continue }
                result[newKey] = boardProseKeys.contains(key) ? child : rewrite(child)
            }
            return result
        default:
            return value
        }
    }

    // MARK: - Preferences

    static func copyDefaults(into defaults: UserDefaults, from legacyDomains: [String]) -> Int {
        guard defaults.bool(forKey: defaultsMigratedKey) == false else { return 0 }
        defer { defaults.set(true, forKey: defaultsMigratedKey) }
        guard let legacy = legacyDomains.lazy.compactMap({ defaults.persistentDomain(forName: $0) }).first else {
            return 0
        }
        var copied = 0
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }
}
