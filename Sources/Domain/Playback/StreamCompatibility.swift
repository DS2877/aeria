import Foundation

/// Quick, offline judgement about whether `AVPlayer` is likely to handle a
/// stream. IPTV sources serve a lot of raw MPEG-TS and non-HTTP protocols that
/// the native player can't play — better to say so up front than spin forever.
public enum StreamCompatibility {

    public enum Verdict: Equatable, Sendable {
        case supported
        case unsupported(reason: String)
        case unknown
    }

    public static func verdict(for url: URL) -> Verdict {
        let scheme = (url.scheme ?? "").lowercased()
        switch scheme {
        case "http", "https":
            break
        case "rtmp", "rtmps", "rtsp", "mms", "udp", "rtp":
            return .unsupported(reason: "This channel uses a streaming protocol Apple TV can't play (\(scheme.uppercased())).")
        default:
            return .unknown
        }

        // An HLS URL sometimes carries a `.ts` last path segment for the media
        // playlist — treat anything mentioning m3u8 as HLS.
        if url.absoluteString.lowercased().contains("m3u8") { return .supported }

        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u", "mp4", "mov", "m4v", "m4a", "mp3", "aac":
            return .supported
        case "ts", "mpegts", "mts", "m2ts":
            return .unsupported(reason: "This is a raw MPEG-TS stream. Apple TV's player needs HLS — ask your provider for an HLS (.m3u8) output.")
        case "mkv", "avi", "flv", "wmv", "divx", "vob", "rmvb":
            return .unsupported(reason: "The \(url.pathExtension.uppercased()) container isn't supported by Apple TV's player.")
        default:
            return .unknown
        }
    }

    public static func isProbablyPlayable(_ url: URL) -> Bool {
        if case .unsupported = verdict(for: url) { return false }
        return true
    }
}
