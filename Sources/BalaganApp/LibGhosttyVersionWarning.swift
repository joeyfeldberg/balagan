import AppKit
import BalaganCore

extension BalaganApplication {
    /// Logs the loaded libghostty version against the shim's pin and, on a mismatch, shows an alert
    /// once per reported version. The Ghostty.app we embed updates itself through Sparkle, and a
    /// release that renumbers the action enum breaks title / bell / pwd / search events without an
    /// error, so this is the only thing that would say the shim's tags need re-verifying.
    func warnOnLibGhosttyVersionMismatch(runtime: TerminalRuntimeOptions) {
        guard runtime.selection.kind == .libghostty else { return }
        let compatibility = LibGhosttyVersionCheck.check(reported: runtime.selection.libGhostty.version)
        let pinned = LibGhosttyVersionCheck.pinnedVersion
        if let warning = compatibility.warning {
            NSLog("Balagan: %@", warning)
        } else {
            NSLog("Balagan: libghostty %@ (shim pinned to Ghostty %@)", compatibility.reported ?? "?", pinned)
        }

        guard case .mismatch(let reported, _) = compatibility else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: AppPreferences.Keys.libGhosttyVersionWarned) != reported else { return }
        defaults.set(reported, forKey: AppPreferences.Keys.libGhosttyVersionWarned)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Ghostty \(reported) doesn't match the version Balagan was built against"
            alert.informativeText = """
            Balagan runs its terminals on the libghostty inside Ghostty.app, and this build was verified \
            against Ghostty \(pinned). Until Balagan is updated for \(reported), terminal titles, bells, \
            working folders and search may not reach it, and agents' running / waiting state depends on \
            those titles.

            Everything else keeps working. This notice shows once per Ghostty version.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
