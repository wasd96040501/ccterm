import AgentSDK
import SwiftUI

/// Floating decision card shown above the input bar when the CLI is
/// waiting on a permission request. Mount as
/// `.overlay(alignment: .bottom)` on `InputBarChrome`:
///
/// - Bottom edge sits flush with the chrome row (permission mode /
///   model+effort), so the card visually extends *up* from there.
/// - Width inherits the chrome wrapper's frame — same span as the
///   attach button + pill of `InputBarView2`.
/// - Z-order is above the input bar; the bar surface fades through
///   the card's material as the card expands upward.
///
/// This file currently ships the stub used by Step 0 of the
/// permission-card landing PR. The real layout / decision plumbing
/// lands in follow-up commits on the same branch.
struct PermissionCardView: View {
    let request: PermissionRequest
    let onAllowOnce: () -> Void
    let onAllowAlways: () -> Void
    let onDeny: () -> Void

    /// Matches `InputBarView2.cornerRadius` so the card visually
    /// belongs to the same surface family as the pill.
    static let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Permission requested")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text(request.toolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .barSurface(cornerRadius: Self.cornerRadius)
    }
}
