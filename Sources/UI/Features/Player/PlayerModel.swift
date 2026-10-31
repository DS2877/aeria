import Foundation
import AVFoundation
import Observation
import UIKit

/// Owns the `AVPlayer` lifecycle for one `PlaybackItem`: start/resume, periodic
/// progress reporting, and failure detection mapped to a friendly message.
///
/// The player *UI* is Apple's `AVPlayerViewController` (see
/// `SystemPlayerView`) — this type never rebuilds transport controls.
@MainActor
@Observable
public final class PlayerModel {

    public enum State: Equatable {
        case loading
        case playing
        case failed(ProviderError)
    }

    public private(set) var state: State = .loading
    /// `true` when playback has started but the buffer ran dry — the UI shows a
    /// spinner over the paused picture rather than a hard error.
    public private(set) var isStalling = false

    @ObservationIgnored public let player: AVPlayer
    /// The item playback started with.
    @ObservationIgnored public let item: PlaybackItem
    /// The item currently loaded — changes when the user zaps between channels.
    public private(set) var activeItem: PlaybackItem

    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var hasSeekedToResume = false
    @ObservationIgnored private var loadTimeout: Task<Void, Never>?
    /// Live streams hiccup; reconnect silently a couple of times before giving up.
    @ObservationIgnored private var autoRetries = 0

    /// Called ~every 10s and on teardown with the current position. No-op for live.
    @ObservationIgnored
    private let onProgress: @MainActor (_ item: PlaybackItem, _ position: Double, _ duration: Double) -> Void

    /// Fired when the item plays to its end, so the host can dismiss and let
    /// "up next" take over.
    @ObservationIgnored public var onFinished: (@MainActor () -> Void)?

    /// Fired when the sleep timer elapses — the host dismisses the player.
    @ObservationIgnored public var onSleepFired: (@MainActor () -> Void)?

    /// Minutes remaining on the sleep timer, or `nil` when it's off.
    public private(set) var sleepMinutes: Int?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    /// The user's preferred spoken / subtitle languages, applied once the item
    /// is ready. Empty / nil means "leave the stream's default".
    @ObservationIgnored private let preferredAudio: [Language]
    @ObservationIgnored private let preferredSubtitle: Language?
    @ObservationIgnored private var hasAppliedLanguages = false

    public init(
        item: PlaybackItem,
        preferredAudio: [Language] = [],
        preferredSubtitle: Language? = nil,
        onProgress: @escaping @MainActor (PlaybackItem, Double, Double) -> Void
    ) {
        self.item = item
        self.activeItem = item
        self.preferredAudio = preferredAudio
        self.preferredSubtitle = preferredSubtitle
        self.onProgress = onProgress
        self.player = AVPlayer(url: item.url)
        self.player.automaticallyWaitsToMinimizeStalling = true

        // Refuse obviously unplayable streams up front rather than spinning.
        if case .unsupported(let reason) = StreamCompatibility.verdict(for: item.url) {
            state = .failed(.streamNotSupported(detail: reason))
            return
        }
        configure()
        startLoadTimeout()
    }

    private func startLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.state == .loading else { return }
            self.fail(with: nil)
        }
    }

    private func configure() {
        guard let currentItem = player.currentItem else { return }

        // Populate the tvOS Info panel / "What's playing" — AVPlayerViewController
        // reads this off the item, so it never fights our values.
        currentItem.externalMetadata = externalMetadata()
        loadInfoPanelArtwork(for: currentItem)

        statusObservation = currentItem.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor in self?.handleStatusChange(status) }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            let waiting = observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                guard let self else { return }
                self.isStalling = waiting && self.state == .playing
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail(with: nil) }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePlayedToEnd() }
        }

        if !activeItem.isLive {
            let interval = CMTime(seconds: 10, preferredTimescale: 1)
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportProgress() }
            }
        }
    }

    public func play() {
        player.play()
    }

    /// Start (or, with `nil`, cancel) a sleep timer. When it elapses the player
    /// pauses and the host is asked to dismiss.
    public func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes, minutes > 0 else { sleepMinutes = nil; return }
        sleepMinutes = minutes
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            self.sleepMinutes = nil
            self.player.pause()
            self.onSleepFired?()
        }
    }

    public func retry() {
        removeObservers()
        state = .loading
        hasSeekedToResume = false
        player.replaceCurrentItem(with: AVPlayerItem(url: activeItem.url))
        configure()
        startLoadTimeout()
        player.play()
    }

    /// Swap to a different stream in place — used for live channel zapping.
    /// Keeps the same `AVPlayer` and view controller so there's no black flash.
    public func switchTo(_ newItem: PlaybackItem) {
        guard newItem.url != activeItem.url else { return }
        reportProgress()            // flush the outgoing item (no-op for live)
        removeObservers()
        activeItem = newItem
        hasSeekedToResume = false
        hasAppliedLanguages = false
        autoRetries = 0
        state = .loading
        player.replaceCurrentItem(with: AVPlayerItem(url: newItem.url))

        if case .unsupported(let reason) = StreamCompatibility.verdict(for: newItem.url) {
            state = .failed(.streamNotSupported(detail: reason))
            return
        }
        configure()
        startLoadTimeout()
        player.play()
    }

    private func removeObservers() {
        loadTimeout?.cancel()
        loadTimeout = nil
        if let token = timeObserverToken { player.removeTimeObserver(token) }
        timeObserverToken = nil
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        isStalling = false
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// The item finished — record it as watched so "up next" logic can fire.
    private func handlePlayedToEnd() {
        guard !activeItem.isLive else { return }
        let duration = resolvedDuration()
        if duration > 0 { onProgress(activeItem, duration, duration) }   // -> WatchProgress.isFinished
        onFinished?()
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            loadTimeout?.cancel()
            autoRetries = 0
            seekToResumeIfNeeded()
            applyLanguagePreferencesIfNeeded()
            state = .playing
            player.play()
        case .failed:
            fail(with: player.currentItem?.error)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Match the user's preferred audio / subtitle language against the stream's
    /// media selection groups. Best-effort — silently leaves defaults if a
    /// language isn't offered.
    private func applyLanguagePreferencesIfNeeded() {
        guard !hasAppliedLanguages else { return }
        hasAppliedLanguages = true
        guard !preferredAudio.isEmpty || preferredSubtitle != nil else { return }
        guard let asset = player.currentItem?.asset else { return }
        let wantAudio = preferredAudio.map(\.code)
        let wantSubtitle = preferredSubtitle?.code

        Task { @MainActor [weak self] in
            if !wantAudio.isEmpty,
               let group = try? await asset.loadMediaSelectionGroup(for: .audible),
               let match = Self.option(in: group, matching: wantAudio) {
                self?.player.currentItem?.select(match, in: group)
            }
            if let wantSubtitle,
               let group = try? await asset.loadMediaSelectionGroup(for: .legible),
               let match = Self.option(in: group, matching: [wantSubtitle]) {
                self?.player.currentItem?.select(match, in: group)
            }
        }
    }

    private static func option(in group: AVMediaSelectionGroup, matching codes: [String]) -> AVMediaSelectionOption? {
        group.options.first { option in
            guard let identifier = option.locale?.language.languageCode?.identifier.lowercased() else { return false }
            return codes.contains(identifier)
        }
    }

    private func seekToResumeIfNeeded() {
        guard !hasSeekedToResume, !activeItem.isLive, let resumeAt = activeItem.resumeAt, resumeAt > 1 else { return }
        hasSeekedToResume = true
        // A ±1.5 s tolerance lets AVPlayer land on the nearest keyframe instead
        // of decoding forward to an exact frame. Over a network stream that's
        // the difference between resuming instantly and staring at a spinner
        // for several seconds — and nobody can tell where a second went.
        let tolerance = CMTime(seconds: 1.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func fail(with error: Error?) {
        if activeItem.isLive, autoRetries < 2 {
            autoRetries += 1
            AppLog.player.notice("Live stream interrupted — reconnecting (attempt \(self.autoRetries)).")
            retry()
            return
        }
        let providerError: ProviderError = error.map(ProviderError.from) ?? .streamUnavailable
        state = .failed(providerError)
        AppLog.player.error("Playback failed for \(self.activeItem.id.rawValue, privacy: .public): \(String(describing: providerError))")
    }

    private func reportProgress() {
        guard !activeItem.isLive else { return }
        let position = player.currentTime().seconds
        let duration = resolvedDuration()
        guard position.isFinite, position > 0, duration > 0 else { return }
        onProgress(activeItem, position, duration)
    }

    /// Title / description shown in the tvOS Info panel. IPTV streams rarely
    /// carry their own metadata, so we supply the catalog's.
    private func externalMetadata() -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        var items = [entry(.commonIdentifierTitle, activeItem.title)]
        // The Info panel's body: "S02E03 · Infected" over the plot, when we
        // have both.
        let body = [activeItem.subtitle, activeItem.synopsis]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !body.isEmpty {
            items.append(entry(.commonIdentifierDescription, body))
        }
        return items
    }

    /// Poster / still / logo for the Info panel, added once it's loaded (from
    /// the image cache, usually already warm). Never blocks playback.
    private func loadInfoPanelArtwork(for playerItem: AVPlayerItem) {
        guard let url = activeItem.artworkURL else { return }
        Task { [weak self] in
            guard let image = await ImageCache.shared.image(for: url, size: .poster),
                  let data = image.jpegData(compressionQuality: 0.85),
                  let self, self.player.currentItem === playerItem else { return }
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = data as NSData
            artwork.dataType = kCMMetadataBaseDataType_JPEG as String
            artwork.extendedLanguageTag = "und"
            playerItem.externalMetadata = self.externalMetadata() + [artwork]
        }
    }

    private func resolvedDuration() -> Double {
        if let known = activeItem.durationSeconds, known > 0 { return known }
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    /// Call from the view's `onDisappear`.
    public func teardown() {
        sleepTask?.cancel()
        reportProgress()
        player.pause()
        removeObservers()
    }
}
