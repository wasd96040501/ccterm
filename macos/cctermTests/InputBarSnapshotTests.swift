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
/// the public setters — no production-code seam. `InputBarChrome` is
/// private to RootView2 and depends on `SessionManager2` from the
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
        let handle = Self.makeHandle(running: false, contextWindowTokens: 0, contextUsedTokens: 0)
        capture(handle: handle, name: "InputBar-Idle", height: 140)
    }

    func testRunningWithContextSnapshot() throws {
        let handle = Self.makeHandle(
            running: true,
            contextWindowTokens: 200_000,
            contextUsedTokens: 142_000)
        capture(handle: handle, name: "InputBar-Running", height: 140)
    }

    // MARK: - Helpers

    private func capture(handle: SessionHandle2, name: String, height: CGFloat) {
        let size = CGSize(width: 600, height: height)
        let view = InputBarFixture(handle: handle)
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

    private static func makeHandle(
        running: Bool,
        contextWindowTokens: Int,
        contextUsedTokens: Int
    ) -> SessionHandle2 {
        let repo = InMemorySessionRepository()
        let handle = SessionHandle2(
            sessionId: UUID().uuidString, repository: repo)
        handle.setPermissionMode(.auto)
        handle.setModel("claude-opus-4-7")
        handle.setEffort(.xhigh)
        handle.availableModels = Self.mockModels
        handle.contextWindowTokens = contextWindowTokens
        handle.contextUsedTokens = contextUsedTokens
        if running {
            handle.pendingTurnCount = 1
        }
        return handle
    }

    /// Hand-rolled `[ModelInfo]` mirroring what a recent CLI's
    /// `InitializeResponse.models` would return. Only the fields the
    /// picker reads (`value` / `displayName` / `supportedEffortLevels`
    /// / `supportsFastMode`) need to be present; the rest are nil.
    private static let mockModels: [ModelInfo] = {
        let raws: [[String: Any]] = [
            [
                "value": "claude-opus-4-7",
                "displayName": "Opus 4.7",
                "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"],
                "supportsFastMode": false,
            ],
            [
                "value": "claude-sonnet-4-6",
                "displayName": "Sonnet 4.6",
                "supportedEffortLevels": ["low", "medium", "high"],
                "supportsFastMode": true,
            ],
            [
                "value": "claude-haiku-4-5",
                "displayName": "Haiku 4.5",
                "supportedEffortLevels": [],
                "supportsFastMode": true,
            ],
        ]
        return raws.compactMap { try? ModelInfo(json: $0) }
    }()
}

/// Mirror of `InputBarChrome`'s visible composition without the
/// `.task` / environment plumbing the test can't satisfy. Keeps the
/// production `barSpacing` so the snapshot reflects real geometry.
private struct InputBarFixture: View {
    let handle: SessionHandle2

    var body: some View {
        VStack(alignment: .leading, spacing: InputBarSessionChrome.barSpacing) {
            InputBarView2(
                onSubmit: { _ in },
                onStop: {},
                isRunning: handle.isRunning,
                submitEnabled: true
            )
            InputBarSessionChrome(handle: handle)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}
