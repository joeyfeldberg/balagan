import SwiftUI
import BalaganCore

struct ProjectFormSheet: View {
    @State private var draft: ProjectFormDraft
    @FocusState private var focus: Field?
    let onSave: (ProjectFormDraft) -> Void

    private enum Field: Hashable { case name, branch, agent, worktrees, setup }

    init(draft: ProjectFormDraft, onSave: @escaping (ProjectFormDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text(draft.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextField("Project name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focus, equals: .name)
                    .accessibilityIdentifier("project-name-field")
                    .formFieldChrome(focused: focus == .name)

                FormFieldGroup("Repository Path") {
                    RepositoryPathPicker(path: $draft.repoPath)
                }

                FormFieldGroup("Default Branch") {
                    TextField("main", text: $draft.defaultBranch)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focus, equals: .branch)
                        .accessibilityIdentifier("project-default-branch-field")
                        .formFieldChrome(focused: focus == .branch)
                }

                FormFieldGroup("Default Agent Command") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("balagan-agent claude", text: $draft.defaultAgentCommand)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .focused($focus, equals: .agent)
                            .accessibilityIdentifier("project-default-agent-command-field")
                            .formFieldChrome(focused: focus == .agent)

                        HStack(spacing: 8) {
                            agentPreset("Codex", AgentCommandDefaults.codex, id: "project-default-agent-codex-button")
                            agentPreset("Claude", AgentCommandDefaults.claude, id: "project-default-agent-claude-button")
                            agentPreset("OpenCode", AgentCommandDefaults.opencode, id: "project-default-agent-opencode-button")
                            agentPreset("pi", AgentCommandDefaults.pi, id: "project-default-agent-pi-button")
                            Spacer()
                        }
                    }
                }

                FormFieldGroup("Worktrees Folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(draft.defaultWorktreesDirectory, text: $draft.worktreesDirectory)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Theme.textPrimary)
                            .focused($focus, equals: .worktrees)
                            .accessibilityIdentifier("project-worktrees-directory-field")
                            .formFieldChrome(focused: focus == .worktrees)

                        Text("Where a task's Workspace branch gets its git worktree. Blank uses the folder above.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }

                FormFieldGroup("Setup Commands") {
                    VStack(alignment: .leading, spacing: 6) {
                        PlaceholderTextEditor(
                            text: $draft.setupCommands,
                            placeholder: "ln -sfn \"$BALAGAN_REPO_PATH\"/.env .env\nuv sync",
                            minHeight: 64,
                            monospaced: true,
                            identifier: "project-setup-commands-field",
                            focus: $focus,
                            field: .setup
                        )

                        Text("Runs once in a new worktree the first time it's created (in the task's terminal).")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Variables — click to copy")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                            HStack(spacing: 6) {
                                CopyableVarChip(value: "$BALAGAN_REPO_PATH")
                                Text("main repo").font(.caption2).foregroundStyle(Theme.textTertiary)
                            }
                            HStack(spacing: 6) {
                                CopyableVarChip(value: "$BALAGAN_WORKTREE_PATH")
                                Text("this worktree").font(.caption2).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 18)

            SheetFooter(
                style: .prominent,
                cancelIdentifier: "project-form-cancel-button",
                saveHelp: "Save project",
                saveDisabled: !draft.isValid,
                saveIdentifier: "project-form-save-button"
            ) {
                onSave(draft)
            }
        }
        .frame(width: 460)
        .background(Theme.bgWindow)
    }

    private func agentPreset(_ title: String, _ command: String, id: String) -> some View {
        Button(title) {
            draft.defaultAgentCommand = command
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
                .fill(Theme.surfaceHover)
        )
        .accessibilityIdentifier(id)
    }
}
