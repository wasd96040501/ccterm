import SwiftUI

/// Row of per-session controls rendered directly under the input bar
/// — outside the pill, with its left and right edges visually aligned
/// to the bar's left (attach `+`) and right (pill trailing) edges.
///
/// Layout: `[Permission picker] ────── [Model · Effort] [Context ring]`.
/// `InputBarView2`'s outer HStack is `attach (32) + 8pt + pill`; this
/// row spans the same width, so the permission pill sits flush under
/// the attach button and the model trigger sits flush under the pill's
/// trailing edge.
struct InputBarSessionChrome: View {
    let handle: SessionHandle2

    /// Vertical gap between the bar and this row. 10pt reads as a
    /// deliberate "second tier" without feeling detached from the bar.
    /// 4pt felt cramped (the row visually fused with the pill stroke);
    /// 16pt let the transcript scrim creep between them and made the
    /// row look like a separate widget.
    static let barSpacing: CGFloat = 10

    var body: some View {
        HStack(spacing: 8) {
            PermissionModePicker(handle: handle)
            Spacer(minLength: 0)
            ModelEffortPicker(handle: handle)
            ContextRingButton(handle: handle)
        }
    }
}
