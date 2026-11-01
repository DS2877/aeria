import SwiftUI

/// A provider section ("Netflix", "Barnfilm") as a wide tile: the newest
/// poster in it, darkened, with the name and how many titles it holds.
struct CollectionTile: View {
    let category: BrowseCategory
    let action: () -> Void

    static let size = CGSize(width: 400, height: 225)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                ArtworkView(url: category.artworkURL, title: category.title,
                            aspect: Self.size.width / Self.size.height, style: .backdrop, size: .poster)
                    .frame(width: Self.size.width, height: Self.size.height)
                    .blur(radius: 2)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(countLabel(category.count))
                        .font(.dsCaption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(Metrics.space2 + 4)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.card)
        .sectionEntryTarget()
        .accessibilityLabel("\(category.title), \(countLabel(category.count))")
    }
}

/// A genre as a colour tile with its symbol — quicker to read than a poster.
struct GenreTile: View {
    let category: BrowseCategory
    let action: () -> Void

    static let size = CGSize(width: 300, height: 170)

    var body: some View {
        let style = GenreStyle(category)
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [style.color.opacity(0.95), style.color.opacity(0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: style.symbol)
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.22))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(Metrics.space2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(countLabel(category.count))
                        .font(.dsCaption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(Metrics.space2 + 2)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.card)
        .sectionEntryTarget()
        .accessibilityLabel("\(category.title), \(countLabel(category.count))")
    }
}

private func countLabel(_ count: Int) -> String {
    "\(count.formatted()) title\(count == 1 ? "" : "s")"
}

/// Colour + SF Symbol per genre.
private struct GenreStyle {
    let color: Color
    let symbol: String

    init(_ category: BrowseCategory) {
        guard case .genre(let genre) = category.kind else {
            color = Palette.accent; symbol = "square.grid.2x2"; return
        }
        switch genre {
        case .action:      (color, symbol) = (Color(red: 0.86, green: 0.27, blue: 0.20), "flame.fill")
        case .adventure:   (color, symbol) = (Color(red: 0.90, green: 0.55, blue: 0.16), "map.fill")
        case .animation:   (color, symbol) = (Color(red: 0.95, green: 0.45, blue: 0.62), "sparkles")
        case .comedy:      (color, symbol) = (Color(red: 0.96, green: 0.72, blue: 0.15), "face.smiling.inverse")
        case .crime:       (color, symbol) = (Color(red: 0.36, green: 0.36, blue: 0.42), "magnifyingglass")
        case .documentary: (color, symbol) = (Color(red: 0.25, green: 0.60, blue: 0.45), "globe.europe.africa.fill")
        case .drama:       (color, symbol) = (Color(red: 0.55, green: 0.30, blue: 0.70), "theatermasks.fill")
        case .family:      (color, symbol) = (Color(red: 0.30, green: 0.70, blue: 0.85), "figure.2.and.child.holdinghands")
        case .fantasy:     (color, symbol) = (Color(red: 0.45, green: 0.35, blue: 0.85), "wand.and.stars")
        case .history:     (color, symbol) = (Color(red: 0.62, green: 0.48, blue: 0.30), "building.columns.fill")
        case .horror:      (color, symbol) = (Color(red: 0.45, green: 0.08, blue: 0.10), "moon.fill")
        case .music:       (color, symbol) = (Color(red: 0.85, green: 0.30, blue: 0.55), "music.note")
        case .mystery:     (color, symbol) = (Color(red: 0.25, green: 0.30, blue: 0.55), "questionmark.circle.fill")
        case .romance:     (color, symbol) = (Color(red: 0.88, green: 0.33, blue: 0.45), "heart.fill")
        case .sciFi:       (color, symbol) = (Color(red: 0.15, green: 0.50, blue: 0.80), "atom")
        case .thriller:    (color, symbol) = (Color(red: 0.30, green: 0.22, blue: 0.30), "eye.fill")
        case .war:         (color, symbol) = (Color(red: 0.40, green: 0.45, blue: 0.30), "shield.fill")
        case .western:     (color, symbol) = (Color(red: 0.70, green: 0.45, blue: 0.25), "sun.dust.fill")
        case .kids:        (color, symbol) = (Color(red: 0.20, green: 0.75, blue: 0.55), "balloon.2.fill")
        case .news:        (color, symbol) = (Color(red: 0.30, green: 0.40, blue: 0.55), "newspaper.fill")
        case .sport:       (color, symbol) = (Color(red: 0.20, green: 0.62, blue: 0.30), "sportscourt.fill")
        case .reality:     (color, symbol) = (Color(red: 0.80, green: 0.40, blue: 0.30), "camera.fill")
        case .other:       (color, symbol) = (Palette.accent, "square.grid.2x2")
        }
    }
}
