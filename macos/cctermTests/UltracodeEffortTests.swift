import AgentSDK
import XCTest

@testable import ccterm

/// The `.ultracode` effort tier is app-level sugar: it is not a real CLI
/// `effortLevel` value. At every CLI boundary it must translate to
/// `effortLevel: xhigh` plus the `ultracode` flag, and every other tier
/// must send `ultracode: false` so the two stay mutually exclusive.
///
/// These tests pin that translation at both boundaries:
/// - mid-session `applyFlagSettings` (`FlagSettings.effort(_:)`),
/// - session launch (`SessionConfig.toAgentSDKConfig`).
@MainActor
final class UltracodeEffortTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - FlagSettings.effort — the mid-session apply_flag_settings payload

    func testUltracodeEffortSerializesToXhighPlusFlag() {
        let dict = FlagSettings.effort(.ultracode).toDictionary()
        XCTAssertEqual(dict["effortLevel"] as? String, "xhigh")
        XCTAssertEqual(dict["ultracode"] as? Bool, true)
    }

    func testNormalEffortSendsUltracodeFalse() {
        let dict = FlagSettings.effort(.high).toDictionary()
        XCTAssertEqual(dict["effortLevel"] as? String, "high")
        XCTAssertEqual(
            dict["ultracode"] as? Bool, false,
            "Picking a normal effort must turn ultracode off so the tiers stay mutually exclusive")
    }

    // MARK: - Launch injection — SessionConfig.toAgentSDKConfig

    func testUltracodeConfigLaunchesWithInlineFlagSettings() {
        var config = SessionConfig(cwd: "/tmp/ultracode")
        config.effort = .ultracode
        let sdk = config.toAgentSDKConfig(
            sessionId: UUID().uuidString, resume: false, customCommand: nil)

        // `--effort` carries the tier verbatim; the SDK argv builder maps
        // `.ultracode` → xhigh. The ultracode flag itself rides in inline.
        XCTAssertEqual(sdk.effort, .ultracode)
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
