import AppKit
import SwiftUI
import BalaganCore
import UniformTypeIdentifiers

extension BoardViewModel {
    /// A project straight from a folder: named after it, using the default agent from Settings. The
    /// quick path for the first-run screen; the full form is still there for everything else.
    @discardableResult
    func createProject(fromFolder url: URL) -> Project {
        createProject(
            name: url.lastPathComponent,
            repoPath: url.path,
            defaultBranch: nil,
            defaultAgentCommand: AppPreferences.defaultAgent.command,
            worktreesDirectory: nil,
            setupCommands: nil
        )
    }
}

/// The board with no projects yet: what a project is, and a drop target to make one.
struct WelcomeView: View {
    @ObservedObject var viewModel: BoardViewModel
    /// The full New Project form, for people who want to set everything up front.
    let onCreateProject: () -> Void
    @State private var isTargeted = false
    @Environment(\.balaganUIScale) private var scale

    var body: some View {
        VStack(spacing: 18 * scale) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 34 * scale, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 6 * scale) {
                Text("Add your first project")
                    .font(.system(size: Theme.TextSize.heading * scale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("A project is a git repository. Each task in it gets its own terminal and agent, usually on its own branch in a separate worktree.")
                    .font(.system(size: Theme.TextSize.body * scale))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420 * scale)
            }

            VStack(spacing: 10 * scale) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 22 * scale))
                    .foregroundStyle(isTargeted ? Theme.accent : Theme.textSecondary)
                Text("Drop a repository folder here")
                    .font(.system(size: Theme.TextSize.body * scale, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 8 * scale) {
                    Button("Choose Folder…", action: chooseFolder)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("welcome-choose-folder-button")
                    Button("New Project…", action: onCreateProject)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("welcome-new-project-button")
                }
                .font(.system(size: Theme.TextSize.body * scale))
            }
            .padding(24 * scale)
            .frame(width: 420 * scale)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                    .fill(isTargeted ? Theme.accentSoft : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                    .strokeBorder(isTargeted ? Theme.accent : Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        }
        .padding(32 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("welcome-view")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a git repository folder"
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.createProject(fromFolder: url)
        }
    }

    /// Takes the first dropped folder (files are ignored).
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            DispatchQueue.main.async {
                viewModel.createProject(fromFolder: url)
            }
        }
        return true
    }
}
