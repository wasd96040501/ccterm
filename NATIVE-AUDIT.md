# Native-way audit — `components-package`

> **Temporary. Delete this file before the branch merges into `main`.**

Where this branch replaced a native AppKit / Foundation mechanism with a hand-made one, or kept a
native control and overrode the defaults that made it right. Each entry: where, what is wrong, the
native way. Fixed in the order below; every fix lands with a test that drives the real path (real
mouse / key events, the accessibility tree), not a direct method call.

Status: `[ ]` open · `[x]` fixed (commit) · `[-]` dropped (why)

## First batch — user-visible, verified

- [x] **1. Question card options are hand-drawn** — `Components/Rows/QuestionRowView.swift` (`OptionView`, `mark(for:picked:)`).
  `main` had `NSButton(radioButtonWithTitle:)` / `checkboxWithTitle:`; `09a98af0` replaced them with an NSView, an SF Symbol and a tracking area. Lost: Tab / Space, VoiceOver's role and value, act on release.
  Native: radio / checkbox `NSButton`s; the row's hover fill drawn by the container.
  **Fixed** (*Question options are AppKit radio buttons and checkboxes*): each live option is one radio button / checkbox titled with both lines, measured by its own cell; a question's buttons share a view and an action, so its radio buttons are one group; what is picked is the buttons' state (no `picks` copy); *Other* is a radio button beside its field. The hover fill is gone — a radio button takes a click on its mark and words only, so a row-wide fill promised a click that wasn't there; 07-talk.md and preview.css say so. Tests: the window's hit test finds the button under the words, `performClick` picks, the group follows, each question is its own group, *Other* focuses its field, typing picks *Other* alone; roles read from the cells (`AXRadioButton` / `AXCheckBox`).
  Note for the tests that follow: synthetic mouse-down/up don't drive an `NSButton`'s tracking under XCTest (no mouse button is really down) — assert the hit, then `performClick`.
- [x] **2. Menu button and Worktree toggle** — **Fixed** (*Menu buttons are AppKit's buttons, opened on release*): `MenuButton` is the accessory-bar button with its bezel under the pointer (the system's hover, press and corners), acting on release; the 22-pt folder title takes `.flexiblePush`, which grows with it, so its words sit in the bezel's middle. The cell lays out glyph (the button's image) and title; detail, trailing glyph and chevron are characters of the title (SF Symbols on its baseline), no offsets by hand; the chip's `leadingGlyphs` became one `glyph`. Only the popover turns the button on and off (`Cell.nextState` keeps the state a press finds). `closingPress` and every override are gone: a transient popover takes the press that dismisses it, so a second press on its button closes it and nothing reopens it. Worktree shows the draft's value after each press and is drawn on as the system draws it. Also fixed here: the branch row (16, the New view's half) is an `NSStackView`, so the branch button is no longer laid out 6 pt wide and invisible; the title font (26).
  Was: — `Components/Drawing/NSButton+Menu.swift`, `Menu/MenuPopover.swift`, `Composer/ComposerView.swift` (`show(_:on:)`), `NewSession/NewSessionViewController.swift` (`worktreeButton`).
  `.pushOnPushOff` plus the popover / owner writing `state` (two writers); acts on mouse-down; `setAccessibilityRole(.popUpButton)` on a plain button; title hand-built from `NSTextAttachment`s (text off the bezel's centre); `closingPress` event-timestamp hack; open/close decided in three places; Worktree's title hard-codes `.foregroundColor`.
  Native: a button whose state only mirrors its popover, acting on release; the transient popover's own handling of the press that closes it; title / image laid out by the cell.
- [x] **3. Overlay scrollers forced on every form** — **Fixed** (*Forms and lists outside the editor area follow Show scroll bars*): `FormView`'s override is gone; the environment table, the slash list and the style page are plain `NSScrollView`s. `OverlayScrollView` stays for the editor area alone (transcript, composer, documents), as `design/transcript/README.md` *Scrollers* and `main` have it. The tests that forced legacy and asserted overlay are gone.
  Was: — `Components/Form/FormView.swift` (`scrollerStyle` `didSet`), `Drawing/OverlayScrollView.swift` where production uses it.
  Overrides the user's *Show scroll bars* preference; added so the style page's render looked right (`58f20ffa`).
  Native: the system's scroller style; edges kept with insets.
- [ ] **4. Keys outside the menu and the responder chain** — **Fixed but one** (*Keys go through the main menu and the responder chain*): ⌘O is File > *Choose Folder…*, a nil-targeted `chooseFolder:` that the tab hands to its New view (`supplementalTarget(forAction:sender:)`, the composer being the New view's sibling); the view's `performKeyEquivalent` is gone. The field's dead ⌘. branch is gone (the menu's Stop takes ⌘.). ⎋ with no slash list goes up the responder chain, never to `complete:`. A closing menu leaves the focus where it was. The restart alert keeps Cancel's Escape; while Claude works its confirm button is destructive with no Return (design 08 and the sheet follow). **Open:** Stop and New Tab are SwiftUI commands, which AppKit never validates; validating them needs AppKit menu items.
  - ⌘O: `NewSessionRootView.performKeyEquivalent` — fires for whichever New view comes first in the tree, ahead of the main menu. Native: a nil-target *Choose Folder…* ⌘O menu item.
  - ⌘. / ⌘T: SwiftUI `Button { NSApp.sendAction }` in `App/AppCommands.swift` — never validated (Stop always enabled); ⌘. is eaten by the menu, so `ComposerFieldView`'s ⌘. branch is dead. Native: nil-target menu items validated by their responders.
  - ⎋ in the composer with no slash list falls through to NSTextView's `cancelOperation:` → `complete:` (`ComposerFieldView.swift`, `ComposerViewController.swift` `.escape`).
  - `menuDidClose` forces `makeKey()` + focus (`ComposerViewController.swift`).
  - Restart alert replaces Cancel's Escape with Return (`SessionTabViewController.swift`).
- [ ] **5. Composer field edits bypass the text system** — `Composer/ComposerFieldView.swift` (`body` setter, `complete(command:)`, token delete).
  `textView.string =` with `allowsUndo` on: ⌘Z after a send replays edits against text that is gone.
  Native: `shouldChangeText` / `replaceCharacters` / `didChangeText`, or clear the undo stack.
- [ ] **6. git pipe deadlock** — `ccterm/Git/BranchService.swift` `git(_:in:)`.
  Reads stdout to EOF, then stderr, then waits: a hook filling stderr's pipe blocks git and us forever.
  Native: drain both pipes concurrently, wait on termination.

## Second batch

### Hand-made controls
- [ ] **7. Composer status and context ring** — `Composer/ComposerView.swift` (`ComposerStatusView`), `Composer/ContextRingView.swift`: `hitTest` + `mouseDown` + a hand-set `.button` role. Native: borderless `NSButton`.
- [ ] **8. Attachment thumbnails invisible to VoiceOver** — `Rows/AttachmentsRowView.swift` (`Thumbnail`): a label without `isAccessibilityElement`.
- [ ] **9. Slash list selection** — `Composer/SlashListViewController.swift`: selection highlight off, cells paint their own, rows reloaded per ↑↓; `mouseDown` override. Native: `NSTableRowView.drawSelection(in:)`, `clickedRow`.
- [ ] **10. New tab +** — `TranscriptWorkspace` `NewTabButton.swift`: hand-made hover / press, `focusRingType = .none`.
- [ ] **11. Accessibility contradictions** — `MenuItemView` doesn't expose its check; `WorkLineRowView` / `ShowMoreRowView` claim `.button` without a press.

### Hand-measured layout
- [ ] **12. Slash list row heights** — `SlashListViewController.swift` `descriptionWidth` / `boundingRect`, missing the cells' insets. Native: `usesAutomaticRowHeights`.
- [ ] **13. Menu subtitle width** — `Menu/MenuItemView.swift` from the menu's width, assuming 16 a side.
- [ ] **14. Composer tiers by fixed widths** — `ComposerView.layout()` 600 / 500. Native: measure, or stack visibility priorities.
- [ ] **15. Image document centring** — `Documents/ImageDocumentViewController.swift` `ImageHostView.layout()` sets its own frame; doesn't follow the clip view.
- [ ] **16. Hidden views still in hand-made constraints** (the New view's row fixed with 2; the sidebar's glyph open) — New view's branch row (`NewSessionViewController`), the sidebar's branch glyph (`SidebarViewController`). Native: `NSStackView` detaching hidden views.
- [ ] **17. About sized once** — `About/AboutViewController.swift` `fittingSize` in `loadView`. Native: `NSHostingController` sizing.
- [ ] **18. `MenuPopover.popoverSize`** — a getter that sets the list 10 000 tall to measure.

### Timing and flag patches
- [ ] **19. Split expand on measured private priorities** — `EditorAreaViewController.expand(_:)`, the composer's 720 wish at 499 (above the divider's 490).
- [ ] **20. Rise end by `asyncAfter(0.6)`** — `NewSessionViewController`. Native: the animation's completion.
- [ ] **21. Scroll report by `main.async` + flag** — `TranscriptView` `isScrollReportPending`.
- [ ] **22. Style page without containment** — `ComponentsDesign` hosts add a VC's view without `addChild`, patched with `main.async`; specimens' appear callbacks change the page window's focus.
- [ ] **23. Back / forward forwarded by hand** — `MainSplitViewController` instead of `supplementalTarget`.
- [ ] **24. Focus ring ignores the key window** — `ComposerFieldView` / `ComposerView`.
- [ ] **25. Menu keys twice** — `MenuPopover` VC `moveUp`/`moveDown`/`cancelOperation` beside the table's own; hover selection stale on scroll.

### Fonts
- [x] **26. New view title font** (fixed with 2) — variation axis 650 + fixed kern from CSS. Native: `.systemFont(ofSize: 22, weight: .semibold)`.

### Services
- [ ] **27. `SessionStore.known`** — every transcript read is kept for the app's life.
- [ ] **28. `ModelCatalogStore` cache** — mirror types and a `JSONSerialization` round trip for SDK types.
- [ ] **29. Probes outdated by a counter, not cancelled** — `ModelCatalogStore`; the 60 s timeout can't fire through a detached launch (`AppDelegate`).
- [ ] **30. `git status` without `--no-optional-locks`** — `BranchService`.
