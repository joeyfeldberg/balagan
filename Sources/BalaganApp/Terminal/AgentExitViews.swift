import SwiftUI

/// Along the bottom of an agent tab whose process exited: what happened and the one obvious next
/// step, with the terminal's last output still readable above it. ⏎ also resumes — the terminal host
/// forwards it (see `exitedSurfaceReturnReporter`).
struct AgentExitedCard: View {
    let ended: EndedAgent
    let scale: CGFloat
    let onResume: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12 * scale) {
            Image(systemName: ended.offer == .resume ? "arrow.clockwise.circle.fill" : "play.circle.fill")
                .font(.system(size: 22 * scale))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("\(ended.agentName) exited")
                    .font(.system(size: Theme.TextSize.body * scale, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: Theme.TextSize.small * scale))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12 * scale)
            Button("Close Tab", action: onClose)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ended-agent-close-button")
            Button(ended.offer == .resume ? "Resume  ⏎" : "Start Agent  ⏎", action: onResume)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ended-agent-resume-button")
        }
        .font(.system(size: Theme.TextSize.body * scale))
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 12 * scale)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .fill(Theme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusColumn, style: .continuous)
                .stroke(Theme.hairlineStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .padding(12 * scale)
        .accessibilityIdentifier("ended-agent-card")
    }

    private var detail: String {
        switch ended.offer {
        case .resume where ended.gaveUpAutoResume:
            return "It exited again right after resuming, so Balagan stopped retrying. The session is saved; resume when it's ready."
        case .resume:
            return "Its session is saved. Resume picks the conversation up where it left off."
        case .restart:
            return "No session was captured for this tab, so it starts fresh."
        }
    }
}

/// "Codex exited right after starting — probably updating itself — so its session was resumed."
struct AutoResumeNotice: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 7 * scale) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(Theme.accent)
            Text(text)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .font(.system(size: Theme.TextSize.small * scale, weight: .medium))
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 7 * scale)
        .background(Capsule().fill(Theme.surfaceRaised))
        .overlay(Capsule().stroke(Theme.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .frame(maxWidth: 520 * scale)
        .accessibilityIdentifier("auto-resume-notice")
    }
}
