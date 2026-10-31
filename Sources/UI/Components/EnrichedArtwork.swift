import SwiftUI

/// Identifies a catalog item well enough for TMDB to match it.
public struct ArtworkRef: Equatable, Sendable, Hashable {
    public let id: CatalogID
    public let title: String
    public let year: Int?
    public let isSeries: Bool

    public init(id: CatalogID, title: String, year: Int?, isSeries: Bool) {
        self.id = id
        self.title = title
        self.year = year
        self.isSeries = isSeries
    }
}

/// `ArtworkView` that fills in a real TMDB poster/backdrop when the provider
/// gave us none. The generated gradient shows immediately; the fetched image
/// fades in when it arrives.
struct EnrichedArtwork: View {
    @Environment(AppEnvironment.self) private var env

    let ref: ArtworkRef
    let providerURL: URL?
    var aspect: CGFloat = 2.0 / 3.0
    var style: ArtworkView.Style = .poster
    var size: ImageSize = .poster
    /// Called once a real image (provider or TMDB) is available.
    var onResolvedImage: (() -> Void)? = nil
    /// Called with the TMDB rating (0…10) when one is found.
    var onResolvedRating: ((Double) -> Void)? = nil

    /// Show the TMDB image over the provider's once it resolves. For 16:9
    /// slots fed a provider *poster* (Continue Watching), a real backdrop
    /// beats a cropped poster; the provider image still shows meanwhile.
    var preferEnriched: Bool = false

    @State private var fetchedURL: URL?

    private var shownURL: URL? {
        preferEnriched ? (fetchedURL ?? providerURL) : (providerURL ?? fetchedURL)
    }

    var body: some View {
        ArtworkView(url: shownURL, title: ref.title, aspect: aspect, style: style, size: size)
            .task(id: ref) {
                if providerURL != nil, !preferEnriched { onResolvedImage?(); return }
                guard fetchedURL == nil else { return }
                let meta = await env.metadata.metadata(
                    for: ref.id, title: ref.title, year: ref.year, isSeries: ref.isSeries
                )
                if let rating = meta?.rating { onResolvedRating?(rating) }
                let url = style == .backdrop ? (meta?.backdropURL ?? meta?.posterURL) : meta?.posterURL
                if let url {
                    withAnimation(.easeIn(duration: 0.3)) { fetchedURL = url }
                    onResolvedImage?()
                }
            }
    }
}
