import AppKit
import SwiftUI

struct RepositoryPathPicker: View {
    @Binding var path: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("/path/to/repository", text: $path)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .focused($isFocused)
                .accessibilityIdentifier("project-repo-path-field")
                .formFieldChrome(focused: isFocused)

            Button("Choose…") {
                chooseRepositoryFolder()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("project-repo-path-picker-button")
        }
    }

    private func chooseRepositoryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Repository Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = startingDirectoryURL(for: path)

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        path = url.path
    }

    private func startingDirectoryURL(for path: String) -> URL {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.isEmpty == false else {
            return FileManager.default.homeDirectoryForCurrentUser
        }

        let url = URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }

        let parentURL = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return parentURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
    }
}
