import AgentSDK
import SwiftUI

/// Footer-row trigger that opens the permission-mode popover. Reads the
/// current selection from the handle and writes back via
/// `setPermissionMode` — no local @State copy.
///
/// The popover's `auto` row is gated by the active model's
/// `supportsAutoMode` capability (only `default`/Opus 4.7 declares it in
/// the current CLI response). Hiding the row when unsupported avoids
/// letting the user pick a mode the model would silently ignore.
struct PermissionModePicker: View {
    let handle: SessionHandle2
    let activeModel: ModelInfo?
    @State private var isPresented = false

    var body: some View {
        BarChromeButton(label: {
            Text(handle.permissionMode.shortTitle)
                .foregroundStyle(handle.permissionMode.triggerTint)
        }) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            PermissionModePopoverContent(
                modes: Self.visibleModes(for: activeModel),
                selected: handle.permissionMode,
                onSelect: { mode in
                    handle.setPermissionMode(mode)
                    isPresented = false
                }
            )
        }
    }

    /// All cases minus `.auto` unless the active model declares
    /// `supportsAutoMode == true`. Exposed (`internal`) so tests can pin
    /// the rule without standing up a real handle.
    static func visibleModes(for model: ModelInfo?) -> [PermissionMode] {
        let supportsAuto = model?.supportsAutoMode == true
        return PermissionMode.allCases.filter { mode in
            mode != .auto || supportsAuto
        }
    }
}

private struct PermissionModePopoverContent: View {
    let modes: [PermissionMode]
    let selected: PermissionMode
    let onSelect: (PermissionMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Section header reads the same CLI vocabulary as the rows —
            // do not localize.
            PopoverSectionHeader(title: "Mode")
            ForEach(modes, id: \.rawValue) { mode in
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
