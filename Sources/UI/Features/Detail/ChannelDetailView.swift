import SwiftUI

/// Live channel screen: what's on now, what's next, a "Later today" schedule,
/// and the controls to start watching or favourite the channel.
struct ChannelDetailView: View {
    let channelID: CatalogID

    @Environment(AppEnvironment.self) private var env
    @State private var channel: Channel?
    @State private var schedule: [EPGEvent] = []
    @State private var playback: PlaybackItem?
    @State private var lineup: [Channel] = []
    @State private var now = Date()

    var body: some View {
        Group {
            if let channel {
                DetailScaffold(title: channel.name, backdropURL: nil) {
                    header(channel)
                    controls(channel)
                    if let live = liveEvent {
                        onNow(live)
                    }
                    laterToday
                    LanguageSummary(audio: channel.audioLanguages, subtitles: channel.subtitleLanguages)
                }
            } else {
                ProgressView().controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: channelID) { await load() }
        .task {
            // Keep "on now" / progress fresh without a Combine timer.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
        .onChange(of: env.catalogRevision) { _, _ in
            if channel == nil { Task { await load() } }
        }
        .fullScreenCover(item: $playback) { item in
            PlayerScreen(
                item: item,
                lineup: ChannelLineup(channels: lineup, currentID: item.id),
                makePlayback: { channel in await env.playback(forChannel: channel.id) },
                nowText: { channel in
                    guard let epgID = channel.epgID else { return nil }
                    return await env.repository.nowPlaying(forEPGID: epgID, at: .now)?.title
                },
                nowTexts: { channels in
                    // One windowed query for the whole page of the zap list.
                    let now = Date()
                    let window = DateInterval(start: now.addingTimeInterval(-4 * 3600),
                                              end: now.addingTimeInterval(4 * 3600))
                    let epg = await env.repository.epgIndex(
                        forEPGIDs: channels.compactMap(\.epgID), in: window
                    )
                    var out: [CatalogID: String] = [:]
                    for channel in channels {
                        guard let epgID = channel.epgID,
                              let event = epg.nowPlaying(forChannel: epgID, at: now) else { continue }
                        out[channel.id] = event.title
                    }
                    return out
                },
                preferredAudio: env.preferences.preferences.preferredAudioLanguages,
                preferredSubtitle: env.preferences.preferences.preferredSubtitleLanguage
            ) { id, kind, position, duration in
                env.recordProgress(id: id, kind: kind, position: position, duration: duration)
            }
        }
    }

    // MARK: - Data

    private func load() async {
        channel = await env.repository.channel(id: channelID)
        if let epgID = channel?.epgID {
            let window = DateInterval(start: Date().addingTimeInterval(-3600),
                                      end: Date().addingTimeInterval(12 * 3600))
            schedule = await env.repository.epgEvents(forEPGID: epgID, in: window)
        }
        if lineup.isEmpty {
            // "For you" order — enough for zapping through nearby channels.
            lineup = await env.repository.channels(in: nil, sort: .number, page: 0, pageSize: 3000)
        }
    }

    private var liveEvent: EPGEvent? { schedule.first { $0.isLive(at: now) } }

    private var upcoming: [EPGEvent] {
        schedule.filter { $0.start > now }.prefix(8).map { $0 }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(_ channel: Channel) -> some View {
        HStack(alignment: .bottom, spacing: Metrics.space4) {
            if let logo = channel.logoURL {
                CachedImage(url: logo, contentMode: .fit, size: .logo) { EmptyView() }
                    .frame(width: 150, height: 150)
                    .padding(Metrics.space2)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous).strokeBorder(Palette.hairline))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text(channel.name).font(.dsHero).tracking(Metrics.heroTracking).lineLimit(2)
                MetadataLine([
                    channel.category,
                    channel.quality > .unknown ? channel.quality.shortLabel : nil,
                    channel.countryCode,
                ])
            }
        }
    }

    @ViewBuilder
    private func controls(_ channel: Channel) -> some View {
        HStack(spacing: Metrics.space2) {
            Button {
                Task { playback = await env.playback(forChannel: channel.id) }
            } label: {
                Label("Watch Live", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                env.favorites.toggle(id: channel.id, kind: .liveChannel)
            } label: {
                Image(systemName: env.favorites.isFavorite(channel.id) ? "heart.fill" : "heart")
                    .symbolEffect(.bounce, value: env.favorites.isFavorite(channel.id))
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(env.favorites.isFavorite(channel.id) ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    @ViewBuilder
    private func onNow(_ event: EPGEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On now").font(.dsCaption).foregroundStyle(Palette.textTertiary)
            Text(event.title).font(.dsCardTitle).foregroundStyle(Palette.textPrimary)
            if let desc = event.description, !desc.isEmpty {
                Text(desc).font(.dsCaption).foregroundStyle(Palette.textSecondary).lineLimit(3)
                    .frame(maxWidth: 900, alignment: .leading)
            }
            ProgressView(value: event.progress(at: now)).tint(Palette.accent).frame(maxWidth: 520)
            Text("\(timeLabel(event.start))–\(timeLabel(event.stop))")
                .font(.dsTag).foregroundStyle(Palette.textTertiary)
        }
    }

    @ViewBuilder
    private var laterToday: some View {
        let items = upcoming
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text("Later today").font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
                ForEach(items) { event in
                    HStack(alignment: .top, spacing: Metrics.space3) {
                        Text(timeLabel(event.start))
                            .font(.dsCardTitle).foregroundStyle(Palette.textSecondary)
                            .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title).font(.dsCardTitle).foregroundStyle(Palette.textPrimary).lineLimit(1)
                            if let subtitle = event.subtitle ?? event.category, !subtitle.isEmpty {
                                Text(subtitle).font(.dsTag).foregroundStyle(Palette.textTertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func timeLabel(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
