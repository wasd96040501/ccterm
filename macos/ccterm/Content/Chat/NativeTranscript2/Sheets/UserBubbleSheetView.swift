import SwiftUI

/// Modal body for a user bubble's full text. Selection / copy come for
/// free via `Text.textSelection(.enabled)`; the Done button binds the
/// default action key (Return) and routes through `onDismiss` because
/// AppKit owns the sheet lifecycle now — `@Environment(\.dismiss)` is
/// only wired up when SwiftUI presented the sheet.
struct UserBubbleSheetView: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(
            minWidth: 520, idealWidth: 720, maxWidth: 960,
            minHeight: 360, idealHeight: 540, maxHeight: 800)
    }
}
