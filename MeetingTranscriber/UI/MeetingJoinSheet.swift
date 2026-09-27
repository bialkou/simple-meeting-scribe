import SwiftUI

struct MeetingJoinSheet: View {
    let meeting: DetectedMeeting
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric private var sheetIconSize: CGFloat = 38
    @ScaledMetric private var languageTagSize: CGFloat = 28

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 22) {
            VStack(spacing: Theme.space3) {
                Image(systemName: "video.fill")
                    .font(.system(size: sheetIconSize))
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(Color.red.opacity(0.10), in: Circle())
                    .overlay(Circle().stroke(Color.red.opacity(0.18), lineWidth: 0.7))
                Text("Meeting detected")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.4)
                Text(meeting.title)
                    .foregroundStyle(.secondary)
                Text(meeting.platform)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, Theme.space2)

            Toggle(isOn: Binding(
                get: { appState.recordScreen },
                set: { appState.setRecordScreen($0) }
            )) {
                Label("Record screen", systemImage: "video.fill")
            }
            .toggleStyle(.switch)
            .help("Record the meeting's browser window as video")

            VStack(spacing: 10) {
                Text("Record this meeting in:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.space6) {
                    languageButton(.english)
                    languageButton(.polish)
                    languageButton(.russian)
                }
            }

            Button("Ignore", role: .cancel) {
                appState.dismissDetectedMeeting()
                dismiss()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.pressable)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func languageButton(_ language: TranscriptionLanguage) -> some View {
        Button {
            Task { await appState.startRecording(language: language, meeting: meeting) }
            dismiss()
        } label: {
            VStack(spacing: Theme.space2) {
                Text(language.tag)
                    .font(.system(size: languageTagSize * 0.55,
                                  weight: .bold,
                                  design: .rounded))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.primary.opacity(0.08), in: Capsule())
                Text(language.displayName).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .tint(.red)
        .keyboardShortcut(languageShortcut(for: language), modifiers: [.command])
    }

    private func languageShortcut(for language: TranscriptionLanguage) -> KeyEquivalent {
        switch language {
        case .english: "e"
        case .polish:  "p"
        case .russian: "r"
        }
    }
}
