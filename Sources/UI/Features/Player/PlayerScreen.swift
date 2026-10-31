import SwiftUI
import AVKit
import UIKit

/// Full-screen playback. Hosts Apple's native `AVPlayerViewController` and lays
/// a friendly error state over it if the stream fails. For live channels it also
/// offers channel zapping — a transport-bar "Channels" menu plus prev/next.
struct PlayerScreen: View {
    let item: PlaybackItem
    /// Sibling channels for zapping (live only). `nil` for movies / episodes.
    var lineup: ChannelLineup? = nil
    /// Resolve a `PlaybackItem` for a channel we're zapping to.
    var makePlayback: (@MainActor (Channel) async -> PlaybackItem?)? = nil
    /// "Now playing" text for the channel banner, if EPG is available.
    var nowText: (@MainActor (Channel) async -> String?)? = nil
    /// Batched "on now" for the zap panel's visible channels.
    var nowTexts: (@MainActor ([Channel]) async -> [CatalogID: String])? = nil
    /// The viewer's language preferences, applied to the stream's tracks.
    var preferredAudio: [Language] = []
    var preferredSubtitle: Language? = nil
    /// The episode to roll into when this one ends (see
    /// `AppEnvironment.nextEpisodePlayback`). `nil` → the player closes at the end.
    var nextItem: (@MainActor (PlaybackItem) async -> PlaybackItem?)? = nil
    let onProgress: @MainActor (CatalogID, ContentKind, Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: PlayerModel?
    /// What's playing now — `item` until an Up Next hand-off replaces it.
    @State private var current: PlaybackItem?
    /// The episode counting down to start, and the seconds left.
    @State private var upNext: PlaybackItem?
    @State private var upNextSeconds = 0
    private static let upNextDelay = 8

    private var playing: PlaybackItem { current ?? item }
    @State private var currentLineup: ChannelLineup?
    @State private var showChannelPanel = false
    @State private var banner: ChannelBanner.Info?
    /// "On now" for the Info panel's channel strip.
    @State private var infoNow: [CatalogID: String] = [:]

    private var canZap: Bool {
        (currentLineup?.channels.count ?? 0) > 1 && makePlayback != nil
    }

    var body: some View {
        ZStack {
            switch PlaybackEngine.choose(for: playing.url) {
            case .vlc:
                VLCPlayerScreen(item: playing,
                                preferredAudio: preferredAudio,
                                preferredSubtitle: preferredSubtitle,
                                onProgress: onProgress,
                                onFinished: { [finished = playing] in handleFinished(finished) })
                    .id(playing.id)
            case .system:
                systemBody
            }

            if let next = upNext {
                UpNextCard(item: next, seconds: upNextSeconds, total: Self.upNextDelay)
                    .padding(Metrics.screenMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.35), value: upNext?.id)
        .task(id: upNext?.id) {
            guard let next = upNext else { return }
            while upNextSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                upNextSeconds -= 1
            }
            upNext = nil
            advance(to: next)
        }
    }

    /// The current item played to its end: count down into the next episode
    /// in place (no dismiss, no detail-screen flash), or close when there's
    /// nothing after it.
    private func handleFinished(_ finished: PlaybackItem) {
        guard let nextItem else { dismiss(); return }
        Task { @MainActor in
            if let next = await nextItem(finished) {
                upNextSeconds = Self.upNextDelay
                upNext = next
            } else {
                dismiss()
            }
        }
    }

    private func advance(to next: PlaybackItem) {
        let from = PlaybackEngine.choose(for: playing.url)
        let to = PlaybackEngine.choose(for: next.url)
        if from == .system, to == .system, let model {
            // Same AVPlayer, new item — no black flash.
            model.switchTo(next)
            current = next
            return
        }
        if from == .system {
            // Handing over to VLC (an MKV episode after an HLS one, say).
            model?.teardown()
            model = nil
        }
        current = next
    }

    private var systemBody: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                if case .failed(let error) = model.state {
                    VStack(spacing: Metrics.space3) {
                        ErrorStateView(
                            error: error,
                            onRetry: canRetry(error) ? { model.retry() } : nil,
                            onEditProvider: nil
                        )
                        Button("Close", action: { dismiss() })
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.95))
                    .ignoresSafeArea()
                } else {
                    SystemPlayerView(
                        player: model.player,
                        channelActions: canZap ? SystemPlayerView.ChannelActions(
                            openList: { showChannelPanel = true },
                            next: { zap(offset: 1) },
                            previous: { zap(offset: -1) }
                        ) : nil,
                        onSleep: item.isLive ? nil : { model.setSleepTimer(minutes: $0) },
                        allowsSpeeds: !item.isLive,
                        infoChannels: canZap ? currentLineup.map { lineup in
                            SystemPlayerView.InfoChannels(
                                channels: lineup.channels,
                                currentID: model.activeItem.id,
                                nowByID: infoNow,
                                pick: { switchTo($0) }
                            )
                        } : nil
                    )
                    .ignoresSafeArea()

                    if model.state == .loading || model.isStalling {
                        PlaybackLoadingOverlay(
                            title: model.activeItem.title,
                            subtitle: model.activeItem.subtitle,
                            isStalling: model.isStalling
                        )
                        .transition(.opacity)
                    }

                    if let info = banner {
                        ChannelBanner(info: info)
                            .padding(Metrics.screenMargin)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showChannelPanel) {
            if let lineup = currentLineup {
                ChannelZapPanel(
                    lineup: lineup,
                    nowTexts: nowTexts,
                    onPick: { channel in
                        showChannelPanel = false
                        switchTo(channel)
                    },
                    onClose: { showChannelPanel = false }
                )
            }
        }
        .animation(.easeInOut(duration: 0.25), value: banner?.id)
        .animation(.easeInOut(duration: 0.28), value: model?.state == .loading)
        .animation(.easeInOut(duration: 0.28), value: model?.isStalling)
        .onAppear {
            currentLineup = lineup
            if model == nil {
                let m = PlayerModel(item: playing,
                                    preferredAudio: preferredAudio,
                                    preferredSubtitle: preferredSubtitle) { played, position, duration in
                    onProgress(played.id, played.kind, position, duration)
                }
                m.onFinished = { [weak m] in
                    guard let m else { return }
                    handleFinished(m.activeItem)
                }
                m.onSleepFired = { dismiss() }
                model = m
                m.play()
            }
        }
        .onDisappear { model?.teardown() }
        .task {
            // Fill the Info panel's channel strip with what's on.
            guard canZap, let nowTexts, let lineup = currentLineup ?? lineup else { return }
            infoNow = await nowTexts(Array(lineup.channels.prefix(200)))
        }
        .task(id: banner?.id) {
            guard banner != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            banner = nil
        }
    }

    private func zap(offset: Int) {
        guard let next = currentLineup?.channel(offset: offset) else { return }
        switchTo(next)
    }

    private func switchTo(_ channel: Channel) {
        guard let model, let makePlayback else { return }
        Task { @MainActor in
            guard let next = await makePlayback(channel) else { return }
            model.switchTo(next)
            currentLineup = currentLineup?.moved(to: channel.id)
            var now: String?
            if let nowText { now = await nowText(channel) }
            banner = ChannelBanner.Info(channelName: channel.name,
                                        category: channel.category,
                                        nowPlaying: now)
        }
    }

    private func canRetry(_ error: ProviderError) -> Bool {
        if case .streamNotSupported = error { return false }
        return true
    }
}

/// "Up Next" — the episode the player rolls into when this one ends, with a
/// ring that drains over the countdown. Menu during the countdown leaves the
/// player as usual.
private struct UpNextCard: View {
    let item: PlaybackItem
    let seconds: Int
    let total: Int

    var body: some View {
        HStack(spacing: Metrics.space3) {
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(seconds) / CGFloat(max(total, 1)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: seconds)
                Text("\(seconds)")
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 66, height: 66)

            VStack(alignment: .leading, spacing: 4) {
                Text("UP NEXT")
                    .font(.dsTag)
                    .tracking(Metrics.eyebrowTracking)
                    .foregroundStyle(.white.opacity(0.6))
                Text(item.title)
                    .font(.dsCardTitle)
                    .lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(Metrics.space3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Up next: \(item.title), \(item.subtitle ?? ""), starts in \(seconds) seconds")
    }
}

/// What you look at while a stream opens. A bare spinner on black reads as
/// "something is broken"; naming the thing you just chose reads as "it's
/// coming". Doubles as the buffering state mid-playback.
private struct PlaybackLoadingOverlay: View {
    let title: String
    let subtitle: String?
    let isStalling: Bool

    var body: some View {
        VStack(spacing: Metrics.space3) {
            ProgressView().controlSize(.large).tint(.white)

            VStack(spacing: 6) {
                Text(title)
                    .font(.dsCardTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.dsCaption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                Text(isStalling ? "Buffering…" : "Starting…")
                    .font(.dsTag)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 2)
            }
            .frame(maxWidth: 900)
            .multilineTextAlignment(.center)
        }
        .padding(Metrics.space5)
        // A scrim only while the picture is still black; once frames are
        // arriving (a stall) it stays light so you can see them resume.
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black.opacity(isStalling ? 0.45 : 0))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isStalling ? "Buffering \(title)" : "Loading \(title)")
    }
}

/// Thin wrapper around `AVPlayerViewController`. Adds custom transport-bar menu
/// items for live channel zapping; callbacks are refreshed through the
/// coordinator so the menu is built only once.
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var channelActions: ChannelActions? = nil
    /// Set a sleep timer (minutes), or `nil` to turn it off. VOD only.
    var onSleep: ((Int?) -> Void)? = nil
    /// Offer playback speeds (VOD only).
    var allowsSpeeds = false
    /// Live TV: a "Channels" tab in the swipe-down Info panel.
    var infoChannels: InfoChannels? = nil

    struct InfoChannels {
        var channels: [Channel]
        var currentID: CatalogID
        var nowByID: [CatalogID: String]
        var pick: (Channel) -> Void
    }

    struct ChannelActions {
        var openList: () -> Void
        var next: () -> Void
        var previous: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(actions: channelActions, onSleep: onSleep) }

    final class Coordinator {
        var actions: ChannelActions?
        var onSleep: ((Int?) -> Void)?
        var channelHost: UIHostingController<InfoPanelChannels>?
        init(actions: ChannelActions?, onSleep: ((Int?) -> Void)?) {
            self.actions = actions
            self.onSleep = onSleep
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.showsPlaybackControls = true
        // 0.5×–2× in the transport bar for films and episodes (live can't
        // change speed, so the menu would only confuse there).
        controller.speeds = allowsSpeeds ? AVPlaybackSpeed.systemDefaultSpeeds : []

        let coordinator = context.coordinator
        var items: [UIMenuElement] = []

        if channelActions != nil {
            items += [
                UIAction(title: "Previous Channel",
                         image: UIImage(systemName: "backward.end.fill")) { _ in coordinator.actions?.previous() },
                UIAction(title: "Channels",
                         image: UIImage(systemName: "list.bullet")) { _ in coordinator.actions?.openList() },
                UIAction(title: "Next Channel",
                         image: UIImage(systemName: "forward.end.fill")) { _ in coordinator.actions?.next() },
            ]
        }

        if onSleep != nil {
            var options: [UIMenuElement] = [15, 30, 45, 60].map { minutes -> UIMenuElement in
                UIAction(title: "\(minutes) minutes") { _ in coordinator.onSleep?(minutes) }
            }
            options.append(UIAction(title: "Off") { _ in coordinator.onSleep?(nil) })
            items.append(UIMenu(title: "Sleep Timer",
                                image: UIImage(systemName: "moon.zzz"),
                                children: options))
        }

        if !items.isEmpty {
            controller.transportBarCustomMenuItems = items
        }

        if let info = infoChannels {
            let host = UIHostingController(rootView: Self.channelStrip(info))
            host.title = "Channels"
            host.preferredContentSize = CGSize(width: 1920, height: 240)
            controller.customInfoViewControllers = [host]
            coordinator.channelHost = host
        }
        return controller
    }

    private static func channelStrip(_ info: InfoChannels) -> InfoPanelChannels {
        InfoPanelChannels(channels: info.channels, currentID: info.currentID,
                          nowByID: info.nowByID, onPick: info.pick)
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.actions = channelActions
        context.coordinator.onSleep = onSleep
        if let info = infoChannels {
            context.coordinator.channelHost?.rootView = Self.channelStrip(info)
        }
        if controller.player !== player {
            controller.player = player
        }
    }
}
