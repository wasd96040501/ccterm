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

## The style page

`ComponentsDesign` lays every component out as the design sheet does (`design/transcript/index.html`): one column, 1160 wide at most, centred; a section per family — heading, note, then each specimen as a heading over a card the column's width. It is all Auto Layout and follows the window's width; nothing on it has a width of its own. Each family adds a `<Family>Specimen` that builds real components from fixture models, interactive.

- **A new component lands with its specimen.** Moving a component here without one leaves the page behind the app.
- **Look at it off screen**, never by opening a window on the reader's display: `make test-ui FILTER=DesignPageSnapshotTests` renders the page wide and narrow, light and dark, to `/tmp/ccterm-screenshots/Design-<width>-<scheme>.png`. `make design` opens it for hands — scrolling, typing, resizing.
