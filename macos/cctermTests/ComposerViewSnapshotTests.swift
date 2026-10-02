import AppKit
import XCTest

@testable import ccterm

/// The composer under a transcript — empty, holding a message that could not
/// be sent (one line, many lines up to the cap, with the error), and while a
/// turn runs; wide and narrow, in light and dark. Review only —
/// `make test-unit FILTER=ComposerViewSnapshotTests`, then open
/// `/tmp/ccterm-screenshots/ComposerView.png`.
@MainActor
final class ComposerViewSnapshotTests: XCTestCase {
    private func controller(width: CGFloat, height: CGFloat, configure: (ComposerView) -> Void) -> NSViewController {
        let composer = ComposerView()
        configure(composer)
        composer.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.addSubview(composer)
        NSLayoutConstraint.activate([
            composer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    func testTheComposerInEachCase() {
        let long = (1...9).map { "Line \($0) of a message that is longer than the field is tall." }
            .joined(separator: "\n")
        let failure = "Couldn’t send the message: the session ended."
        let cases: [(CGFloat, CGFloat, (ComposerView) -> Void)] = [
            (900, 90, { _ in }),
            (900, 90, { $0.showFailure(failure, of: "Run the tests again") }),
            (900, 230, { $0.showFailure(failure, of: long) }),
            (900, 90, { $0.configure(isResponding: true) }),
            (360, 120, { $0.showFailure(failure, of: "Run the tests again, and then the linter") }),
        ]
        let sheets = cases.map { width, height, configure in
            ViewSnapshot.renderLightAndDark(
                { self.controller(width: width, height: height, configure: configure) },
                size: CGSize(width: width, height: height), name: "")
        }
        let url = ViewSnapshot.writeStack(sheets, name: "ComposerView")
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
