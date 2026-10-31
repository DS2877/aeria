import SwiftUI

/// Horizontal rail of cast members with circular TMDB photos. Sits inside the
/// padded detail column, so it does no horizontal padding of its own.
struct CastRail: View {
    let credits: [TMDBClient.CastCredit]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text("Cast")
                .font(.dsSectionHeader)
                .foregroundStyle(Palette.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.space2) {
                    ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                        VStack(spacing: 10) {
                            CachedImage(url: credit.imageURL, size: .logo) {
                                ZStack {
                                    Circle().fill(Palette.surface)
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 34))
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                            .frame(width: 118, height: 118)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(Palette.hairline))

                            VStack(spacing: 3) {
                                Text(credit.name)
                                    .font(.dsCaption)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                if let character = credit.character {
                                    Text(character)
                                        .font(.dsTag)
                                        .foregroundStyle(Palette.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 150)
                    }
                }
                .padding(.vertical, Metrics.space1)
            }
            .focusSection()
        }
    }
}

/// One entry in the "More Like This" rail.
struct RelatedItem: Identifiable, Hashable {
    let id: CatalogID
    let title: String
    let year: Int?
    let posterURL: URL?
    let isSeries: Bool

    var artworkRef: ArtworkRef {
        ArtworkRef(id: id, title: title, year: year, isSeries: isSeries)
    }
    var route: AppRoute { isSeries ? .series(id) : .movie(id) }
}

/// "More Like This" — genre-matched picks from the user's own library.
/// Uses `NavigationLink` so a tap pushes a fresh detail screen (which reloads
/// its own metadata) rather than trying to mutate this one in place.
struct RelatedRail: View {
    let title: String
    let items: [RelatedItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text(title)
                    .font(.dsSectionHeader)
                    .foregroundStyle(Palette.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(items) { item in
                            // Only the artwork lifts on focus; the caption sits
                            // below it so it's never clipped by the card.
                            VStack(alignment: .leading, spacing: Metrics.space1 + 2) {
                                NavigationLink(value: item.route) {
                                    EnrichedArtwork(ref: item.artworkRef, providerURL: item.posterURL,
                                                    aspect: 2.0 / 3.0, style: .poster)
                                        .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius,
                                                                    style: .continuous))
                                }
                                .buttonStyle(.card)
                                .accessibilityLabel(item.title)
                                Text(item.title)
                                    .font(.dsCaption)
                                    .foregroundStyle(Palette.textPrimary)
                                    .lineLimit(1)
                                if let year = item.year {
                                    Text(String(year))
                                        .font(.dsTag)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                            .frame(width: Metrics.posterWidth, alignment: .leading)
                        }
                    }
                    .padding(.vertical, Metrics.space3)
                }
                // The focused card grows past the row's edge — don't clip it.
                .scrollClipDisabled()
                .focusSection()
            }
        }
    }
}
