import AgentSDK
import SwiftUI

/// Row of per-session controls rendered directly under the input bar
/// — outside the pill, with its left and right edges aligned to the
/// **pill's** leading and trailing edges (NOT to the attach `+`
/// floating to the bar's left). Visually the `+` is a discrete
/// floating control beside the bar; the chrome row belongs to the bar
/// proper, so it's inset past the attach button + the bar's internal
/// gap to start where the pill starts.
///
/// Layout: `[Permission] ────── [Model · Effort] [Context ring]`.
struct InputBarSessionChrome: View {
    let session: Session

    /// Vertical gap between the bar and this row. 10pt reads as a
    /// deliberate "second tier" without feeling detached from the bar.
    /// 4pt felt cramped (the row visually fused with the pill stroke);
    /// 16pt let the transcript scrim creep between them and made the
    /// row look like a separate widget.
    static let barSpacing: CGFloat = 10

    /// Leading inset that lines the row up with the pill's leading
    /// edge. Mirrors `InputBarView2`'s outer HStack geometry —
    /// `AttachButton.size` (32) + the bar's `attachToPillSpacing` (8,
    /// private to `InputBarView2` and stable per its layout doc).
    /// Defining it here rather than widening that private constant
    /// keeps `InputBarView2` untouched.
    static let pillLeadingInset: CGFloat = AttachButton.size + 8

    var body: some View {
        HStack(spacing: 8) {
            PermissionModePicker(session: session, activeModel: activeModel)
            BackgroundTaskButton(session: session)
            TodoButton(session: session)
            Spacer(minLength: 0)
            ModelEffortPicker(session: session)
            ContextRingButton(session: session)
        }
        .padding(.leading, Self.pillLeadingInset)
    }

    /// Resolves `session.model` to the matching `ModelInfo` from the
    /// per-session catalog (preferred) or the cross-launch
    /// `ModelStore` cache. Returned nil when the user hasn't picked
    /// one yet OR the catalog hasn't arrived — the permission picker
    /// uses this to decide whether the `auto` row is visible.
    private var activeModel: ModelInfo? {
        guard let value = session.model else { return nil }
        let live = session.availableModels
        let base = live.isEmpty ? ModelStore.shared.models : live
        let pool = ModelStore.withExtendedModels(base)
        return pool.first(where: { $0.value == value })
    }
}
