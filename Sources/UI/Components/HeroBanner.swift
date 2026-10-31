import SwiftUI

/// Home's featured banner — a rotating set of top titles with a full-bleed
/// cinematic backdrop (resolved from TMDB when the provider gave none). The
/// backdrop + copy crossfade on a timer; the action button and page dots stay
/// put so focus is never dropped mid-rotation.
struct HeroBanner: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let heroes: [HomeCard]
    let onSelect: (HomeCard) -> Void

    private enum Control: Hashable { case play, info }

    @State private var index = 0
    @State private var overview: String?
    /// Drives the slow "Ken Burns" push-in on the backdrop. Reset without
    /// animation on every new hero, then eased toward 1 over the hold time —
    /// a scale on one already-composited layer, so it costs the GPU nothing
    /// worth measuring.
    @State private var drift = false
    @State private var playback: PlaybackItem?
    @FocusState private var focusedControl: Control?

    /// The first time Home shows a hero in a session, focus lands on its main
    /// button — the app opens on "Play", like the Apple TV app, not on a dimmed
    /// screen behind an expanded menu. Once only, so coming back to Home from
    /// the rail leaves focus where the viewer put it.
    @MainActor private static var claimedLaunchFocus = false

    private let interval: Duration = .seconds(9)
    /// Tall enough to feel cinematic on a 1080-pt canvas while the first
    /// shelf still peeks up into the bottom fade (`shelfOverlap`).
    static let height: CGFloat = 800
    /// How far the first shelf below rides up over the hero's fade.
    static let shelfOverlap: CGFloat = 170
    private var height: CGFloat { Self.height }

    private var current: HomeCard? {
        guard !heroes.isEmpty else { return nil }
        return heroes[min(index, heroes.count - 1)]
    }

    /// Restart the rotation whenever the set *or its lead item* changes, not just
    /// its length.
    private var heroKey: String { "\(heroes.count)-\(heroes.first?.id.rawValue ?? "")" }

    var body: some View {
        if let hero = current {
            ZStack(alignment: .bottomLeading) {
                backdrop(for: hero)
                overlayContent(for: hero)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .task(id: hero.id) { await resolveOverview(for: hero) }
            .task(id: hero.id) { await startDrift() }
            .task { await claimLaunchFocus(for: hero) }
            .task(id: heroKey) {
                if index >= heroes.count { index = 0 }
                await rotate()
            }
            .fullScreenCover(item: $playback) { item in
                PlayerScreen(
                    item: item,
                    preferredAudio: env.preferences.preferences.preferredAudioLanguages,
                    preferredSubtitle: env.preferences.preferences.preferredSubtitleLanguage
                ) { id, kind, position, duration in
                    env.recordProgress(id: id, kind: kind, position: position, duration: duration)
                }
            }
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private func backdrop(for hero: HomeCard) -> some View {
        ZStack {
            if let ref = hero.artworkRef {
                EnrichedArtwork(ref: ref, providerURL: hero.artworkURL,
                                aspect: 16.0 / 7.0, style: .backdrop)
            } else {
                ArtworkView(url: hero.artworkURL, title: hero.title, aspect: 16.0 / 7.0,
                            style: .backdrop, size: .backdrop)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .scaleEffect(drift ? 1.07 : 1.0, anchor: .center)
        .clipped()
        .id(hero.id)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: hero.id)
        .overlay(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Palette.canvas.opacity(0.15), location: 0.35),
                    .init(color: Palette.canvas.opacity(0.7), location: 0.72),
                    .init(color: Palette.canvas.opacity(0.97), location: 0.92),
                    .init(color: Palette.canvas, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(
            LinearGradient(
                colors: [Palette.canvas.opacity(0.8), Palette.canvas.opacity(0.2), .clear],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    private func overlayContent(for hero: HomeCard) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Group {
                if let eyebrow = hero.eyebrow, !eyebrow.isEmpty {
                    Text(eyebrow)
                        .font(.dsTag)
                        .foregroundStyle(Palette.textSecondary)
                        .textCase(.uppercase)
                        .tracking(Metrics.eyebrowTracking)
                }
                Text(hero.title)
                    .font(.dsHero)
                    .lineLimit(2)
                    .tracking(Metrics.heroTracking)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
                if let line = overview ?? hero.subtitle, !line.isEmpty {
                    Text(line)
                        .font(.dsBody)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: 780, alignment: .leading)
                }
            }
            .id(hero.id)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: hero.id)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: overview)
            .accessibilityElement(children: .combine)

            HStack(alignment: .center, spacing: Metrics.space2) {
                if hero.kind == .movie {
                    Button {
                        Task { playback = await env.playback(forMovie: hero.id) }
                    } label: {
                        Label("Spela", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .focused($focusedControl, equals: .play)
                    .accessibilityLabel("Spela \(hero.title)")

                    Button { onSelect(hero) } label: {
                        Label("Mer info", systemImage: "info.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .focused($focusedControl, equals: .info)
                    .accessibilityLabel("Mer info, \(hero.title)")
                } else {
                    Button { onSelect(hero) } label: {
                        Label("Mer info", systemImage: "info.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .focused($focusedControl, equals: .info)
                    .accessibilityLabel("Mer info, \(hero.title)")
                }

                if heroes.count > 1 { pageDots }
            }
            .padding(.top, Metrics.space3)
        }
        .padding(.horizontal, Metrics.screenMargin)
        // Clear the shelf that rides up over the bottom of the banner.
        .padding(.bottom, Self.shelfOverlap + Metrics.space4)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(heroes.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? Palette.textPrimary : Palette.textPrimary.opacity(0.25))
                    .frame(width: i == index ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
        .accessibilityHidden(true)
    }

    // MARK: - Behaviour

    private func resolveOverview(for hero: HomeCard) async {
        overview = nil
        guard let ref = hero.artworkRef else { return }
        let meta = await env.metadata.metadata(
            for: ref.id, title: ref.title, year: ref.year, isSeries: ref.isSeries
        )
        if let text = meta?.overview { overview = text }
    }

    private func claimLaunchFocus(for hero: HomeCard) async {
        guard !Self.claimedLaunchFocus else { return }
        Self.claimedLaunchFocus = true
        // A beat for the focus engine to finish its own initial pass first.
        try? await Task.sleep(for: .milliseconds(150))
        focusedControl = hero.kind == .movie ? .play : .info
    }

    private func startDrift() async {
        guard !reduceMotion else { return }
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { drift = false }
        // Let the reset commit as its own frame — set back-to-back, SwiftUI
        // would coalesce false→true into "no change" and never animate.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        withAnimation(.linear(duration: 14)) { drift = true }
    }

    private func rotate() async {
        // Reduce Motion: hold on the top title, no auto-advance.
        guard heroes.count > 1, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, focusedControl == nil, playback == nil else { continue }
            withAnimation(.easeInOut(duration: 0.6)) {
                index = (index + 1) % heroes.count
            }
        }
    }
}
