import SwiftUI

/// A titled horizontal rail. Lazy so only visible cards render — the pattern
/// the whole app uses for large libraries.
public struct Shelf<Item: Identifiable, Card: View>: View {
    let title: String
    let subtitle: String?
    let items: [Item]
    /// When set, the header becomes a "see all" link into the ambient
    /// `NavigationStack`.
    let headerRoute: AppRoute?
    @ViewBuilder let card: (Item) -> Card

    public init(
        title: String,
        subtitle: String? = nil,
        items: [Item],
        headerRoute: AppRoute? = nil,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.headerRoute = headerRoute
        self.card = card
    }

    public var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                header
                    .padding(.horizontal, Metrics.screenMargin)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Metrics.cardSpacing) {
                        ForEach(items) { item in
                            card(item)
                        }
                    }
                    .padding(.horizontal, Metrics.screenMargin)
                    .padding(.vertical, Metrics.space4)   // room for the focus lift + its shadow
                }
            }
            .focusSection()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let headerRoute {
            NavigationLink(value: headerRoute) {
                HStack(spacing: Metrics.space1) {
                    SectionHeader(title, subtitle: subtitle)
                    Image(systemName: "chevron.right")
                        .font(.dsCaption)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SeeAllLinkStyle())
            .accessibilityLabel("See all \(title)")
        } else {
            SectionHeader(title, subtitle: subtitle)
        }
    }
}

/// A shelf's "see all" header link — a restrained focus tint + lift, no card fill.
private struct SeeAllLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SeeAllLinkBody(configuration: configuration)
    }
}

private struct SeeAllLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    var body: some View {
        configuration.label
            .foregroundStyle(isFocused ? Palette.accent : Palette.textTertiary)
            .scaleEffect(isFocused ? 1.03 : 1, anchor: .leading)
            .animation(Metrics.focusAnimation, value: isFocused)
    }
}
