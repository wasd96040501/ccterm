# Components

Every view the app draws with: generic controls and the app's own components. A sibling of `TranscriptKit`, and like it a package so the compiler holds the boundary: **it depends on nothing** — not the app, not AgentSDK, not TranscriptKit — so a component can't reach a store, a session or a sibling. The app depends on it; it never depends back. The style page alone (`ComponentsDesign`, an executable) depends on TranscriptKit and TranscriptWorkspace: the main window's transcript and tabs are theirs, and the page shows the window whole.

```
Sources/DisplayModels/   what a component is shown, as values — Foundation only (Settings/, Transcript/ …)
Sources/Components/      the views: one directory per family (Form/, Settings/ …), over DisplayModels
  Drawing/               what the families share: the tile, the pill button, the corner radii, the colours, StyledText's fonts
  Documents/             what opens beside a transcript: the jump bar, the approval bar and the command, source and image bodies, over `NumberedLinesView` (values: `DocumentHeader`, `CommandSummary`, `SourceLines`)
  Menu/                  every pop-up: MenuPopover (MenuContent in, choices out) — an NSPopover without its animation holding an inset table under an optional search field, opened by a `MenuButton` (the system's accessory-bar button, bezel under the pointer, on while its popover is open); MenuPopup, the slash list's child panel
  Composer/              the composer card (ComposerViewController) with its menus and slash list, over ComposerPresentation; the dock that fades the transcript under it
  NewSession/            the New view (hero, folder, branch row, rise) with its folder and branch menus, over NewSessionContent and NewSessionBranchMenu
  Rows/                  the transcript's row views (PageRowView and its kinds), drawn from display values; the contract test holds each to its declared height
Sources/ComponentsDesign/  the style page — every component in its real host, live (`make design`)
Tests/ComponentsTests/   component tests; *SnapshotTests render off screen, only when named
```

## A component

What belongs here and what stays in the app is [macos/CLAUDE.md § Where code lives](../CLAUDE.md#where-code-lives--the-app-or-a-package); this is how a component is written once it is here.

- **It draws values already worded for it and reports intents up.** It never formats a domain value, holds a domain type or calls a service.
- **A value it is shown is a public type in `DisplayModels`** (`AccountRowContent`, `ValidationDetail`, `StyledText`, `Tile`) — no AppKit, no default actor — so the app's models and view models (`Page/`, `AccountEditorViewModel`, a field's validation) build them while importing `DisplayModels` alone, never `Components`. A value only one component takes as its input (`SubscriptionSectionViewController.State`) may nest in it. A display model's own words are in `DisplayModels`' catalogue (`bundle: .module` there).
- **`public` is its surface, and only that:** the type, its `init`, `configure(with:)` / its settable display properties, its delegate or callbacks. Everything else stays `internal` or `private`. A public class also makes public every `override` and `required init` and every method that answers a public protocol — Swift requires it.
- **The app's compiler settings:** Swift 5 mode, `MainActor` by default, approachable concurrency, member import visibility (`appSettings` in `Package.swift`). A component compiles here exactly as it did in the app.
- **Its words are the package's.** A component's own copy (an accessibility label, a fixed title) is `String(localized: "…", bundle: .module)` in `Resources/<lang>.lproj/Localizable.strings` — English and `zh-Hans`, landing in the same commit as the code. Words that come from the app arrive in the display model, already localized.
- The component-boundary rules of `macos/CLAUDE.md` (B1–B4) apply here as in the app; `make arch` checks both.

## The design says what; AppKit says how

The design sheets are every component's source: `design/transcript/index.html` (its parts written up in `design/transcript/01-run.md` … `08-live.md`, styled by `preview.css` and `preview-live.css`) and `design/settings/index.html`. They fix what a component is — its parts, its states and what moves it between them, its words, colours, corner radii and spacing. They are not a pixel spec: HTML can't draw an AppKit control, so a CSS value says what the control should be, never how to draw it.

- **Build from the AppKit control that does the job, and keep its own behaviour and look.** A button is an `NSButton` on a system bezel (`.accessoryBar` for a chip-sized title; `.flexiblePush` when the title outgrows its control size); a choice is a radio button or checkbox; a pop-up is an `NSPopover`; a list is a table; a row whose parts come and go is an `NSStackView`. What the control brings is the design's intent met: hover, press feedback, on state, corners, focus ring, acting on release, keyboard, VoiceOver, its measured size, the user's system settings (scroll bars, accent, contrast).
- **Never bend a control to fit the sheet.** No acting on mouse-down, no hover or press drawn by hand, no accessibility role set on a control that has its own, no title laid out from hand-offset attachments, no system setting forced, no timestamp or delay patching what the control already handles (a transient popover already takes the press that dismisses it). Each of these trades the system's behaviour for a look and loses keyboard, VoiceOver or a state.
- **Where the sheet and AppKit differ, AppKit wins and the sheet changes** — the HTML / CSS and its write-up in the same commit, so the sheet always describes what ships. The system's version is the one the user knows from every other Mac app.
- **One writer per state.** A control that mirrors something — a menu button's on state, a toggle's value — is set only by what owns that thing; its own press doesn't flip it.
- **Don't test AppKit.** A test covers the component's own logic: what it shows for a value, what it reports for a press (assert the window's hit test finds the control, then `performClick`). Whether a bezel highlights or a popover dismisses is the system's — look at it in the render (*Verify*, step 4) instead; a test that calls methods directly has never seen the control.

## Moving a component in

The app's views come here one unit at a time — a family, or a component with the leaves only it uses — and each unit lands as one commit that leaves every gate green.

- **Move, then refine:** `git mv` the files, then edit them in place — `public` on the surface, `bundle: .module` on every string. Never retype a file.
- **Cut the domain out, don't carry it in.** A component that takes an app type (`Account`, `Subscription`, a store's state, an AgentSDK value) takes a display model instead, and its delegate reports an id or a display value. The mapping from the app's type to the display model is an `extension` on the display model in the app, next to the screen that uses it (`AccountRowContent+Account.swift`); the store subscription stays in the app's controller.
- **A view model stays in the app; its binder joins it to the component.** The view model publishes the component's display model; the binder (a controller, or a coordinator for a flow such as a sheet: `AccountEditorCoordinator`) owns both, shows each presentation, turns each reported edit into a view-model call and reports the outcome in domain terms. The view model never imports `Components`, and the component never sees the view model.
- **Leaves a component alone uses move with it and stay `internal`** (`EnvironmentVariableCellView` with its list). A subview is never made `public` so the app can reach into it.
- **Assets it draws come with it** into `Resources/Assets.xcassets`, published as a `public` accessor where the app also draws them (`NSImage.claudeMark`). An icon is a system SF Symbol or the design's, built by its `design/<set>/src/build.ts` into this catalogue (`macos/CLAUDE.md`, *An icon is a system SF Symbol or an image the design builds*): an SF Symbol in a file being moved stays one; a glyph drawn in Swift is replaced by its design asset.
- **Its tests come with it.** What the component does on its own — its controls, its states, its wording — is tested here; the app keeps only the tests of its mapping and its flow, asserting against the component's own values (`.problem(…)`, `.checking`), never against the component's words.

## Verify — every unit, before its commit

1. **Words:** `grep -rn 'localized:' macos/Components/Sources/Components` shows `bundle: .module` on every hit (a wrapped call carries it on the next line); each key is in both `Resources/*.lproj/Localizable.strings` and gone from `ccterm/Localizable.xcstrings` unless the app still says it.
2. **Gates:** `make build`, `make test-unit`, `make test-ui`, `make fmt-check` — all green.
3. **Architecture:** `make arch`; `build/arch/rules.md` has no more findings than before the unit, and none in `Components` or `DisplayModels` — the domain stays out by the compiler, the rest by these rules.
4. **Look:** `make test-ui FILTER=DesignPageSnapshotTests`, then open your section's `macos/Components/.build/design/Design-<section>-1240-{light,dark}.png` (inside your own checkout, so no other worktree overwrites it) (the section's title, lower-cased, words joined by `-`) and read the new specimen against its design part, at the same size: every state the design shows is there; nothing collapsed, clipped, truncated or overlapping; edges that line up in the design line up here (a form's content and its button bar); the dark render its own. Whatever looks wrong is wrong — a legacy scroller, a non-key window, a mouse attached are a real Mac, not the environment.
5. **Commit and push.**

## The style page

`ComponentsDesign` lays the components out as the design sheets do (`design/transcript/index.html`, `design/settings/index.html`): one column, 1160 wide at most, centred; a section per family — heading, note, then each specimen as a heading over a card. Each family adds a `<Family>Specimen` that builds real components from fixture models, interactive. The page follows the window's width; a component never does.

- **A specimen is the component in its real host, at the host's real size.** Every component lives where the app gives it a size: a Settings pane 700 × 628 (the window's 880 × 680 less its 180 sidebar and 52 toolbar), the account sheet 540 × 600, the main window's sidebar 290 wide (the narrowest its split item gives it), a transcript row at the transcript's column. The specimen builds that host — the window's content, a sheet drawn as the design draws one (corners, edge, shadow) — at that size, and the card holds it centred. Nothing is stretched to the card: a size the app can't give a component shows problems the app doesn't have and hides the ones it does. The size is named once in the specimen, with where it comes from.
- **The page is never narrower than its widest host**, as the design never narrows a window (its `.window` is a fixed 880 × 680): the window's minimum width fits that host at its real size, and nothing is scaled: a live AppKit host scaled below 1 loses its drawing or its layout, whichever way it is scaled.
- **A part the design draws as a whole window is shown in a window, through one shared host.** The transcript's Playground (the main window: sidebar, tabs, transcript, composer), the Settings window, the sidebar in its window: `WindowFrame` draws the design's window — traffic lights and title bar from the design's assets, the toolbar row, corners, hairline edge, shadow — around the real content at the window's content size, and is its card (no inset around it). A sheet is drawn as the design draws one (corners, edge, shadow over its scrim) inside its window's frame. A component that lives in no window of its own keeps a plain card.
- **A new component lands with its specimen.** Moving a component here without one leaves the page behind the app.
- **Look at it off screen**, never by opening a window on the reader's display: `make test-ui FILTER=DesignPageSnapshotTests` renders the page 1240 wide, light and dark, one PNG per section (the whole page is taller than a capture can be) to `macos/Components/.build/design/Design-<section>-<width>-<scheme>.png`. The render is the executable's own mode, `ComponentsDesign --render <dir> <width> <light|dark>`, which the test starts as a process with `-AppleLanguages '(en)'` — Foundation fixes a process's language at launch, so only a process of its own renders the package's words in English. `make design` opens it for hands — scrolling, typing, resizing.
