import Foundation

/// Codable models for the `player_api.php` responses. All numeric-ish fields go
/// through `LenientInt`/`LenientString` because panels are inconsistent.
/// A stream-list entry that names its category — lets the import fetch lists
/// category by category and check the panel really filtered.
protocol XtreamCategorized {
    var category_id: String? { get }
}

enum XtreamDTO {

    struct AuthResponse: Decodable {
        struct UserInfo: Decodable {
            @LenientString var auth: String?
            @LenientString var status: String?          // "Active", "Expired", …
            @LenientString var message: String?
        }
        let user_info: UserInfo?
    }

    struct Category: Decodable, Sendable {
        @LenientString var category_id: String?
        @LenientString var category_name: String?
    }

    /// `get_short_epg` — now/next for one stream. Title and description are
    /// base64 on most panels.
    struct ShortEPG: Decodable, Sendable {
        struct Listing: Decodable, Sendable {
            @LenientString var title: String?
            @LenientString var description: String?
            @LenientString var channel_id: String?
            @LenientString var epg_id: String?
            @LenientInt var start_timestamp: Int?
            @LenientInt var stop_timestamp: Int?
        }
        let epg_listings: [Listing]?
    }

    struct LiveStream: Decodable, Sendable, XtreamCategorized {
        @LenientInt var stream_id: Int?
        @LenientString var name: String?
        @LenientString var stream_icon: String?
        @LenientString var epg_channel_id: String?
        @LenientString var category_id: String?
        @LenientInt var num: Int?
    }

    struct VODStream: Decodable, Sendable, XtreamCategorized {
        @LenientInt var stream_id: Int?
        @LenientString var name: String?
        @LenientString var stream_icon: String?
        @LenientString var category_id: String?
        @LenientString var container_extension: String?
        @LenientString var rating: String?
        @LenientString var added: String?
        @LenientString var releaseDate: String?
        @LenientString var plot: String?
        @LenientString var genre: String?
        @LenientString var cast: String?
        @LenientString var director: String?
        @LenientInt var episode_run_time: Int?
    }

    struct SeriesListItem: Decodable, Sendable, XtreamCategorized {
        @LenientInt var series_id: Int?
        @LenientString var name: String?
        @LenientString var cover: String?
        @LenientString var plot: String?
        @LenientString var cast: String?
        @LenientString var director: String?
        @LenientString var genre: String?
        @LenientString var releaseDate: String?
        @LenientString var rating: String?
        @LenientString var category_id: String?
        @LenientString var last_modified: String?
    }

    struct SeriesInfo: Decodable {
        struct Episode: Decodable {
            @LenientString var id: String?
            @LenientInt var episode_num: Int?
            @LenientString var title: String?
            @LenientString var container_extension: String?
            struct Info: Decodable {
                @LenientString var plot: String?
                @LenientString var movie_image: String?
                @LenientInt var duration_secs: Int?
            }
            let info: Info?
        }
        struct Season: Decodable {
            @LenientInt var season_number: Int?
            @LenientString var name: String?
        }
        let seasons: [Season]?
        /// Keyed by season number as a string.
        let episodes: [String: [Episode]]?
    }
}
