#if DEBUG

import AppKit
import SwiftUI

/// UI-test-only injection point for the image-attach flow. `NSOpenPanel` is
/// an OS-owned modal that XCUITest cannot drive, so the test path bypasses
/// the panel entirely: when `CCTERM_TEST_MODE=1`, an invisible button keyed
/// by `accessibilityIdentifier("InputBar2.TestAttachImage")` is overlaid on
/// the bar. Clicking it attaches a synthetic in-memory PNG without ever
/// opening the panel.
///
/// The button is gated on the env var (not just `#if DEBUG`) so that
/// developers running the app from Xcode without test mode set don't see
/// an accidental tap target.
///
/// Layout: top-leading overlay sized 16×16, `opacity(0.001)` so it has
/// hittable bounds but is visually inert. Sits over the attach button —
/// fine because human users in this mode are the test runner.
extension InputBarView2 {

    @ViewBuilder
    func testAttachHook() -> some View {
        if ProcessInfo.processInfo.environment["CCTERM_TEST_MODE"] == "1" {
            Button {
                attachImage(data: Self.testImagePNGData, mediaType: "image/png")
            } label: {
                Color.clear.frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(0.001)
            .accessibilityIdentifier("InputBar2.TestAttachImage")
        } else {
            EmptyView()
        }
    }

    /// Synthetic 16×16 solid-color PNG used by the test attach hook.
    /// Generated lazily once per process via Core Graphics; ~100 bytes.
    static let testImagePNGData: Data = {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }()
}

#endif
