import Foundation
import Observation

/// Persists the user's configured providers (non-secret parts in `UserDefaults`,
/// secrets in the Keychain) and builds the right `ProviderClient` for the active
/// one.
@MainActor
@Observable
public final class ProviderStore {

    public private(set) var configurations: [ProviderConfiguration] = []
    public private(set) var activeID: String?

    private let defaults: UserDefaults
    private let configKey = "providers.configs.v1"
    private let activeKey = "providers.active.v1"

    /// Sentinel id for the built-in demo library.
    public static let demoID = MockCatalogData.providerID

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public var activeConfiguration: ProviderConfiguration? {
        guard let activeID else { return nil }
        if activeID == Self.demoID { return Self.demoConfiguration }
        return configurations.first { $0.id == activeID }
    }

    public var hasAnyProvider: Bool { activeID != nil }

    public static var demoConfiguration: ProviderConfiguration {
        ProviderConfiguration(id: demoID, kind: .mock, displayName: "Demo Library")
    }

    /// All choices to show in Settings (demo + user providers).
    public var allConfigurations: [ProviderConfiguration] {
        [Self.demoConfiguration] + configurations
    }

    // MARK: - Mutations

    public func addXtream(host: String, username: String, password: String, displayName: String) -> ProviderConfiguration {
        let config = ProviderConfiguration(
            kind: .xtream,
            displayName: displayName.isEmpty ? host : displayName,
            xtreamHost: Self.normalizedOrigin(host),
            xtreamUsername: username
        )
        ProviderSecrets.setXtreamPassword(password, for: config.id)
        configurations.append(config)
        persist()
        return config
    }

    public func addM3U(playlistURL: String, epgURL: String?, displayName: String) -> ProviderConfiguration {
        let config = ProviderConfiguration(
            kind: .m3u,
            displayName: displayName.isEmpty ? "Playlist" : displayName,
            m3uHostForDisplay: URL(string: playlistURL)?.host,
            epgHostForDisplay: epgURL.flatMap { URL(string: $0)?.host }
        )
        ProviderSecrets.setM3UURL(playlistURL, for: config.id)
        if let epgURL, !epgURL.isEmpty { ProviderSecrets.setEPGURL(epgURL, for: config.id) }
        configurations.append(config)
        persist()
        return config
    }

    public func remove(_ id: String) {
        guard id != Self.demoID else { return }
        ProviderSecrets.deleteAll(for: id)
        configurations.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        persist()
    }

    public func setActive(_ id: String) {
        activeID = id
        persist()
    }

    // MARK: - Client construction

    public func makeClient(for config: ProviderConfiguration) -> (any ProviderClient)? {
        switch config.kind {
        case .mock:
            return MockProviderClient()
        case .xtream:
            guard let password = ProviderSecrets.xtreamPassword(for: config.id) else { return nil }
            return XtreamProviderClient(configuration: config, password: password)
        case .m3u:
            guard let url = ProviderSecrets.m3uURL(for: config.id) else { return nil }
            return M3UProviderClient(configuration: config,
                                     playlistURLString: url,
                                     epgURLString: ProviderSecrets.epgURL(for: config.id))
        }
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode([ProviderConfiguration].self, from: data) {
            configurations = decoded
        }
        activeID = defaults.string(forKey: activeKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(configurations) {
            defaults.set(data, forKey: configKey)
        }
        defaults.set(activeID, forKey: activeKey)
    }

    static func normalizedOrigin(_ host: String) -> String {
        var raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "http://" + raw }
        guard let c = URLComponents(string: raw), let scheme = c.scheme, let h = c.host else { return raw }
        if let port = c.port { return "\(scheme)://\(h):\(port)" }
        return "\(scheme)://\(h)"
    }
}
