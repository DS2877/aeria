import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SectionModels.self) private var models
    @State private var model: SearchViewModel?
    @State private var path: [AppRoute] = []
    @State private var didAutoFocus = false
    @FocusState private var searchFieldFocused: Bool

    private let examples = [
        "Something scary with Swedish subtitles",
        "English series released after 2020",
        "A comedy under 90 minutes",
        "Something like Game of Thrones",
        "4K action movies",
    ]

    private let columns = Array(repeating: GridItem(.fixed(Metrics.posterWidth), spacing: Metrics.cardSpacing),
                                count: 5)

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    contentBody(model)
                } else {
                    Color.clear
                }
            }
            .appThemeBackground()
            .appRouteDestinations()
        }
        // Shared, so coming back to Search still shows your last results.
        // Re-fetched when the store resets (provider switch).
        .task(id: models.generation) { model = models.search(env) }
        .task(id: env.catalogRevision) {
            await models.search(env).loadTrending(ratings: await env.metadata.ratingsSnapshot(),
                                                  revision: env.catalogRevision)
        }
    }

    @ViewBuilder
    private func contentBody(_ model: SearchViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space4) {
                header(model)

                if model.isSearching {
                    VStack(spacing: Metrics.gridSpacing) {
                        ForEach(0..<2, id: \.self) { _ in
                            HStack(spacing: Metrics.cardSpacing) {
                                ForEach(0..<5, id: \.self) { _ in
                                    SkeletonBox().frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Metrics.space4)
                } else if !model.hasSearched {
                    if !model.trending.isEmpty {
                        VStack(alignment: .leading, spacing: Metrics.space2) {
                            Text("New to your library").font(.dsSectionHeader)
                            posterGrid(model.trending)
                        }
                    }
                    exampleQueries(model)
                } else if model.results.isEmpty, env.loadState.isImporting {
                    LibraryLoadingPlaceholder().frame(minHeight: 360)
                } else if model.results.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "Nothing matched",
                        message: "\u{201C}\(model.interpretedFrom)\u{201D} didn't turn up anything in your library. Try removing a filter or rephrasing.",
                        actionTitle: "Clear",
                        action: { model.clear() }
                    )
                    .frame(minHeight: 360)
                } else {
                    results(model)
                }
            }
            .padding(Metrics.screenMargin)
        }
    }

    private func header(_ model: SearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text("Search").font(.dsTitle).accessibilityAddTraits(.isHeader)

            HStack(spacing: Metrics.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
                TextField("What do you want to watch?", text: Binding(
                    get: { model.query },
                    set: { model.query = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.dsCardTitle)
                .focused($searchFieldFocused)
                .onSubmit {
                    Task {
                        await model.search(vocabulary: env.vocabulary)
                        // Drop keyboard focus so the remote's next press lands on
                        // the results, not back in the field.
                        searchFieldFocused = false
                    }
                }
                .task {
                    // Land on the field the first time Search opens, the way the
                    // Apple TV search screens do. Not on every return trip.
                    if !didAutoFocus, !model.hasSearched, model.query.isEmpty {
                        didAutoFocus = true
                        searchFieldFocused = true
                    }
                }
            }
            .padding(.horizontal, Metrics.space3)
            .padding(.vertical, Metrics.space2 + 4)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.06))
            )
            .frame(maxWidth: 1100)

            if !model.chips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Interpreted as").font(.dsCaption).foregroundStyle(Palette.textTertiary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Metrics.space1) {
                            ForEach(model.chips) { chip in
                                FilterChip(label: chip.label, isSelected: true, showsRemoveIcon: true) {
                                    model.removeChip(chip)
                                }
                            }
                        }
                    }
                    .focusSection()
                    if model.hasSearched {
                        Text("\(model.results.count) result\(model.results.count == 1 ? "" : "s")")
                            .font(.dsCaption).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
    }

    private func exampleQueries(_ model: SearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            if !model.recentQueries.isEmpty {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    HStack {
                        Text("Recent").font(.dsSectionHeader)
                        Spacer()
                        Button("Clear") { model.clearRecents() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    ForEach(model.recentQueries, id: \.self) { recent in
                        Button {
                            Task { await model.runRecent(recent, vocabulary: env.vocabulary) }
                        } label: {
                            HStack(spacing: Metrics.space2) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Palette.textTertiary)
                                Text(recent).font(.dsBody).foregroundStyle(Palette.textPrimary)
                                Spacer()
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityLabel("Search again: \(recent)")
                    }
                }
                .focusSection()
            }

            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text("Try asking for…").font(.dsSectionHeader)
                ForEach(examples, id: \.self) { example in
                    Button {
                        model.query = example
                        Task { await model.search(vocabulary: env.vocabulary) }
                    } label: {
                        HStack(spacing: Metrics.space2) {
                            Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                            Text(example).font(.dsBody).foregroundStyle(Palette.textPrimary)
                            Spacer()
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityLabel("Search: \(example)")
                }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
    }

    private func results(_ model: SearchViewModel) -> some View {
        posterGrid(model.results)
    }

    @ViewBuilder
    private func posterGrid(_ items: [SearchResult]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridSpacing) {
            ForEach(items) { result in
                switch result.item {
                case .movie(let m):
                    PosterCard(title: m.title,
                               subtitle: [m.year.map(String.init), m.genres.first?.displayName].compactMap { $0 }.joined(separator: " · "),
                               artworkURL: m.posterURL,
                               ref: ArtworkRef(id: m.id, title: m.title, year: m.year, isSeries: false),
                               isNew: CatalogFreshness.isNew(m.addedAt),
                               action: { path.append(.movie(m.id)) })
                case .series(let s):
                    PosterCard(title: s.title,
                               subtitle: s.cardSubtitle,
                               artworkURL: s.posterURL,
                               ref: ArtworkRef(id: s.id, title: s.title, year: s.year, isSeries: true),
                               isNew: CatalogFreshness.isNew(s.addedAt),
                               action: { path.append(.series(s.id)) })
                case .channel(let c):
                    PosterCard(title: c.name, subtitle: c.category, artworkURL: c.logoURL,
                               action: { path.append(.channel(c.id)) })
                }
            }
        }
        .focusSection()
    }
}
