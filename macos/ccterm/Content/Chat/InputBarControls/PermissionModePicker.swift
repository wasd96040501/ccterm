import AgentSDK
import SwiftUI

/// Footer-row trigger that opens the permission-mode popover. Reads the
/// current selection from the handle and writes back via
/// `setPermissionMode` — no local @State copy.
struct PermissionModePicker: View {
    let handle: SessionHandle2
    @State private var isPresented = false

    var body: some View {
        BarChromeButton(label: {
            Text(handle.permissionMode.shortTitle)
                .foregroundStyle(modeTint)
        }) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            PermissionModePopoverContent(
                selected: handle.permissionMode,
                onSelect: { mode in
                    handle.setPermissionMode(mode)
                    isPresented = false
                }
            )
        }
    }

    /// Color the trigger label by mode — matches Claude.app's hint that
    /// the "looser" modes (Auto, Bypass) are visually flagged.
    private var modeTint: Color {
        switch handle.permissionMode {
        case .default, .acceptEdits, .plan: return .secondary
        case .auto: return .accentColor
        case .bypassPermissions: return .red
        }
    }
}

private struct PermissionModePopoverContent: View {
    let selected: PermissionMode
    let onSelect: (PermissionMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Section header reads the same CLI vocabulary as the rows —
            // do not localize.
            PopoverSectionHeader(title: "Mode")
            ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                PopoverRow(
                    title: mode.title,
                    isSelected: mode == selected,
                    onSelect: { onSelect(mode) }
                )
            }
        }
        .padding(PopoverList.outerPadding)
        .frame(width: PopoverList.width)
    }
}
