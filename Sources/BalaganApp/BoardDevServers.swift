import AppKit
import BalaganCore
import SwiftUI

/// Local servers started from a task's terminals (`npm run dev`, `rails s`, …), found every few
/// seconds by scanning the app's descendant processes for TCP listeners and matching each one's
/// folder to a task (`ListeningPortScanner` / `DevServerPorts`, Core). Shown as `localhost:<port>`
/// chips on the card and in the task header.
extension BoardViewModel {
    static let devServerQueue = DispatchQueue(label: "com.joeyfeldberg.balagan.dev-servers", qos: .utility)

    func refreshDevServerPorts() {
        guard devServerTrackingEnabled else { return }
        // Only tasks with live terminals can be serving anything.
        let directories: [String: [String]] = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
            guard liveTaskIDs.contains(task.id) else { return nil }
            var folders = Set(task.workspace.surfaces.map(\.cwd))
            if let directory = taskWorkingDirectory(task) { folders.insert(directory) }
            return (task.id, Array(folders))
        })
        guard directories.isEmpty == false else {
            if devServerPorts.isEmpty == false { devServerPorts = [:] }
            return
        }
        Self.devServerQueue.async { [weak self] in
            let ports = DevServerPorts.assign(processes: ListeningPortScanner.scan(), taskDirectories: directories)
            DispatchQueue.main.async {
                guard let self, self.devServerPorts != ports else { return }
                self.devServerPorts = ports
            }
        }
    }

    /// `BALAGAN_FIXTURE_PORTS=1`: sample servers on the first two tasks, for a snapshot.
    func seedDevServerPortsForSnapshot() {
        let ids = tasks.filter { $0.isProjectTerminals == false }.prefix(2).map(\.id)
        if let first = ids.first { devServerPorts[first] = [DevServerPort(port: 3000, processName: "node"), DevServerPort(port: 5173, processName: "node")] }
        if ids.count > 1 { devServerPorts[ids[1]] = [DevServerPort(port: 8000, processName: "Python")] }
    }
}

extension BalaganApplication {
    /// Scans for dev servers every 3 s (not in `--ui-test-mode`: it reads the process table).
    @MainActor
    func startDevServerScan() {
        viewModel?.refreshDevServerPorts()
        devServerTimer?.invalidate()
        devServerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel?.refreshDevServerPorts()
            }
        }
    }
}

/// `localhost:3000` chips that open the server in the browser.
struct DevServerChips: View {
    let ports: [DevServerPort]
    /// The card's smaller variant shows `:3000`; the header shows the full `localhost:3000`.
    var compact = false
    @Environment(\.balaganUIScale) private var scale

    var body: some View {
        HStack(spacing: 5 * scale) {
            ForEach(ports, id: \.port) { port in
                Button {
                    NSWorkspace.shared.open(port.url)
                } label: {
                    HStack(spacing: 3 * scale) {
                        Circle()
                            .fill(Color(red: 0.25, green: 0.73, blue: 0.44))
                            .frame(width: 5 * scale, height: 5 * scale)
                        // String(port): Text's number interpolation would print "8,765".
                        Text(verbatim: compact ? ":\(String(port.port))" : "localhost:\(String(port.port))")
                            .font(.system(size: (compact ? Theme.TextSize.micro : Theme.TextSize.small) * scale, weight: .medium).monospacedDigit())
                    }
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(Capsule().fill(Theme.hairlineStrong))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Open http://localhost:\(port.port) (\(port.processName))")
                .accessibilityIdentifier("dev-server-\(port.port)")
            }
        }
    }
}
