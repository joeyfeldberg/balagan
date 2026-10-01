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
