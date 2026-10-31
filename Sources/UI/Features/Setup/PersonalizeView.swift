import SwiftUI

/// Lets the user shape the experience — languages, subtitles, content filters,
/// and which Home rows appear. Last onboarding step and re-openable from Settings.
struct PersonalizeView: View {
    enum Mode { case onboarding, settings }
    var mode: Mode = .settings
    var onDone: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var working = UserPreferences()
    @State private var padRequest: PadRequest?

    private enum PadRequest: Identifiable {
        case unlockAdult, createPIN, removePIN
        var id: String { String(describing: self) }
    }

    /// Swedish-market languages only. Whatever the library or an older
    /// version surfaced (German audio on a Swedish-subbed film, say) isn't
    /// offered — the picker is for the viewer's own languages.
    private func languageChoices(detected _: [Language]) -> [Language] {
        Language.commonPickerChoices
    }

    private var audioLanguages: [Language] {
        languageChoices(detected: env.vocabulary.audioLanguages + env.vocabulary.subtitleLanguages)
    }
    private var subtitleLanguages: [Language] {
        languageChoices(detected: env.vocabulary.subtitleLanguages)
    }

    private let choiceColumns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: Metrics.space2)]

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space7) {
                    header

                    if audioLanguages.isEmpty {
                        PersonalizeSection("Dina språk", nil) {
                            Text("Vi känner av språken i ditt bibliotek när det har lästs in. Du kan ändra dem i Inställningar när som helst.")
                                .font(.dsBody).foregroundStyle(Palette.textSecondary)
                        }
                    } else {
                        PersonalizeSection("Dina språk", "Innehåll på de här språken får en egen rad på Hem och prioriteras överallt.") {
                            LazyVGrid(columns: choiceColumns, alignment: .leading, spacing: Metrics.space2) {
                                ForEach(audioLanguages, id: \.self) { lang in
                                    ChoiceCard(title: lang.displayName,
                                               isSelected: working.preferredAudioLanguages.contains(lang)) {
                                        toggleArray(\.preferredAudioLanguages, lang)
                                    }
                                }
                            }
                        }
                    }

                    if !subtitleLanguages.isEmpty {
                        PersonalizeSection("Undertextspråk", "Används för raden med dina undertexter och som förvald textning.") {
                            LazyVGrid(columns: choiceColumns, alignment: .leading, spacing: Metrics.space2) {
                                ForEach(subtitleLanguages, id: \.self) { lang in
                                    ChoiceCard(title: lang.displayName,
                                               isSelected: working.preferredSubtitleLanguage == lang) {
                                        working.preferredSubtitleLanguage =
                                            (working.preferredSubtitleLanguage == lang) ? nil : lang
                                    }
                                }
                            }
                        }
                    }

                    PersonalizeSection("Live-TV-kanaler", "Vilka kanaler som visas i Live-TV, TV-guiden och kanalraderna på Hem.") {
                        LazyVGrid(columns: choiceColumns, alignment: .leading, spacing: Metrics.space2) {
                            ForEach(ChannelRegionScope.offered) { option in
                                ChoiceCard(title: option.title,
                                           isSelected: working.channelRegionScope.swedishMarket == option) {
                                    working.channelRegionScope = option
                                }
                            }
                        }
                        Text(working.channelRegionScope.swedishMarket.note)
                            .font(.dsCaption).foregroundStyle(Palette.textTertiary)
                    }

                    PersonalizeSection("Uppspelning & innehåll", nil) {
                        VStack(spacing: Metrics.space2) {
                            OptionRow(icon: "eye.slash",
                                      title: "Dölj vuxenkategorier",
                                      note: "Håller vuxenmärkta kanaler och titlar borta från Hem, bläddring och sök.",
                                      isOn: working.hideAdultContent) { toggleHideAdult() }
                            OptionRow(icon: "lock.shield",
                                      title: "PIN-kod för föräldrar",
                                      note: env.parental.isEnabled
                                          ? "En fyrsiffrig PIN-kod krävs innan vuxeninnehåll kan visas."
                                          : "Välj en fyrsiffrig PIN-kod så att vuxenkategorier inte kan slås på utan den.",
                                      isOn: env.parental.isEnabled) {
                                padRequest = env.parental.isEnabled ? .removePIN : .createPIN
                            }
                            OptionRow(icon: "play.rectangle.on.rectangle",
                                      title: "Spela nästa avsnitt automatiskt",
                                      note: "När ett avsnitt tar slut startar nästa efter en kort nedräkning.",
                                      isOn: working.autoPlayNextEpisode) { working.autoPlayNextEpisode.toggle() }
                            OptionRow(icon: "sparkles",
                                      title: "AI-stödd sökning",
                                      note: "Vid oklara sökningar skickas bara dina ord och bibliotekets genrer/språk — aldrig inloggning, länkar eller historik.",
                                      isOn: working.aiAssistedSearch) { working.aiAssistedSearch.toggle() }
                        }
                    }

                    PersonalizeSection("Rader på Hem", "Slå på eller av rader — de visas i den här ordningen.") {
                        VStack(spacing: Metrics.space2) {
                            ForEach(HomeRowKind.allCases) { row in
                                OptionRow(icon: nil,
                                          title: row.title,
                                          note: row.explanation,
                                          isOn: working.homeRows.contains(row)) { toggleHomeRow(row) }
                            }
                        }
                    }

                    footer
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.space6)
            }
        }
        .onAppear { working = env.preferences.preferences }
        .fullScreenCover(item: $padRequest) { request in
            switch request {
            case .unlockAdult:
                PINPadView(purpose: .enter, heading: "Visa vuxeninnehåll",
                           verify: { env.parental.verify($0) },
                           onDone: { _ in working.hideAdultContent = false; padRequest = nil },
                           onCancel: { padRequest = nil })
            case .createPIN:
                PINPadView(purpose: .create, heading: "Skapa en PIN-kod",
                           onDone: { pin in env.parental.setPIN(pin); padRequest = nil },
                           onCancel: { padRequest = nil })
            case .removePIN:
                PINPadView(purpose: .enter, heading: "Ange PIN-koden för att ta bort den",
                           verify: { env.parental.verify($0) },
                           onDone: { pin in _ = env.parental.disable(currentPIN: pin); padRequest = nil },
                           onCancel: { padRequest = nil })
            }
        }
    }

    private func toggleHideAdult() {
        if working.hideAdultContent {
            // Turning the filter OFF reveals adult content — gated by the PIN.
            if env.parental.isEnabled {
                padRequest = .unlockAdult
            } else {
                working.hideAdultContent = false
            }
        } else {
            working.hideAdultContent = true   // turning protection back on is always allowed
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(mode == .onboarding ? "Gör den till din" : "Anpassa")
                .font(.dsHero)
            Text("Några snabba val så att appen visar det som är viktigt för dig. Allt kan ändras senare i Inställningar.")
                .font(.dsBody)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var footer: some View {
        HStack(spacing: Metrics.space2) {
            if mode == .settings {
                Button("Avbryt") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button {
                var next = working
                if mode == .onboarding { next.hasOnboarded = true }
                env.preferences.update { $0 = next }
                Task { await env.applyPreferences() }
                onDone()
                if mode == .settings { dismiss() }
            } label: {
                Text(mode == .onboarding ? "Slutför" : "Spara ändringar")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.top, Metrics.space4)
    }

    // MARK: - Mutation helpers

    private func toggleArray(_ keyPath: WritableKeyPath<UserPreferences, [Language]>, _ value: Language) {
        if let idx = working[keyPath: keyPath].firstIndex(of: value) {
            working[keyPath: keyPath].remove(at: idx)
        } else {
            working[keyPath: keyPath].append(value)
        }
    }

    private func toggleHomeRow(_ row: HomeRowKind) {
        if working.homeRows.contains(row) {
            working.homeRows.removeAll { $0 == row }
        } else {
            working.homeRows = HomeRowKind.allCases.filter { working.homeRows.contains($0) || $0 == row }
        }
    }
}

// MARK: - Section wrapper

private struct PersonalizeSection<Content: View>: View {
    let title: String
    let note: String?
    let content: () -> Content

    init(_ title: String, _ note: String?, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.dsSectionHeader).foregroundStyle(Palette.textPrimary)
                if let note {
                    Text(note).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(Palette.hairline).frame(height: 1).padding(.top, 4)
            }
            content()
        }
    }
}

// MARK: - Reusable choices

/// A compact multi/single-select card (languages).
private struct ChoiceCard: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space1) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.textTertiary)
                Text(title)
                    .font(.dsCardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.space2)
            .frame(height: 84)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.card)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A full-width on/off row for a preference or a Home row.
private struct OptionRow: View {
    let icon: String?
    let title: String
    let note: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.space3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 26))
                        .foregroundStyle(isOn ? Palette.accent : Palette.textTertiary)
                        .frame(width: 40)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.dsCardTitle).foregroundStyle(Palette.textPrimary)
                    Text(note).font(.dsCaption).foregroundStyle(Palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.space2)
                StatePill(isOn: isOn)
            }
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "På" : "Av")
        .accessibilityAddTraits(.isButton)
    }
}

private struct StatePill: View {
    let isOn: Bool
    var body: some View {
        Text(isOn ? "På" : "Av")
            .font(.dsTag)
            .foregroundStyle(isOn ? Palette.canvas : Palette.textSecondary)
            .padding(.horizontal, Metrics.space2)
            .padding(.vertical, 8)
            .background(isOn ? Palette.accent : Palette.surfaceElevated, in: Capsule())
    }
}
