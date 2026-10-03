# Components

Every view the app draws with: generic controls and the app's own components. A sibling of `TranscriptKit`, and like it a package so the compiler holds the boundary: **it depends on nothing** — not the app, not AgentSDK, not TranscriptKit — so a component can't reach a store, a session or a sibling. The app depends on it; it never depends back.

```
Sources/DisplayModels/   what a component is shown, as values — Foundation only (Settings/, Transcript/ …)
Sources/Components/      the views: one directory per family (Form/, Settings/ …), over DisplayModels
  Drawing/               what the families share: the tile, the pill button, the corner radii, the colours, StyledText's fonts
  Menu/                  the one menu every pop-up opens: MenuPanel (MenuContent in, choices out), over MenuPanelViewController and MenuPopup
Sources/ComponentsDesign/  the style page — every component in its real host, live (`make design`)
Tests/ComponentsTests/   component tests; *SnapshotTests render off screen, only when named
```

## A component

- **Built from its init, a display model and a delegate (or closures) — nothing else.** It draws values already worded for it and reports intents up; it never formats a domain value, holds a domain type or calls a service. Turning the app's state into a display model is the app's job, in the app.
- **Display models live in `DisplayModels`; views in `Components`.** A value a component is shown (`AccountRowContent`, `ValidationDetail`, `StyledText`, `Tile`) is a public type in `DisplayModels`, which imports Foundation and nothing else — no AppKit, no default actor — so the app's models and view models (`Page/`, `AccountEditorViewModel`, a field's validation) build them while importing `DisplayModels` alone, never `Components`. A value only one component takes as its input (`SubscriptionSectionViewController.State`) may nest in it. A display model's own words are in `DisplayModels`' catalogue (`bundle: .module` there).
- **`public` is its surface, and only that:** the type, its `init`, `configure(with:)` / its settable display properties, its delegate or callbacks. Everything else stays `internal` or `private`. A public class also makes public every `override` and `required init` and every method that answers a public protocol — Swift requires it.
- **The app's compiler settings:** Swift 5 mode, `MainActor` by default, approachable concurrency, member import visibility (`appSettings` in `Package.swift`). A component compiles here exactly as it did in the app.
- **Its words are the package's.** A component's own copy (an accessibility label, a fixed title) is `String(localized: "…", bundle: .module)` in `Resources/<lang>.lproj/Localizable.strings` — English and `zh-Hans`, landing in the same commit as the code. Words that come from the app arrive in the display model, already localized.
- The component-boundary rules of `macos/CLAUDE.md` (B1–B4) apply here as in the app; `make arch` checks both.

## Moving a component in

The app's views come here one unit at a time — a family, or a component with the leaves only it uses — and each unit lands as one commit that leaves every gate green.

- **Move, then refine:** `git mv` the files, then edit them in place — `public` on the surface, `bundle: .module` on every string. Never retype a file.
- **Cut the domain out, don't carry it in.** A component that takes an app type (`Account`, `Subscription`, a store's state, an AgentSDK value) takes a display model instead, and its delegate reports an id or a display value. The mapping from the app's type to the display model is an `extension` on the display model in the app, next to the screen that uses it (`AccountRowContent+Account.swift`); the store subscription stays in the app's controller.
- **A view model stays in the app; a coordinator joins it to the component.** The view model publishes the component's display model; a small app-side coordinator owns both, shows each presentation, turns each reported edit into a view-model call and reports the outcome in domain terms (`AccountEditorCoordinator`). The view model never imports `Components`, and the component never sees the view model.
- **Leaves a component alone uses move with it and stay `internal`** (`EnvironmentVariableCellView` with its list). A subview is never made `public` so the app can reach into it.
- **Assets it draws come with it** into `Resources/Assets.xcassets`, published as a `public` accessor where the app also draws them (`NSImage.claudeMark`). Every glyph is the design's, built by its `design/<set>/src/build.ts` into this catalogue (`macos/CLAUDE.md`, *Every icon is an image the design builds*); an SF Symbol in a file being moved is replaced by its design accessor.
- **Its tests come with it.** What the component does on its own — its controls, its states, its wording — is tested here; the app keeps only the tests of its mapping and its flow, asserting against the component's own values (`.problem(…)`, `.checking`), never against the component's words.

## Verify — every unit, before its commit

1. **Boundary:** `grep -rnE 'AccountStore|LaunchStore|LaunchCheckService|SubscriptionService|SessionStore|LibraryStore|GitService|SettingsContext|TranscriptTab|import (AgentSDK|TranscriptKit|ccterm)' macos/Components/Sources` finds nothing. Domain types the compiler refuses on its own: the package can't see them.
2. **Words:** `grep -rn 'localized:' macos/Components/Sources/Components` shows `bundle: .module` on every hit (a wrapped call carries it on the next line); each key is in both `Resources/*.lproj/Localizable.strings` and gone from `ccterm/Localizable.xcstrings` unless the app still says it.
3. **Gates:** `make build`, `make test-unit`, `make test-ui`, `make fmt-check` — all green.
4. **Architecture:** `make arch`; `build/arch/coupling.md` has no more findings than before the unit, and none names a type in `Components`.
5. **Look:** `make test-ui FILTER=DesignPageSnapshotTests`, then open `/tmp/ccterm-screenshots/Design-{1240,600}-{light,dark}.png` and read the new specimen against its design part, at the same size: every state the design shows is there; nothing collapsed, clipped, truncated or overlapping; edges that line up in the design line up here (a form's content and its button bar); the dark render its own. Whatever looks wrong is wrong — a legacy scroller, a non-key window, a mouse attached are a real Mac, not the environment.
6. **Commit and push.**

## The style page

`ComponentsDesign` lays the components out as the design sheets do (`design/transcript/index.html`, `design/settings/index.html`): one column, 1160 wide at most, centred; a section per family — heading, note, then each specimen as a heading over a card. Each family adds a `<Family>Specimen` that builds real components from fixture models, interactive. The page follows the window's width; a component never does.

- **A specimen is the component in its real host, at the host's real size.** Every component lives where the app gives it a size: a Settings pane 700 × 628 (the window's 880 × 680 less its 180 sidebar and 52 toolbar), the account sheet 540 × 600, the main window's sidebar 260 wide, a transcript row at the transcript's column. The specimen builds that host — the window's content, a sheet drawn as the design draws one (corners, edge, shadow) — at that size, and the card holds it centred. Nothing is stretched to the card: a size the app can't give a component shows problems the app doesn't have and hides the ones it does. The size is named once in the specimen, with where it comes from.
- **A host wider than the column is scaled down whole**, never laid out narrower: the narrow render shows the same layout smaller.
- **A part the design draws as a whole window is shown in a window, through one shared host.** The transcript's Playground (the main window: sidebar, tabs, transcript, composer), the Settings window, the sidebar in its window: `WindowFrame` draws the design's window — traffic lights and title bar from the design's assets, the toolbar row, corners, hairline edge, shadow — around the real content at the window's content size, and is its card (no inset around it). A sheet is drawn as the design draws one (corners, edge, shadow over its scrim) inside its window's frame. A component that lives in no window of its own keeps a plain card.
- **A new component lands with its specimen.** Moving a component here without one leaves the page behind the app.
- **Look at it off screen**, never by opening a window on the reader's display: `make test-ui FILTER=DesignPageSnapshotTests` renders the page wide and narrow, light and dark, to `/tmp/ccterm-screenshots/Design-<width>-<scheme>.png`. `make design` opens it for hands — scrolling, typing, resizing.
