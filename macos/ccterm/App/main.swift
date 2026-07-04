import AppKit

// Wire the AppDelegate explicitly before entering the runloop.
//
// `@main` on an `NSApplicationDelegate` subclass without a Storyboard /
// NIB doesn't reliably wire the delegate — `NSApplicationMain` reads
// `NSPrincipalClass` from Info.plist and creates the `NSApplication`,
// but the "delegate = MainMenu.nib's File's Owner" hookup lives inside
// the nib. Without one, the process launches (`NSApp` exists, XPC /
// input-method / CoreSpotlight background wiring happens), but every
// `NSApplicationDelegate` callback silently no-ops — no window, no
// menu, no `applicationDidFinishLaunching`.
//
// The fix is an explicit entry point: construct the delegate, assign
// it, then hand off to `NSApplicationMain`. Because this file provides
// the top-level `main`, `AppDelegate` MUST NOT carry `@main` (Swift
// forbids both routes coexisting).
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
