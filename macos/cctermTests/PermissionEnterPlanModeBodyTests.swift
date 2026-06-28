import AgentSDK
import AppKit
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot) for the AppKit `.enterPlanMode` body —
/// `PermissionEnterPlanModeCardBodyView` (migration plan §4.4, §9). Drives the
/// REAL production body builder
/// (`PermissionEnterPlanModeCardBodyBuilder.makeBody`) with a
/// representative `PermissionRequest` and asserts the parsed fields render into
/// the real view — never a re-implemented approximation, never the SwiftUI data
/// struct in isolation (the static product copy is pinned separately by
/// `PermissionEnterPlanModeCardBodyTests`; THIS test pins the AppKit render of
/// that copy).
@MainActor
final class PermissionEnterPlanModeBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Build the body through the production dispatch conformer (NOT by calling
    /// the view initializer directly) so the test exercises the same surface the
    /// card mounts. `.enterPlanMode` carries no per-request data, so the input is
    /// empty — exactly the request shape the card receives in production.
    private func makeBodyView(tool: String = "EnterPlanMode") -> PermissionEnterPlanModeCardBodyView {
        let req = PermissionRequest.makePreview(
            requestId: "plan-\(UUID().uuidString)", toolName: tool, input: [:])
        let view = PermissionEnterPlanModeCardBodyBuilder()
            .makeBody(request: req, engine: nil)
        return try! XCTUnwrap(view as? PermissionEnterPlanModeCardBodyView)
    }

    /// Mount at a fixed settled width so the wrapping labels lay out at a real
    /// width (mirrors `PermissionTaskAgentBodyTests.mount`).
    @discardableResult
    private func mount(_ view: NSView, width: CGFloat = 480) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = container
        window.ccterm_orderFrontForTesting()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        addTeardownBlock {
            window.contentView = nil
            window.close()
        }
        return window
    }

    // MARK: - Intro row (icon + sentence)

    func testIntroSentenceRenders() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedIntro,
            String(
                localized:
                    "Claude wants to enter plan mode to explore and design an implementation approach."
            ),
            "The intro row renders the localized intro sentence verbatim (reused getter).")
    }

    func testIntroSentenceIsPrimaryColored() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedIntroColor, NSColor.labelColor,
            "Intro text is primary (SwiftUI .foregroundStyle(.primary) → labelColor).")
    }

    func testIntroIconUsesAccentTint() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.introIconTint, NSColor.controlAccentColor,
            "The wand icon is tinted with the control accent (SwiftUI .foregroundStyle(.tint)).")
    }

    // MARK: - Bullet block

    func testBulletHeaderRenders() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedBulletHeader, String(localized: "In plan mode, Claude will:"),
            "The bullet-block header renders the localized header verbatim.")
    }

    func testFourBulletsRenderInUpstreamOrder() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedBullets,
            [
                String(localized: "Explore the codebase thoroughly"),
                String(localized: "Identify existing patterns"),
                String(localized: "Design an implementation strategy"),
                String(localized: "Present a plan for your approval"),
            ],
            "All four bullets render in upstream order, with the ` · ` prefix stripped.")
    }

    func testBulletCountMatchesData() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedBullets.count, PermissionEnterPlanModeCardBody.bullets.count,
            "Exactly the data-layer bullet count renders — no extra/missing line.")
    }

    func testBulletLinesCarryMiddleDotPrefix() {
        let view = makeBodyView()
        mount(view)
        // Assert on the RAW rendered string (prefix intact): each bullet must be
        // emitted as exactly ` · <bullet>`, matching the SwiftUI body's
        // ` · \(bullet)` literal (`PermissionEnterPlanModeCardBody.swift:48`). The
        // stripped `renderedBullets` can't catch a missing prefix; this can.
        let raw = view.renderedBulletsRaw
        XCTAssertEqual(raw.count, PermissionEnterPlanModeCardBody.bullets.count)
        for (rendered, bullet) in zip(raw, PermissionEnterPlanModeCardBody.bullets) {
            XCTAssertEqual(
                rendered, " · \(bullet)",
                "Bullet must render with the ` · ` prefix exactly once.")
        }
    }

    // MARK: - Closing reassurance

    func testClosingSentenceRenders() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedClosing,
            String(localized: "No code changes will be made until you approve the plan."),
            "The closing reassurance renders the localized closing sentence verbatim.")
    }

    func testClosingSentenceIsSecondaryColored() {
        let view = makeBodyView()
        mount(view)
        XCTAssertEqual(
            view.renderedClosingColor, NSColor.secondaryLabelColor,
            "Closing text is dim (SwiftUI .foregroundStyle(.secondary) → secondaryLabelColor).")
    }

    // MARK: - Stability across requests (static copy is request-independent)

    func testCopyIsRequestIndependent() {
        // `.enterPlanMode` has no per-request fields — two distinct requests (and
        // a non-canonical tool name) must render byte-identical copy.
        let a = makeBodyView(tool: "EnterPlanMode")
        let b = makeBodyView(tool: "ExitPlanModeButRoutedHere")
        mount(a)
        mount(b)
        XCTAssertEqual(a.renderedIntro, b.renderedIntro)
        XCTAssertEqual(a.renderedBulletHeader, b.renderedBulletHeader)
        XCTAssertEqual(a.renderedBullets, b.renderedBullets)
        XCTAssertEqual(a.renderedClosing, b.renderedClosing)
    }

    // MARK: - Sizing (no width leak — regime-B parity, plan R1)

    func testPublishesNoIntrinsicWidth() {
        let view = makeBodyView()
        XCTAssertEqual(
            view.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "The body publishes noIntrinsicMetric width so it can't leak a min-width to the host (R1).")
    }

    func testPublishesNoIntrinsicHeight() {
        let view = makeBodyView()
        XCTAssertEqual(
            view.intrinsicContentSize.height, NSView.noIntrinsicMetric,
            "The body publishes noIntrinsicMetric height; the vertical stack's edge pins drive height.")
    }
}
