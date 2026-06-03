# Spotlight Panel — Design Proposal

A floating, Raycast-style command palette summoned by **double-tapping ⌥
Option** anywhere on the system, showing the user's in-progress ccterm
sessions (title + status) and letting them jump into one with a single
keystroke.

Out of scope: rendering transcripts, editing prompts, anything beyond
"list active sessions, pick one to open in the main window."

## Decision: split into an LSUIElement helper process (option C)

The panel runs in its **own helper app**, embedded inside the main
ccterm bundle, with `LSUIElement = YES` and activation policy
`.accessory`. It talks to the main ccterm process over `NSXPCConnection`.

### Why not "panel inside the main app"

We evaluated three options:

| Option | What it is | Why we rejected it |
|---|---|---|
| A | NSPanel inside main app, `close` calls `NSApp.hide(nil)` to return focus | `NSApp.hide(nil)` also hides the main window — user has to cmd-tab back. |
| B | Same as A but skip `NSApp.hide(nil)` | Closing the panel leaves ccterm frontmost; the user's previous frontmost app (Safari, editor, …) does not get focus back. |
| **C** | Separate LSUIElement helper process talks to main app via XPC | Helper "hiding" is invisible (no Dock icon, no main window). Frontmost-app focus is restored automatically by macOS when the helper resigns active. Same activation model Raycast / Alfred / Spotlight use. |

C is normally expensive (split codebase, XPC plumbing, two-target
debugging) but the panel's shared surface with the main app is tiny —
literally one Codable struct and two RPC methods — so most of those
costs collapse.

## Shape

```
ccterm.app/
└── Contents/
    ├── MacOS/ccterm                              # main app, unchanged activation policy (.regular)
    └── Library/LoginItems/
        └── ccterm-spotlight.app/                 # helper, LSUIElement, .accessory
            └── Contents/MacOS/ccterm-spotlight
```

### Targets

- **Main app** (existing) — adds an `NSXPCListener` that vends a
  `SpotlightBridge` implementation. No other behavioural change.
- **`ccterm-spotlight.app`** (new) — LSUIElement helper. Owns the
  `NSPanel`, the global hotkey, and a SwiftUI list view. ~300 LOC.
- **`SpotlightBridge` Swift package** at `macos/Shared/SpotlightBridge/`
  — protocol + Codable types only. ~30 LOC. Both targets depend on it.

### Wire protocol

```swift
@objc public protocol SpotlightBridge {
    func currentSessions(reply: @escaping ([SessionSnapshot]) -> Void)
    func openSession(id: UUID)
}

public struct SessionSnapshot: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let status: Status
    public enum Status: String, Codable, Sendable {
        case idle, running, waiting, done
    }
}
```

Data flow: helper is **read-only and stateless**. It pulls the session
list on every panel show; the main app stays the single source of
truth. No caching, no sync protocol.

### Helper lifecycle

- Main app spawns the helper on launch via
  `NSWorkspace.shared.openApplication(at:)`. Main app also kills it on
  termination — the helper has no reason to outlive ccterm.
- **Not** `SMAppService.loginItem` / `LaunchAgent` — those imply
  "user logs in, service runs forever," which is not the model.
- If the helper crashes, the main app re-spawns it with exponential
  backoff (a simple watchdog, no fancy logic).

### IPC

`NSXPCConnection` with a Mach service name (`com.ccterm.spotlight`).
Standard `NSXPCListener` on the main-app side, `NSXPCConnection` on the
helper side. Codable types flow over `NSSecureCoding`-backed proxies.

### Hotkey

[`Clipy/Magnet`](https://github.com/Clipy/Magnet) — registers
`KeyCombo(doubledCocoaModifiers: .option)`. Magnet handles the
double-tap state machine and Carbon hot-key glue. Lives in the helper
target only; main app doesn't depend on it.

### Panel

`NSPanel` subclass following the
[Multi blog](https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette)
pattern:

- styleMask: `[.nonactivatingPanel, .titled, .fullSizeContentView, .resizable]`
- `level = .statusBar`
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`
- `hidesOnDeactivate = true`
- override `canBecomeKey -> true`, `canBecomeMain -> false`
- override `becomeKey()` → `NSApp.activate()`
- override `resignKey()` → `close()` (click-outside dismiss)
- override `cancelOperation` → `close()` (ESC dismiss)
- override `close()` → `super.close()` + `NSApp.hide(nil)` (return focus to previous app — clean in an LSUIElement process)

### Bundle id

`com.ccterm.spotlight`. Mach service registers under the same name.

## Engineering estimate

| Module | LOC (rough) | Effort |
|---|---|---|
| Main-app XPC listener + `currentSessions` / `openSession` impl | ~80 | 0.5 day |
| Helper target (panel, hotkey, list view, XPC client) | ~300 | 1 day |
| Shared `SpotlightBridge` Swift package | ~30 | 0.5 hr |
| `scripts/build.sh` + signing: nested bundle copy | ~20 | 0.5 hr |
| Unit tests (status mapping, snapshot of panel list) | ~150 | 0.5 day |

Total: ~2 days for a working slice; another day to polish.

## Out of scope for this proposal

- Customising the hotkey (defaults to double-tap ⌥; surfacing it in
  Settings comes later).
- Search / fuzzy filtering inside the panel.
- Anything beyond "list active sessions and open one."
- Distributing the helper via `SMAppService` for autostart on login.

## Sources

- [Multi — Nailing the Activation Behavior of a Spotlight/Raycast-Like Command Palette](https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette)
- [Cindori — Make a floating panel in SwiftUI for macOS](https://cindori.com/developer/floating-panel)
- [Ardent Swift — Spotlight-like hotkey window](https://ardentswift.com/posts/hotkey-window/)
- [`Clipy/Magnet`](https://github.com/Clipy/Magnet) — global hotkeys, double-tap modifier
- [Apple — `nonactivatingPanel` style mask](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
