import AgentSDK
import AppKit
import Foundation
import XCTest

@testable import ccterm

/// CI-gate measurement test (non-snapshot — runs on the unfiltered suite) for
/// the AppKit Skill permission card body (migration plan §4.4, §9).
///
/// Drives the REAL body builder (`PermissionSkillCardBodyBuilder.makeBody`) with
/// a representative `PermissionRequest` and asserts the parsed fields actually
/// render into the production `PermissionSkillCardBodyView`'s NSTextFields — the
/// real surface, no stub, no re-implemented approximation. The data getters
/// (`skillName` / `skillArgs` on `PermissionRequest`, `headline` / `cwdLabel` on
/// the view) are also exercised directly since they are ported verbatim and back
/// the rendering.
@MainActor
final class PermissionSkillBodyTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func request(_ input: [String: Any]) -> PermissionRequest {
        PermissionRequest.makePreview(
            requestId: "skill-\(UUID().uuidString)",
            toolName: "Skill",
            input: input)
    }

    /// Build the body through the REAL dispatch builder and mount it so layout
    /// settles, then return the concrete production view for field assertions.
    private func makeBody(_ input: [String: Any]) -> PermissionSkillCardBodyView {
        let builder = PermissionSkillCardBodyBuilder()
        let view = builder.makeBody(request: request(input), engine: nil)
        guard let body = view as? PermissionSkillCardBodyView else {
            XCTFail(
                "Skill builder must produce a PermissionSkillCardBodyView, got \(type(of: view))")
            return PermissionSkillCardBodyView(request: request(input))
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        container.layoutSubtreeIfNeeded()
        return body
    }

    // MARK: - The builder produces the real body view

    func testBuilderProducesSkillBodyView() {
        let view = PermissionSkillCardBodyBuilder().makeBody(
            request: request(["skill": "commit"]), engine: nil)
        XCTAssertTrue(
            view is PermissionSkillCardBodyView,
            "The Skill builder must build the real PermissionSkillCardBodyView.")
    }

    func testDispatchReturnsSkillBuilderForSkillKind() {
        // The dispatch (the spine) must route `.skill` to a builder whose
        // makeBody yields the real Skill body — guards the integration wiring.
        let builder = permissionCardBodyBuilder(for: .skill)
        let view = builder.makeBody(request: request(["skill": "commit"]), engine: nil)
        XCTAssertTrue(
            view is PermissionSkillCardBodyView,
            "permissionCardBodyBuilder(for: .skill) must build the real Skill body.")
    }

    // MARK: - Headline renders the quoted skill name

    func testHeadlineRendersQuotedSkillName() {
        let body = makeBody(["skill": "commit"])
        let expected = String(localized: "Use skill \"\("commit")\"")
        XCTAssertEqual(body.request.skillName, "commit")
        XCTAssertEqual(body.headline, expected)
        XCTAssertEqual(
            body.renderedHeadlineText, expected,
            "The headline NSTextField must render the quoted skill name.")
    }

    func testHeadlineFallsBackWhenSkillOmitted() {
        let body = makeBody([:])
        XCTAssertNil(body.request.skillName)
        XCTAssertEqual(body.headline, String(localized: "Use skill"))
        XCTAssertEqual(body.renderedHeadlineText, String(localized: "Use skill"))
    }

    func testCamelCaseSkillNameIsAccepted() {
        let body = makeBody(["skillName": "review-pr"])
        XCTAssertEqual(body.request.skillName, "review-pr")
        XCTAssertEqual(
            body.renderedHeadlineText, String(localized: "Use skill \"\("review-pr")\""))
    }

    // MARK: - Args row renders only when non-empty, monospaced + selectable

    func testArgsRowRendersWhenPresent() {
        let body = makeBody(["skill": "review-pr", "args": "--no-confirm 123"])
        XCTAssertEqual(body.request.skillArgs, "--no-confirm 123")
        XCTAssertEqual(
            body.renderedArgsText, "--no-confirm 123",
            "The args NSTextField must render the parsed args string.")
        XCTAssertTrue(
            body.argsIsSelectableReadOnly,
            "Args field is read-only + selectable (SwiftUI .textSelection(.enabled)).")
    }

    func testNoArgsRowWhenArgsEmpty() {
        let body = makeBody(["skill": "pdf", "args": ""])
        XCTAssertNil(body.request.skillArgs)
        XCTAssertNil(body.renderedArgsText, "An empty args string must not build an args row.")
    }

    func testNoArgsRowWhenArgsOmitted() {
        let body = makeBody(["skill": "commit"])
        XCTAssertNil(body.renderedArgsText)
    }

    // MARK: - cwd chip renders the process cwd basename

    func testCwdChipRendersBasename() {
        let body = makeBody(["skill": "commit"])
        let expected = (FileManager.default.currentDirectoryPath as NSString).lastPathComponent
        // The chip is hidden only on an empty/"/" cwd; the test environment always
        // has a real cwd, so the row + its label must be present and match.
        XCTAssertEqual(body.cwdLabel, expected.isEmpty ? nil : expected)
        XCTAssertEqual(
            body.renderedCwdText, expected.isEmpty ? nil : expected,
            "The cwd label must render the basename of FileManager.currentDirectoryPath.")
    }

    // MARK: - Row composition per input

    func testRowCompositionWithSkillArgsAndCwd() {
        let body = makeBody(["skill": "review-pr", "args": "--scope diff"])
        // headline + args + cwd (cwd present in the test environment).
        let hasCwd = body.renderedCwdText != nil
        XCTAssertEqual(
            body.arrangedSubviews.count, hasCwd ? 3 : 2,
            "Skill + args (+ cwd) builds headline + args (+ cwd) rows.")
    }

    func testRowCompositionWithSkillOnly() {
        let body = makeBody(["skill": "commit"])
        // headline + cwd (no args row).
        let hasCwd = body.renderedCwdText != nil
        XCTAssertEqual(
            body.arrangedSubviews.count, hasCwd ? 2 : 1,
            "Skill only (no args) builds headline (+ cwd) rows, no args row.")
        XCTAssertNil(body.renderedArgsText)
    }

    // MARK: - Constants match the SwiftUI source verbatim

    func testConstantsMatchSwiftUISource() {
        XCTAssertEqual(PermissionSkillCardBodyBuilder.stackSpacing, 8)
        XCTAssertEqual(PermissionSkillCardBodyBuilder.headlineFontSize, 12)
        XCTAssertEqual(PermissionSkillCardBodyBuilder.argsFontSize, 12)
        XCTAssertEqual(PermissionSkillCardBodyBuilder.argsLineLimit, 3)
        XCTAssertEqual(PermissionSkillCardBodyBuilder.cwdRowSpacing, 4)
        XCTAssertEqual(PermissionSkillCardBodyBuilder.cwdIconSize, 10)
        XCTAssertEqual(PermissionSkillCardBodyBuilder.cwdLabelFontSize, 11)
    }

    // MARK: - No width leak (R1)

    func testPublishesNoIntrinsicWidth() {
        let body = makeBody(["skill": "commit"])
        XCTAssertEqual(
            body.intrinsicContentSize.width, NSView.noIntrinsicMetric,
            "The body must publish noIntrinsicMetric width so it can't leak a min-width up (R1).")
    }

    // MARK: - Data getters parse rawInput identically to the SwiftUI source

    func testSkillNameGetterFallsThroughToCamelCase() {
        XCTAssertEqual(request(["skill": "a"]).skillName, "a")
        XCTAssertEqual(request(["skillName": "b"]).skillName, "b")
        // snake-case `skill` takes precedence when both are present.
        XCTAssertEqual(request(["skill": "a", "skillName": "b"]).skillName, "a")
        XCTAssertNil(request(["skill": ""]).skillName, "Empty skill is treated as absent.")
        XCTAssertNil(request([:]).skillName)
    }

    func testSkillArgsGetterTreatsEmptyAsNil() {
        XCTAssertEqual(request(["args": "--x"]).skillArgs, "--x")
        XCTAssertNil(request(["args": ""]).skillArgs)
        XCTAssertNil(request([:]).skillArgs)
    }
}
