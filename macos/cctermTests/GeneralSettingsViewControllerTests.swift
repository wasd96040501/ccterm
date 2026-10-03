import AgentSDK
import AppKit
import CCTermUI
import Combine
import XCTest

@testable import ccterm

/// General's two fields through the pane's own controls: what Return and
/// leaving a field save, and that a value that fails its check never is.
@MainActor
final class GeneralSettingsViewControllerTests: XCTestCase {
    private var suite: String!
    private var folder: URL!
    private let probe = FakeProbe()
    private var launch: LaunchStore!
    private var pane: GeneralSettingsViewController!
    private var commandField: FormTextField!
    private var folderField: FormTextField!

    override func setUpWithError() throws {
        suite = UUID().uuidString
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        launch = LaunchStore(
            defaults: UserDefaults(suiteName: suite)!, accounts: Just([Account.subscription()]).eraseToAnyPublisher(),
            resolveDirectory: { _ in SessionDirectory(url: URL(fileURLWithPath: "/resolved/projects")) })
        pane = GeneralSettingsViewController(
            launch: launch, launchCheck: LaunchCheckService(probe: probe.probe), debounce: .zero)
        pane.loadView()
        pane.viewDidLoad()
        let fields = textFields(in: pane.view)
        commandField = try XCTUnwrap(fields.first)
        folderField = try XCTUnwrap(fields.last)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    private func textFields(in view: NSView) -> [FormTextField] {
        view.subviews.flatMap { ($0 as? FormTextField).map { [$0] } ?? textFields(in: $0) }
    }

    /// Types `text` into `field` and presses Return.
    private func typeAndReturn(_ text: String, in field: NSTextField) {
        field.stringValue = text
        field.sendAction(field.action, to: field.target)
    }

    /// Types `text` into `field` and clicks away: the field's delegate hears
    /// the editing end, and no action is sent.
    private func typeAndLeave(_ text: String, in field: NSTextField) {
        field.stringValue = text
        field.delegate?.controlTextDidEndEditing?(
            Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    func testTheFieldsStartWithWhatIsSavedAndTheFolderInEffect() async {
        XCTAssertEqual(commandField.stringValue, "")
        XCTAssertEqual(folderField.stringValue, "")
        await waitFor(launch.$sessionDirectory) { $0.configDirectory.path == "/resolved" }
        XCTAssertEqual(folderField.placeholderString, "/resolved")
    }

    func testReturnSavesAValidFolder() async {
        typeAndReturn(folder.path, in: folderField)
        await waitFor(launch.$preferences) { $0.configDirectory == self.folder.path }
    }

    func testLeavingTheFieldSavesAValidFolder() async {
        typeAndLeave(folder.path, in: folderField)
        await waitFor(launch.$preferences) { $0.configDirectory == self.folder.path }
    }

    func testLeavingTheFieldSavesAValidCommand() async {
        typeAndLeave("orange", in: commandField)
        await waitFor(launch.$preferences) { $0.command == "orange" }
    }

    func testAMissingFolderIsNeverSavedAndTheLastGoodOneStays() async {
        typeAndReturn(folder.path, in: folderField)
        await waitFor(launch.$preferences) { $0.configDirectory == self.folder.path }

        typeAndReturn(folder.appendingPathComponent("missing").path, in: folderField)
        typeAndLeave(folder.appendingPathComponent("missing").path, in: folderField)
        // The check ran off the main thread; let it answer.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(launch.preferences.configDirectory, folder.path)
    }

    func testAFailingCommandIsNeverSaved() async {
        probe.fail("bad", with: AgentSDKError.binaryNotFound)
        typeAndReturn("bad", in: commandField)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(launch.preferences.command, "")
    }

    func testAnEmptyFolderIsValidAndClearsTheSetting() async {
        typeAndReturn(folder.path, in: folderField)
        await waitFor(launch.$preferences) { $0.configDirectory == self.folder.path }

        typeAndReturn("", in: folderField)
        await waitFor(launch.$preferences) { $0.configDirectory.isEmpty }
    }

    // MARK: - Allow Bypass Permissions

    private func bypassCheckbox() throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton,
                button.accessibilityLabel() == String(localized: "Allow Bypass Permissions")
            {
                return button
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(pane.view), "no Allow Bypass Permissions checkbox in General")
    }

    func testAllowBypassPermissionsStartsOffAndFollowsTheSetting() throws {
        let checkbox = try bypassCheckbox()
        XCTAssertEqual(checkbox.state, .off, "off by default")

        launch.setAllowsBypassPermissions(true)
        XCTAssertEqual(checkbox.state, .on, "the checkbox did not follow the setting")
    }

    func testTheCheckboxSetsAndClearsAllowBypassPermissions() throws {
        let checkbox = try bypassCheckbox()

        checkbox.performClick(nil)
        XCTAssertTrue(launch.preferences.allowsBypassPermissions)

        checkbox.performClick(nil)
        XCTAssertFalse(launch.preferences.allowsBypassPermissions)
    }
}
