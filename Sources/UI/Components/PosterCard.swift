import SwiftUI

/// A 2:3 poster with its caption beneath. Only the artwork is the focusable
/// `.card` — the title and metadata sit outside it, the way the Apple TV app
/// lays out a poster shelf, so nothing gets clipped by the card's corners.
public struct PosterCard: View {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let ref: ArtworkRef?
    let badge: String?
    let progress: Double?
    let isNew: Bool
    let action: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        ref: ArtworkRef? = nil,
        badge: String? = nil,
        progress: Double? = nil,
        isNew: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.ref = ref
        self.badge = badge
        self.progress = progress
        self.isNew = isNew
        self.action = action
    }

    @State private var showsRealImage = false
    @State private var rating: Double?

    private var clampedProgress: Double { Swift.min(1, Swift.max(0, progress ?? 0)) }

    private var accessibilityLabel: String {
        var parts = [title]
        if isNew, (progress ?? 0) == 0 { parts.append("New") }
        if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if progress != nil { parts.append("\(Int((clampedProgress * 100).rounded()))% watched") }
        return parts.joined(separator: ", ")
    }

    private var captionLine: String {
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return showsRealImage ? title : ""
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1 + 2) {
            Button(action: action) {
                ZStack(alignment: .topTrailing) {
                    artwork
                        .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                        .overlay(alignment: .bottomLeading) {
                            if let rating, (progress ?? 0) == 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "star.fill").font(.system(size: 11))
                                        .foregroundStyle(Palette.accent)
                                    Text(String(format: "%.1f", rating))
                                        .font(.dsTag)
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if (progress ?? 0) > 0 {
                                ZStack(alignment: .bottomLeading) {
                                    LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                                   startPoint: .center, endPoint: .bottom)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.28))
                                        Capsule().fill(Palette.accent)
                                            .frame(width: Swift.max(4, (Metrics.posterWidth - 24) * clampedProgress))
                                    }
                                    .frame(height: 4)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if isNew, (progress ?? 0) == 0 {
                                Text("NEW")
                                    .font(.dsTag)
                                    .foregroundStyle(Palette.canvas)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Palette.accent, in: Capsule())
                                    .padding(Metrics.space1)
                            }
                        }

                    if let badge {
                        Text(badge)
                            .font(.dsTag)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(Metrics.space1)
                    }
                }
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 3) {
                // With no artwork the generated poster carries the title, so the
                // caption drops to just the metadata line.
                if showsRealImage {
                    Text(title)
                        .font(.dsCardTitle)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                }
                if !captionLine.isEmpty {
                    Text(captionLine)
                        .font(.dsCaption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 30, alignment: .top)
        }
        .frame(width: Metrics.posterWidth, alignment: .leading)
        .onAppear { if artworkURL != nil { showsRealImage = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var artwork: some View {
        if let ref {
            EnrichedArtwork(ref: ref, providerURL: artworkURL, aspect: 2.0 / 3.0, style: .poster,
                            onResolvedImage: { showsRealImage = true },
                            onResolvedRating: { rating = $0 })
        } else {
            ArtworkView(url: artworkURL, title: title, aspect: 2.0 / 3.0)
        }
    }
}
