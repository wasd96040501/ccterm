# Components

Every view the app draws with: generic controls and the app's own components. A sibling of `TranscriptKit`, and like it a package so the compiler holds the boundary: **it depends on nothing** — not the app, not AgentSDK, not TranscriptKit — so a component can't reach a store, a session or a sibling. The app depends on it; it never depends back.

```
Sources/Components/      the library: one directory per family (Form/ …)
Sources/ComponentsDesign/  the style page — every component tiled, live (`make design`)
Tests/ComponentsTests/   component tests; *SnapshotTests render off screen, only when named
```

## A component

- **Built from its init, a display model and a delegate (or closures) — nothing else.** It draws values already worded for it and reports intents up; it never formats a domain value, holds a domain type or calls a service. Turning the app's state into a display model is the app's job, in the app.
- **`public` is its surface, and only that:** the type, its `init`, `configure(with:)` / its settable display properties, its delegate or callbacks. Everything else stays `internal` or `private`. A public class also makes public every `override` and `required init` and every method that answers a public protocol — Swift requires it.
- **The app's compiler settings:** Swift 5 mode, `MainActor` by default, approachable concurrency, member import visibility (`appSettings` in `Package.swift`). A component compiles here exactly as it did in the app.
- **Its words are the package's.** A component's own copy (an accessibility label, a fixed title) is `String(localized: "…", bundle: .module)` in `Resources/<lang>.lproj/Localizable.strings` — English and `zh-Hans`, landing in the same commit as the code. Words that come from the app arrive in the display model, already localized.
- The component-boundary rules of `macos/CLAUDE.md` (B1–B4) apply here as in the app; `make arch` checks both.

## Moving a component in

The app's views come here one unit at a time — a family, or a component with the leaves only it uses — and each unit lands as one commit that leaves every gate green.

- **Move, then refine:** `git mv` the files, then edit them in place — `public` on the surface, `bundle: .module` on every string. Never retype a file.
- **Cut the domain out, don't carry it in.** A component that takes an app type (`Account`, `Subscription`, a store's state, an AgentSDK value) takes a display model instead, and its delegate reports an id or a display value. The mapping from the app's type to the display model is an `extension` on the display model in the app, next to the screen that uses it (`AccountRowContent+Account.swift`); the store subscription stays in the app's controller.
- **Leaves a component alone uses move with it and stay `internal`** (`EnvironmentVariableCellView` with its list). A subview is never made `public` so the app can reach into it.
- **Assets it draws come with it** into `Resources/Assets.xcassets`, published as a `public` accessor where the app also draws them (`NSImage.claudeMark`).
- **Its tests come with it.** What the component does on its own — its controls, its states, its wording — is tested here; the app keeps only the tests of its mapping and its flow, asserting against the component's own values (`.problem(…)`, `.checking`), never against the component's words.

## Verify — every unit, before its commit

1. **Boundary:** `grep -rnE 'AccountStore|LaunchStore|LaunchCheckService|SubscriptionService|SessionStore|LibraryStore|GitService|SettingsContext|TranscriptTab|import (AgentSDK|TranscriptKit|ccterm)' macos/Components/Sources` finds nothing. Domain types the compiler refuses on its own: the package can't see them.
2. **Words:** `grep -rn 'localized:' macos/Components/Sources/Components` shows `bundle: .module` on every hit (a wrapped call carries it on the next line); each key is in both `Resources/*.lproj/Localizable.strings` and gone from `ccterm/Localizable.xcstrings` unless the app still says it.
3. **Gates:** `make build`, `make test-unit`, `make test-ui`, `make fmt-check` — all green.
4. **Architecture:** `make arch`; `build/arch/coupling.md` has no more findings than before the unit, and none names a type in `Components`.
5. **Look:** `make test-ui FILTER=DesignPageSnapshotTests`, then open `/tmp/ccterm-screenshots/Design-{1240,600}-{light,dark}.png` and read the new specimen against its design part: every state the design shows is there, nothing collapsed, clipped or overlapping, the dark render its own.
6. **Commit and push.**

## The style page

`ComponentsDesign` lays every component out as the design sheet does (`design/transcript/index.html`): one column, 1160 wide at most, centred; a section per family — heading, note, then each specimen as a heading over a card the column's width. It is all Auto Layout and follows the window's width; nothing on it has a width of its own. Each family adds a `<Family>Specimen` that builds real components from fixture models, interactive.

- **A new component lands with its specimen.** Moving a component here without one leaves the page behind the app.
- **Look at it off screen**, never by opening a window on the reader's display: `make test-ui FILTER=DesignPageSnapshotTests` renders the page wide and narrow, light and dark, to `/tmp/ccterm-screenshots/Design-<width>-<scheme>.png`. `make design` opens it for hands — scrolling, typing, resizing.
