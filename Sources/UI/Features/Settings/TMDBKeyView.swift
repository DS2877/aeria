import SwiftUI

/// Paste a TMDB API key to enrich the catalog with real artwork and metadata.
/// Stored in the Keychain; only titles + years are ever sent to TMDB.
struct TMDBKeyView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Metrics.space4) {
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text("Connect The Movie Database").font(.dsTitle)
                    Text("Create a free account at themoviedb.org → Settings → API. Paste either the v3 \u{201C}API Key\u{201D} or the v4 \u{201C}API Read Access Token\u{201D} — both work. Stored only on this Apple TV; each lookup sends just a title and year.")
                        .font(.dsBody).foregroundStyle(Palette.textSecondary)
                        .frame(maxWidth: 900, alignment: .leading)
                }

                SecureField("API key", text: $key)
                    .textFieldStyle(.plain)
                    .font(.dsBody)
                    .padding(Metrics.space2)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.06)))
                    .frame(maxWidth: 820)

                HStack(spacing: Metrics.space2) {
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Button("Save") {
                        Task { await env.setTMDBKey(key); dismiss() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(key.trimmingCharacters(in: .whitespaces).count < 8)

                    if env.hasTMDBKey {
                        Button(role: .destructive) {
                            Task { await env.setTMDBKey(""); dismiss() }
                        } label: { Label("Remove key", systemImage: "trash") }
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
