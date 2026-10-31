import SwiftUI

/// Full filter editor for a browse screen. Edits a working copy and applies on
/// dismiss-with-Apply so the grid doesn't thrash on every tap.
struct FilterSheet: View {
    @Binding var filter: CatalogFilter
    let genres: [Genre]
    let audio: [Language]
    let subtitles: [Language]

    @Environment(\.dismiss) private var dismiss
    @State private var working = CatalogFilter()

    private let years: [Int] = Array(stride(from: 2025, through: 1950, by: -5))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space4) {
                HStack {
                    Text("Filters").font(.dsHero)
                    Spacer()
                    Button("Reset") { working = CatalogFilter(sort: working.sort) }
                        .buttonStyle(.bordered)
                    Button("Apply") { filter = working; dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                Group {
                    section("Sort") {
                        chipRow(BrowseSort.allCases, id: \.self, label: \.label,
                                isOn: { working.sort == $0 },
                                toggle: { working.sort = $0 })
                    }

                    if !genres.isEmpty {
                        section("Genre") {
                            chipRow(genres, id: \.self, label: \.displayName,
                                    isOn: { working.genres.contains($0) },
                                    toggle: { toggle(\.genres, $0) })
                        }
                    }
                    if !audio.isEmpty {
                        section("Audio language") {
                            chipRow(audio, id: \.self, label: \.displayName,
                                    isOn: { working.audioLanguages.contains($0) },
                                    toggle: { toggle(\.audioLanguages, $0) })
                        }
                    }
                    if !subtitles.isEmpty {
                        section("Subtitles") {
                            chipRow(subtitles, id: \.self, label: \.displayName,
                                    isOn: { working.subtitleLanguages.contains($0) },
                                    toggle: { toggle(\.subtitleLanguages, $0) })
                        }
                    }
                    section("Minimum quality") {
                        let options: [VideoQuality] = [.hd, .fhd, .uhd]
                        chipRow(options, id: \.self, label: { $0.shortLabel + "+" },
                                isOn: { working.minQuality == $0 },
                                toggle: { working.minQuality = (working.minQuality == $0) ? nil : $0 })
                    }
                    section("From year") {
                        chipRow(years, id: \.self, label: { "\($0)+" },
                                isOn: { working.minYear == $0 },
                                toggle: { working.minYear = (working.minYear == $0) ? nil : $0 })
                    }
                }
            }
            .padding(Metrics.screenMargin)
        }
        .appThemeBackground()
        .onAppear { working = filter }
    }

    private func toggle<V: Equatable>(_ keyPath: WritableKeyPath<CatalogFilter, [V]>, _ value: V) {
        if let idx = working[keyPath: keyPath].firstIndex(of: value) {
            working[keyPath: keyPath].remove(at: idx)
        } else {
            working[keyPath: keyPath].append(value)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text(title).font(.dsSectionHeader)
            content()
        }
    }

    private func chipRow<Item, ID: Hashable>(
        _ items: [Item],
        id: KeyPath<Item, ID>,
        label: @escaping (Item) -> String,
        isOn: @escaping (Item) -> Bool,
        toggle: @escaping (Item) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.space1) {
                ForEach(items, id: id) { item in
                    FilterChip(label: label(item), isSelected: isOn(item)) { toggle(item) }
                }
            }
        }
        .focusSection()
    }
}
