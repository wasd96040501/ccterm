import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders `PermissionCardView` in two contexts and writes PNGs so
/// the card surface and the over-input-bar composition can both be
/// reviewed without launching the app.
@MainActor
final class PermissionCardSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCardAloneSnapshot() throws {
        let request = PermissionRequest.makePreview(
            requestId: "req-1",
            toolName: "Bash",
            input: ["command": "rm -rf node_modules", "description": "Reset deps"])

        // 380 tall accommodates the new bash card layout: header +
        // command DiffView (caps at 240pt) + description + buttons +
        // padding. The previous 220pt fit the single-line Text-only
        // command surface; the diff body is intrinsically larger.
        let size = CGSize(width: 520, height: 380)
        let view = StandalonePermissionCardFixture(request: request)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        capture(view, size: size, name: "PermissionCard-Bash")
    }

    /// Mirrors `InputBarChrome`'s real composition: the
    /// `InputBarView2` + `InputBarSessionChrome` VStack with the
    /// permission card overlaid on top. Verifies the three geometric
    /// claims of the design at once — bottom-aligned with the chrome
    /// row, full chrome width, z above the input bar.
    /// Renders the AskUserQuestion permission card with a realistic
    /// single-select payload (header chip + 3 options) so the
    /// vstack-of-rows look + chrome takeover can be reviewed.
    func testAskUserQuestionCardSnapshot() throws {
        let request = PermissionRequest.makePreview(
            requestId: "req-ask",
            toolName: "AskUserQuestion",
            input: [
                "questions": [
                    [
                        "question":
                            "Should we keep backwards-compatibility shims for the old API?",
                        "header": "Compat",
                        "multiSelect": false,
                        "options": [
                            [
                                "label": "Yes, keep them",
                                "description": "Existing clients still depend on them",
                            ],
                            [
                                "label": "No, remove them",
                                "description": "Cleaner break, faster releases",
                            ],
                            [
                                "label": "Defer to next milestone",
                                "description": "We'll re-evaluate after the migration",
                            ],
                        ],
                    ],
                    [
                        "question": "Pick the default theme.",
                        "header": "Theme",
                        "multiSelect": false,
                        "options": [
                            ["label": "Auto"],
                            ["label": "Light"],
                            ["label": "Dark"],
                        ],
                    ],
                ]
            ])

        let size = CGSize(width: 560, height: 460)
        let view = StandalonePermissionCardFixture(request: request)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        capture(view, size: size, name: "PermissionCard-AskUserQuestion")
    }

    /// Multi-select variant — same payload structure but the bottom
    /// "Submit" row is expected to render.
    func testAskUserQuestionMultiSelectCardSnapshot() throws {
        let request = PermissionRequest.makePreview(
            requestId: "req-ask-multi",
            toolName: "AskUserQuestion",
            input: [
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
                    ]
                ]
            ])

        let size = CGSize(width: 560, height: 440)
        let view = StandalonePermissionCardFixture(request: request)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        capture(view, size: size, name: "PermissionCard-AskUserQuestion-Multi")
    }

    func testCardOverInputBarSnapshot() throws {
        let session = Self.makeSession()
        Self.enqueuePermission(
            on: session,
            requestId: "req-over",
            toolName: "Bash",
            input: ["command": "git push --force origin main"])

        let size = CGSize(width: 600, height: 460)
        let view = InputBarChromeMirrorFixture(session: session)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        capture(view, size: size, name: "PermissionCard-OverInputBar")
    }

    // MARK: - Helpers

    private func capture(_ view: some View, size: CGSize, name: String) {
        let image = ViewSnapshot.render(view, size: size, settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: name)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    /// Builds a `Session` (active phase) and seeds the bare minimum
    /// runtime state the chrome row reads. Permission card injection
    /// uses the package-internal `pendingPermissions` setter on
    /// `SessionRuntime` — same path the production CLI sink uses,
    /// just without the response closure plumbing.
    private static func makeSession() -> ccterm.Session {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: repo)
        runtime.setPermissionMode(.default)
        return ccterm.Session(runtime: runtime)
    }

    /// Append a pending permission directly onto the runtime's
    /// `internal(set)` storage. Mirrors what
    /// `SessionRuntime.enqueuePermission` would do at runtime, minus
    /// the response closure (the snapshot doesn't exercise it).
    private static func enqueuePermission(
        on session: ccterm.Session,
        requestId: String,
        toolName: String,
        input: [String: Any]
    ) {
        guard case .active(let runtime) = session.phase else {
            XCTFail("expected active session for permission seeding")
            return
        }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: toolName, input: input)
        let pending = PendingPermission(
            id: requestId,
            request: request,
            respond: { _ in })
        runtime.pendingPermissions.append(pending)
    }
}

/// Standalone card on a transparent canvas. Padding mirrors the
/// horizontal inset the chrome wrapper sits under so the snapshot
/// reads as a fair preview of real geometry.
private struct StandalonePermissionCardFixture: View {
    let request: PermissionRequest

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            PermissionCardView(
                request: request,
                onAllowOnce: {},
                onAllowAlways: {},
                onDeny: {}
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// Mirrors the visible composition of `ChatRestingBar`: the input bar +
/// session chrome stack with the permission card layered on the z-axis
/// over it via `ZStack(alignment: .bottom)` (the card covers the bar,
/// bottom-flush, rather than stacking above it on the y-axis). Uses
/// production constants verbatim — `barSpacing`, the unmodified card
/// view, no alternate fixture geometry.
private struct InputBarChromeMirrorFixture: View {
    let session: ccterm.Session

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: InputBarSessionChrome.barSpacing) {
                    InputBarView2(
                        onSubmit: { _ in },
                        onStop: {},
                        isRunning: session.isRunning,
                        submitEnabled: true
                    )
                    InputBarSessionChrome(session: session)
                }
                if let pending = session.pendingPermissions.first {
                    PermissionCardView(
                        request: pending.request,
                        onAllowOnce: {},
                        onAllowAlways: {},
                        onDeny: {}
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // `InputBarView2` reads `@Environment(InputDraftStore.self)`;
        // inject a fresh in-memory store so the offscreen render doesn't
        // trap on a missing environment object.
        .environment(InputDraftStore())
    }
}
