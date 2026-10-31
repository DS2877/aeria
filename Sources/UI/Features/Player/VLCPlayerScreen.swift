import SwiftUI
import UIKit

/// Full-screen VLC playback with a lightweight custom transport (VLC has no
/// native tvOS player UI). Siri Remote: Play/Pause toggles, left/right seek
/// ±10s, up opens tracks, Menu exits.
struct VLCPlayerScreen: View {
    let item: PlaybackItem
    var preferredAudio: [Language] = []
    var preferredSubtitle: Language? = nil
    let onProgress: @MainActor (CatalogID, ContentKind, Double, Double) -> Void
    /// Replaces the default "close at the end" — the host rolls into Up Next.
    var onFinished: (@MainActor () -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var model: VLCPlayerModel?
    @State private var controlsVisible = true
    @State private var showTracks = false
    @State private var hideWorkItem: DispatchWorkItem?
    /// The transport has no visible controls to focus, so the whole surface must
    /// hold focus or the remote's Play/Pause / arrows / Menu never reach us.
    @FocusState private var surfaceFocused: Bool

    // Scrubbing: presses accumulate into a pending target shown on the bar and
    // committed a beat after the last press, so seeking an MKV over the network
    // buffers once instead of on every tap.
    @State private var pendingSeek: Double?
    @State private var seekCommitWork: DispatchWorkItem?
    @State private var lastSeekPress = Date.distantPast
    @State private var seekStreak = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let model {
                VLCVideoView(model: model).ignoresSafeArea()

                if case .failed(let error) = model.state {
                    VStack(spacing: Metrics.space3) {
                        ErrorStateView(error: error, onRetry: nil, onEditProvider: nil)
                        Button("Close") { dismiss() }.buttonStyle(PrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.96))
                } else {
                    if model.state == .loading {
                        // Same identity-while-loading treatment as the native
                        // player — MKV over the network is the slowest start in
                        // the app, so this is where it matters most.
                        VStack(spacing: Metrics.space3) {
                            ProgressView().controlSize(.large).tint(.white)
                            VStack(spacing: 6) {
                                Text(item.title)
                                    .font(.dsCardTitle).foregroundStyle(.white).lineLimit(1)
                                if let subtitle = item.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.dsCaption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                                }
                                Text("Starting…")
                                    .font(.dsTag).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
                            }
                            .frame(maxWidth: 900)
                            .multilineTextAlignment(.center)
                        }
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading \(item.title)")
                    }
                    if controlsVisible {
                        controls(model).transition(.opacity)
                    }
                }
            }
        }
        .focusable()
        .focused($surfaceFocused)
        .accessibilityLabel(item.title)
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Swipe left or right to seek. Press play-pause to pause or resume. Press Menu to exit.")
        .accessibilityAddTraits(.startsMediaSession)
        .onPlayPauseCommand { model?.togglePlayPause(); flashControls() }
        .onMoveCommand { direction in
            flashControls()
            switch direction {
            case .left:  scrub(by: -1)
            case .right: scrub(by: 1)
            case .up:    if hasTracks || !item.isLive { showTracks = true }
            default:     break
            }
        }
        .onExitCommand { dismiss() }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.28), value: model?.state == .loading)
        .fullScreenCover(isPresented: $showTracks) {
            if let model { VLCTrackSheet(model: model) }
        }
        .onChange(of: showTracks) { _, showing in
            if !showing { surfaceFocused = true }   // reclaim focus when the sheet closes
        }
        .onChange(of: model?.state) { _, state in
            if case .failed = state {} else { surfaceFocused = true }
        }
        .onAppear {
            let m = VLCPlayerModel(item: item,
                                   preferredAudio: preferredAudio,
                                   preferredSubtitle: preferredSubtitle) { played, position, duration in
                onProgress(played.id, played.kind, position, duration)
            }
            m.onFinished = { if let onFinished { onFinished() } else { dismiss() } }
            m.onSleepFired = { dismiss() }
            model = m
            surfaceFocused = true
            flashControls()
        }
        .onDisappear {
            hideWorkItem?.cancel()
            seekCommitWork?.cancel()
            model?.teardown()
        }
    }

    /// Whether ▲ opens the options sheet: track choices, or — for films and
    /// episodes — speed and the sleep timer.
    private var hasTracks: Bool {
        (model?.subtitleTracks.count ?? 0) > 1 || (model?.audioTracks.count ?? 0) > 1 || !item.isLive
    }

    /// Spoken status for VoiceOver — the custom transport has no focusable
    /// controls of its own.
    private var accessibilityStatus: String {
        guard let model else { return "Loading" }
        switch model.state {
        case .loading: return "Loading"
        case .failed:  return "Playback failed"
        case .paused:  return "Paused"
        case .playing:
            guard model.duration > 0 else { return item.isLive ? "Live" : "Playing" }
            return "\(timecode(model.position)) of \(timecode(model.duration))"
        }
    }

    /// Accumulate a seek. Quick repeated presses grow the step (10s → 30s → 60s).
    private func scrub(by sign: Double) {
        guard let model, model.duration > 0 else { return }
        let now = Date()
        seekStreak = now.timeIntervalSince(lastSeekPress) < 0.7 ? seekStreak + 1 : 0
        lastSeekPress = now

        let step: Double = seekStreak >= 6 ? 60 : (seekStreak >= 3 ? 30 : 10)
        let base = pendingSeek ?? model.position
        pendingSeek = min(max(0, base + sign * step), model.duration)

        seekCommitWork?.cancel()
        let work = DispatchWorkItem {
            if let target = pendingSeek { model.seek(to: target) }
            pendingSeek = nil
            seekStreak = 0
        }
        seekCommitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    private func flashControls() {
        controlsVisible = true
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { controlsVisible = false }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @ViewBuilder
    private func controls(_ model: VLCPlayerModel) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text(item.title).font(.dsCardTitle).foregroundStyle(.white)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.dsCaption).foregroundStyle(.white.opacity(0.7))
                }

                if model.duration > 0 {
                    let shown = pendingSeek ?? model.position
                    ProgressView(value: shown, total: model.duration)
                        .tint(pendingSeek == nil ? Palette.accent : .white)
                    HStack {
                        Text(timecode(shown))
                            .font(.dsCaption)
                            .foregroundStyle(pendingSeek == nil ? .white.opacity(0.8) : .white)
                        if let pendingSeek {
                            let delta = pendingSeek - model.position
                            Text("\(delta >= 0 ? "+" : "−")\(timecode(abs(delta)))")
                                .font(.dsCaption).foregroundStyle(Palette.accent)
                        }
                        Spacer()
                        Text(timecode(model.duration)).font(.dsCaption).foregroundStyle(.white.opacity(0.5))
                    }
                } else if item.isLive {
                    Text("LIVE").font(.dsTag).foregroundStyle(Palette.accent)
                }

                Text((hasTracks || !item.isLive)
                     ? "‹ ›  scrub      ▮▮  play/pause      ▲  options      Menu  exit"
                     : "‹ ›  scrub      ▮▮  play/pause      Menu  exit")
                    .font(.dsCaption).foregroundStyle(.white.opacity(0.45))
                    .padding(.top, Metrics.space1)
            }
            .padding(Metrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Subtitle + audio track picker over the (still playing) video.
private struct VLCTrackSheet: View {
    @Bindable var model: VLCPlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Palette.canvas.opacity(0.96).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space5) {
                    if model.audioTracks.count > 1 {
                        section("Audio", tracks: model.audioTracks, current: model.currentAudioID) {
                            model.selectAudio($0); dismiss()
                        }
                    }
                    if model.subtitleTracks.count > 1 {
                        section("Subtitles", tracks: model.subtitleTracks, current: model.currentSubtitleID) {
                            model.selectSubtitle($0); dismiss()
                        }
                    }
                    if !model.item.isLive {
                        speedSection
                        sleepSection
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.space6)
            }
        }
        .onExitCommand { dismiss() }
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text("Speed").font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0] as [Float], id: \.self) { speed in
                Button {
                    model.setRate(speed)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: model.rate == speed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.rate == speed ? Palette.accent : Palette.textTertiary)
                        Text(speed == 1 ? "Normal" : String(format: "%g×", speed))
                            .font(.dsBody).foregroundStyle(Palette.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    private var sleepSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text("Sleep timer").font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
            ForEach([nil, 15, 30, 45, 60] as [Int?], id: \.self) { minutes in
                Button {
                    model.setSleepTimer(minutes: minutes)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: model.sleepMinutes == minutes ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.sleepMinutes == minutes ? Palette.accent : Palette.textTertiary)
                        Text(minutes.map { "\($0) minutes" } ?? "Off")
                            .font(.dsBody).foregroundStyle(Palette.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, tracks: [VLCPlayerModel.Track], current: Int,
                         onPick: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text(title).font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
            ForEach(tracks) { track in
                Button { onPick(track.id) } label: {
                    HStack {
                        Image(systemName: track.id == current ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(track.id == current ? Palette.accent : Palette.textTertiary)
                        Text(track.name).font(.dsBody).foregroundStyle(Palette.textPrimary)
                        Spacer()
                    }
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }
}

/// VLC renders into a plain `UIView`.
private struct VLCVideoView: UIViewRepresentable {
    let model: VLCPlayerModel

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        model.start(in: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
