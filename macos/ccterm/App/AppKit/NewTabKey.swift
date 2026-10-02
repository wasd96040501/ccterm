import AppKit

/// ⌘N as a second key for New Tab (design 08): a SwiftUI menu item takes one
/// key equivalent (⌘T), so `AppDelegate` watches for the other with a local
/// key-down monitor and does what the item does.
///
/// A monitor sees every key-down in the app, so what it takes is decided here,
/// narrowly: ⌘N pressed in the **main window**, with no sheet over it. In
/// Settings, About, a popup panel or a sheet the key goes on to whoever
/// answers it — those windows are not where a tab opens from.
@MainActor
enum NewTabKey {
    /// Whether a key-down is ⌘N for the main window: exactly ⌘ (Caps Lock aside), the letter N,
    /// in `window` — the event's own window — which is `mainWindow` and has no
    /// sheet on it.
    static func handles(
        modifiers: NSEvent.ModifierFlags, characters: String?, in window: NSWindow?, mainWindow: NSWindow?
    ) -> Bool {
        guard modifiers.intersection([.command, .shift, .option, .control, .function]) == .command, characters == "n"
        else { return false }
        guard let window, window === mainWindow else { return false }
        return window.attachedSheet == nil
    }
}
