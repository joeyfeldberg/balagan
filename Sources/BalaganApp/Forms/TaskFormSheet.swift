import SwiftUI
import BalaganCore

struct TaskFormSheet: View {
    @State private var draft: TaskFormDraft
    @State private var workspaceMode: WorkspaceMode
    /// Once the user types in the branch field we stop auto-deriving it from the title.
    @State private var branchManuallyEdited: Bool
    @FocusState private var focus: Field?
    let projects: [Project]
    let onSave: (TaskFormDraft) -> Void

    private enum Field: Hashable { case title, notes, tags, branch }
    private enum WorkspaceMode: Hashable { case worktree, main }

    init(draft: TaskFormDraft, projects: [Project], onSave: @escaping (TaskFormDraft) -> Void) {
        var initialDraft = draft
        if initialDraft.projectID.isEmpty, let firstProjectID = projects.first?.id {
            initialDraft.projectID = firstProjectID
        }
        if initialDraft.branchOrWorktree.nilIfBlank != nil {
            // Existing branch → keep it as-is (an isolated worktree, name preserved).
            _workspaceMode = State(initialValue: .worktree)
            _branchManuallyEdited = State(initialValue: true)
        } else if initialDraft.taskID == nil {
            // New task → default to an isolated worktree, auto-named from the title.
            _workspaceMode = State(initialValue: .worktree)
            _branchManuallyEdited = State(initialValue: false)
            initialDraft.branchOrWorktree = BranchNaming.slug(from: initialDraft.title)
        } else {
            // Existing task with no branch → it works on the project's main checkout.
            _workspaceMode = State(initialValue: .main)
            _branchManuallyEdited = State(initialValue: false)
        }
        _draft = State(initialValue: initialDraft)
        self.projects = projects
        self.onSave = onSave
    }

    private var selectedProject: Project? {
        projects.first { $0.id == draft.projectID }
    }

    /// The lanes to offer for the chosen project (its board's columns), defaulting to the built-ins.
    private var formLanes: [Lane] {
        selectedProject?.lanes ?? Lane.defaults
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text(draft.sheetTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Title is the hero field — no label, larger type.
                TextField("Task title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focus, equals: .title)
                    .accessibilityIdentifier("task-title-field")
                    .formFieldChrome(focused: focus == .title)

                HStack(alignment: .top, spacing: 12) {
                    FormFieldGroup("Status") {
                        ColoredSegmentedPicker(
                            values: formLanes.map(\.status),
                            selection: $draft.status,
                            title: { status in formLanes.first { $0.status == status }?.name ?? status.displayName },
                            color: { status in formLanes.first { $0.status == status }?.color ?? status.color }
                        )
                        .accessibilityIdentifier("task-form-status-control")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    FormFieldGroup("Priority") {
                        ColoredSegmentedPicker(
                            values: TaskPriority.allCases,
                            selection: $draft.priority,
                            title: { $0.displayName },
                            color: { $0.tint }
                        )
                        .accessibilityIdentifier("task-priority-picker")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                FormFieldGroup("Notes") {
                    PlaceholderTextEditor(
                        text: $draft.summary,
                        placeholder: "Add notes…",
                        minHeight: 96,
                        identifier: "task-notes-field",
                        focus: $focus,
                        field: .notes
                    )
                }

                FormFieldGroup("Tags") {
                    TextField("comma, separated", text: $draft.tagsText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focus, equals: .tags)
                        .accessibilityIdentifier("task-tags-field")
                        .formFieldChrome(focused: focus == .tags)
                }

                FormFieldGroup("Workspace") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Workspace", selection: $workspaceMode) {
                            Text("Isolated worktree").tag(WorkspaceMode.worktree)
                            Text("Work on main").tag(WorkspaceMode.main)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("task-workspace-mode-picker")

                        if workspaceMode == .worktree {
                            TextField("branch-name", text: Binding(
                                get: { draft.branchOrWorktree },
                                set: { draft.branchOrWorktree = $0; branchManuallyEdited = true }
                            ))
                            .textFieldStyle(.plain)
                            .foregroundStyle(Theme.textPrimary)
                            .focused($focus, equals: .branch)
                            .accessibilityIdentifier("task-branch-field")
                            .formFieldChrome(focused: focus == .branch)

                            Text("A git worktree on this branch, auto-named from the title. Edit to rename.")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        } else {
                            Text("Opens in the project's main checkout — no separate worktree or branch.")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .onChange(of: draft.title) { _, newTitle in
                if workspaceMode == .worktree, branchManuallyEdited == false {
                    draft.branchOrWorktree = BranchNaming.slug(from: newTitle)
                }
            }
            .onChange(of: workspaceMode) { _, mode in
                if mode == .worktree, branchManuallyEdited == false, draft.branchOrWorktree.nilIfBlank == nil {
                    draft.branchOrWorktree = BranchNaming.slug(from: draft.title)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 18)

            SheetFooter(
                style: .prominent,
                cancelIdentifier: "task-form-cancel-button",
                saveHelp: "Save task",
                saveDisabled: !draft.canSave,
                saveIdentifier: "task-form-save-button"
            ) {
                var saved = draft
                // "Work on main" means no worktree — an empty branch opens the repo's main checkout.
                if workspaceMode == .main {
                    saved.branchOrWorktree = ""
                }
                onSave(saved)
            }
        }
        .frame(width: 460)
        .background(Theme.bgWindow)
    }

}
