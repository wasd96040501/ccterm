# ExactList's tests

- **One method per requirement, named with its ID** (`testA5_…`). The generated
  skeleton is frozen: filling a test in replaces its `XCTFail("pending…")` body
  and nothing else. `SpecCoverageTests` checks that every ID in `SPEC.md` has a
  test.
- **The oracle is the test's own model.** `RecordingHost`'s height function and
  `ReferenceLayout` give the expected frames. The list's answers are never
  compared with themselves.
- **Real AppKit.** `ListStage` mounts in a real window off screen: the pattern
  of `cctermTests/Harness`, copied because this package can't import the app's
  tests. Width comes from the window or from a real `NSSplitView` divider,
  events come through `NSWindow.sendEvent(_:)`, and motion is read from
  `presentation()`.
- **Motion has two samplers** (`PresentationSampler`):
  - Scrubbing freezes time and gives exact `t`, which the formula checks use.
  - The display-link timeline shows what was actually on screen, which the "no
    jump, no blank" checks use. It needs macOS 14, behind `#available`.
- **What isn't covered here** is in SPEC §13: pixels and real speech. Those are
  the demo's checklist (`Sources/ExactListDemo/CLAUDE.md`).
- `NSTableViewCharacterizationTests` backs each "Characterized" claim in SPEC
  §2. When one fails, AppKit changed; update §2 rather than the test.
