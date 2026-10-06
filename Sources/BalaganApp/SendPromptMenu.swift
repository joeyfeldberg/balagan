import SwiftUI
import BalaganCore

/// "Send Prompt ▸ Write tests / Review your diff / …" for a task's menus. When the agent can't take a
/// message right now, the submenu says why instead of offering prompts that would do nothing.
struct SendPromptMenu: View {
    let prompts: [SavedPrompt]
    let blocker: String?
    let onSend: (SavedPrompt) -> Void

    var body: some View {
        Menu {
            if let blocker {
                Text(blocker)
            } else if prompts.isEmpty {
                Text("No saved prompts. Add some in Settings → Prompts.")
            } else {
                ForEach(prompts) { prompt in
                    Button(prompt.title) { onSend(prompt) }
                }
            }
        } label: {
            Label("Send Prompt", systemImage: "paperplane")
        }
        .accessibilityIdentifier("send-prompt-menu")
    }
}
