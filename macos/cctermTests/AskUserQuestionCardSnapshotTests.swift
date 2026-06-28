import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// Review-only snapshots (opt-in; SKIPPED on the unfiltered CI gate) for the
/// pure-AppKit AskUserQuestion wizard (`AskUserQuestionCardViewController`,
/// migration plan §4.5). Renders the real production VC via
/// `ViewSnapshot.renderViewController` so the vstack-of-rows look + chrome
/// takeover + Other row + empty fallback can be eyeballed. Mirrors the three
/// `#Preview` fixtures the deleted SwiftUI body carried (single-select-with-
/// Other, multi-select 2-of-3 step 1, empty fallback).
///
/// Not a regression gate — `make test-unit FILTER=AskUserQuestionCardSnapshotTests`
/// then `open /tmp/ccterm-screenshots/AskUserQuestionCard-*.png`.
@MainActor
final class AskUserQuestionCardSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Wrap the wizard VC (which sizes to its content) in a padded, opaque
    /// host VC so the snapshot reads like the production card surface.
    private func render(_ input: [String: Any], name: String, size: CGSize) {
        let request = PermissionRequest.makePreview(
            requestId: name, toolName: "AskUserQuestion", input: input)
        let card = PermissionCardContentView(
            request: request, engine: nil,
            onAllowOnce: {}, onAllowAlways: {}, onDeny: {}, onAllowWithInput: { _ in })

        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
        ])
        card.widthAnchor.constraint(equalToConstant: min(520, size.width - 32)).isActive = true

        let vc = NSViewController()
        vc.view = host

        let image = ViewSnapshot.renderViewController(vc, size: size)
        let url = ViewSnapshot.writePNG(image, name: name)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    func testSingleSelectWithOther() {
        render(
            [
                "questions": [
                    [
                        "question":
                            "Should we keep backwards-compatibility shims for the old API?",
                        "header": "Compat",
                        "multiSelect": false,
                        "options": [
                            [
                                "label": "Yes, keep them",
                                "description": "Existing clients still need them",
                            ],
                            [
                                "label": "No, remove them",
                                "description": "Cleaner break, faster releases",
                            ],
                        ],
                    ]
                ]
            ],
            name: "AskUserQuestionCard-SingleSelectWithOther",
            size: CGSize(width: 560, height: 420))
    }

    func testMultiSelectStep1() {
        render(
            [
                "questions": [
                    [
                        "question": "Which features should we enable in v1?",
                        "header": "Features",
                        "multiSelect": true,
                        "options": [
                            ["label": "Diff view", "description": "Side-by-side patches"],
                            ["label": "Inline syntax highlight"],
                            ["label": "Code folding"],
                        ],
                    ],
                    [
                        "question": "Pick the default theme.",
                        "header": "Theme",
                        "options": [["label": "Auto"], ["label": "Light"], ["label": "Dark"]],
                    ],
                ]
            ],
            name: "AskUserQuestionCard-MultiSelectStep1",
            size: CGSize(width: 560, height: 460))
    }

    func testEmptyFallback() {
        render(
            [:],
            name: "AskUserQuestionCard-EmptyFallback",
            size: CGSize(width: 480, height: 200))
    }
}
