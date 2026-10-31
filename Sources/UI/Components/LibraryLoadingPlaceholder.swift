import SwiftUI

/// Shown by a feature screen when it has nothing to display *because the library
/// is still importing* — as opposed to a genuine "no results" state. Mirrors the
/// grid it stands in for, so the screen doesn't visibly jump when data arrives.
struct LibraryLoadingPlaceholder: View {
    var columns = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            HStack(spacing: Metrics.space2) {
                ProgressView().controlSize(.small).tint(Palette.textSecondary)
                Text("Building your library…")
                    .font(.dsCaption)
                    .foregroundStyle(Palette.textSecondary)
            }

            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: Metrics.cardSpacing) {
                    ForEach(0..<columns, id: \.self) { _ in
                        SkeletonBox()
                            .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.screenMargin)
        .padding(.top, Metrics.space4)
        .accessibilityLabel("Your library is still loading")
    }
}

extension AppEnvironment.LoadState {
    var isImporting: Bool { if case .loading = self { return true } else { return false } }
}
