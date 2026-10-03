import AgentSDK
import XCTest

@testable import ccterm

/// What the composer says, worded from the catalog, the settings and the
/// session's phase (design 08 *The composer*, `accHTML` / `menuItems`). Pure.
///
/// The rules asked of `SessionSettings` (`effectiveEffort`, `unavailability`,
/// `nextCycledMode`) are tested in `SessionSettingsTests`; here a test that
/// reads them checks only that their answer reaches the words.
final class ComposerModelTests: XCTestCase {
    // MARK: Fixtures

    /// A word of the composer as the running language has it.
    private func L(_ key: String.LocalizationValue) -> String { String(localized: key) }

    private static let subscription = UUID()
    private static let relay = UUID()
    private static let deepseek = UUID()

    private static func model(
        _ value: String, _ name: String, resolved: String? = nil, levels: [String]? = nil, fast: Bool = false,
        auto: Bool = true
    ) -> InitializationResult.Model {
        let levels = levels ?? ["low", "medium", "high", "xhigh", "max"]
        var model = InitializationResult.Model(
            value: value, displayName: name, supportsEffort: !levels.isEmpty, supportedEffortLevels: levels,
            supportsFastMode: fast, supportsAutoMode: auto)
        model.resolvedModel = resolved
        return model
    }

    private static let catalog = ModelCatalog(accounts: [
        AccountCatalog(
            id: subscription, name: "Claude Max", detail: "Subscription", isSubscription: true, isLoaded: true,
            models: [
                model("default", "Default (recommended)", resolved: "claude-opus-5-5", fast: true),
                model("opus", "Opus 5.5", fast: true),
                model("fable", "Fable 5.1"),
                model("sonnet", "Sonnet 5.5"),
                model("haiku", "Haiku 4.5", levels: [], auto: false),
                model("opus-5", "Opus 5", fast: true),
                model("sonnet-4-6", "Sonnet 4.6", levels: ["low", "medium", "high", "max"]),
            ],
            shownModelCount: 5, commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: .auto),
        AccountCatalog(
            id: relay, name: "Work Relay", detail: "relay.example.com", isSubscription: false, isLoaded: true,
            models: [
                model(
                    "default", "Default", resolved: "claude-sonnet-4-6", levels: ["low", "medium", "high", "max"]),
                model("opus", "Opus", resolved: "claude-opus-4-6", levels: ["low", "medium", "high", "max"]),
            ],
            shownModelCount: 2, commands: [], fastModeUnavailableReason: nil, defaultPermissionMode: nil),
        AccountCatalog(
            id: deepseek, name: "DeepSeek", detail: "api.deepseek.com", isSubscription: false, isLoaded: false,
            models: [], shownModelCount: 0, commands: [], fastModeUnavailableReason: nil,
            defaultPermissionMode: nil),
    ])

    private func settings(
        _ value: String = "opus", on account: UUID = ComposerModelTests.subscription, effort: Effort? = .high,
        mode: PermissionMode = .auto, fast: Bool = false
    ) -> SessionSettings {
        SessionSettings(
            model: ModelChoice(account: account, value: value), effort: effort, permissionMode: mode, fastMode: fast)
    }

    private func model(
        _ context: ComposerModel.Context = .draft, settings: SessionSettings? = nil, pendingModel: ModelChoice? = nil,
        pendingFast: Bool? = nil, catalog: ModelCatalog = ComposerModelTests.catalog, allowsBypass: Bool = false,
        usage: Double? = nil, refusal: String? = nil
    ) -> ComposerModel {
        ComposerModel(
            ComposerModel.Input(
                context: context, placement: context == .draft ? .page : .floating,
                settings: settings ?? self.settings(), pendingModel: pendingModel,
                pendingFastMode: pendingFast, catalog: catalog, allowsBypassPermissions: allowsBypass,
                contextUsage: usage, refusal: refusal, commands: []))
    }

    private func session(
        _ phase: SessionState.Phase, waiting: Bool = false, visible: Bool = true
    ) -> ComposerModel.Context {
        .session(phase: phase, isWaitingForYou: waiting, isWaitingRequestVisible: visible)
    }

    // MARK: Loading, placeholder

    func testWithNothingKnownTheChipsSayLoadingAndNothingCanBeChosen() {
        let model = ComposerModel(
            ComposerModel.Input(
                context: .draft, placement: .page, settings: nil, pendingModel: nil, pendingFastMode: nil,
                catalog: ModelCatalog(),
                allowsBypassPermissions: false, contextUsage: nil, refusal: nil, commands: []))
        XCTAssertEqual(model.model.title, L("Loading…"))
        XCTAssertFalse(model.model.isEnabled)
        XCTAssertFalse(model.effort.isEnabled)
        XCTAssertFalse(model.mode.isEnabled)
        XCTAssertEqual(model.effortMenu.sections, [])
        XCTAssertEqual(model.modeMenu.sections, [])
        XCTAssertEqual(model.modelSections, [])
        XCTAssertFalse(model.fastMode.isEnabled)
    }

    func testThePlaceholderFollowsTheTab() {
        XCTAssertEqual(model(.draft).placeholder, L("Ask Claude to…"))
        XCTAssertEqual(model(session(.idle)).placeholder, L("Message Claude"))
    }

    // MARK: Chips

    func testTheModelChipNamesTheModelAndNoAccountForTheSubscription() {
        let chip = model(settings: settings("sonnet")).model
        XCTAssertEqual(chip.title, "Sonnet 5.5")
        XCTAssertNil(chip.detail)
        XCTAssertEqual(chip.leadingGlyphs, [])
        XCTAssertNil(chip.trailingGlyph)
        XCTAssertTrue(chip.isEnabled)
        XCTAssertFalse(chip.titleIsDroppable)
        XCTAssertEqual(chip.toolTip, "Claude Max · Sonnet 5.5")
    }

    func testTheDefaultModelIsNamedByWhatItResolvesTo() {
        XCTAssertEqual(model(settings: settings("default")).model.title, "Opus 5.5")
    }

    func testAProviderModelNamesItsAccountAndItsResolvedModel() {
        let chip = model(settings: settings("default", on: Self.relay)).model
        XCTAssertEqual(chip.title, "Sonnet 4.6")
        XCTAssertEqual(chip.detail, "Work Relay")
        XCTAssertEqual(chip.toolTip, "Work Relay · claude-sonnet-4-6")
    }

    func testFastAddsABoltBeforeTheName() {
        XCTAssertEqual(model(settings: settings(fast: true)).model.leadingGlyphs, [.fast])
    }

    func testAModelChosenWhileClaudeWorksShowsWithAClockAndItsToolTipSaysWhen() {
        let sonnet = ModelChoice(account: Self.subscription, value: "sonnet")
        let chip = model(session(.responding), settings: settings("opus"), pendingModel: sonnet).model
        XCTAssertEqual(chip.title, "Sonnet 5.5")
        XCTAssertEqual(chip.trailingGlyph, .later)
        XCTAssertEqual(chip.toolTip, "Claude Max · Sonnet 5.5 — " + L("switches after this turn"))
    }

    func testFastChosenWhileClaudeWorksShowsTheBoltAndAClock() {
        let chip = model(session(.responding), settings: settings(fast: false), pendingFast: true).model
        XCTAssertEqual(chip.leadingGlyphs, [.fast])
        XCTAssertEqual(chip.trailingGlyph, .later)
    }

    func testTheEffortChipShowsTheMeterAndTheLevelAndMayDropItsName() {
        let chip = model(settings: settings(effort: .xhigh)).effort
        XCTAssertEqual(chip.title, L("Extra High"))
        XCTAssertEqual(chip.leadingGlyphs, [.effort(level: 4)])
        XCTAssertTrue(chip.titleIsDroppable)
        XCTAssertEqual(chip.toolTip, String(localized: "Effort: \(L("Extra High"))"))
    }

    func testAModelWithNoEffortKeepsTheChipDisabledWithADash() {
        let chip = model(settings: settings("haiku", effort: .high)).effort
        XCTAssertEqual(chip.title, "—")
        XCTAssertFalse(chip.isEnabled)
        XCTAssertEqual(chip.leadingGlyphs, [.effort(level: nil)])
        XCTAssertEqual(chip.toolTip, String(localized: "\("Haiku 4.5") doesn’t take an effort level"))
    }

    func testTheModeChipShowsTheGlyphAndTheShortNameAndBypassIsDanger() {
        let ask = model(settings: settings(mode: .default)).mode
        XCTAssertEqual(ask.title, L("Ask"))
        XCTAssertEqual(ask.leadingGlyphs, [.permissionMode(.default)])
        XCTAssertEqual(ask.toolTip, L("Ask Permissions"))
        XCTAssertFalse(ask.isDanger)
        XCTAssertTrue(ask.titleIsDroppable)
        let bypass = model(settings: settings(mode: .bypassPermissions)).mode
        XCTAssertEqual(bypass.title, L("Bypass"))
        XCTAssertTrue(bypass.isDanger)
    }

    // MARK: Effort menu

    func testTheEffortMenuListsTheFiveLevelsUnderAHeaderNamingTheModel() throws {
        let menu = model(settings: settings("opus", effort: .high)).effortMenu
        let section = try XCTUnwrap(menu.sections.first)
        XCTAssertEqual(menu.sections.count, 1)
        XCTAssertEqual(section.header, String(localized: "Effort · \("Opus 5.5")"))
        XCTAssertEqual(section.items.map(\.title), [L("Low"), L("Medium"), L("High"), L("Extra High"), L("Max")])
        XCTAssertEqual(section.items.map(\.isChecked), [false, false, true, false, false])
        XCTAssertEqual(section.items.map(\.isEnabled), [true, true, true, true, true])
        XCTAssertEqual(section.items.map(\.subtitle), [nil, nil, L("Default"), nil, L("This session only")])
        XCTAssertEqual(section.items.map(\.glyph), (1...5).map { .effort(level: $0) })
        XCTAssertEqual(section.items.map(\.change), [.low, .medium, .high, .xhigh, .max].map { .effort($0) })
    }

    func testALevelTheModelLacksIsListedGreyedWithTheReason() throws {
        let menu = model(settings: settings("sonnet-4-6", effort: .high)).effortMenu
        let items = try XCTUnwrap(menu.sections.first).items
        XCTAssertEqual(items.map(\.isEnabled), [true, true, true, false, true])
        XCTAssertEqual(items[3].subtitle, String(localized: "Not on \("Sonnet 4.6")"))
    }

    // MARK: Mode menu

    func testTheModeMenuListsFiveModesThenBypassSetApart() throws {
        let menu = model(settings: settings(mode: .auto)).modeMenu
        XCTAssertEqual(menu.sections.count, 2)
        XCTAssertEqual(menu.sections[0].header, L("Permission Mode"))
        XCTAssertEqual(menu.sections[0].headerHint, "⇧⇥")
        XCTAssertEqual(
            menu.sections[0].items.map(\.title),
            [
                L("Ask Permissions"), L("Accept Edits"),
                String(localized: "Plan (permission mode)", defaultValue: "Plan"), L("Auto"), L("Don’t Ask"),
            ])
        XCTAssertEqual(menu.sections[0].items.map(\.isChecked), [false, false, false, true, false])
        XCTAssertEqual(menu.sections[1].items.map(\.title), [L("Bypass Permissions")])
        XCTAssertTrue(menu.sections[1].items[0].isDanger)
        XCTAssertEqual(
            menu.sections[0].items.map(\.change),
            [PermissionMode.default, .acceptEdits, .plan, .auto, .dontAsk].map { .permissionMode($0) })
    }

    /// Needs `SessionSettings.unavailability` (workstream B).
    func testAModeIsGreyedWithTheRulesWordsAndOtherwiseDescribedByItsOwn() throws {
        let menu = model(settings: settings("opus", mode: .acceptEdits, fast: true)).modeMenu
        let auto = menu.sections[0].items[3]
        XCTAssertFalse(auto.isEnabled)
        XCTAssertEqual(auto.subtitle, L("Unavailable while Fast Mode is on"))
        let bypass = menu.sections[1].items[0]
        XCTAssertFalse(bypass.isEnabled)
        XCTAssertEqual(bypass.subtitle, L("Allow it in Settings › General"))
        let plan = menu.sections[0].items[2]
        XCTAssertTrue(plan.isEnabled)
        XCTAssertEqual(plan.subtitle, L("Reads and plans; changes nothing"))
        let allowed = model(settings: settings("opus", mode: .acceptEdits), allowsBypass: true).modeMenu
        XCTAssertTrue(allowed.sections[1].items[0].isEnabled)
        XCTAssertEqual(allowed.sections[1].items[0].subtitle, L("Runs everything without asking"))
    }

    /// Needs `SessionSettings.unavailability` (workstream B).
    func testAutoOnAModelWithoutItIsGreyedWithTheModelsName() {
        let menu = model(settings: settings("haiku", mode: .default)).modeMenu
        XCTAssertFalse(menu.sections[0].items[3].isEnabled)
        XCTAssertEqual(menu.sections[0].items[3].subtitle, String(localized: "Not on \("Haiku 4.5")"))
    }

    /// Needs `SessionSettings.nextCycledMode` (workstream B).
    func testShiftTabChoosesTheNextModeInTheCycle() {
        XCTAssertEqual(model(settings: settings(mode: .default)).cycledMode, .permissionMode(.acceptEdits))
        XCTAssertEqual(model(settings: settings(mode: .acceptEdits)).cycledMode, .permissionMode(.plan))
        XCTAssertEqual(model(settings: settings(mode: .plan)).cycledMode, .permissionMode(.auto))
        XCTAssertEqual(model(settings: settings(mode: .auto)).cycledMode, .permissionMode(.default))
    }

    // MARK: Model panel

    func testThePanelHasASectionPerAccountInSettingsOrder() {
        let sections = model(settings: settings("opus")).modelSections
        XCTAssertEqual(sections.map(\.name), ["Claude Max", "Work Relay", "DeepSeek"])
        XCTAssertEqual(sections.map(\.detail), ["Subscription", "relay.example.com", "api.deepseek.com"])
        XCTAssertEqual(sections.map(\.glyph), [.subscription, .provider, .provider])
    }

    func testTheSubscriptionFoldsItsOlderModelsIntoMoreModels() {
        let section = model(settings: settings("opus")).modelSections[0]
        XCTAssertEqual(
            section.items.map(\.title), ["Default (recommended)", "Opus 5.5", "Fable 5.1", "Sonnet 5.5", "Haiku 4.5"])
        XCTAssertEqual(section.foldedItems.map(\.title), ["Opus 5", "Sonnet 4.6"])
    }

    func testTheCurrentModelIsNeverFolded() {
        let section = model(settings: settings("opus-5")).modelSections[0]
        XCTAssertEqual(section.foldedItems, [])
        XCTAssertTrue(section.items.contains { $0.title == "Opus 5" && $0.isChecked })
        XCTAssertEqual(section.items.count, 7)
    }

    func testTheCurrentModelIsChecked() {
        let section = model(settings: settings("sonnet")).modelSections[0]
        XCTAssertEqual(section.items.filter(\.isChecked).map(\.title), ["Sonnet 5.5"])
        XCTAssertEqual(
            model(settings: settings("default", on: Self.relay)).modelSections[1].items.map(\.isChecked), [true, false])
    }

    func testTheDefaultAndAProvidersModelsCarryWhatTheyResolveTo() {
        let sections = model(settings: settings("opus")).modelSections
        XCTAssertEqual(sections[0].items[0].subtitle, "Opus 5.5")
        XCTAssertNil(sections[0].items[1].subtitle)
        XCTAssertEqual(sections[1].items.map(\.subtitle), ["claude-sonnet-4-6", "claude-opus-4-6"])
    }

    func testChoosingAModelAnnouncesItsAccountAndValue() {
        let item = model(settings: settings("opus")).modelSections[1].items[1]
        XCTAssertEqual(item.change, .model(ModelChoice(account: Self.relay, value: "opus")))
    }

    func testAnAccountWhoseCliHasNotAnsweredSaysLoading() {
        let section = model(settings: settings("opus")).modelSections[2]
        XCTAssertEqual(section.note, L("Loading…"))
        XCTAssertEqual(section.items, [])
    }

    func testWhileAProcessRunsOtherAccountsRestartTheSessionAndTheirItemsSayTooButNotTheCurrentOne() {
        for phase in [SessionState.Phase.idle, .responding, .compacting] {
            let sections = model(session(phase), settings: settings("opus")).modelSections
            XCTAssertNil(sections[0].note, "\(phase)")
            XCTAssertEqual(sections[0].items.map(\.restarts), [false, false, false, false, false])
            XCTAssertEqual(sections[1].note, L("Restarts the session"), "\(phase)")
            XCTAssertEqual(sections[1].items.map(\.restarts), [true, true])
        }
    }

    func testWithNoProcessAnotherAccountIsFree() {
        for context in [
            ComposerModel.Context.draft, session(.atRest), session(.starting),
            session(.failed(SessionFailure(message: "x"))),
        ] {
            let sections = model(context, settings: settings("opus")).modelSections
            XCTAssertNil(sections[1].note, "\(context)")
            XCTAssertEqual(sections[1].items.map(\.restarts), [false, false])
        }
    }

    func testThePanelSaysWhenChangesWaitForTheTurn() {
        XCTAssertEqual(model(session(.responding)).modelPanelHeader, L("Applies after this turn"))
        XCTAssertEqual(model(session(.compacting)).modelPanelHeader, L("Applies after this turn"))
        XCTAssertNil(model(session(.idle)).modelPanelHeader)
        XCTAssertNil(model(.draft).modelPanelHeader)
    }

    // MARK: Fast Mode

    func testFastModeIsAvailableOnAModelThatSupportsIt() {
        let fast = model(settings: settings("opus", fast: true)).fastMode
        XCTAssertTrue(fast.isOn)
        XCTAssertTrue(fast.isEnabled)
        XCTAssertEqual(fast.subtitle, L("Faster output on Opus · billed as extra usage"))
    }

    func testOnASubscriptionModelWithoutFastTheSwitchNamesTheModelsThatHaveIt() {
        let fast = model(settings: settings("sonnet")).fastMode
        XCTAssertFalse(fast.isEnabled)
        XCTAssertFalse(fast.isOn)
        let names = ListFormatter.localizedString(byJoining: ["Opus 5.5", "Opus 5"])
        XCTAssertEqual(fast.subtitle, String(localized: "\(names) only"))
    }

    func testOnAProviderTheSwitchSaysOnlyWithTheSubscription() {
        let fast = model(settings: settings("opus", on: Self.relay)).fastMode
        XCTAssertFalse(fast.isEnabled)
        XCTAssertEqual(fast.subtitle, L("Only with the subscription"))
    }

    func testAnAccountThatCannotUseFastGivesItsReason() {
        var catalog = Self.catalog
        catalog.accounts[0].fastModeUnavailableReason = "Requires extra usage"
        let fast = model(settings: settings("opus"), catalog: catalog).fastMode
        XCTAssertFalse(fast.isEnabled)
        XCTAssertEqual(fast.subtitle, "Requires extra usage")
    }

    func testFastChosenWhileClaudeWorksIsOnAndSaysWhenItLands() {
        let fast = model(session(.responding), settings: settings("opus"), pendingFast: true).fastMode
        XCTAssertTrue(fast.isOn)
        XCTAssertEqual(fast.subtitle, L("After this turn"))
    }

    // MARK: Status, ring, action

    func testTheStatusSlotIsEmptyUnlessSomethingIsOutOfTheOrdinary() {
        XCTAssertNil(model(.draft).status)
        XCTAssertNil(model(session(.idle)).status)
        XCTAssertNil(model(session(.responding)).status)
        XCTAssertEqual(model(session(.starting)).status, .note(L("Starting Claude…")))
        XCTAssertEqual(model(session(.compacting)).status, .note(L("Compacting…")))
        XCTAssertEqual(model(session(.atRest)).status, .note(L("Will resume when you send")))
    }

    func testWaitingForYouShowsOnlyWhenTheRequestIsOutOfView() {
        XCTAssertEqual(
            model(session(.responding, waiting: true, visible: false)).status, .waitingForYou(L("Waiting for you ↑")))
        XCTAssertNil(model(session(.responding, waiting: true, visible: true)).status)
    }

    func testTheContextRingAppearsFromHalfFull() {
        XCTAssertNil(model(session(.idle), usage: nil).contextRing)
        XCTAssertNil(model(session(.idle), usage: 0.49).contextRing)
        XCTAssertEqual(model(session(.idle), usage: 0.5).contextRing, 0.5)
        XCTAssertEqual(model(session(.idle), usage: 0.72).contextRing, 0.72)
        XCTAssertEqual(model(session(.idle), usage: 1.4).contextRing, 1)
    }

    func testTheActionIsStopWhileClaudeWorksOrStartsAndSendOtherwise() {
        XCTAssertEqual(model(.draft).action, .send)
        for phase in [SessionState.Phase.idle, .atRest, .failed(SessionFailure(message: "x"))] {
            XCTAssertEqual(model(session(phase)).action, .send, "\(phase)")
        }
        for phase in [SessionState.Phase.starting, .responding, .compacting] {
            XCTAssertEqual(model(session(phase)).action, .stop, "\(phase)")
        }
    }

    // MARK: Failure, error

    func testAFailedSessionPutsItsReasonAtTheTopOfTheCard() throws {
        let failed = model(session(.failed(SessionFailure(message: "Exit code 1 · API Error: 529"))))
        let failure = try XCTUnwrap(failed.failure)
        XCTAssertEqual(failure.title, L("Claude quit unexpectedly"))
        XCTAssertEqual(failure.detail, "Exit code 1 · API Error: 529")
        XCTAssertNil(model(session(.idle)).failure)
    }

    /// The exit code is words; stderr's last line is the CLI's own output,
    /// apart, for the monospaced face.
    func testAnExitKeepsStderrsLineApartFromTheReason() throws {
        let exited = SessionFailure(Termination(exitCode: 1, stderr: "retrying\nAPI Error: 529\n"))
        let failure = try XCTUnwrap(model(session(.failed(exited))).failure)
        XCTAssertEqual(failure.detail, String(localized: "Exit code \(1)"))
        XCTAssertEqual(failure.output, "API Error: 529")
        XCTAssertEqual(exited.message, "\(String(localized: "Exit code \(1)")) · API Error: 529")
    }

    func testARefusalIsTheRedLine() {
        XCTAssertEqual(
            model(refusal: "Opus 4.8 isn’t available to your organization.").error,
            "Opus 4.8 isn’t available to your organization.")
        XCTAssertNil(model().error)
    }

    // MARK: Names

    func testModelIdsReadAsNames() {
        XCTAssertEqual(ComposerModel.prettyModelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ComposerModel.prettyModelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ComposerModel.prettyModelName("claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertNil(ComposerModel.prettyModelName("deepseek-v3.2"))
    }
}
