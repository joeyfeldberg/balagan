import SwiftUI

struct SurfaceFormSheet: View {
    @State private var draft: SurfaceFormDraft
    let onSave: (SurfaceFormDraft) -> Void

    init(draft: SurfaceFormDraft, onSave: @escaping (SurfaceFormDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Terminal Tab")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Title", text: $draft.title)
                    .accessibilityIdentifier("surface-title-field")

                TextField("Working Directory", text: $draft.cwd)
                    .accessibilityIdentifier("surface-cwd-field")

                TextField("Startup Command", text: $draft.startupCommand)
                    .accessibilityIdentifier("surface-startup-command-field")
            }

            SheetFooter(
                cancelIdentifier: "surface-form-cancel-button",
                saveHelp: "Save terminal tab",
                saveDisabled: !draft.canSave,
                saveIdentifier: "surface-form-save-button"
            ) {
                onSave(draft)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct SurfaceRenameFormSheet: View {
    @State private var draft: SurfaceRenameDraft
    let onSave: (SurfaceRenameDraft) -> Void

    init(draft: SurfaceRenameDraft, onSave: @escaping (SurfaceRenameDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Terminal Tab")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Title", text: $draft.title)
                    .accessibilityIdentifier("surface-rename-title-field")
            }

            SheetFooter(
                cancelIdentifier: "surface-rename-cancel-button",
                saveHelp: "Rename tab",
                saveDisabled: !draft.canSave,
                saveIdentifier: "surface-rename-save-button"
            ) {
                onSave(draft)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
