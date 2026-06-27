import AgentSDK
import AppKit
import SwiftUI
import XCTest

@testable import ccterm

/// Renders the input bar plus its session-chrome row (permission /
/// model+effort / context ring) and writes a PNG so the layout can be
/// reviewed without launching the app. Covers the three "interesting"
/// states for visual review: idle compose-mode-ish (no context yet),
/// running with a populated context ring, and the standalone chrome
/// row at its natural width.
///
/// The handle is seeded directly via its `internal(set)` fields plus
/// the public setters — no production-code seam. `InputBarChrome`
/// depends on `SessionManager` from the
/// environment + a `.task`-driven `prepareDraft`; neither fires
/// reliably offscreen, so this test composes the two visible parts
/// (`InputBarView2` and `InputBarSessionChrome`) in the same VStack
/// the wrapper uses, with the production `barSpacing`.
@MainActor
final class InputBarSnapshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testIdleStateSnapshot() throws {
        let session = Self.makeSession(running: false, contextWindowTokens: 0, contextUsedTokens: 0)
        capture(session: session, name: "InputBar-Idle", height: 140)
    }

    func testRunningWithContextSnapshot() throws {
        let session = Self.makeSession(
            running: true,
            contextWindowTokens: 200_000,
            contextUsedTokens: 142_000)
        capture(session: session, name: "InputBar-Running", height: 140)
    }

    // MARK: - Helpers

    private func capture(session: ccterm.Session, name: String, height: CGFloat) {
        let size = CGSize(width: 600, height: height)
        let view = InputBarFixture(session: session)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let image = ViewSnapshot.render(view, size: size, settle: 0.6)
        let url = ViewSnapshot.writePNG(image, name: name)

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(image.size.width, size.width - 1)
    }

    private static func makeSession(
        running: Bool,
        contextWindowTokens: Int,
        contextUsedTokens: Int
    ) -> ccterm.Session {
        let repo = InMemorySessionRepository()
        let runtime = SessionRuntime(
            sessionId: UUID().uuidString, repository: repo)
        runtime.setPermissionMode(.auto)
        runtime.setModel("default")
        runtime.setEffort(.xhigh)
        runtime.availableModels = Self.mockModels
        runtime.contextWindowTokens = contextWindowTokens
        runtime.contextUsedTokens = contextUsedTokens
        if running {
            runtime.isRunning = true
        }
        return ccterm.Session(runtime: runtime)
    }

    /// Hand-rolled `[ModelInfo]` mirroring what a current CLI's
    /// `InitializeResponse.models` actually returns (captured via
    /// `scripts/probe_claude_models.py`): three entries — `default` /
    /// `sonnet` / `haiku` — with per-model `supportsEffort` and
    /// `supportedEffortLevels`. Only `default` declares
    /// `supportsAutoMode`, which the permission picker uses to gate
    /// the `auto` row.
    private static let mockModels: [ModelInfo] = {
        let raws: [[String: Any]] = [
            [
                "value": "default",
                "displayName": "Default (recommended)",
                "description": "Opus 4.7 with 1M context · Most capable for complex work",
                "supportsEffort": true,
                "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"],
                "supportsAutoMode": true,
            ],
            [
                "value": "sonnet",
                "displayName": "Sonnet",
                "description": "Sonnet 4.6 · Best for everyday tasks",
                "supportsEffort": true,
                "supportedEffortLevels": ["low", "medium", "high", "max"],
            ],
            [
                "value": "haiku",
                "displayName": "Haiku",
                "description": "Haiku 4.5 · Fastest for quick answers",
            ],
        ]
        return raws.compactMap { try? ModelInfo(json: $0) }
    }()
}

/// Mirror of `InputBarChrome`'s visible composition without the
/// `.task` / environment plumbing the test can't satisfy. Keeps the
/// production `barSpacing` so the snapshot reflects real geometry.
private struct InputBarFixture: View {
    let session: ccterm.Session

    var body: some View {
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
        .padding(.vertical, 16)
    }
}
