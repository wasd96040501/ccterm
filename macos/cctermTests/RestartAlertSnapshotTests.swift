import AppKit
import XCTest

@testable import ccterm

/// The restart sheet (design 08 *Another account restarts the session*) beside
/// the sheet's alert, while Claude works: `/tmp/ccterm-parity/<scheme>-part-26-alert0.png`.
/// The alert is assembled from `RestartConfirmation` as
/// `SessionTabViewController.confirmRestart` assembles it, and drawn from its
/// own window after `layout()` — an `NSAlert` lays itself out without running.
@MainActor
final class RestartAlertSnapshotTests: XCTestCase {
    private func alert(_ confirmation: RestartConfirmation) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: confirmation.cancelTitle)
        if confirmation.confirmIsDestructive {
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[0].hasDestructiveAction = true
        }
        return alert
    }

    func testTheSheetAgainstTheDesign() throws {
        let confirmation = RestartConfirmation(accountName: "Work Relay", modelName: "Sonnet 4.6", isWorking: true)
        for scheme in DesignParity.Scheme.allCases {
            _ = try DesignParity.part("part-26-alert0", scheme)
            let alert = alert(confirmation)
            alert.window.appearance = scheme.appearance
            alert.layout()
            let content = try XCTUnwrap(alert.window.contentView)
            content.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let image = NSImage(size: content.bounds.size)
            image.addRepresentation(rep)
            let attachment = XCTAttachment(
                contentsOfFile: try DesignParity.write("part-26-alert0", scheme, ours: image))
            attachment.lifetime = .keepAlways
            add(attachment)
            alert.window.close()
        }
    }
}
