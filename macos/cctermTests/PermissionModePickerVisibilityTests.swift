import AgentSDK
import XCTest

@testable import ccterm

/// Pins `PermissionModePicker.visibleModes(for:)` — the rule that the
/// `auto` row is only surfaced when the active `ModelInfo` declares
/// `supportsAutoMode == true`. Driven by the static helper so the test
/// doesn't need to stand up a real `SessionRuntime` + `View`.
@MainActor
final class PermissionModePickerVisibilityTests: XCTestCase {

    func testHidesAutoWhenNoActiveModel() {
        let modes = PermissionModePicker.visibleModes(for: nil)
        XCTAssertFalse(modes.contains(.auto))
        // Other modes still surface so the picker is never empty.
        XCTAssertTrue(modes.contains(.default))
        XCTAssertTrue(modes.contains(.plan))
    }

    func testHidesAutoWhenActiveModelLacksCapability() {
        // sonnet in the current CLI: no `supportsAutoMode` field.
        let sonnet = Self.makeModel(value: "sonnet", supportsAutoMode: nil)
        XCTAssertFalse(PermissionModePicker.visibleModes(for: sonnet).contains(.auto))
    }

    func testShowsAutoWhenActiveModelDeclaresCapability() {
        // `default` (Opus 4.7) — only entry that declares
        // `supportsAutoMode: true` in current CLI responses.
        let defaultModel = Self.makeModel(value: "default", supportsAutoMode: true)
        XCTAssertTrue(PermissionModePicker.visibleModes(for: defaultModel).contains(.auto))
    }

    private static func makeModel(value: String, supportsAutoMode: Bool?) -> ModelInfo {
        var raw: [String: Any] = ["value": value, "displayName": value]
        if let supportsAutoMode { raw["supportsAutoMode"] = supportsAutoMode }
        return try! ModelInfo(json: raw)
    }
}
