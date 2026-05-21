import AgentSDK
import SwiftUI

/// Footer-row trigger that opens the permission-mode popover. Reads the
/// current selection from the session and writes back via
/// `setPermissionMode` — no local @State copy.
///
/// The popover's `auto` row is gated by the active model's
/// `supportsAutoMode` capability (only `default`/Opus 4.7 declares it in
/// the current CLI response). Hiding the row when unsupported avoids
/// letting the user pick a mode the model would silently ignore.
struct PermissionModePicker: View {
    let session: Session
    let activeModel: ModelInfo?
    @State private var isPresented = false

    var body: some View {
        BarChromeButton(label: {
            Text(session.permissionMode.shortTitle)
                .foregroundStyle(session.permissionMode.triggerTint)
        }) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            PermissionModePopoverContent(
                modes: Self.visibleModes(for: activeModel),
                selected: session.permissionMode,
                onSelect: { mode in
                    session.setPermissionMode(mode)
                    if session.draft != nil {
                        NewSessionDefaultsStore.shared.setPermissionMode(mode)
                    }
                    isPresented = false
                }
            )
        }
        .task(id: SeedKey(sessionId: session.sessionId, supportsAuto: activeModel?.supportsAutoMode == true)) {
            seedFromDefaultsIfNeeded()
        }
    }

    /// Re-run `seedFromDefaultsIfNeeded` both when the session id changes
    /// *and* when the model catalog flips `supportsAuto` from false to
    /// true. The catalog arrives asynchronously (cold launch: `ModelStore`
    /// is still fetching when the picker first renders), so a session-id
    /// only id would miss the saved `.auto` case and leave the session on
    /// `.default`. The seed body is idempotent — once `permissionMode`
    /// has moved off `.default`, every later trigger is a no-op.
    private struct SeedKey: Hashable {
        let sessionId: String
        let supportsAuto: Bool
    }

    /// Apply the user's last-picked permission mode from
    /// `NewSessionDefaultsStore` when this picker first surfaces for a
    /// draft session. `SessionConfig.init` always starts at `.default`
    /// — that's the "no user choice yet" signal we gate on. Active
    /// sessions skip this path entirely (their `permissionMode` is
    /// authoritative from the record).
    private func seedFromDefaultsIfNeeded() {
        guard session.draft != nil,
            session.permissionMode == .default,
            let saved = NewSessionDefaultsStore.shared.permissionMode,
            saved != .default
        else { return }
        // Auto mode is model-gated — don't seed it when the active model
        // doesn't advertise support, the popover would hide it anyway.
        if saved == .auto, activeModel?.supportsAutoMode != true { return }
        session.setPermissionMode(saved)
    }

    /// All cases minus `.auto` unless the active model declares
    /// `supportsAutoMode == true`. Exposed (`internal`) so tests can pin
    /// the rule without standing up a real session.
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
        ScrollView {
            VStack(spacing: 0) {
                // Section header reads the same CLI vocabulary as the
                // rows — do not localize.
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
        }
        .frame(width: PopoverList.width)
        .frame(maxHeight: PopoverList.maxHeight)
    }
}
