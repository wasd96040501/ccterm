#if DEBUG

import AppKit
import SwiftUI

/// UI-test-only data backing the image-attach flow. `NSOpenPanel` is an
/// OS-owned modal that XCUITest cannot drive, so the test path injects a
/// synthetic in-memory PNG instead.
///
/// The hidden "Test Attach Image" menu item lives directly inside
/// `InputBarView2.attachButton` under `#if DEBUG` + `CCTERM_TEST_MODE=1`,
/// because SwiftUI menus are `@ViewBuilder` content that doesn't compose
/// cleanly from extension methods. This file isolates the **data** (the
/// synthetic PNG bytes) so production InputBarView2 stays focused on
/// production behavior.
extension InputBarView2 {

    /// Synthetic 16×16 solid-color PNG used by the test attach menu item.
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
