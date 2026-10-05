import AgentSDK
import XCTest

@testable import ccterm

/// `SessionSettings`: what a change brings with it, what the CLI will run,
/// what cannot be chosen and why, and how the last settings of a transcript
/// are read back — the rules a draft and a live session share.
final class SessionSettingsTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private let catalog = Fixture.catalog

    // MARK: - applying

    func testAModelWithoutFastModeTurnsFastOff() {
        let settings = Fixture.settings("opus", fast: true)
        XCTAssertEqual(settings.applying(.model(Fixture.choice("sonnet")), catalog: catalog).fastMode, false)
        XCTAssertEqual(settings.applying(.model(Fixture.choice("default")), catalog: catalog).fastMode, true)
    }

    func testAModelWithoutAutoStepsAutoDownToAsk() {
        let settings = Fixture.settings("sonnet", mode: .auto)
        XCTAssertEqual(
            settings.applying(.model(Fixture.choice("haiku")), catalog: catalog).permissionMode, .default)
        XCTAssertEqual(
            settings.applying(.model(Fixture.choice("opus")), catalog: catalog).permissionMode, .auto)
    }

    func testOtherModesSurviveAModelWithoutAuto() {
        let settings = Fixture.settings("sonnet", mode: .plan)
        XCTAssertEqual(settings.applying(.model(Fixture.choice("haiku")), catalog: catalog).permissionMode, .plan)
    }

    func testFastOnStepsAutoDownToAsk() {
        let settings = Fixture.settings("opus", mode: .auto)
        let next = settings.applying(.fastMode(true), catalog: catalog)
        XCTAssertTrue(next.fastMode)
        XCTAssertEqual(next.permissionMode, .default)
        XCTAssertEqual(settings.applying(.fastMode(false), catalog: catalog).permissionMode, .auto)
    }

    func testAnEffortTheNewModelLacksIsKeptSoSwitchingBackRestoresIt() {
        let settings = Fixture.settings("opus", effort: .xhigh)
        let onOlder = settings.applying(.model(Fixture.choice("claude-opus-4-6")), catalog: catalog)
        XCTAssertEqual(onOlder.effort, .xhigh)
        XCTAssertEqual(onOlder.effectiveEffort(catalog: catalog), .high, "the CLI runs it as High")
        let back = onOlder.applying(.model(Fixture.choice("opus")), catalog: catalog)
        XCTAssertEqual(back.effectiveEffort(catalog: catalog), .xhigh)
    }

    func testAnUnknownModelBringsNothingAlong() {
        let settings = Fixture.settings("opus", mode: .auto, fast: true)
        let next = settings.applying(.model(Fixture.choice("brand-new")), catalog: catalog)
        XCTAssertTrue(next.fastMode)
        XCTAssertEqual(next.permissionMode, .auto)
        XCTAssertEqual(next.model.value, "brand-new")
    }

    func testPlainChangesJustSet() {
        let settings = Fixture.settings("opus")
        XCTAssertEqual(settings.applying(.effort(.max), catalog: catalog).effort, .max)
        XCTAssertNil(settings.applying(.effort(.max), catalog: catalog).applying(.effort(nil), catalog: catalog).effort)
        XCTAssertEqual(settings.applying(.permissionMode(.plan), catalog: catalog).permissionMode, .plan)
    }

    func testAnotherAccountsModelIsJustTheNewChoice() {
        let next = Fixture.settings("opus").applying(
            .model(Fixture.choice("haiku", on: Fixture.relay)), catalog: catalog)
        XCTAssertEqual(next.model.account, Fixture.relay)
    }

    // MARK: - effectiveEffort

    func testEffectiveEffortIsTheChosenLevelWhenTheModelHasIt() {
        XCTAssertEqual(Fixture.settings("opus", effort: .max).effectiveEffort(catalog: catalog), .max)
    }

    func testEffectiveEffortOfAModelWithNoEffortIsNil() {
        XCTAssertNil(Fixture.settings("haiku", effort: .max).effectiveEffort(catalog: catalog))
        XCTAssertNil(Fixture.settings("haiku").effectiveEffort(catalog: catalog))
    }

    func testEffectiveEffortWithNoChoiceIsTheModelsDefault() {
        XCTAssertEqual(Fixture.settings("opus").effectiveEffort(catalog: catalog), .high)
        XCTAssertEqual(SessionSettings.defaultEffort(for: Fixture.choice("claude-opus-4-6"), catalog: catalog), .high)
        XCTAssertNil(SessionSettings.defaultEffort(for: Fixture.choice("haiku"), catalog: catalog), "takes no effort")
        XCTAssertNil(SessionSettings.defaultEffort(for: Fixture.choice("unlisted"), catalog: catalog))
    }

    func testEffectiveEffortOfAModelNotInTheCatalogIsWhatWasChosen() {
        XCTAssertEqual(Fixture.settings("unlisted", effort: .low).effectiveEffort(catalog: catalog), .low)
        XCTAssertNil(Fixture.settings("unlisted").effectiveEffort(catalog: ModelCatalog()))
    }

    func testTheLevelsOfAModelAreInTheScalesOrder() {
        let model = InitializationResult.Model(
            value: "x", supportsEffort: true, supportedEffortLevels: ["max", "low", "bogus", "high"])
        XCTAssertEqual(SessionSettings.levels(of: model), [.low, .high, .max])
    }

    // MARK: - unavailability

    func testAutoIsUnavailableWhileFastModeIsOn() {
        XCTAssertEqual(
            Fixture.settings("opus", fast: true).unavailability(
                of: .auto, catalog: catalog, allowsBypassPermissions: false),
            String(localized: "Unavailable while Fast Mode is on"))
    }

    func testAutoIsUnavailableOnAModelWithoutItNamingTheModel() {
        XCTAssertEqual(
            Fixture.settings("haiku").unavailability(of: .auto, catalog: catalog, allowsBypassPermissions: false),
            String(localized: "Not on \("Haiku 4.5")"))
    }

    func testBypassNeedsGeneralsPermission() {
        let settings = Fixture.settings("opus")
        XCTAssertEqual(
            settings.unavailability(of: .bypassPermissions, catalog: catalog, allowsBypassPermissions: false),
            String(localized: "Allow it in Settings › General"))
        XCTAssertNil(settings.unavailability(of: .bypassPermissions, catalog: catalog, allowsBypassPermissions: true))
    }

    func testTheOtherModesAreAlwaysAvailable() {
        let settings = Fixture.settings("haiku", fast: true)
        for mode in [PermissionMode.default, .acceptEdits, .plan, .dontAsk] {
            XCTAssertNil(settings.unavailability(of: mode, catalog: catalog, allowsBypassPermissions: false))
        }
    }

    func testAutoOnADefaultRowNamesWhatItResolvesTo() {
        let relayHaiku = Fixture.settings("haiku", on: Fixture.relay)
        XCTAssertEqual(
            relayHaiku.unavailability(of: .auto, catalog: catalog, allowsBypassPermissions: false),
            String(localized: "Not on \("Haiku")"))
    }

    // MARK: - nextCycledMode

    func testCyclingGoesAskAcceptEditsPlanAutoAndAround() {
        var settings = Fixture.settings("sonnet")
        var seen: [PermissionMode] = []
        for _ in 0..<5 {
            settings.permissionMode = settings.nextCycledMode(catalog: catalog, allowsBypassPermissions: false)
            seen.append(settings.permissionMode)
        }
        XCTAssertEqual(seen, [.acceptEdits, .plan, .auto, .default, .acceptEdits])
    }

    func testCyclingSkipsAutoWhereItIsUnavailable() {
        let settings = Fixture.settings("haiku", mode: .plan)
        XCTAssertEqual(settings.nextCycledMode(catalog: catalog, allowsBypassPermissions: false), .default)
        let fast = Fixture.settings("opus", mode: .plan, fast: true)
        XCTAssertEqual(fast.nextCycledMode(catalog: catalog, allowsBypassPermissions: false), .default)
    }

    func testCyclingFromAModeOutsideTheCycleStartsAtAsk() {
        let settings = Fixture.settings("opus", mode: .dontAsk)
        XCTAssertEqual(settings.nextCycledMode(catalog: catalog, allowsBypassPermissions: false), .default)
        let bypass = Fixture.settings("opus", mode: .bypassPermissions)
        XCTAssertEqual(bypass.nextCycledMode(catalog: catalog, allowsBypassPermissions: true), .default)
    }

    // MARK: - Codable

    func testSettingsRoundTripThroughTheirRawValues() throws {
        let settings = Fixture.settings("opus", effort: .xhigh, mode: .acceptEdits, fast: true)
        let data = try JSONEncoder().encode(settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["effort"] as? String, "xhigh")
        XCTAssertEqual(json["permissionMode"] as? String, "acceptEdits")
        XCTAssertEqual(try JSONDecoder().decode(SessionSettings.self, from: data), settings)
    }

    func testAnUnknownValueReadsAsTheDefaultRatherThanFailing() throws {
        let id = Fixture.subscription.uuidString
        let data = Data(
            #"{"model":{"account":"\#(id)","value":"opus"},"effort":"turbo","permissionMode":"someday"}"#.utf8)
        let settings = try JSONDecoder().decode(SessionSettings.self, from: data)
        XCTAssertNil(settings.effort)
        XCTAssertEqual(settings.permissionMode, .default)
        XCTAssertFalse(settings.fastMode)
    }

    // MARK: - lastOf

    private func assistant(_ model: String, effort: Effort? = nil, parent: String? = nil) -> Message {
        var message = AssistantMessage(
            uuid: UUID().uuidString, sessionID: "s", messageID: UUID().uuidString, model: model,
            content: [.text("hi")], parentToolUseID: parent)
        message.effort = effort
        return .assistant(message)
    }

    private func user(_ mode: PermissionMode?) -> Message {
        var message = UserMessage(content: [.text("hi")])
        message.permissionMode = mode
        return .user(message)
    }

    private func last(
        _ messages: [Message], allowsBypass: Bool = true, catalog: ModelCatalog? = nil
    ) -> SessionSettings? {
        SessionSettings(
            lastOf: Transcript(messages: messages), catalog: catalog ?? self.catalog,
            allowsBypassPermissions: allowsBypass)
    }

    func testTheLastAssistantsModelAndEffortAndTheLastUsersModeAreTheLastSettings() {
        let settings = last([
            user(.plan), assistant("claude-sonnet-5-5", effort: .low), user(.acceptEdits),
            assistant("claude-opus-5-5", effort: .xhigh),
        ])
        XCTAssertEqual(settings?.model, Fixture.choice("opus"))
        XCTAssertEqual(settings?.effort, .xhigh)
        XCTAssertEqual(settings?.permissionMode, .acceptEdits)
        XCTAssertEqual(settings?.fastMode, false)
    }

    func testAModelOnAProviderIsMappedOntoItsAccountWhenTheSubscriptionLacksIt() {
        var catalog = self.catalog
        catalog.accounts[1].models.append(Fixture.model("relay-model", resolved: "my-relay-model"))
        let settings = last([assistant("my-relay-model")], catalog: catalog)
        XCTAssertEqual(settings?.model, Fixture.choice("relay-model", on: Fixture.relay))
    }

    func testANamedRowWinsOverAnAccountsDefault() {
        // Both the subscription's *Default* and *Opus 5.5* resolve to this id.
        XCTAssertEqual(last([assistant("claude-opus-5-5")])?.model.value, "opus")
    }

    func testAModelNoAccountListsIsKeptByNameOnTheSubscription() {
        XCTAssertEqual(last([assistant("claude-mystery-9")])?.model, Fixture.choice("claude-mystery-9"))
    }

    func testBypassBecomesAskWhenGeneralNoLongerAllowsIt() {
        let messages = [user(.bypassPermissions), assistant("claude-opus-5-5")]
        XCTAssertEqual(last(messages, allowsBypass: false)?.permissionMode, .default)
        XCTAssertEqual(last(messages, allowsBypass: true)?.permissionMode, .bypassPermissions)
    }

    func testNoModeRecordedIsAsk() {
        XCTAssertEqual(last([assistant("claude-opus-5-5")])?.permissionMode, .default)
    }

    func testNoAssistantEntryMeansNoSettings() {
        XCTAssertNil(last([user(.plan)]))
        XCTAssertNil(last([]))
    }

    func testSyntheticAndSubagentMessagesRanNoModel() {
        let settings = last([
            assistant("claude-sonnet-5-5"), assistant("<synthetic>"), assistant("claude-opus-5-5", parent: "toolu_1"),
        ])
        XCTAssertEqual(settings?.model, Fixture.choice("sonnet"))
    }

    func testNothingIsReadWhileNoAccountIsKnown() {
        XCTAssertNil(last([assistant("claude-opus-5-5")], catalog: ModelCatalog()))
    }
}
