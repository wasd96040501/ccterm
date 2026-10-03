import AppKit

/// The glyphs the Settings window's design sheet draws (`design/settings`, built by
/// `design/settings-icons`), from the package's catalogue, named by the sheet's `G` keys.
/// All are template images: tint them.
extension NSImage {
    public static var settingsArrowOut: NSImage { Bundle.module.image(forResource: "SettingsArrowOut") ?? NSImage() }
    public static var settingsBack: NSImage { Bundle.module.image(forResource: "SettingsBack") ?? NSImage() }
    public static var settingsCheck: NSImage { Bundle.module.image(forResource: "SettingsCheck") ?? NSImage() }
    public static var settingsChevDown: NSImage { Bundle.module.image(forResource: "SettingsChevDown") ?? NSImage() }
    public static var settingsEye: NSImage { Bundle.module.image(forResource: "SettingsEye") ?? NSImage() }
    public static var settingsEyeOff: NSImage { Bundle.module.image(forResource: "SettingsEyeOff") ?? NSImage() }
    public static var settingsForward: NSImage { Bundle.module.image(forResource: "SettingsForward") ?? NSImage() }
    public static var settingsGear: NSImage { Bundle.module.image(forResource: "SettingsGear") ?? NSImage() }
    public static var settingsInfo: NSImage { Bundle.module.image(forResource: "SettingsInfo") ?? NSImage() }
    public static var settingsMinus: NSImage { Bundle.module.image(forResource: "SettingsMinus") ?? NSImage() }
    public static var settingsPerson: NSImage { Bundle.module.image(forResource: "SettingsPerson") ?? NSImage() }
    public static var settingsPlus: NSImage { Bundle.module.image(forResource: "SettingsPlus") ?? NSImage() }
    public static var settingsProviderMark: NSImage {
        Bundle.module.image(forResource: "SettingsProviderMark") ?? NSImage()
    }
    public static var settingsServerRack: NSImage {
        Bundle.module.image(forResource: "SettingsServerRack") ?? NSImage()
    }
    public static var settingsSpinner: NSImage { Bundle.module.image(forResource: "SettingsSpinner") ?? NSImage() }
    public static var settingsUpdown: NSImage { Bundle.module.image(forResource: "SettingsUpdown") ?? NSImage() }
    public static var settingsWarn: NSImage { Bundle.module.image(forResource: "SettingsWarn") ?? NSImage() }
}
