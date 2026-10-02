import AgentSDK
import XCTest

@testable import ccterm

/// `NewSessionDefaults`: what a New tab starts on — the last choices, else the
/// CLI's own.
@MainActor
final class NewSessionDefaultsTests: XCTestCase {
    private typealias Fixture = SessionCatalogFixture
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testBeforeAnyChoiceItIsTheCLIsOwnOnTheSubscription() {
        let settings = NewSessionDefaults(defaults: defaults).settings(catalog: Fixture.catalog)
        XCTAssertEqual(
            settings,
            SessionSettings(
                model: .default(on: Fixture.subscription), effort: nil, permissionMode: .auto, fastMode: false))
    }

    func testWithoutACatalogThereIsNothingToStartOn() {
        XCTAssertNil(NewSessionDefaults(defaults: defaults).settings(catalog: ModelCatalog()))
    }

    func testTheCLIsModeIsAskWhenItSaidNone() {
        var catalog = Fixture.catalog
        catalog.accounts[0].defaultPermissionMode = nil
        XCTAssertEqual(NewSessionDefaults(defaults: defaults).settings(catalog: catalog)?.permissionMode, .default)
    }

    func testTheLastChoicesComeBackThroughANewInstance() {
        let chosen = Fixture.settings("sonnet", effort: .max, mode: .plan, fast: false)
        NewSessionDefaults(defaults: defaults).save(chosen)
        XCTAssertEqual(NewSessionDefaults(defaults: defaults).settings(catalog: Fixture.catalog), chosen)
    }

    func testTheLastChoicesStandEvenBeforeTheCatalogLoads() {
        let chosen = Fixture.settings("sonnet", mode: .acceptEdits)
        NewSessionDefaults(defaults: defaults).save(chosen)
        XCTAssertEqual(NewSessionDefaults(defaults: defaults).settings(catalog: ModelCatalog()), chosen)
    }

    func testAProviderModelWhoseAccountIsGoneIsTheSubscriptionsDefaultAgain() {
        let gone = Fixture.settings("haiku", on: UUID(), effort: .low, mode: .plan)
        NewSessionDefaults(defaults: defaults).save(gone)
        let settings = NewSessionDefaults(defaults: defaults).settings(catalog: Fixture.catalog)
        XCTAssertEqual(settings?.model, .default(on: Fixture.subscription))
        XCTAssertEqual(settings?.effort, .low)
        XCTAssertEqual(settings?.permissionMode, .plan)
    }

    func testASessionTabsChoicesAreNotTheDefaults() {
        // Only `save` writes; nothing else touches the defaults.
        _ = NewSessionDefaults(defaults: defaults).settings(catalog: Fixture.catalog)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.contains("newSession") }.isEmpty)
    }
}
