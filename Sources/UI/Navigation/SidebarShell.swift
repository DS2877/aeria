import SwiftUI

/// The app's main navigation — a left rail that sits **collapsed to icons while
/// you're in the content** and expands with labels, over the content, the moment
/// focus returns to it (the Apple TV app pattern). The selected section's screen
/// fills the rest; screens you've visited stay mounted behind the current one,
/// so switching sections is instant and keeps scroll position and focus.
///
/// Non-blocking: if the library is still importing, a slim status pill appears
/// over the content instead of locking the user out.
struct SidebarShell: View {
    @Environment(AppEnvironment.self) private var env

    enum Section: String, CaseIterable, Identifiable {
        case home, search, liveTV, guide, movies, series, favorites, history, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Hem"
            case .search: return "Sök"
            case .liveTV: return "Live-TV"
            case .guide: return "TV-guide"
            case .movies: return "Filmer"
            case .series: return "Serier"
            case .favorites: return "Favoriter"
            case .history: return "Historik"
            case .settings: return "Inställningar"
            }
        }
        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .search: return "magnifyingglass"
            case .liveTV: return "tv.fill"
            case .guide: return "rectangle.grid.1x2.fill"
            case .movies: return "film.fill"
            case .series: return "rectangle.stack.fill"
            case .favorites: return "heart.fill"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape.fill"
            }
        }
    }

    private static let primary: [Section] = [.home, .search, .liveTV, .guide, .movies, .series, .favorites, .history]

    /// Rail widths. The content keeps a permanent `collapsed`-wide gutter; when
    /// the rail expands it draws over the gutter *and* the content scales back
    /// out of its way (the Apple TV app move) so nothing is ever hidden.
    private static let collapsed: CGFloat = 108
    private static let expanded: CGFloat = 292

    /// How far the content is pushed + how much it shrinks while the rail is
    /// open. Tuned so the content's leading edge clears the expanded rail.
    private static let contentInsetShift: CGFloat = expanded - collapsed
    private static let railAnimation: Animation = .easeOut(duration: 0.26)

    /// Restored synchronously at init so the first frame already shows the
    /// right screen — setting it later (`.onAppear`) would flash Home first.
    @State private var selection: Section
    @FocusState private var focusedItem: Section?
    /// Sections the user has opened at least once — kept mounted from then on.
    @State private var visited: Set<Section>
    /// Section view models outlive the view tree, so revisiting a screen shows
    /// what it already had instead of re-querying.
    @State private var models = SectionModels()
    /// The content area's focus scope — clicking a rail item moves focus into
    /// it with `resetFocus`, rather than releasing focus and letting the
    /// focus engine pick (it picked the rail's top item, Home).
    @Namespace private var contentScope
    @Environment(\.resetFocus) private var resetFocus

    private static let lastSectionKey = "sidebar.lastSection.v1"

    init() {
        // Settings is a place you visit, not one you live in — relaunching into
        // it feels like a glitch, so it falls back to Home.
        let saved = UserDefaults.standard.string(forKey: Self.lastSectionKey)
            .flatMap(Section.init(rawValue:))
        let restored: Section
        if let saved, saved != .settings { restored = saved } else { restored = .home }
        _selection = State(initialValue: restored)
        _visited = State(initialValue: [restored])
    }

    /// The rail is expanded whenever it owns focus.
    private var railExpanded: Bool { focusedItem != nil }

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.collapsed)   // permanent gutter
            content
                .focusScope(contentScope)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    VStack(spacing: Metrics.space1) {
                        if !env.network.isOnline { OfflinePill() }
                        LibraryStatusPill()
                    }
                    .animation(.easeInOut, value: env.network.isOnline)
                }
                // While the rail is open: nudge the content right and shrink it
                // toward its trailing edge so its leading edge clears the rail,
                // and dim it so the menu clearly has focus.
                .offset(x: railExpanded ? Self.contentInsetShift * 0.32 : 0)
                .scaleEffect(railExpanded ? 0.92 : 1, anchor: .trailing)
                .overlay {
                    Rectangle().fill(.black)
                        .opacity(railExpanded ? 0.42 : 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .animation(Self.railAnimation, value: railExpanded)
                // Its own focus region — pressing → from anywhere in the rail
                // lands on the content's last-focused element (the tvOS
                // two-column pattern).
                .focusSection()
                // Menu from a section root moves focus back to the rail (the
                // Apple TV convention). On Home, Menu is left alone so it
                // backgrounds the app, per the HIG. A pushed detail screen's
                // NavigationStack still gets Menu first and pops as usual.
                .modifier(MenuReturnsToSidebar(enabled: selection != .home) {
                    withAnimation(Self.railAnimation) { focusedItem = selection }
                })
        }
        .background(Palette.canvas.ignoresSafeArea())
        .overlay(alignment: .leading) { rail }
        .environment(models)
        .onChange(of: env.activeProvider?.id) { _, _ in
            // A different library — nothing the old models hold is valid.
            models.reset()
            visited = [selection]
        }
        .onChange(of: focusedItem) { old, item in
            // Backstop for the default-focus rule above: arriving in the rail
            // from the content on any item but the current section snaps to
            // the current section instead of switching screens.
            if old == nil, let item, item != selection {
                focusedItem = selection
                return
            }
            // Focus-driven, the way the Apple TV app works: moving up/down the
            // rail switches the content live. Cheap now that panels stay mounted.
            if let item {
                selection = item
                visited.insert(item)
            }
        }
        .onChange(of: selection) { _, section in
            UserDefaults.standard.set(section.rawValue, forKey: Self.lastSectionKey)
        }
        .onChange(of: env.pendingRoute) { _, route in
            // A Top Shelf deep link lands here — Home owns the nav stack that
            // shows detail screens.
            if route != nil {
                selection = .home
                visited.insert(.home)
                focusedItem = .home
            }
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            railHeader
                .padding(.top, Metrics.space4)
                .padding(.bottom, Metrics.space3)

            ForEach(Self.primary) { item in
                SidebarItem(section: item, isSelected: selection == item, expanded: railExpanded) {
                    select(item)
                }
                .focused($focusedItem, equals: item)
            }

            Spacer(minLength: 0)

            SidebarItem(section: .settings, isSelected: selection == .settings, expanded: railExpanded) {
                select(.settings)
            }
            .focused($focusedItem, equals: .settings)
            .padding(.bottom, Metrics.space4)
        }
        .frame(width: railExpanded ? Self.expanded : Self.collapsed, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(railBackground)
        .shadow(color: .black.opacity(railExpanded ? 0.6 : 0), radius: 44, x: 14)
        .animation(Self.railAnimation, value: railExpanded)
        .focusSection()
        // Menu in the rail on any section but Home goes Home first (the Apple
        // TV app's behaviour); only Menu on Home leaves the app.
        .onExitCommand(perform: selection != .home ? ({
            withAnimation(Self.railAnimation) {
                selection = .home
                visited.insert(.home)
                focusedItem = .home
            }
        } as () -> Void) : nil)
        // Entering the rail always lands on the section you're *in* — not on
        // whichever item happens to sit level with the focused card (tvOS's
        // geometric default). `.userInitiated` makes this apply on every
        // ← into the rail, not just the first focus pass.
        .defaultFocus($focusedItem, selection, priority: .userInitiated)
    }

    @ViewBuilder
    private var railHeader: some View {
        Group {
            if railExpanded {
                Wordmark(size: 30).padding(.leading, 34)
            } else {
                Text("A+")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Wordmark.chrome)
                    .frame(width: Self.collapsed, alignment: .center)
            }
        }
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    private var railBackground: some View {
        ZStack {
            // Collapsed: a soft leading scrim so the icons stay legible over
            // bright artwork without reading as a panel.
            LinearGradient(colors: [Palette.canvas.opacity(0.9), Palette.canvas.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .opacity(railExpanded ? 0 : 1)
            // Expanded: a solid floating panel.
            Rectangle().fill(Palette.surface.opacity(0.55))
                .background(Palette.canvas)
                .opacity(railExpanded ? 1 : 0)
        }
        .ignoresSafeArea()
    }

    private func select(_ item: Section) {
        selection = item
        visited.insert(item)
        // Clicking a rail item commits it and dives into the content (the
        // section already switched on focus). Moving up/down without clicking
        // keeps you in the rail to browse. Focus is *moved* into the content
        // scope — clearing it instead let the engine fall back to the rail's
        // first item and switch to Home.
        withAnimation(Self.railAnimation) { resetFocus(in: contentScope) }
    }

    // MARK: Content

    private var content: some View {
        ZStack {
            ForEach(Section.allCases) { section in
                if shouldMount(section) {
                    sectionView(section)
                        .opacity(section == selection ? 1 : 0)
                        .allowsHitTesting(section == selection)
                        .accessibilityHidden(section != selection)
                        .disabled(section != selection)
                        .zIndex(section == selection ? 1 : 0)
                }
            }
        }
        // A quick crossfade between sections instead of a hard cut as focus
        // moves down the rail.
        .animation(.easeInOut(duration: 0.16), value: selection)
    }

    /// The selected screen is always mounted. A screen you've visited stays
    /// mounted too — but only once the library has finished loading, so a cold
    /// import isn't shaping several off-screen screens at once.
    private func shouldMount(_ section: Section) -> Bool {
        section == selection || (visited.contains(section) && env.catalogComplete)
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        switch section {
        case .home:      HomeView()
        case .search:    SearchView()
        case .liveTV:    LiveTVBrowseView()
        case .guide:     GuideView()
        case .movies:    VODBrowseView(kind: .movies)
        case .series:    VODBrowseView(kind: .series)
        case .favorites: FavoritesView()
        case .history:   HistoryView()
        case .settings:  SettingsView()
        }
    }
}

/// Applies `.onExitCommand` only when `enabled` — `.onExitCommand` always
/// consumes the press, so on Home we must not attach it at all.
private struct MenuReturnsToSidebar: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onExitCommand(perform: action)
        } else {
            content
        }
    }
}

private struct SidebarItem: View {
    let section: SidebarShell.Section
    let isSelected: Bool
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space2) {
                Image(systemName: section.icon)
                    .font(.system(size: 25))
                    .frame(width: 44, height: 30)
                if expanded {
                    Text(section.title)
                        .font(.dsBody)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 36)   // keeps the icon column fixed across states
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .buttonStyle(SidebarButtonStyle(isSelected: isSelected, expanded: expanded))
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    let isSelected: Bool
    let expanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarButtonBody(configuration: configuration, isSelected: isSelected, expanded: expanded)
    }
}

private struct SidebarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let expanded: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.vertical, Metrics.space1 + 4)
            .foregroundStyle(textColor)
            .background(alignment: .leading) { highlight }
            .overlay(alignment: .leading) {
                // Slim brand marker on the active section (not while focused).
                if isSelected && !isFocused {
                    Capsule().fill(Palette.accent)
                        .frame(width: 4, height: 24)
                        .offset(x: 10)
                }
            }
            .scaleEffect(isFocused ? 1.04 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: isFocused ? 18 : 0, y: isFocused ? 8 : 0)
            .animation(Metrics.focusAnimation, value: isFocused)
    }

    /// Collapsed: a compact rounded backing behind the icon. Expanded: a
    /// full-width pill inset from the rail edges.
    @ViewBuilder
    private var highlight: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(fill)
            .frame(maxWidth: expanded ? .infinity : 72, alignment: .leading)
            .frame(height: 56)
            .padding(.leading, expanded ? Metrics.space2 : 22)
            .padding(.trailing, expanded ? Metrics.space2 : 0)
    }

    private var textColor: Color {
        if isFocused { return Palette.canvas }              // dark label on the bright highlight
        if isSelected { return Palette.textPrimary }
        return Palette.textSecondary
    }

    private var fill: Color {
        if isFocused { return Palette.focusFill }
        if isSelected { return .white.opacity(0.08) }
        return .clear
    }
}

/// Shown across the top when the Apple TV has no network — everything here needs
/// one (the provider, artwork, streams).
private struct OfflinePill: View {
    var body: some View {
        HStack(spacing: Metrics.space1) {
            Image(systemName: "wifi.slash")
            Text("Du är offline — kontrollera nätverket")
        }
        .font(.dsCaption)
        .foregroundStyle(Palette.textPrimary)
        .padding(.horizontal, Metrics.space2)
        .padding(.vertical, Metrics.space1)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.liveDot.opacity(0.5)))
        .padding(.top, Metrics.space2)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Slim non-blocking status shown over any screen while the library imports or
/// if the last refresh failed.
private struct LibraryStatusPill: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch env.loadState {
            case .loading:
                pill {
                    HStack(spacing: Metrics.space1) {
                        ProgressView().controlSize(.small).tint(Palette.textPrimary)
                        Text(env.reachedPhases.contains(.guide)
                             ? "Organiserar ditt bibliotek…"
                             : "Importerar ditt bibliotek…")
                    }
                }
            case .failed(let error):
                pill {
                    HStack(spacing: Metrics.space1) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error.title)
                        Button("Försök igen") { Task { await env.bootstrap(forceReload: true) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            case .idle, .ready:
                EmptyView()
            }
        }
        .padding(.top, Metrics.space2)
        .animation(.easeInOut, value: statusKey)
    }

    private var statusKey: Int {
        switch env.loadState {
        case .idle: return 0
        case .loading: return 1
        case .ready: return 2
        case .failed: return 3
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.dsCaption)
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, Metrics.space2)
            .padding(.vertical, Metrics.space1)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
    }
}
