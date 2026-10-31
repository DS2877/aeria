import SwiftUI
import Observation

struct GuideChannelRow: Identifiable, Sendable {
    let id: CatalogID
    let name: String
    let logoURL: URL?
    let events: [EPGEvent]
}

@MainActor
@Observable
final class GuideViewModel {
    private(set) var rows: [GuideChannelRow] = []
    private(set) var isLoading = true
    /// The guide is capped so a 15k-channel provider doesn't build 15k rows.
    private(set) var truncated = false
    /// The guide's clock — LIVE badges, progress bars and the "on now" focus
    /// target all read it. Ticked every minute while the guide is on screen.
    private(set) var now = Date()
    private var loadedAt = Date.distantPast

    /// Advance the clock; reload the schedule when it has been a while, so the
    /// window (−1 h … +8 h) keeps covering "now".
    func tick() async {
        now = Date()
        if now.timeIntervalSince(loadedAt) > 30 * 60 { await load() }
    }

    /// Most people never scroll past a few hundred channels in a guide.
    private static let rowCap = 250

    private let repository: any CatalogQuerying
    private var pendingLoad: Task<Void, Never>?

    init(repository: any CatalogQuerying) { self.repository = repository }

    /// Coalesced — the catalog revision bumps several times during a staged
    /// import; without this each bump kicks off another full channel scan.
    func load() async {
        pendingLoad?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.performLoad()
        }
        pendingLoad = task
        await task.value
    }

    private func performLoad() async {
        // Keep showing the old rows while refreshing — only the first load
        // shows the skeleton.
        if rows.isEmpty { isLoading = true }
        defer { isLoading = false }
        now = Date()
        loadedAt = now

        let cap = Self.rowCap
        // "For you" order, EPG-carrying channels only — the store already caps it.
        let channels = await repository.guideChannels(limit: cap)
        guard !Task.isCancelled else { return }

        let epgIDs = channels.compactMap(\.epgID)
        let window = DateInterval(start: now.addingTimeInterval(-3600),
                                  end: now.addingTimeInterval(8 * 3600))
        let epg = await repository.epgIndex(forEPGIDs: epgIDs, in: window)
        guard !Task.isCancelled else { return }

        var built: [GuideChannelRow] = []
        for channel in channels {
            guard let epgID = channel.epgID, let events = epg[epgID], !events.isEmpty else { continue }
            built.append(GuideChannelRow(id: channel.id, name: channel.name,
                                         logoURL: channel.logoURL, events: events))
        }
        rows = built
        truncated = channels.count >= cap && built.count == channels.count
    }
}

/// A vertical list of channels; each row is a horizontally-focusable strip of
/// its upcoming programmes. This is a far better fit for the Siri Remote than a
/// dense 2-D timeline grid.
struct GuideView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(SectionModels.self) private var models
    /// False while another sidebar section is showing — the keep-alive shell
    /// disables hidden sections, which is our cue to stop the preview's sound.
    @Environment(\.isEnabled) private var isEnabled
    @State private var model: GuideViewModel?
    @State private var path: [AppRoute] = []

    /// The programme under focus — drives the info pane.
    @FocusState private var focusedEvent: String?
    /// The channel playing in the mini player (one click), and its stream.
    @State private var previewRow: GuideChannelRow?
    @State private var previewItem: PlaybackItem?
    /// Full-screen playback (a second click on the previewed channel).
    @State private var fullScreen: PlaybackItem?
    /// Re-open the preview on this channel when full screen closes.
    @State private var resumePreviewAfterFullScreen: GuideChannelRow?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    Color.clear
                }
            }
            .appThemeBackground()
            // Menu: close the preview first; then back to the sidebar.
            .menuReturnsToSidebar(first: previewItem != nil ? ({ stopPreview() } as () -> Void) : nil)
            .appRouteDestinations()
        }
        .task(id: models.generation) {
            let shared = models.guide(env)
            model = shared
            guard models.needsLoad(.guide, revision: env.catalogRevision) else { return }
            let revision = env.catalogRevision
            await shared.load()
            guard !Task.isCancelled else { return }
            models.markLoaded(.guide, revision: revision)
        }
        .onChange(of: env.catalogRevision) { _, revision in
            models.markLoaded(.guide, revision: revision)
            Task { await model?.load() }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { stopPreview() }
        }
        // Keep LIVE badges and progress current while the guide is showing.
        .task(id: isEnabled) {
            guard isEnabled else { return }
            await model?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await model?.tick()
            }
        }
        .fullScreenCover(item: $fullScreen, onDismiss: {
            if let row = resumePreviewAfterFullScreen {
                resumePreviewAfterFullScreen = nil
                startPreview(row)
            }
        }) { item in
            PlayerScreen(
                item: item,
                preferredAudio: env.preferences.preferences.preferredAudioLanguages,
                preferredSubtitle: env.preferences.preferences.preferredSubtitleLanguage
            ) { id, kind, position, duration in
                env.recordProgress(id: id, kind: kind, position: position, duration: duration)
            }
        }
    }

    // MARK: - Preview

    /// First click: play the channel in the mini player and stay in the guide.
    /// Second click on the same channel: full screen.
    private func activate(_ row: GuideChannelRow) {
        if previewRow?.id == row.id, previewItem != nil {
            openFullScreen(row)
        } else {
            startPreview(row)
        }
    }

    private func startPreview(_ row: GuideChannelRow) {
        previewRow = row
        Task { @MainActor in
            let item = await env.playback(forChannel: row.id, recordView: false)
            guard previewRow?.id == row.id else { return }   // moved on meanwhile
            previewItem = item
        }
    }

    private func stopPreview() {
        previewItem = nil
        previewRow = nil
    }

    private func openFullScreen(_ row: GuideChannelRow) {
        // Release the preview's connection before opening the full stream —
        // many providers allow only one at a time.
        previewItem = nil
        resumePreviewAfterFullScreen = row
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            fullScreen = await env.playback(forChannel: row.id)
        }
    }

    /// The event the info pane describes: the focused programme, else what's
    /// on now on the previewed channel.
    private func paneEvent(_ model: GuideViewModel) -> (row: GuideChannelRow, event: EPGEvent)? {
        if let id = focusedEvent {
            for row in model.rows {
                if let event = row.events.first(where: { $0.id == id }) { return (row, event) }
            }
        }
        if let row = previewRow,
           let event = row.events.first(where: { $0.isLive(at: model.now) }) ?? row.events.first {
            return (row, event)
        }
        return nil
    }

    @ViewBuilder
    private func content(_ model: GuideViewModel) -> some View {
        if model.isLoading {
            SkeletonGuide()
        } else if model.rows.isEmpty, env.loadState.isImporting || !env.catalogComplete {
            SkeletonGuide()
        } else if model.rows.isEmpty {
            EmptyStateView(
                icon: "rectangle.grid.1x2",
                title: "No TV guide",
                message: "Your provider didn't include EPG data, or it hasn't matched your channels yet."
            )
        } else {
            VStack(spacing: 0) {
                infoPane(model)
                    .padding(.horizontal, Metrics.screenMargin)
                    .padding(.top, Metrics.space3)
                    .padding(.bottom, Metrics.space3)
                    .background(Palette.canvas)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
                    .zIndex(1)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.space3) {
                        Color.clear.frame(height: Metrics.space3)
                        ForEach(model.rows) { row in
                            channelRow(row, now: model.now, entryID: row.id == model.rows.first?.id
                                       ? entryFocusID(model) : nil)
                        }
                        if model.truncated {
                            Text("Showing the first \(model.rows.count) channels with guide data. Use Live TV to browse the rest.")
                                .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                                .padding(.horizontal, Metrics.screenMargin)
                                .padding(.top, Metrics.space2)
                        }
                    }
                    .padding(.bottom, Metrics.space7)
                }
            }
            // The info pane at the top has nothing focusable, and tvOS only
            // moves focus to something roughly level with where you are — so
            // → from the sidebar's Guide item found nothing and focus stayed
            // in the rail. The *whole* guide (pane included, top to bottom) is
            // one focus section, so it's always level with the sidebar item;
            // entering it lands — every time — on what's on now on the first
            // channel.
            .focusSection()
            .defaultFocus($focusedEvent, entryFocusID(model), priority: .userInitiated)
        }
    }

    /// Where focus lands when you enter the guide: the programme on now on the
    /// first channel (or its first programme).
    private func entryFocusID(_ model: GuideViewModel) -> String? {
        guard let first = model.rows.first else { return nil }
        return (first.events.first { $0.isLive(at: model.now) } ?? first.events.first)?.id
    }

    /// Top of the guide: what the focused programme is, and the mini player.
    private func infoPane(_ model: GuideViewModel) -> some View {
        HStack(alignment: .top, spacing: Metrics.space5) {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TV Guide").font(.dsSectionHeader).accessibilityAddTraits(.isHeader)
                    Text(model.now.formatted(date: .abbreviated, time: .shortened))
                        .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                }
                if let pane = paneEvent(model) {
                    let row = pane.row, event = pane.event
                    Text(row.name)
                        .font(.dsTag)
                        .foregroundStyle(Palette.textSecondary)
                        .textCase(.uppercase)
                        .tracking(Metrics.eyebrowTracking)
                        .padding(.top, Metrics.space2)
                    Text(event.title)
                        .font(.dsTitle)
                        .lineLimit(2)
                    HStack(spacing: Metrics.space1) {
                        Text("\(event.start.formatted(date: .omitted, time: .shortened))–\(event.stop.formatted(date: .omitted, time: .shortened))")
                            .font(.dsCaption)
                            .foregroundStyle(event.isLive(at: model.now) ? Palette.accent : Palette.textTertiary)
                        if event.isLive(at: model.now) { LiveBadge() }
                    }
                    if let about = event.description ?? event.subtitle, !about.isEmpty {
                        Text(about)
                            .font(.dsCaption)
                            .foregroundStyle(Palette.textSecondary)
                            .lineLimit(3)
                    }
                } else {
                    Text("Select a programme to preview the channel here. Select it again to watch full screen.")
                        .font(.dsCaption)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.top, Metrics.space2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeOut(duration: 0.15), value: focusedEvent)

            previewWindow
        }
        .frame(height: Self.paneHeight)
    }

    private static let paneHeight: CGFloat = 300
    private static let previewWidth: CGFloat = paneHeight * 16 / 9

    @ViewBuilder
    private var previewWindow: some View {
        ZStack {
            if let item = previewItem {
                GuidePreviewPlayer(item: item)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .fill(Palette.surface)
                Image(systemName: "play.tv")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .frame(width: Self.previewWidth, height: Self.paneHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if previewItem != nil, let row = previewRow {
                HStack(spacing: 8) {
                    LiveBadge()
                    Text(row.name).font(.dsTag).lineLimit(1)
                    Text("· Select again for full screen")
                        .font(.dsTag)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: previewItem?.id)
    }

    private func channelRow(_ row: GuideChannelRow, now: Date, entryID: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Metrics.space1) {
                Text(row.name)
                    .font(.dsTag)
                    .foregroundStyle(previewRow?.id == row.id ? Palette.accent : Palette.textSecondary)
                    .textCase(.uppercase)
                    .tracking(Metrics.eyebrowTracking)
                if previewRow?.id == row.id {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                        .accessibilityLabel("Previewing")
                }
            }
            .padding(.horizontal, Metrics.screenMargin)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.space1) {
                    ForEach(row.events.prefix(14)) { event in
                        Button {
                            activate(row)
                        } label: {
                            ProgrammeCell(event: event, now: now)
                        }
                        .buttonStyle(.card)
                        .focused($focusedEvent, equals: event.id)
                        .sectionEntryFocus(event.id == entryID)
                        .accessibilityLabel("\(row.name), \(event.start.formatted(date: .omitted, time: .shortened)), \(event.title)\(event.isLive(at: now) ? ", on now" : "")")
                    }
                }
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.space1)
            }
            .focusSection()
        }
    }
}

private struct ProgrammeCell: View {
    let event: EPGEvent
    let now: Date

    private var live: Bool { event.isLive(at: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(.dsCaption).foregroundStyle(live ? Palette.accent : Palette.textTertiary)
                if live { LiveBadge() }
            }
            Text(event.title)
                .font(.dsCardTitle)
                .foregroundStyle(live ? Palette.textPrimary : Palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if live {
                ProgressView(value: event.progress(at: now)).tint(Palette.accent)
            }
        }
        .padding(Metrics.space2)
        .frame(width: 248, height: 118, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(live ? Palette.accent.opacity(0.55) : .clear, lineWidth: 1.5)
        )
    }
}
