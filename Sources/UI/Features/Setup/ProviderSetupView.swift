import SwiftUI

/// Onboarding + "add another provider" flow. Deliberately hides IPTV jargon:
/// the user picks how they connect, fills a short form, and waits while the
/// library is prepared.
struct ProviderSetupView: View {
    /// When presented from Settings we can be dismissed; at first launch we can't.
    var isDismissable: Bool = false
    var onFinished: (() -> Void)? = nil
    /// Onboarding: fired once a provider has been chosen and the import kicked
    /// off, so the parent can take over the "preparing" and "personalize" steps.
    var onProviderReady: (() -> Void)? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable {
        case choose
        case xtream
        case m3u
        case preparing
        case failed(ProviderError)
    }
    @State private var step: Step = .choose

    // Xtream form
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    // M3U form
    @State private var playlistURL = ""
    @State private var epgURL = ""
    @State private var nickname = ""

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            content
                .frame(maxWidth: 1100)
                .padding(Metrics.screenMargin)
        }
        .onChange(of: env.loadState) { _, state in
            guard step == .preparing else { return }
            switch state {
            case .ready:
                onFinished?()
                if isDismissable { dismiss() }
            case .failed(let error):
                step = .failed(error)
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .choose:      chooser
        case .xtream:      xtreamForm
        case .m3u:         m3uForm
        case .preparing:   LibraryLoadingView()
        case .failed(let error):
            ErrorStateView(error: error,
                           onRetry: { step = .choose },
                           onEditProvider: { step = .choose })
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text("Add your TV provider").font(.dsHero)
                Text("Connect the IPTV service you already subscribe to. Aeria+ is just the player — it provides, hosts, and controls no channels or content of its own.")
                    .font(.dsBody).foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: 800, alignment: .leading)
            }

            HStack(spacing: Metrics.space3) {
                choiceCard(title: "Xtream Codes", subtitle: "Server, username & password", icon: "person.badge.key") {
                    step = .xtream
                }
                choiceCard(title: "M3U Playlist URL", subtitle: "A playlist link (.m3u / .m3u8)", icon: "link") {
                    step = .m3u
                }
                choiceCard(title: "Try the demo", subtitle: "Explore with sample content", icon: "sparkles") {
                    Task { await activate(.demo) }
                }
            }

            if isDismissable {
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
        }
    }

    private func choiceCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Image(systemName: icon).font(.system(size: 44)).foregroundStyle(Palette.accent)
                Spacer(minLength: 0)
                Text(title).font(.dsCardTitle).foregroundStyle(Palette.textPrimary)
                Text(subtitle).font(.dsCaption).foregroundStyle(Palette.textTertiary).lineLimit(2)
            }
            .padding(Metrics.space3)
            .frame(width: 320, height: 260, alignment: .leading)
        }
        .buttonStyle(.card)
    }

    // MARK: Xtream form

    private var xtreamForm: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text("Xtream Codes").font(.dsTitle)
            Text("Enter the details from your provider. These are stored securely on this Apple TV and only sent to your provider.")
                .font(.dsCaption).foregroundStyle(Palette.textSecondary).frame(maxWidth: 800, alignment: .leading)

            LabeledField("Server URL or host", text: $host, prompt: "http://example.com:8080")
            LabeledField("Username", text: $username, prompt: "username")
            LabeledField("Password", text: $password, prompt: "password", isSecure: true)
            LabeledField("Name (optional)", text: $nickname, prompt: "My Provider")

            HStack(spacing: Metrics.space2) {
                Button("Back") { step = .choose }.buttonStyle(SecondaryButtonStyle())
                Button("Connect") { Task { await activate(.xtream) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
    }

    // MARK: M3U form

    private var m3uForm: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text("M3U Playlist").font(.dsTitle)
            LabeledField("Playlist URL", text: $playlistURL, prompt: "https://…/get.php?…")
            LabeledField("EPG / TV guide URL (optional)", text: $epgURL, prompt: "https://…/xmltv.php?…")
            LabeledField("Name (optional)", text: $nickname, prompt: "My Playlist")

            HStack(spacing: Metrics.space2) {
                Button("Back") { step = .choose }.buttonStyle(SecondaryButtonStyle())
                Button("Connect") { Task { await activate(.m3u) } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(playlistURL.isEmpty)
            }
        }
    }

    // MARK: Actions

    private enum Kind { case demo, xtream, m3u }

    private func activate(_ kind: Kind) async {
        let config: ProviderConfiguration
        switch kind {
        case .demo:
            config = ProviderStore.demoConfiguration
        case .xtream:
            config = env.providers.addXtream(host: host, username: username, password: password, displayName: nickname)
        case .m3u:
            config = env.providers.addM3U(playlistURL: playlistURL,
                                          epgURL: epgURL.isEmpty ? nil : epgURL,
                                          displayName: nickname)
        }
        if let onProviderReady {
            onProviderReady()
        } else {
            step = .preparing
        }
        await env.activate(config)
    }
}

/// Focusable labelled text field styled for tvOS.
struct LabeledField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""
    var isSecure: Bool = false

    @FocusState private var focused: Bool

    init(_ label: String, text: Binding<String>, prompt: String = "", isSecure: Bool = false) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.isSecure = isSecure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.dsCaption).foregroundStyle(Palette.textTertiary)
            Group {
                if isSecure {
                    SecureField(prompt, text: $text)
                } else {
                    TextField(prompt, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.dsBody)
            .focused($focused)
            .padding(Metrics.space2)
            .background(focused ? Palette.surfaceElevated : Palette.surface,
                        in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius)
                .strokeBorder(focused ? Palette.accent : Palette.hairline, lineWidth: focused ? 2 : 1))
            .animation(Metrics.focusAnimation, value: focused)
            .frame(maxWidth: 760)
        }
    }
}

/// The library-import checklist. `isReady` reflects the app actually being
/// usable (`loadState == .ready`), not a self-reported provider phase — so
/// "Your TV is ready" never shows prematurely.
struct LibraryLoadingView: View {
    /// Show a "Start Watching" button on completion (onboarding). Otherwise the
    /// parent dismisses this view when `loadState` becomes ready.
    var showStartButton: Bool = false
    var onStart: () -> Void = {}
    /// Called when the user chooses to fix a failed import (e.g. bad credentials).
    var onRetry: (() -> Void)? = nil

    @Environment(AppEnvironment.self) private var env
    @FocusState private var startFocused: Bool
    @State private var secondsElapsed = 0

    /// After this long the user can enter the app even if the import is still
    /// running or stuck — the app works fine with a partial / empty catalog.
    private let escapeAfter = 12

    private var canEscape: Bool { showStartButton && secondsElapsed >= escapeAfter }
    private var isReady: Bool { if case .ready = env.loadState { return true } else { return false } }
    private var failure: ProviderError? { if case .failed(let e) = env.loadState { return e } else { return nil } }
    private var isConnecting: Bool { env.reachedPhases.isSubset(of: [.connecting]) }
    private var isNormalizing: Bool {
        !isReady && env.reachedPhases.contains(.guide)
    }

    var body: some View {
        if let failure {
            ErrorStateView(
                error: failure,
                onRetry: {
                    if let onRetry { onRetry() }
                    else { Task { await env.bootstrap(forceReload: true) } }
                },
                onEditProvider: { onRetry?() }
            )
        } else {
            checklist
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(isReady ? "Your TV is ready" : "Preparing your library")
                    .font(.dsHero)
                Text(subtitle)
                    .font(.dsBody).foregroundStyle(Palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: Metrics.space2) {
                ForEach(ImportPhase.checklist) { phase in
                    ChecklistRow(label: phase.label, state: rowState(for: phase))
                }
                ChecklistRow(label: "Organising your library",
                             state: isReady ? .done : (isNormalizing ? .active : .pending))
            }
            .padding(Metrics.space3)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius))

            if !isReady {
                ProgressView(value: Double(env.reachedPhases.count),
                             total: Double(ImportPhase.allCases.count))
                    .tint(Palette.accent)
                    .frame(maxWidth: 640)
            }

            if showStartButton, isReady || canEscape {
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Button(isReady ? "Start Watching" : "Enter the app", action: onStart)
                        .buttonStyle(PrimaryButtonStyle())
                        .focused($startFocused)
                    if !isReady {
                        Text("Your library is still loading — it'll keep filling in while you browse.")
                            .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                    }
                }
                .task(id: isReady) { startFocused = true }
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled, secondsElapsed < escapeAfter + 1 {
                try? await Task.sleep(for: .seconds(1))
                secondsElapsed += 1
            }
        }
    }

    private var subtitle: String {
        if isReady { return "Everything's imported and tidied up." }
        if isConnecting { return "Connecting to your provider…" }
        if isNormalizing { return "Cleaning up channel names, matching episodes and languages…" }
        return "This can take a minute the first time for a large library."
    }

    private enum RowState: Equatable { case pending, active, done }

    private func rowState(for phase: ImportPhase) -> RowState {
        // Cache fast-path flips `isReady` without ever reporting phases, so a
        // ready library must show every row complete regardless.
        if isReady { return .done }
        if env.reachedPhases.contains(phase) { return .done }
        let firstPending = ImportPhase.checklist.first { !env.reachedPhases.contains($0) }
        return firstPending == phase ? .active : .pending
    }

    private struct ChecklistRow: View {
        let label: String
        let state: RowState

        var body: some View {
            HStack(spacing: Metrics.space2) {
                Group {
                    switch state {
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    case .active:
                        ProgressView().controlSize(.small).tint(Palette.accent)
                    case .pending:
                        Image(systemName: "circle").foregroundStyle(Palette.textTertiary)
                    }
                }
                .frame(width: 34)
                Text(label)
                    .font(.dsBody)
                    .foregroundStyle(state == .pending ? Palette.textTertiary : Palette.textPrimary)
                Spacer()
            }
        }
    }
}
