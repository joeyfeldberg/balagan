import AppKit
import BalaganCore

extension BalaganApplication {
    /// Logs the loaded libghostty version against the releases the shim is verified for and, on a
    /// mismatch, shows an alert once per reported version. The Ghostty.app we embed updates itself
    /// through Sparkle, and for a release it has no action numbers for the shim routes no title /
    /// bell / pwd / search events, so this is the only thing that says why those went quiet.
    func warnOnLibGhosttyVersionMismatch(runtime: TerminalRuntimeOptions) {
        guard runtime.selection.kind == .libghostty else { return }
        let compatibility = LibGhosttyVersionCheck.check(reported: runtime.selection.libGhostty.version)
        let verified = LibGhosttyVersionCheck.verifiedVersions.joined(separator: ", ")
        if let warning = compatibility.warning {
            NSLog("Balagan: %@", warning)
        } else {
            NSLog("Balagan: libghostty %@ (shim verified against Ghostty %@)", compatibility.reported ?? "?", verified)
        }

        guard case .mismatch(let reported, _) = compatibility else { return }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: AppPreferences.Keys.libGhosttyVersionWarned) != reported else { return }
        defaults.set(reported, forKey: AppPreferences.Keys.libGhosttyVersionWarned)

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Balagan hasn't been verified against Ghostty \(reported)"
            alert.informativeText = """
            Balagan runs its terminals on the libghostty inside Ghostty.app, and this build was verified \
            against Ghostty \(verified). Until Balagan is updated for \(reported), terminal titles, bells, \
            working folders and search are switched off, and agents' running / waiting state depends on \
            those titles.

            Everything else keeps working. This notice shows once per Ghostty version.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
