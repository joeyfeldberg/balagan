import Foundation
import BalaganCore

/// Which agents are installed on this Mac, for the `+` menu and Settings → Agents. The app's own
/// `PATH` (from launchd) is minimal, so it asks your login shell for the real one, once, off the main
/// thread — the same `PATH` a Balagan terminal would see, minus Balagan's shims.
extension BoardViewModel {
    static let agentDetectionQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.agent-detection", qos: .utility)

    func detectInstalledAgents() {
        let profiles = AgentProfiles.all
        Self.agentDetectionQueue.async { [weak self] in
            let path = Self.loginShellPath() ?? ProcessInfo.processInfo.environment["PATH"]
            var found: [String: String] = [:]
            for profile in profiles {
                if let executable = AgentExecutableResolver.resolve(
                    command: profile.command,
                    path: path,
                    excluding: [AgentIntegrationPaths().shims]
                ) {
                    found[profile.id] = executable
                }
            }
            DispatchQueue.main.async { self?.installedAgents = found }
        }
    }

    /// The profiles to offer: installed ones once detection has run, every profile before that.
    var offeredAgentProfiles: [AgentProfile] {
        guard let installedAgents else { return AgentProfiles.all }
        return AgentProfiles.all.filter { installedAgents[$0.id] != nil }
    }

    /// `PATH` as your login shell sets it up, or nil if the shell didn't answer within 5 s.
    static func loginShellPath() -> String? {
        let shell = UserShell.defaultShellPath()
        let isFish = (shell as NSString).lastPathComponent == "fish"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", isFish ? "string join : $PATH" : "printf '%s' \"$PATH\""]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment.removeValue(forKey: "ZDOTDIR")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        // Startup files may print banners first; PATH is the last line.
        let text = String(decoding: data, as: UTF8.self)
        let last = text.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return last?.contains("/") == true ? last : nil
    }
}
