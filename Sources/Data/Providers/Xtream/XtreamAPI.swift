import Foundation

/// Builds `player_api.php` URLs and stream URLs for an Xtream account.
/// `host` is an origin only (`http://example.com:8080`); credentials are applied
/// per request and never logged.
struct XtreamAPI: Sendable {
    let origin: URL
    let username: String
    let password: String

    enum Action: String {
        case liveCategories = "get_live_categories"
        case liveStreams = "get_live_streams"
        case vodCategories = "get_vod_categories"
        case vodStreams = "get_vod_streams"
        case seriesCategories = "get_series_categories"
        case series = "get_series"
        case seriesInfo = "get_series_info"
    }

    init?(host: String, username: String, password: String) {
        var raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "http://" + raw }
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme, let host = components.host else { return nil }
        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        guard let origin = components.url else { return nil }
        self.origin = origin
        self.username = username
        self.password = password
    }

    private func apiURL(action: Action?, extra: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: origin.appendingPathComponent("player_api.php"),
                              resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action.rawValue)) }
        items += extra
        c.queryItems = items
        return c.url!
    }

    var authURL: URL { apiURL(action: nil) }
    func url(_ action: Action) -> URL { apiURL(action: action) }
    /// A stream list limited to one category (`&category_id=`).
    func url(_ action: Action, categoryID: String) -> URL {
        apiURL(action: action, extra: [URLQueryItem(name: "category_id", value: categoryID)])
    }
    func seriesInfoURL(seriesID: String) -> URL {
        apiURL(action: .seriesInfo, extra: [URLQueryItem(name: "series_id", value: seriesID)])
    }
    var xmltvURL: URL {
        var c = URLComponents(url: origin.appendingPathComponent("xmltv.php"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        return c.url!
    }

    // MARK: Stream URLs
    //
    // Xtream stream paths are `/{type}/{user}/{pass}/{id}.{ext}`. Built by string
    // so the slashes stay real; credential segments are percent-encoded.

    func liveStreamURL(id: Int, extension ext: String = "m3u8") -> URL {
        streamURL(type: "live", id: String(id), ext: ext, fallbackExt: "m3u8")
    }
    func vodStreamURL(id: Int, extension ext: String) -> URL {
        streamURL(type: "movie", id: String(id), ext: ext, fallbackExt: "mp4")
    }
    func seriesStreamURL(episodeID: String, extension ext: String) -> URL {
        streamURL(type: "series", id: episodeID, ext: ext, fallbackExt: "mp4")
    }

    private func streamURL(type: String, id: String, ext: String, fallbackExt: String) -> URL {
        let u = username.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? username
        let p = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        let e = sanitize(ext, fallback: fallbackExt)
        return URL(string: "\(origin.absoluteString)/\(type)/\(u)/\(p)/\(id).\(e)")!
    }

    private func sanitize(_ ext: String, fallback: String) -> String {
        let cleaned = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        return cleaned.isEmpty ? fallback : cleaned
    }
}
