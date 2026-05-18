import AgentSDK
import XCTest

@testable import ccterm

/// Pins `EffortDefaultStore`'s per-model resolution. The store is
/// tested through an injected `UserDefaults` instance so parallel
/// suites don't fight over `.standard` (CLAUDE.md § "No UserDefaults
/// reads / writes" — the rule allows it when the value is injected at
/// the call boundary).
@MainActor
final class EffortDefaultStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: EffortDefaultStore!
    private var suiteName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        suiteName = "EffortDefaultStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = EffortDefaultStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
    }

    // MARK: First-time defaults

    func testFirstTimeDefaultMapsKnownValues() {
        XCTAssertEqual(EffortDefaultStore.firstTimeDefault(for: "default"), .xhigh)
        XCTAssertEqual(EffortDefaultStore.firstTimeDefault(for: "sonnet"), .high)
        // Anything not in the table falls through to `high` — same as
        // ccmaster's `getDefaultEffortLevelForOption` final fallback.
        XCTAssertEqual(EffortDefaultStore.firstTimeDefault(for: "haiku"), .high)
        XCTAssertEqual(EffortDefaultStore.firstTimeDefault(for: "future-model"), .high)
    }

    // MARK: effort(for:) core

    func testReturnsFirstTimeDefaultClampedToSupportedLevels() {
        // `default` first-time default is xhigh; CLI's default model
        // does include xhigh, so it's returned as-is.
        let info = Self.makeModel(
            value: "default", supportsEffort: true,
            levels: ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(store.effort(for: info), .xhigh)
    }

    func testFirstTimeDefaultIsClampedWhenNotInSupportedLevels() {
        // Hypothetical: a sonnet build that drops `high` from its
        // levels. Boundary case — must not surface an unsupported
        // level; falls to the first declared level.
        let info = Self.makeModel(
            value: "sonnet", supportsEffort: true,
            levels: ["low", "medium"])
        XCTAssertEqual(store.effort(for: info), .low)
    }

    func testRemembersWriteAndReadsBack() {
        let info = Self.makeModel(
            value: "default", supportsEffort: true,
            levels: ["low", "medium", "high", "xhigh", "max"])
        store.remember(.medium, for: "default")
        XCTAssertEqual(store.effort(for: info), .medium)
    }

    func testRememberedValueIsClampedToSupportedLevels() {
        // Earlier write happened on a CLI build where `xhigh` was
        // supported; current build dropped it. Memory must not let an
        // unsupported level survive into the picker.
        store.remember(.xhigh, for: "sonnet")
        let info = Self.makeModel(
            value: "sonnet", supportsEffort: true,
            levels: ["low", "medium", "high", "max"])
        XCTAssertEqual(store.effort(for: info), .low)
    }

    func testReturnsNilWhenModelDoesNotSupportEffort() {
        // haiku in the current CLI — no supportsEffort, no levels.
        let info = Self.makeModel(value: "haiku", supportsEffort: nil, levels: nil)
        XCTAssertNil(store.effort(for: info))
    }

    // MARK: Helpers

    private static func makeModel(
        value: String, supportsEffort: Bool?, levels: [String]?
    ) -> ModelInfo {
        var raw: [String: Any] = ["value": value, "displayName": value]
        if let supportsEffort { raw["supportsEffort"] = supportsEffort }
        if let levels { raw["supportedEffortLevels"] = levels }
        return try! ModelInfo(json: raw)
    }
}
