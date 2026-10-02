import AppKit

/// ⌘N as a second key for New Tab (design 08): a SwiftUI menu item takes one
/// key equivalent (⌘T), so `AppDelegate` watches for the other with a local
/// key-down monitor and does what the item does — from every window ⌘T works
/// from: the main window, Settings, About, a popup panel, or none key.
///
/// A monitor sees every key-down in the app, so what it takes is decided here,
/// narrowly: exactly ⌘N, and not while something modal owns the keyboard — a
/// modal session (the menu bar is off then, ⌘T included) or a sheet, whose
/// text fields keep their keys.
@MainActor
enum NewTabKey {
    /// Whether a key-down is ⌘N for New Tab: exactly ⌘ (Caps Lock aside), the
    /// letter N, with no modal session running (`modalWindow`) and the event's
    /// own `window` neither a sheet nor holding one.
    static func handles(
        modifiers: NSEvent.ModifierFlags, characters: String?, in window: NSWindow?, modalWindow: NSWindow?
    ) -> Bool {
        guard modifiers.intersection([.command, .shift, .option, .control, .function]) == .command, characters == "n"
        else { return false }
        guard modalWindow == nil else { return false }
        guard let window else { return true }
        return window.attachedSheet == nil && window.sheetParent == nil
    }
}
