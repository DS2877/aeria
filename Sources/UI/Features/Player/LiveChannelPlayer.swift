import SwiftUI

/// "Click a channel, watch the channel" — the one way every screen starts live
/// TV. Resolves the stream, builds the zapping lineup (your regulars first) and
/// presents the full-screen player with channel up/down, the channel list and
/// the now-playing banner. Attach once per screen:
///
///     .liveChannelPlayer($watchingChannel)
///
/// and set the binding to a channel id to start watching.
struct LiveChannelPlayerModifier: ViewModifier {
    @Binding var channelID: CatalogID?
    @Environment(AppEnvironment.self) private var env
    @State private var playback: PlaybackItem?
    @State private var lineup: [Channel] = []

    func body(content: Content) -> some View {
        content
            .onChange(of: channelID) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    if lineup.isEmpty {
                        lineup = await env.repository.channels(in: nil, sort: .number, page: 0, pageSize: 3000)
                    }
                    playback = await env.playback(forChannel: id)
                    if playback == nil { channelID = nil }
                }
            }
            .fullScreenCover(item: $playback, onDismiss: { channelID = nil }) { item in
                PlayerScreen(
                    item: item,
                    lineup: ChannelLineup(channels: lineup, currentID: item.id),
                    makePlayback: { channel in await env.playback(forChannel: channel.id) },
                    nowText: { channel in
                        guard let epgID = channel.epgID else { return nil }
                        return await env.repository.nowPlaying(forEPGID: epgID, at: .now)?.title
                    },
                    nowTexts: { channels in
                        let now = Date()
                        let window = DateInterval(start: now.addingTimeInterval(-4 * 3600),
                                                  end: now.addingTimeInterval(4 * 3600))
                        let epg = await env.repository.epgIndex(forEPGIDs: channels.compactMap(\.epgID),
                                                                in: window)
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
}

extension View {
    /// Present live playback for whichever channel `channelID` is set to.
    func liveChannelPlayer(_ channelID: Binding<CatalogID?>) -> some View {
        modifier(LiveChannelPlayerModifier(channelID: channelID))
    }
}

/// Long-press actions every channel card offers: open its info page, and
/// heart / un-heart it.
struct ChannelContextMenu: View {
    let channelID: CatalogID
    let onInfo: () -> Void
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Button(action: onInfo) {
            Label("Channel Info & Schedule", systemImage: "info.circle")
        }
        let isFavorite = env.favorites.isFavorite(channelID)
        Button {
            env.favorites.toggle(id: channelID, kind: .liveChannel)
        } label: {
            Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: isFavorite ? "heart.slash" : "heart")
        }
    }
}
