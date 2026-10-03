import AppKit
import Components

/// The sizes of the hosts the app gives its components, each named once with
/// where it comes from. A specimen builds its host at the size here and the
/// page shows it at it, never scaled
/// (`macos/Components/CLAUDE.md`, *The style page*).
enum Host {
    /// The Settings window's content: 880 × 680, not resizable
    /// (`SettingsWindowController.contentSize`; design/settings `.window`).
    static let settingsWindow = NSSize(width: 880, height: 680)

    /// Its source list: 180 wide, fixed (`SettingsSplitViewController.sidebarWidth`).
    static let settingsSidebarWidth: CGFloat = 180

    /// The toolbar row over the detail, which a pane's content starts under
    /// (design/settings `.toolbar`, `.pane`'s 52-pt top padding).
    static let settingsToolbarHeight: CGFloat = 52

    /// A Settings pane: the window less its sidebar and its toolbar row —
    /// 700 × 628.
    static let settingsPane = NSSize(
        width: settingsWindow.width - settingsSidebarWidth, height: settingsWindow.height - settingsToolbarHeight)

    /// The form's side insets in a pane (design/settings `.scroll`'s
    /// `padding: 0 20px`; the sheet body's too).
    static let formInset: CGFloat = 20

    /// A form section as a pane lays it out: the pane less the form's insets.
    static let paneForm = settingsPane.width - 2 * formInset

    /// An account's sheet: 540 × 600 for either kind (`AccountEditorViewController.size`;
    /// design/settings `.sheet.fixed`).
    static let accountSheet = AccountEditorViewController.size

    /// The main window's sidebar at the narrowest the app gives it: its split
    /// item runs 290 to 350 (`MainSplitViewController`), 22 % of the window
    /// between.
    static let sidebarWidth: CGFloat = 290

    /// The widest the sidebar is let be (`MainSplitViewController`).
    static let sidebarMaximumWidth: CGFloat = 350

    /// The editors' narrowest (`MainSplitViewController`'s detail item; the
    /// window's 970 minimum is the sidebar's 290 beside it).
    static let editorsMinimumWidth: CGFloat = 680

    /// The main window's content in the design's Playground: as wide as the
    /// sheet's column (1160 less its 16 a side), 720 high less its 44-pt title
    /// bar (design/transcript `.lv-win`) — 1128 × 676. The app opens at
    /// 1200 × 860 and is resizable down to 970 × 540 (`MainWindowController`),
    /// so this is a size it can have.
    static let mainWindow = NSSize(width: 1128, height: 720 - WindowFrame.titleBarHeight)
}
