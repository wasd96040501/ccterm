import AgentSDK
import XCTest

@testable import ccterm

/// Covers `ModelEffortPicker.resolveCurrentModel` — the resolver the
/// picker uses to look up the "current" model for feature-flag
/// (fast mode / effort) lookups.
///
/// The earlier version returned nil whenever `handle.model` was nil,
/// which made the Fast Mode toggle render permanently disabled on
/// fresh sessions where the user hadn't explicitly picked a model —
/// even though the default model usually supports fast mode. The new
/// resolver falls back to the first available model in that case,
/// mirroring the CLI's "first entry == recommended default" listing.
final class ModelEffortPickerResolverTests: XCTestCase {

    private static let sonnet = makeModel(value: "claude-sonnet-4-6", displayName: "Sonnet 4.6", fast: true)
    private static let opus = makeModel(value: "claude-opus-4-7", displayName: "Opus 4.7", fast: false)
    private static let haiku = makeModel(value: "claude-haiku-4-5", displayName: "Haiku 4.5", fast: true)

    func testExactMatchReturnsThatModel() {
        let resolved = ModelEffortPicker.resolveCurrentModel(
            value: "claude-opus-4-7",
            in: [Self.sonnet, Self.opus, Self.haiku])
        XCTAssertEqual(resolved?.value, "claude-opus-4-7")
    }

    func testNilValueFallsBackToFirstModel() {
        let resolved = ModelEffortPicker.resolveCurrentModel(
            value: nil,
            in: [Self.sonnet, Self.opus, Self.haiku])
        XCTAssertEqual(resolved?.value, "claude-sonnet-4-6")
    }

    func testUnknownValueFallsBackToFirstModel() {
        // Stale handle pointed at a model the CLI no longer lists —
        // the resolver still surfaces *some* model so the fast-mode
        // toggle has a metadata source.
        let resolved = ModelEffortPicker.resolveCurrentModel(
            value: "claude-future-model-99",
            in: [Self.sonnet, Self.opus, Self.haiku])
        XCTAssertEqual(resolved?.value, "claude-sonnet-4-6")
    }

    func testEmptyModelsReturnsNil() {
        let resolved = ModelEffortPicker.resolveCurrentModel(
            value: "claude-opus-4-7",
            in: [])
        XCTAssertNil(resolved)
    }

    func testFallbackPreservesFastModeSupportOfFirstModel() {
        // The whole motivation for the fallback: when the user hasn't
        // picked a model yet, the toggle should reflect the default
        // model's `supportsFastMode` rather than always reading as
        // disabled.
        let resolved = ModelEffortPicker.resolveCurrentModel(
            value: nil,
            in: [Self.sonnet, Self.opus])
        XCTAssertEqual(resolved?.supportsFastMode, true)
    }

    private static func makeModel(value: String, displayName: String, fast: Bool) -> ModelInfo {
        let raw: [String: Any] = [
            "value": value,
            "displayName": displayName,
            "supportsFastMode": fast,
        ]
        return try! ModelInfo(json: raw)
    }
}
