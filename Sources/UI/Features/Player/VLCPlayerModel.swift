import Foundation
import MediaPlayer
import Observation
import UIKit
import VLCKitSPM

/// Playback via libVLC for the containers `AVPlayer` can't open (MKV, AVI, raw
/// MPEG-TS, rtmp/rtsp). Mirrors `PlayerModel`'s surface so `PlayerScreen` can
/// route to either.
@MainActor
@Observable
public final class VLCPlayerModel {

    public enum State: Equatable {
        case loading
        case playing
        case paused
        case failed(ProviderError)
    }

    public struct Track: Identifiable, Equatable, Sendable {
        public let id: Int          // VLC's own index; -1 = "Off" for subtitles
        public let name: String
    }

    public private(set) var state: State = .loading
    public private(set) var position: Double = 0      // seconds
    public private(set) var duration: Double = 0      // seconds, 0 when unknown / live
    public private(set) var subtitleTracks: [Track] = []
    public private(set) var audioTracks: [Track] = []
    public private(set) var currentSubtitleID: Int = -1
    public private(set) var currentAudioID: Int = 0

    @ObservationIgnored public let item: PlaybackItem
    @ObservationIgnored private let player = VLCMediaPlayer()
    @ObservationIgnored private lazy var coordinator = Coordinator(owner: self)
    @ObservationIgnored private let preferredAudio: [Language]
    @ObservationIgnored private let preferredSubtitle: Language?
    @ObservationIgnored private var hasSeekedToResume = false
    @ObservationIgnored private var hasAppliedPreferredTracks = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loadTimeout: Task<Void, Never>?
    @ObservationIgnored private var lastNowPlayingPush = Date.distantPast

    @ObservationIgnored
    private let onProgress: @MainActor (_ item: PlaybackItem, _ position: Double, _ duration: Double) -> Void
    @ObservationIgnored public var onFinished: (@MainActor () -> Void)?
    @ObservationIgnored public var onSleepFired: (@MainActor () -> Void)?

    /// Minutes remaining on the sleep timer, or `nil` when off.
    public private(set) var sleepMinutes: Int?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    public init(
        item: PlaybackItem,
        preferredAudio: [Language] = [],
        preferredSubtitle: Language? = nil,
        onProgress: @escaping @MainActor (PlaybackItem, Double, Double) -> Void
    ) {
        self.item = item
        self.preferredAudio = preferredAudio
        self.preferredSubtitle = preferredSubtitle
        self.onProgress = onProgress
    }

    /// Attach VLC's output to a view and begin playback. Idempotent.
    public func start(in view: UIView) {
        guard !started else { return }
        started = true
        player.delegate = coordinator
        player.drawable = view
        player.media = VLCMedia(url: item.url)
        player.play()
        startLoadTimeout()
    }

    public var isPlaying: Bool { player.isPlaying }

    public func togglePlayPause() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    /// Playback speed (1 = normal). VOD only — live can't run ahead.
    public private(set) var rate: Float = 1

    public func setRate(_ newRate: Float) {
        rate = newRate
        player.rate = newRate
    }

    /// Start (or, with `nil`, cancel) a sleep timer.
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

    /// Relative seek in seconds.
    public func seek(by seconds: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, position + seconds), duration)
        player.position = Float(target / duration)
    }

    public func seek(toFraction fraction: Double) {
        player.position = Float(min(1, max(0, fraction)))
    }

    /// Absolute seek to a wall-clock offset in seconds.
    public func seek(to seconds: Double) {
        guard duration > 0 else { return }
        player.position = Float(min(1, max(0, seconds / duration)))
        position = min(max(0, seconds), duration)
    }

    // MARK: - Tracks

    public func selectSubtitle(_ id: Int) {
        player.currentVideoSubTitleIndex = Int32(id)
        currentSubtitleID = id
    }

    public func selectAudio(_ id: Int) {
        player.currentAudioTrackIndex = Int32(id)
        currentAudioID = id
    }

    private func refreshTracks() {
        subtitleTracks = zipTracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames)
        audioTracks = zipTracks(player.audioTrackIndexes, player.audioTrackNames)
        currentSubtitleID = Int(player.currentVideoSubTitleIndex)
        currentAudioID = Int(player.currentAudioTrackIndex)
    }

    private func zipTracks(_ indexes: [Any]?, _ names: [Any]?) -> [Track] {
        guard let indexes = indexes as? [NSNumber], let names = names as? [String],
              indexes.count == names.count else { return [] }
        return zip(indexes, names).map { Track(id: $0.intValue, name: $1) }
    }

    private func applyPreferredTracksIfNeeded() {
        guard !hasAppliedPreferredTracks, !subtitleTracks.isEmpty || !audioTracks.isEmpty else { return }
        hasAppliedPreferredTracks = true

        if let subtitle = preferredSubtitle, let match = matching(subtitleTracks, subtitle) {
            selectSubtitle(match.id)
        }
        if let audio = preferredAudio.first, let match = matching(audioTracks, audio) {
            selectAudio(match.id)
        }
    }

    private func matching(_ tracks: [Track], _ language: Language) -> Track? {
        let needle = language.displayName.lowercased()
        let code = language.code.lowercased()
        return tracks.first { $0.name.lowercased().contains(needle) || $0.name.lowercased().contains(code) }
    }

    public func teardown() {
        sleepTask?.cancel()
        reportProgress()
        loadTimeout?.cancel()
        player.delegate = nil
        player.stop()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// VLC playback has no `AVPlayerViewController`, so the system "What's
    /// playing" surface only reflects what we push here.
    private func updateNowPlaying() {
        guard !item.isLive else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Delegate callbacks (hopped to MainActor)

    fileprivate func stateChanged() {
        refreshTracks()
        updateNowPlaying()
        // `isPlaying` is an unambiguous Bool — prefer it over matching the state
        // enum, whose case names shift between VLCKit builds.
        if player.isPlaying {
            markPlaying()
            return
        }
        switch player.state {
        case .paused:
            if state == .playing { state = .paused }
        case .error:
            fail(.streamUnavailable)
        case .stopped, .ended:
            handleEnded()
        default:
            break
        }
    }

    fileprivate func timeChanged() {
        position = Double(player.time.intValue) / 1000
        let length = player.media?.length.intValue ?? 0
        if length > 0 { duration = Double(length) / 1000 }
        if position > 0 {
            markPlaying()                       // clock advancing = definitely playing
            if position < 6 { refreshTracks() } // tracks appear a beat after play
        }
        reportProgress()
    }

    private func markPlaying() {
        loadTimeout?.cancel()
        applyPreferredTracksIfNeeded()
        guard state != .playing else { return }
        state = .playing
        seekToResumeIfNeeded()
    }

    // MARK: - Helpers

    private func startLoadTimeout() {
        loadTimeout?.cancel()
        loadTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self, self.state == .loading else { return }
            if self.player.isPlaying || self.position > 0 {
                self.markPlaying()          // playing fine, we just missed the signal
            } else {
                self.fail(.streamUnavailable)
            }
        }
    }

    private func seekToResumeIfNeeded() {
        guard !hasSeekedToResume, !item.isLive, let resumeAt = item.resumeAt, resumeAt > 1 else { return }
        hasSeekedToResume = true
        // `time` is read-only on VLCMediaPlayer; jump relative from the start.
        player.jumpForward(Int32(resumeAt))
    }

    private func reportProgress() {
        guard !item.isLive, duration > 0, position > 0 else { return }
        onProgress(item, position, duration)
        if Date().timeIntervalSince(lastNowPlayingPush) > 5 {
            lastNowPlayingPush = Date()
            updateNowPlaying()
        }
    }

    private func handleEnded() {
        guard !item.isLive else { return }
        if duration > 0 { onProgress(item, duration, duration) }
        onFinished?()
    }

    private func fail(_ error: ProviderError) {
        loadTimeout?.cancel()
        state = .failed(error)
        AppLog.player.error("VLC playback failed for \(self.item.id.rawValue, privacy: .public).")
    }

    private final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        weak var owner: VLCPlayerModel?
        init(owner: VLCPlayerModel) { self.owner = owner }

        // VLCKit's delegate thread isn't contractually main — always hop.
        func mediaPlayerStateChanged(_ aNotification: Notification!) {
            Task { @MainActor [weak owner] in owner?.stateChanged() }
        }
        func mediaPlayerTimeChanged(_ aNotification: Notification!) {
            Task { @MainActor [weak owner] in owner?.timeChanged() }
        }
    }
}
