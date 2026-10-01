import SwiftUI
import BalaganCore

/// The floating playback bar shown while a response is being spoken (or a speech notice is up):
/// current sentence, sentence back/forward, pause/resume, rate presets, stop. Lives at the
/// `BoardScreen` level so playback survives navigating between tasks and the board.
struct SpeechHUD: View {
    @ObservedObject var speech: SpeechController

    var body: some View {
        Group {
            if let notice = speech.notice {
                Label(notice, systemImage: "speaker.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(hudBackground)
            } else if speech.isActive {
                playbackBar
            }
        }
        .animation(.easeOut(duration: 0.15), value: speech.isActive)
        .animation(.easeOut(duration: 0.15), value: speech.notice != nil)
    }

    private var playbackBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, isActive: speech.state == .speaking)

            Text(currentSentence)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 380, alignment: .leading)

            Text("\(speech.currentIndex + 1)/\(speech.sentences.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)

            Divider().frame(height: 14)

            transportButton("backward.fill", help: "Previous sentence", id: "speech-previous") {
                speech.skip(-1)
            }
            transportButton(
                speech.state == .paused ? "play.fill" : "pause.fill",
                help: speech.state == .paused ? "Resume" : "Pause",
                id: "speech-pause"
            ) {
                speech.togglePause()
            }
            transportButton("forward.fill", help: "Next sentence", id: "speech-next") {
                speech.skip(1)
            }

            Menu {
                ForEach(SpeechController.rateMultipliers, id: \.self) { multiplier in
                    Button {
                        speech.setRateMultiplier(multiplier)
                    } label: {
                        if multiplier == speech.rateMultiplier {
                            Label(rateLabel(multiplier), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(multiplier))
                        }
                    }
                }
            } label: {
                Text(rateLabel(speech.rateMultiplier))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Speech rate")

            Divider().frame(height: 14)

            transportButton("xmark", help: "Stop speaking", id: "speech-stop") {
                speech.stop()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(hudBackground)
        .accessibilityIdentifier("speech-hud")
    }

    private var currentSentence: String {
        speech.sentences.indices.contains(speech.currentIndex) ? speech.sentences[speech.currentIndex] : ""
    }

    private func rateLabel(_ multiplier: Double) -> String {
        multiplier == multiplier.rounded()
            ? "\(Int(multiplier))×"
            : "\(String(format: "%.2g", multiplier))×"
    }

    private func transportButton(
        _ symbol: String,
        help: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textSecondary)
        .help(help)
        .accessibilityIdentifier(id)
    }

    private var hudBackground: some View {
        Capsule(style: .continuous)
            .fill(Theme.surfaceRaised)
            .overlay(Capsule(style: .continuous).stroke(Theme.hairlineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}
