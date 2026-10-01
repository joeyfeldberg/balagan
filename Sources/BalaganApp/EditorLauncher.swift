import AppKit

/// Opens files/directories in an external app — Zed (editor) and Fork (git client). Both accept a
/// directory argument: Zed opens it as a project, Fork opens it as a repository.
enum EditorLauncher {
    private static let zedBundleIdentifiers = ["dev.zed.Zed", "dev.zed.Zed-Preview"]
    private static let forkBundleIdentifiers = ["com.DanPristupov.Fork"]

    /// The installed Zed application URL, if any. Memoized — install state is stable for a session,
    /// and the lookup hits LaunchServices, so we avoid repeating it in SwiftUI bodies.
    static let zedApplicationURL: URL? = firstInstalled(of: zedBundleIdentifiers)

    /// The installed Fork application URL, if any. Memoized for the same reason as `zedApplicationURL`.
    static let forkApplicationURL: URL? = firstInstalled(of: forkBundleIdentifiers)

    static var isZedInstalled: Bool { zedApplicationURL != nil }
    static var isForkInstalled: Bool { forkApplicationURL != nil }

    /// Opens `path` (a file or directory) in Zed, activating it. No-op if Zed isn't installed.
    @discardableResult
    static func openInZed(path: String) -> Bool {
        open(path: path, withApplicationAt: zedApplicationURL)
    }

    /// Opens `path` (a repository directory) in Fork, activating it. No-op if Fork isn't installed.
    @discardableResult
    static func openInFork(path: String) -> Bool {
        open(path: path, withApplicationAt: forkApplicationURL)
    }

    private static func firstInstalled(of bundleIdentifiers: [String]) -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    private static func open(path: String, withApplicationAt appURL: URL?) -> Bool {
        guard let appURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: appURL,
            configuration: configuration,
            completionHandler: nil
        )
        return true
    }
}
