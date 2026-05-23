import AppKit
import SwiftUI

/// Modal preview for a tapped attachment chip. Aspect-fits the original
/// `NSImage` inside a generously-sized window; click anywhere (or hit
/// Return) to dismiss — matches the Quick Look "tap to close" muscle
/// memory. AppKit owns the sheet lifecycle now, so dismissal routes
/// through the injected `onDismiss` closure rather than
/// `@Environment(\.dismiss)`.
struct ImagePreviewSheetView: View {
    let image: NSImage
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            }
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }

            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(
            minWidth: 480, idealWidth: 880, maxWidth: 1400,
            minHeight: 360, idealHeight: 660, maxHeight: 1050)
    }
}
