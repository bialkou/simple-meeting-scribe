import SwiftUI

/// Shown when the user drops a media file into the window or picks one via
/// Browse/Import. Lets them choose the transcription language for this file.
struct ImportFileSheet: View {
    let url: URL
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric private var sheetIconSize: CGFloat = 38
    @ScaledMetric private var languageTagSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: Theme.space3) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: sheetIconSize))
                    .foregroundStyle(Theme.accent)
                    .padding(10)
                    .background(Theme.accent.opacity(0.10), in: Circle())
                    .overlay(Circle().stroke(Theme.accent.opacity(0.18), lineWidth: 0.7))
                Text("Import file")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.4)
                Text(url.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
            }
            .padding(.top, Theme.space2)

            VStack(spacing: 10) {
                Text("Transcribe in:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: Theme.space6) {
                    languageButton(.english)
                    languageButton(.polish)
                    languageButton(.russian)
                }
            }

            Button("Cancel", role: .cancel) {
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
            Task { await appState.importFile(url: url, language: language) }
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
        .tint(Theme.accent)
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
