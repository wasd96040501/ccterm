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
    let handle: SessionHandle2

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
            PermissionModePicker(handle: handle)
            Spacer(minLength: 0)
            ModelEffortPicker(handle: handle)
            ContextRingButton(handle: handle)
        }
        .padding(.leading, Self.pillLeadingInset)
    }
}
