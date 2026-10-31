import SwiftUI

/// A removable/selectable pill used for interpreted search filters and browse
/// filters.
public struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let showsRemoveIcon: Bool
    let action: () -> Void

    @Environment(\.isFocused) private var isFocused

    public init(
        label: String,
        isSelected: Bool = false,
        showsRemoveIcon: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.isSelected = isSelected
        self.showsRemoveIcon = showsRemoveIcon
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.dsTag)
                if showsRemoveIcon {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .padding(.horizontal, Metrics.space2)
            .padding(.vertical, Metrics.space1 + 2)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 2))
            .foregroundStyle(isFocused || isSelected ? Palette.textPrimary : Palette.textSecondary)
            .scaleEffect(isFocused ? 1.06 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: isFocused ? 16 : 0, y: isFocused ? 8 : 0)
            .animation(Metrics.focusAnimation, value: isFocused)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsRemoveIcon ? "Remove filter: \(label)" : label)
        .accessibilityAddTraits(isSelected && !showsRemoveIcon ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isFocused { return Palette.focusFill.opacity(0.16) }
        return isSelected ? Palette.accentSoft : Palette.surface
    }

    private var borderColor: Color {
        if isFocused { return Palette.accent }
        return isSelected ? Palette.accent : Palette.hairline
    }
}
