import SwiftUI

/// Visual building blocks for the menus dropped from the input-bar
/// footer buttons (permission / model+effort). The layout mirrors
/// Claude.app's popovers: small gray section header, then a stack of
/// rows where the currently-selected row gets a soft highlight plus a
/// leading checkmark. Keyboard shortcuts are deliberately not rendered
/// — those go through the system menu bar elsewhere.
enum PopoverList {
    static let width: CGFloat = 240
    static let rowHeight: CGFloat = 28
    static let horizontalInset: CGFloat = 10
    static let outerPadding: CGFloat = 6
}

/// Header line for a popover section ("Mode", "Models", "Effort", ...).
struct PopoverSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PopoverList.horizontalInset)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

/// One selectable row: text label fills the row, checkmark trails on the
/// right when selected. Hover paints a soft background, press darkens
/// slightly. Mirrors a system menu item.
struct PopoverRow<Accessory: View>: View {
    let title: String
    let isSelected: Bool
    @ViewBuilder var accessory: () -> Accessory
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                accessory()
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, PopoverList.horizontalInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: PopoverList.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(_PopoverRowButtonStyle())
    }
}

extension PopoverRow where Accessory == EmptyView {
    init(title: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.init(title: title, isSelected: isSelected, accessory: { EmptyView() }, onSelect: onSelect)
    }
}

private struct _PopoverRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            }
            .onHover { hovering = $0 }
            .animation(.linear(duration: 0.08), value: hovering)
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return Color.primary.opacity(0.12) }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}
