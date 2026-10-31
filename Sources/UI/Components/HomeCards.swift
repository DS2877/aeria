import SwiftUI

/// Continue Watching — a wide 16:9 still with the episode / time-left line and
/// a progress bar on the image, the way the Apple TV app's Up Next row reads.
/// Wider than a poster on purpose: it's the row people come back for, so it
/// gets the most real estate after the hero.
struct ResumeCard: View {
    let card: HomeCard
    let action: () -> Void

    static let width: CGFloat = 448
    static var height: CGFloat { width * 9 / 16 }

    private var clampedProgress: Double { Swift.min(1, Swift.max(0, card.progress ?? 0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1 + 2) {
            Button(action: action) {
                ZStack(alignment: .bottomLeading) {
                    artwork
                        .frame(width: Self.width, height: Self.height)

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.35),
                            .init(color: .black.opacity(0.82), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 15, weight: .bold))
                            if let line = card.subtitle, !line.isEmpty {
                                Text(line)
                                    .font(.dsTag)
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)

                        if card.progress != nil {
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.28))
                                Capsule().fill(Palette.accent)
                                    .frame(width: Swift.max(5, (Self.width - 36) * clampedProgress))
                            }
                            .frame(height: 5)
                        }
                    }
                    .padding(18)
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.card)

            Text(card.title)
                .font(.dsCardTitle)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text([card.title, card.subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var artwork: some View {
        if let ref = card.artworkRef {
            EnrichedArtwork(ref: ref, providerURL: card.artworkURL, aspect: 16.0 / 9.0,
                            style: .backdrop, size: .poster, preferEnriched: true)
        } else {
            ArtworkView(url: card.artworkURL, title: card.title, aspect: 16.0 / 9.0,
                        style: .backdrop, size: .poster)
        }
    }
}

/// A Top 10 entry — a big rank numeral the poster tucks against. The numeral is
/// decorative (fades to the canvas at its foot) so the poster stays the focus.
struct RankedPosterCard: View {
    let rank: Int
    let card: HomeCard
    let action: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: rank >= 10 ? -46 : -30) {
            Text("\(rank)")
                .font(.system(size: 250, weight: .black, design: .rounded))
                .monospacedDigit()
                .tracking(rank >= 10 ? -22 : 0)
                .foregroundStyle(
                    LinearGradient(colors: [Palette.textPrimary.opacity(0.92),
                                            Palette.textPrimary.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                // Sit the numeral's baseline on the poster's foot, above the caption.
                .padding(.bottom, 40)
                .accessibilityHidden(true)

            PosterCard(
                title: card.title,
                subtitle: card.subtitle,
                artworkURL: card.artworkURL,
                ref: card.artworkRef,
                badge: card.badge,
                isNew: card.isNew,
                action: action
            )
            .accessibilityLabel(Text("Nummer \(rank), \(card.title)"))
        }
    }
}
