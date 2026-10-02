import XCTest

@testable import AgentSDK

/// ``Settings``, ``SettingsKey`` values and ``SettingsSnapshot`` decoding.
/// Whether the real CLI accepts these shapes is `SettingsSmoke`'s job.
final class SettingsTests: XCTestCase {
    // MARK: - Settings

    func testTypedSubscriptReadsAndWritesJSON() {
        var settings = Settings()
        settings[.fastMode] = true
        settings[.effortLevel] = .xhigh
        settings[.bashOutputMaxChars] = 50_000
        settings[.fallbackModel] = ["sonnet", "haiku"]
        settings[.env] = ["FOO": "1"]
        settings[.promptCacheTTL] = .oneHour
        settings[.hooks] = ["Stop": []]

        XCTAssertEqual(
            settings.json,
            [
                "fastMode": true, "effortLevel": "xhigh", "bashOutputMaxChars": 50_000,
                "fallbackModel": ["sonnet", "haiku"], "env": ["FOO": "1"], "promptCacheTtl": "1h",
                "hooks": ["Stop": []],
            ])
        XCTAssertEqual(settings[.fastMode], true)
        XCTAssertEqual(settings[.effortLevel], .xhigh)
        XCTAssertEqual(settings[.bashOutputMaxChars], 50_000)
        XCTAssertEqual(settings[.fallbackModel], ["sonnet", "haiku"])
        XCTAssertEqual(settings[.env], ["FOO": "1"])
        XCTAssertEqual(settings[.promptCacheTTL], .oneHour)
    }

    func testMismatchedJSONReadsAsNil() {
        let settings = Settings(json: [
            "fastMode": "yes", "effortLevel": "turbo", "bashOutputMaxChars": 1.5, "fallbackModel": ["a", 1],
            "env": ["A": true],
        ])
        XCTAssertNil(settings[.fastMode])
        XCTAssertNil(settings[.effortLevel])
        XCTAssertNil(settings[.bashOutputMaxChars])
        XCTAssertNil(settings[.fallbackModel])
        XCTAssertNil(settings[.env])
        XCTAssertEqual(settings["fastMode"], "yes")
    }

    func testNilRemovesTheEntryAndUnsetRecordsARemoval() {
        var settings = Settings()
        settings[.fastMode] = true
        settings[.fastMode] = nil
        XCTAssertTrue(settings.isEmpty)

        settings.unset(.effortLevel)
        XCTAssertTrue(settings.isUnset(.effortLevel))
        XCTAssertNil(settings[.effortLevel])
        XCTAssertEqual(settings.json, ["effortLevel": .null])

        settings[.effortLevel] = .low
        XCTAssertFalse(settings.isUnset(.effortLevel))
    }

    func testCustomKeysExtendTheCatalog() {
        var settings = Settings()
        settings[.spinnerTipsEnabled] = false
        XCTAssertEqual(settings.json, ["spinnerTipsEnabled": false])
    }

    func testLaunchArgumentDropsUnsetKeys() throws {
        XCTAssertNil(Settings().launchArgument)
        var settings = Settings()
        settings.unset(.fastMode)
        XCTAssertNil(settings.launchArgument)

        settings[.ultracode] = true
        let argument = try XCTUnwrap(settings.launchArgument)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(argument.utf8)), ["ultracode": true])

        let configuration = SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"), settings: settings)
        let index = try XCTUnwrap(configuration.arguments.firstIndex(of: "--settings"))
        XCTAssertEqual(configuration.arguments[index + 1], argument)
        XCTAssertFalse(
            SessionConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp")).arguments.contains("--settings"))
    }

    func testCatalogKeysMatchSettingsJSON() {
        let names = [
            SettingsKey<String>.model.rawValue, SettingsKey<String>.agent.rawValue,
            SettingsKey<String>.advisorModel.rawValue, SettingsKey<[String]>.fallbackModel.rawValue,
            SettingsKey<Effort>.effortLevel.rawValue, SettingsKey<Bool>.ultracode.rawValue,
            SettingsKey<Bool>.fastMode.rawValue, SettingsKey<Bool>.alwaysThinkingEnabled.rawValue,
            SettingsKey<Bool>.showThinkingSummaries.rawValue, SettingsKey<PromptCacheTTL>.promptCacheTTL.rawValue,
            SettingsKey<PermissionSettings>.permissions.rawValue, SettingsKey<JSONValue>.hooks.rawValue,
            SettingsKey<Bool>.disableAllHooks.rawValue, SettingsKey<String>.outputStyle.rawValue,
            SettingsKey<String>.language.rawValue, SettingsKey<String>.plansDirectory.rawValue,
            SettingsKey<[String: String]>.env.rawValue, SettingsKey<AttributionSettings>.attribution.rawValue,
            SettingsKey<Bool>.includeGitInstructions.rawValue, SettingsKey<Bool>.autoCompactEnabled.rawValue,
            SettingsKey<Bool>.autoMemoryEnabled.rawValue, SettingsKey<Bool>.fileCheckpointingEnabled.rawValue,
            SettingsKey<Bool>.promptSuggestionEnabled.rawValue, SettingsKey<Bool>.todoFeatureEnabled.rawValue,
            SettingsKey<Bool>.respectGitignore.rawValue, SettingsKey<Int>.bashOutputMaxChars.rawValue,
            SettingsKey<Int>.cleanupPeriodDays.rawValue, SettingsKey<Bool>.enableAllProjectMCPServers.rawValue,
            SettingsKey<[String]>.enabledMCPJSONServers.rawValue,
            SettingsKey<[String]>.disabledMCPJSONServers.rawValue, SettingsKey<JSONValue>.worktree.rawValue,
        ]
        XCTAssertEqual(
            names,
            [
                "model", "agent", "advisorModel", "fallbackModel", "effortLevel", "ultracode", "fastMode",
                "alwaysThinkingEnabled", "showThinkingSummaries", "promptCacheTtl", "permissions", "hooks",
                "disableAllHooks", "outputStyle", "language", "plansDirectory", "env", "attribution",
                "includeGitInstructions", "autoCompactEnabled", "autoMemoryEnabled", "fileCheckpointingEnabled",
                "promptSuggestionEnabled", "todoFeatureEnabled", "respectGitignore", "bashOutputMaxChars",
                "cleanupPeriodDays", "enableAllProjectMcpServers", "enabledMcpjsonServers", "disabledMcpjsonServers",
                "worktree",
            ])
    }

    // MARK: - Values

    func testPermissionRuleStringForm() {
        let cases: [(PermissionRule, String)] = [
            (PermissionRule(toolName: "Read"), "Read"),
            (PermissionRule(toolName: "Bash", ruleContent: "git status:*"), "Bash(git status:*)"),
            (PermissionRule(toolName: "Bash", ruleContent: #"echo (a) \ b"#), #"Bash(echo \(a\) \\ b)"#),
        ]
        for (rule, string) in cases {
            XCTAssertEqual(rule.settingsJSON, .string(string))
            XCTAssertEqual(PermissionRule(settingsJSON: .string(string)), rule)
        }
        XCTAssertEqual(PermissionRule(settingsJSON: "Edit()"), PermissionRule(toolName: "Edit"))
        XCTAssertEqual(PermissionRule(settingsJSON: "Edit(*)"), PermissionRule(toolName: "Edit"))
        XCTAssertNil(PermissionRule(settingsJSON: ""))
        XCTAssertNil(PermissionRule(settingsJSON: 3))
    }

    func testPermissionSettingsWritesOnlyWhatIsSet() {
        let permissions = PermissionSettings(
            allow: [PermissionRule(toolName: "Bash", ruleContent: "ls:*")], defaultMode: .acceptEdits,
            disablesBypassPermissionsMode: true)
        XCTAssertEqual(
            permissions.settingsJSON,
            ["allow": ["Bash(ls:*)"], "defaultMode": "acceptEdits", "disableBypassPermissionsMode": "disable"])
        XCTAssertEqual(PermissionSettings(disablesBypassPermissionsMode: false).settingsJSON, [:])
    }

    func testPermissionSettingsKeepsUnmodeledFields() throws {
        let json: JSONValue = [
            "deny": ["WebFetch"], "defaultMode": "manual", "additionalDirectories": ["/a"],
            "blockReadsOutsideWorkingDirectories": true, "futureField": ["x": 1],
        ]
        var permissions = try XCTUnwrap(PermissionSettings(settingsJSON: json))
        XCTAssertEqual(permissions.deny, [PermissionRule(toolName: "WebFetch")])
        XCTAssertEqual(permissions.defaultMode, .default)
        XCTAssertEqual(permissions.additionalDirectories, ["/a"])
        XCTAssertEqual(permissions.blocksReadsOutsideWorkingDirectories, true)
        XCTAssertEqual(permissions.additionalFields, ["futureField": ["x": 1]])

        permissions.additionalDirectories?.append("/b")
        XCTAssertEqual(permissions.settingsJSON["futureField"], ["x": 1])
        XCTAssertEqual(permissions.settingsJSON["additionalDirectories"], ["/a", "/b"])
        XCTAssertNil(PermissionSettings(settingsJSON: ["a"]))
    }

    func testAttributionForms() {
        XCTAssertEqual(AttributionSettings(settingsJSON: false), .hidden)
        XCTAssertEqual(AttributionSettings(settingsJSON: true), AttributionSettings())
        XCTAssertEqual(
            AttributionSettings(settingsJSON: ["commit": "c", "pr": "", "sessionUrl": false]),
            AttributionSettings(commit: "c", pullRequest: "", includesSessionURL: false))
        XCTAssertEqual(AttributionSettings(commit: "c").settingsJSON, ["commit": "c"])
        XCTAssertEqual(AttributionSettings.hidden.settingsJSON, ["commit": "", "pr": "", "sessionUrl": false])
        XCTAssertNil(AttributionSettings(settingsJSON: "x"))
    }

    // MARK: - Snapshot

    func testSnapshotDecodesGetSettingsResponse() {
        let response: JSONValue = [
            "effective": ["fastMode": true, "theme": "dark"],
            "sources": [
                ["source": "userSettings", "settings": ["theme": "dark"]],
                ["source": "flagSettings", "settings": ["fastMode": true]],
                ["source": "someNewSource", "settings": [:]],
                ["settings": ["orphan": true]],
            ],
            "applied": ["model": "claude-opus-5-5", "effort": "max", "advisor": nil, "ultracode": true],
            "errors": [["file": "SDK inline settings", "path": "fastMode", "message": "Expected boolean"]],
        ]
        let snapshot = SettingsSnapshot(response: response)
        XCTAssertEqual(snapshot.effective[.fastMode], true)
        XCTAssertEqual(snapshot.layers.map(\.source), [.user, .flag, .other("someNewSource")])
        XCTAssertEqual(snapshot.layer(.flag), Settings(json: ["fastMode": true]))
        XCTAssertNil(snapshot.layer(.project))
        XCTAssertEqual(
            snapshot.applied, SettingsSnapshot.Applied(model: "claude-opus-5-5", effort: "max", ultracode: true))
        XCTAssertEqual(
            snapshot.errors,
            [SettingsSnapshot.Issue(file: "SDK inline settings", path: "fastMode", message: "Expected boolean")])
    }

    func testSnapshotToleratesGarbage() {
        let snapshot = SettingsSnapshot(response: ["sources": "nope", "applied": 3, "errors": [1, ["path": "x"]]])
        XCTAssertTrue(snapshot.effective.isEmpty)
        XCTAssertEqual(snapshot.layers, [])
        XCTAssertEqual(snapshot.applied, SettingsSnapshot.Applied())
        XCTAssertEqual(snapshot.errors, [])
    }
}

extension SettingsKey where Value == Bool {
    /// A key the SDK does not define, declared the way a consumer would.
    fileprivate static var spinnerTipsEnabled: Self { Self("spinnerTipsEnabled") }
}
