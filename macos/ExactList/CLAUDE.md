# ExactList

A standalone Swift package: a vertical list for AppKit, `ExactListView`, with
exact geometry, anchoring and CoreAnimation motion.

- [SPEC.md](SPEC.md) is **normative**. It defines every behaviour, the
  structure (§15) and the verification (§13).
- [README.md](README.md) is the tour.
- This file holds the rules for changing the package.

Run from the repo root:

- `make test-list [FILTER=<Class>]`
- `make bench-list`
- `make demo-list`
- `make record-list [FILTER=<part of a name>]`

## 0. Look at motion frame by frame

Before and after changing anything that moves, record it:
`make record-list FILTER=stream` captures the demo's scenario off screen into
`/tmp/exactlist-recordings/<name>/`: every frame as a PNG named by its time
from the action, `sheet.png` (the frames at each 60 Hz tick, labelled), and
`movie.mov`. Read the sheet first, then the frames around anything odd. A
recording for a new state goes in `DemoRecording.all`
(`Tests/ExactListRecordings`).

## 1. The spec comes first

- **A behaviour change starts in `SPEC.md`**: a new or changed requirement with
  an ID. Code and tests follow in the same PR.
- **A test name carries the ID of each requirement it proves**
  (`testA5_removedAnchorPassesToNextSurvivor`). `SpecCoverageTests` fails when
  an ID has no test.
- **The framework is frozen**: the targets, the files, the types, and every
  signature, public or internal. Implementing means filling in bodies only. A
  framework change is a spec amendment (SPEC §14) in a commit of its own, with
  its reason stated.

## 2. Mirror AppKit; deviate only with a reason

Use `NSTableView`'s spelling and semantics unless SPEC.md records a deviation.
Before naming anything public, look up the AppKit counterpart
(`make appkit-doc SYMBOL=NSTableView`). A deviation without its reason in both
SPEC.md and the member's doc comment is a bug.

## 3. Nothing speculative

Public API lands when something calls it, and SPEC §12 lists what was left out
on purpose. TranscriptKit is the first consumer; what it needs comes in as
amendments.

## 4. Layering

- `ExactListCore` never imports AppKit: Foundation and CoreGraphics only. It
  holds no timers and no main-actor state, and every function in it is
  testable without a window.
- `ExactList` holds the AppKit engine. Collaborators talk back through one
  narrow internal protocol, never by naming `ExactListView`.
- Planning is Core's; applying the plan is the engine's. A decision about
  where something goes (an offset, a frame, a delta) never gets made inside a
  view.

## 5. Tests are real or they don't count

- The oracle is never the code under test. Core properties compare against a
  naive reference that uses only heights the test generated.
- Window tests use a real window, real layout passes and real events, driven
  through the public API. Motion tests read `presentation()` layers.
- No test-only API, environment switches, or access widened for a test. If a
  test can't reach something, drive the public surface (root `CLAUDE.md`).
