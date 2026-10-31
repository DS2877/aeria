import SwiftUI

/// Shared cinematic layout for detail screens: full-bleed backdrop, darkening
/// gradients, and a left-aligned content column.
struct DetailScaffold<Content: View>: View {
    let title: String
    let backdropURL: URL?
    /// How wide the content column may grow. Series pass a wider value so the
    /// episode list doesn't float in a narrow strip.
    var contentMaxWidth: CGFloat = 1320
    @ViewBuilder let content: () -> Content

    private var hasBackdrop: Bool { backdropURL != nil }
    private var backdropHeight: CGFloat { hasBackdrop ? 680 : 300 }

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                backdrop

                VStack(alignment: .leading, spacing: Metrics.space3) {
                    Spacer().frame(height: hasBackdrop ? backdropHeight * 0.52 : Metrics.space7)
                    content()
                }
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.bottom, Metrics.space7)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
            }
        }
        .background(Palette.canvas.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var backdrop: some View {
        if hasBackdrop {
            ArtworkView(url: backdropURL, title: title, aspect: 16.0 / 9.0,
                        style: .backdrop, size: .backdrop)
                .frame(height: backdropHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Palette.canvas.opacity(0.2), location: 0.4),
                            .init(color: Palette.canvas.opacity(0.7), location: 0.72),
                            .init(color: Palette.canvas.opacity(0.97), location: 0.92),
                            .init(color: Palette.canvas, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    LinearGradient(
                        colors: [Palette.canvas.opacity(0.85), Palette.canvas.opacity(0.3), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        } else {
            // No artwork: a restrained top glow, not a full smudge of colour.
            RadialGradient(
                colors: [Palette.accent.opacity(0.09), .clear],
                center: UnitPoint(x: 0.28, y: -0.1), startRadius: 0, endRadius: 620
            )
            .frame(height: backdropHeight)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A small "★ 7.8" pill for a TMDB rating.
struct TMDBRatingBadge: View {
    let rating: Double
    var votes: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "star.fill")
                .font(.system(size: 15))
                .foregroundStyle(Palette.accent)
            Text(String(format: "%.1f", rating))
                .font(.dsTag)
                .foregroundStyle(Palette.textPrimary)
            if let votes, votes >= 50 {
                Text(Self.shortCount(votes))
                    .font(.dsTag)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, Metrics.space2)
        .padding(.vertical, Metrics.space1)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .accessibilityLabel("Rated \(String(format: "%.1f", rating)) out of 10 on The Movie Database")
    }

    private static func shortCount(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.0fk", Double(n) / 1000) : "\(n)"
    }
}

/// A labelled row of language chips ("English audio", "Swedish subtitles").
struct LanguageSummary: View {
    let audio: [Language]
    let subtitles: [Language]

    var body: some View {
        if !audio.isEmpty || !subtitles.isEmpty {
            HStack(spacing: Metrics.space2) {
                if !audio.isEmpty {
                    chip("Audio", audio.map(\.displayName).joined(separator: ", "))
                }
                if !subtitles.isEmpty {
                    chip("Subtitles", subtitles.map(\.displayName).joined(separator: ", "))
                }
            }
        }
    }

    private func chip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.dsTag).foregroundStyle(Palette.textTertiary)
            Text(value).font(.dsTag).foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, Metrics.space2)
        .padding(.vertical, Metrics.space1)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline))
    }
}
