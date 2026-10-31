import SwiftUI

/// A 16:9 live-channel card with its name + current programme beneath. Only the
/// artwork is the focusable `.card`; the caption sits outside it.
public struct ChannelCard: View {
    let name: String
    let logoURL: URL?
    let nowTitle: String?
    let nextTitle: String?
    let quality: VideoQuality
    let nowProgress: Double?
    /// The provider's channel number (Xtream `num` / M3U `tvg-chnb`). IPTV users
    /// navigate by number, not name — `nil` or non-positive hides the chip
    /// (playlists that never set one land on `Channel.sortIndex == 0`).
    let channelNumber: Int?
    let action: () -> Void

    public init(
        name: String,
        logoURL: URL? = nil,
        nowTitle: String? = nil,
        nextTitle: String? = nil,
        quality: VideoQuality = .unknown,
        nowProgress: Double? = nil,
        channelNumber: Int? = nil,
        action: @escaping () -> Void
    ) {
        self.name = name
        self.logoURL = logoURL
        self.nowTitle = nowTitle
        self.nextTitle = nextTitle
        self.quality = quality
        self.nowProgress = nowProgress
        self.channelNumber = channelNumber
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1 + 2) {
            Button(action: action) {
                ZStack {
                    GeneratedArtwork(seed: name)

                    if let logoURL {
                        CachedImage(url: logoURL, contentMode: .fit, size: .logo) { monogram }
                            .padding(Metrics.space3)
                    } else {
                        monogram
                    }

                    if quality > .unknown || (channelNumber ?? 0) > 0 {
                        VStack {
                            HStack {
                                if let channelNumber, channelNumber > 0 {
                                    ChannelNumberBadge(number: channelNumber).padding(Metrics.space1)
                                }
                                Spacer()
                                if quality > .unknown {
                                    QualityBadge(quality: quality).padding(Metrics.space1)
                                }
                            }
                            Spacer()
                        }
                    }
                }
                .frame(width: Metrics.wideCardWidth, height: Metrics.wideCardHeight)
                .overlay(alignment: .bottom) {
                    if let nowProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.18))
                                Rectangle().fill(Palette.accent)
                                    .frame(width: geo.size.width * Swift.min(1, Swift.max(0, nowProgress)))
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            }
            .buttonStyle(.card)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.dsCardTitle)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                metadataLine
            }
            .padding(.horizontal, 2)
        }
        .frame(width: Metrics.wideCardWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(nowTitle.map { "\(name), now playing \($0)" } ?? name))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var metadataLine: some View {
        if let nowTitle {
            HStack(spacing: 7) {
                Circle().fill(Palette.liveDot).frame(width: 7, height: 7)
                Text(nowTitle)
                    .font(.dsCaption)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        } else {
            Text("Live")
                .font(.dsCaption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private var monogram: some View {
        Text(name.split(separator: " ").compactMap(\.first).prefix(2).map(String.init).joined().uppercased())
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.30))
    }
}
