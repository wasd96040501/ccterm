import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders `PermissionCardView` and the standalone `PermissionCardOverlay`
/// in a few contexts and writes PNGs so the card surface and the
/// floats-over-the-bar composition can be reviewed without launching the
/// app.
///
/// Post-merge the card is composited inline by `ChatBottomCluster` (fade +
/// input bar + permission card in one bottom-anchored host), bottom-pinned
/// with `chatBottomInset` (36) so it visually extends *up* from the bar's
/// bottom edge — and the bar's `frame.minY` is NOT moved by the card. The
/// `OverInputBar` fixture reproduces that geometry (card on a higher z-layer
/// above an unchanged input-bar stack), and the `Overlay` snapshot renders
/// the standalone `PermissionCardOverlay` (the same card subtree + decision
/// wiring) over a transcript-height canvas so the float position + bottom
/// inset can be eyeballed.
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

    /// The card floating over the input-bar stack, post-PR5 geometry: the
    /// card sits on a SEPARATE z-layer (a `ZStack` mirroring the dedicated
    /// `permissionCardHost`) bottom-pinned with `chatBottomInset`, so it
    /// extends up from the bar's bottom edge WITHOUT growing the bar stack's
    /// height. Verifies the three geometric claims of the design at once —
    /// the bar band stays its intrinsic height, the card overlaps it from a
    /// higher layer, and the card is bottom-flush at the bar inset.
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

    /// Renders the standalone `PermissionCardOverlay` resolved through a
    /// `SessionManager` + `MainSelectionModel` — the same card subtree +
    /// decision wiring `ChatBottomCluster` composites inline. The pane is
    /// transcript-height so the bottom-pinned card (at `chatBottomInset`)
    /// floats at the bottom with the rest of the pane transparent —
    /// confirming the card's bottom-anchor geometry rather than an
    /// over-input-bar mock.
    func testOverlaySnapshot() throws {
        let (model, manager) = Self.makeSelectedSessionWithPermission(
            requestId: "req-overlay",
            toolName: "Bash",
            input: ["command": "rm -rf build"])

        let size = CGSize(width: 820, height: 600)
        let view = PermissionCardOverlay(model: model)
            .environment(manager)
            .environment(InputDraftStore())
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        capture(view, size: size, name: "PermissionCard-Overlay")
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

    /// Builds a `SessionManager` (in-memory repo) holding one active
    /// session with a pending permission, plus a `MainSelectionModel`
    /// selected on it — the exact inputs `PermissionCardOverlay` resolves
    /// through (`manager.prepareDraftSession(sid)` +
    /// `model.selection`). Lets the overlay snapshot render the production
    /// view rather than a hand-built mock.
    private static func makeSelectedSessionWithPermission(
        requestId: String,
        toolName: String,
        input: [String: Any]
    ) -> (MainSelectionModel, SessionManager) {
        let repo = InMemorySessionRepository()
        let sid = UUID().uuidString
        repo.save(
            SessionRecord(
                sessionId: sid, title: "Permission demo", cwd: "/tmp/perm", status: .created))
        let manager = SessionManager(
            repository: repo, cliClientFactory: { _ in FakeCLIClient() })
        guard let session = manager.session(sid), case .active(let runtime) = session.phase else {
            XCTFail("expected an active session for overlay seeding")
            return (MainSelectionModel(), manager)
        }
        let request = PermissionRequest.makePreview(
            requestId: requestId, toolName: toolName, input: input)
        runtime.pendingPermissions.append(
            PendingPermission(id: requestId, request: request, respond: { _ in }))

        let model = MainSelectionModel()
        model.selection = .session(sid)
        return (model, manager)
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

/// Mirrors the merged-cluster composition: the input-bar stack
/// (`InputBarView2` + `InputBarSessionChrome`) bottom-anchored, with the
/// permission card on a higher z-layer above it — the way `ChatBottomCluster`
/// composites the bar (its own intrinsic height) and the card in one tree. The
/// card is bottom-pinned with `ChatSessionViewController.chatBottomInset` (36)
/// so it floats up from the bar's bottom edge, and lives outside the bar's
/// VStack so it can't pump the bar's height. `ChatRestingBar` no longer
/// carries the card, so this fixture reproduces the layering rather than the
/// old single-stack ZStack.
private struct InputBarChromeMirrorFixture: View {
    let session: ccterm.Session

    var body: some View {
        // Two siblings in a bottom-aligned ZStack, mirroring the merged
        // cluster: the bar band (its own intrinsic height) and the card
        // overlay layered on top.
        ZStack(alignment: .bottom) {
            // Bar host analog: bottom-anchored, height = its own content.
            VStack(alignment: .leading, spacing: InputBarSessionChrome.barSpacing) {
                InputBarView2(
                    onSubmit: { _ in },
                    onStop: {},
                    isRunning: session.isRunning,
                    submitEnabled: true
                )
                InputBarSessionChrome(session: session)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxHeight: .infinity, alignment: .bottom)

            // Permission-card overlay analog: full-pane, card bottom-pinned
            // at `chatBottomInset` so it overlaps the bar from a higher layer
            // without growing it.
            if let pending = session.pendingPermissions.first {
                PermissionCardView(
                    request: pending.request,
                    onAllowOnce: {},
                    onAllowAlways: {},
                    onDeny: {}
                )
                .frame(maxWidth: BlockStyle.maxLayoutWidth)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, ChatSessionViewController.chatBottomInset)
            }
        }
        // `InputBarView2` reads `@Environment(InputDraftStore.self)`;
        // inject a fresh in-memory store so the offscreen render doesn't
        // trap on a missing environment object.
        .environment(InputDraftStore())
    }
}
