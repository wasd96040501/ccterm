import AgentSDK
import XCTest

@testable import ccterm

/// The `.ultracode` effort tier is app-level sugar: it is not a real CLI
/// `effortLevel` value. At every CLI boundary it must translate to
/// `effortLevel: xhigh` plus the `ultracode` flag, and every other tier
/// must send `ultracode: false` so the two stay mutually exclusive.
///
/// These tests pin that translation at both boundaries:
/// - mid-session `applyFlagSettings` (`Effort.flagSettings`),
/// - session launch (`SessionConfig.toAgentSDKConfig`).
@MainActor
final class UltracodeEffortTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Effort.flagSettings — the mid-session apply_flag_settings payload

    func testUltracodeEffortSerializesToXhighPlusFlag() {
        let dict = Effort.ultracode.flagSettings
        XCTAssertEqual(dict["effortLevel"], "xhigh")
        XCTAssertEqual(dict["ultracode"], true)
    }

    func testNormalEffortSendsUltracodeFalse() {
        let dict = Effort.high.flagSettings
        XCTAssertEqual(dict["effortLevel"], "high")
        XCTAssertEqual(
            dict["ultracode"], false,
            "Picking a normal effort must turn ultracode off so the tiers stay mutually exclusive")
    }

    // MARK: - Launch injection — SessionConfig.toAgentSDKConfig

    func testUltracodeConfigLaunchesWithInlineFlagSettings() {
        var config = SessionConfig(cwd: "/tmp/ultracode")
        config.effort = .ultracode
        let sdk = config.toAgentSDKConfig(
            sessionId: UUID().uuidString, resume: false, customCommand: nil)

        // `--effort` carries the CLI level; the ultracode flag itself rides
        // in inline settings.
        XCTAssertEqual(sdk.effort, .xhigh)
        XCTAssertEqual(sdk.settings, "{\"ultracode\":true}")
    }

    func testNormalEffortConfigInjectsNoSettings() {
        var config = SessionConfig(cwd: "/tmp/normal")
        config.effort = .high
        let sdk = config.toAgentSDKConfig(
            sessionId: UUID().uuidString, resume: false, customCommand: nil)

        XCTAssertEqual(sdk.effort, .high)
        XCTAssertNil(sdk.settings)
    }
}
