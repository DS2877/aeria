import SwiftUI

/// Lets the user paste an Anthropic API key to power AI-assisted search. The key
/// is stored in the Keychain and is only ever sent to api.anthropic.com, with
/// nothing but the search text and the library's genre/language lists.
struct AIKeyView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var saving = false

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Metrics.space4) {
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text("Connect Claude").font(.dsTitle)
                    Text("Paste an Anthropic API key from console.anthropic.com. It's stored only on this Apple TV. Each AI-assisted search sends just your words and your library's genre and language lists — never your provider, links, or history.")
                        .font(.dsBody).foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }

                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.plain)
                    .font(.dsBody)
                    .padding(Metrics.space2)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.06)))
                    .frame(maxWidth: 820)

                HStack(spacing: Metrics.space2) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())

                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            await env.setAIKey(key)
                            dismiss()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(key.trimmingCharacters(in: .whitespaces).count < 8)

                    if env.hasAIKey {
                        Button(role: .destructive) {
                            Task { await env.setAIKey(""); dismiss() }
                        } label: {
                            Label("Remove key", systemImage: "trash")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, Metrics.screenMargin)
        }
        .onExitCommand { dismiss() }
    }
}
