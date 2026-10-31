import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showAddProvider = false
    @State private var showPersonalize = false
    @State private var showAIKey = false
    @State private var showTMDBKey = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space5) {
                    Text("Inställningar").font(.dsTitle)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, Metrics.space4)

                    providersSection.modifier(SettingsCard())
                    personalizeSection.modifier(SettingsCard())
                    artworkSection.modifier(SettingsCard())
                    aiSection.modifier(SettingsCard())
                    aboutSection.modifier(SettingsCard())
                }
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.bottom, Metrics.space7)
                .frame(maxWidth: 1200, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .appThemeBackground()
        }
        .fullScreenCover(isPresented: $showAddProvider) {
            ProviderSetupView(isDismissable: true)
                .environment(env)
        }
        .fullScreenCover(isPresented: $showPersonalize) {
            PersonalizeView(mode: .settings)
                .environment(env)
        }
        .fullScreenCover(isPresented: $showAIKey) {
            AIKeyView().environment(env)
        }
        .fullScreenCover(isPresented: $showTMDBKey) {
            TMDBKeyView().environment(env)
        }
    }

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            SectionHeader("Bilder & information", subtitle: "Riktiga affischer, bakgrundsbilder och handlingar från The Movie Database")
            Button { showTMDBKey = true } label: {
                HStack {
                    Label(env.hasTMDBKey ? "Använder din egen TMDB-nyckel" : "The Movie Database — på",
                          systemImage: "checkmark.seal")
                        .font(.dsBody)
                    Spacer()
                    Text(env.hasTMDBKey ? "Ändra" : "Använd egen nyckel").font(.dsCaption).foregroundStyle(Palette.textTertiary)
                }
            }
            .buttonStyle(RowButtonStyle())
            Text("Det här är påslaget som standard. Du kan använda en egen gratis nyckel från themoviedb.org om du vill. Bara titel och år på det du bläddrar bland skickas.")
                .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: 900, alignment: .leading)
            Text("Den här produkten använder TMDB:s API men är inte godkänd eller certifierad av TMDB.")
                .font(.dsTag).foregroundStyle(Palette.textTertiary)
        }
    }

    private var personalizeSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            SectionHeader("Anpassa", subtitle: "Språk, undertexter, vuxenfilter, rader på Hem")
            Button {
                showPersonalize = true
            } label: {
                HStack {
                    Label("Ändra dina inställningar", systemImage: "slider.horizontal.3")
                        .font(.dsBody)
                    Spacer()
                    Text(preferenceSummary).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                }
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private var preferenceSummary: String {
        let p = env.preferences.preferences
        var parts: [String] = []
        if !p.preferredAudioLanguages.isEmpty {
            parts.append(p.preferredAudioLanguages.map(\.displayName).joined(separator: ", "))
        }
        if let s = p.preferredSubtitleLanguage { parts.append("Text: \(s.displayName)") }
        parts.append("Kanaler: \(p.channelRegionScope.swedishMarket.title)")
        if p.hideAdultContent { parts.append("Vuxet dolt") }
        if env.parental.isEnabled { parts.append("PIN på") }
        return parts.isEmpty ? "Inte valt" : parts.joined(separator: " · ")
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            SectionHeader("Din leverantör")

            ForEach(env.providers.allConfigurations) { config in
                HStack(spacing: Metrics.space2) {
                    Image(systemName: icon(for: config.kind))
                        .font(.system(size: 28)).foregroundStyle(Palette.accent)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.displayName).font(.dsCardTitle)
                        Text(subtitle(for: config)).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer()
                    if config.id == env.providers.activeID {
                        Text("Aktiv").font(.dsTag).foregroundStyle(Palette.accent)
                    } else {
                        Button("Använd") { Task { await env.activate(config) } }
                            .buttonStyle(.bordered)
                    }
                    if config.kind != .mock {
                        Button(role: .destructive) {
                            Task { await env.removeProvider(config.id) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Ta bort \(config.displayName)")
                    }
                }
                .padding(Metrics.space2)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
            }

            HStack(spacing: Metrics.space2) {
                Button {
                    showAddProvider = true
                } label: {
                    Label("Lägg till leverantör", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await env.refreshLibrary() }
                } label: {
                    Label(env.isRefreshing ? "Uppdaterar…" : "Uppdatera biblioteket",
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(env.isRefreshing || env.activeProvider == nil)
            }
            .padding(.top, Metrics.space1)
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            SectionHeader("AI-sökning", subtitle: "Förstår sökningar på vanligt språk")
            Toggle(isOn: Binding(
                get: { env.preferences.preferences.aiAssistedSearch },
                set: { on in
                    env.preferences.update { $0.aiAssistedSearch = on }
                    Task { await env.applyPreferences() }
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Använd AI-stöd").font(.dsBody)
                    Text("När det är på skickar oklara sökningar bara dina ord och bibliotekets genrer/språk — aldrig leverantörsuppgifter, strömlänkar eller vad du tittar på.")
                        .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                        .frame(maxWidth: 900, alignment: .leading)
                }
            }
            .padding(Metrics.space2)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))

            if env.preferences.preferences.aiAssistedSearch {
                Button {
                    showAIKey = true
                } label: {
                    HStack {
                        Label(env.hasAIKey ? "Claude-nyckel ansluten" : "Anslut en Claude API-nyckel",
                              systemImage: env.hasAIKey ? "checkmark.seal" : "key")
                            .font(.dsBody)
                        Spacer()
                        Text(env.hasAIKey ? "Ändra" : "Lägg till").font(.dsCaption).foregroundStyle(Palette.textTertiary)
                    }
                }
                .buttonStyle(RowButtonStyle())

                Text("Utan nyckel används sökningen som körs direkt på enheten.")
                    .font(.dsCaption).foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            SectionHeader("Om")
            Text("Aeria+ är enbart en spelare. Den tillhandahåller, lagrar eller styr inga kanaler, strömmar eller medier — du ansluter en IPTV-tjänst du redan abonnerar på. Vi ansvarar inte för innehåll som tredje part väljer att titta på via spelaren.")
                .font(.dsCaption).foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: 1000, alignment: .leading)
            HStack(spacing: Metrics.space3) {
                Text("Version \(Self.appVersion)")
                Text("info@aeriaplus.se")
            }
            .font(.dsCaption)
            .foregroundStyle(Palette.textTertiary)
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// Groups a settings section into a calm surface card.
    private struct SettingsCard: ViewModifier {
        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.space4)
                .background(Palette.surface.opacity(0.45),
                            in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(Palette.hairline))
        }
    }

    private func icon(for kind: ProviderKind) -> String {
        switch kind {
        case .mock:   return "sparkles"
        case .xtream: return "person.badge.key"
        case .m3u:    return "link"
        }
    }

    private func subtitle(for config: ProviderConfiguration) -> String {
        switch config.kind {
        case .mock:   return "Exempelinnehåll för att utforska appen"
        case .xtream: return [config.xtreamUsername, config.xtreamHost].compactMap { $0 }.joined(separator: " · ")
        case .m3u:    return config.m3uHostForDisplay ?? "Spellista"
        }
    }
}
