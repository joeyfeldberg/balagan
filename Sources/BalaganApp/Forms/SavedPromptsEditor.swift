import SwiftUI
import BalaganCore

/// An editable list of saved prompts (title + text), used by Settings → Prompts and the project form.
struct SavedPromptsEditor: View {
    @Binding var prompts: [SavedPrompt]
    var emptyMessage = "No prompts yet."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if prompts.isEmpty {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach($prompts) { $prompt in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("Title", text: $prompt.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("saved-prompt-title")
                        Button {
                            prompts.removeAll { $0.id == prompt.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this prompt")
                    }
                    TextField("What to tell the agent", text: $prompt.text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("saved-prompt-text")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceRaised))
            }
            Button {
                prompts.append(SavedPrompt(title: "", text: ""))
            } label: {
                Label("Add Prompt", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("saved-prompt-add")
        }
    }
}
