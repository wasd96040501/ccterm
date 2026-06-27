# Adversarial review — final refactor deliverable (spec + 6 table fragments + PR plan)

Verdict: **sound-with-fixes.** The spec is genuinely explicit and mechanically
checkable; the six fragments place essentially every meaningful class with a clean
single-owner / single-channel filing; the PR plan is a credible, correctly-ordered,
independently-shippable sequence whose ✗ rows are real as-is defects that map to a
fixing PR. The deliverable is NOT flawed. But it has a small number of concrete
issues that should be corrected before it is treated as the final conformance proof:
one closed-set vocabulary breach, a class of ✗ rows that *remain* ✗ at the end of the
plan (contradicting the user's "no class stays ✗" criterion and the deliverable's own
✓-treatment of the same decision elsewhere), four DEBUG classes with no table row, a
dangling spec cross-reference, and two minor mis-filings. None is an unplaceable
production class; all are fixable in the docs.

Each finding below is FACT (read in source / the docs) or INFERENCE (judgment).

---

## 1. Is the spec EXPLICIT? — Yes, with one dangling reference

The spec is the strongest part of the deliverable. §0 fixes a closed-set schema; §1
gives a layer lattice with a single named exemption (`selectionObserver`); §3 ships a
per-edge verdict table that each row's channel cells can be checked against; §4 maps
every regime to its `sizingOptions` + constraint recipe; §6 states the 6-point
conformance test. A reader CAN mechanically check a component. No spec rule contradicts
BOUNDARY-SPEC (the regime table is a faithful condensation, including the load-bearing
H-4 "regime-A sizing + passthrough hit-testing, NOT B″" for the card).

**Issue S1 (FACT, minor) — dangling cross-reference.** spec.md:37 defines
`Target Δ (PR#)` as "the migration step number **from §7 below**." spec.md has no §7
(its sections are 0–6); the PR mapping lives in the separate `pr-plan.md`. The spec
claims to be "single, self-contained" (spec.md:3-4) but the PR-number authority is
external. Fix: change ":37" to point at `pr-plan.md`, or drop the "§7 below" clause.

---

## 2. Is the ownership table COMPLETE? — Four DEBUG classes have no row

I enumerated every `NSViewController` / `NSView` subclass and every `@Observable` type
in the touched areas and cross-checked each against the six fragments.

**Issue C1 (FACT) — four DEBUG VCs are unplaced.** spec §1 explicitly lists "demo VCs"
under the Detail-child-VC layer, and the shell-routing fragment's prose says the router
mounts "demo VCs in DEBUG," yet **no fragment has a row for any of them**:

- `TranscriptDemoViewController` (`Content/TranscriptDemo/...:20`)
- `TranscriptPerfDemoViewController` (`...:16`)
- `TranscriptStressViewController` (`...:11`)
- `PermissionSessionDemoViewController` (`...:28`)

This matters beyond completeness: **`PermissionSessionDemoViewController` is touched by
PR5** (pr-plan.md:110, M3: "Migrate `PermissionSessionDemoViewController` to mount the
overlay … else the demo silently breaks"). A class a PR changes must have a row, or the
"every non-`unchanged` row is claimed by exactly one PR" invariant (pr-plan.md:13) is
unprovable for it. It is also the host of BOUNDARY-SPEC's documented *legacy hand-rolled*
input-bar shape (`sizingOptions=[]` + PreferenceKey, BOUNDARY-SPEC §3) — exactly the
anti-pattern the spec warns against — so its regime filing is non-trivial and worth a row.

**Issue C2 (FACT) — two DEBUG `@Observable` demo helpers are unplaced.**
`TranscriptStressStatusModel` (`TranscriptStressViewController.swift:159`) and
`ControlPanelState` (`PermissionSessionDemoViewController.swift:313`) are `@Observable`
`@MainActor` view-private state machines with no row. They are the clean case (Rule-5
view-private state, like `GitProbe`) — but the fragments place `GitProbe` /
`BackgroundTaskOutputStream` / `CompletionState` and omit these two, so the omission is
inconsistent, not principled.

INFERENCE: all six belong in a single "DEBUG demos" sub-table (Layer Detail-child-VC for
the VCs, View-scope-state for the two models). They are all conformant; the defect is the
*missing rows*, which leaves PR5's demo-migration row unclaimed.

Everything else is placed. Production `NSViewController`s (Chat / DetailRouter / Archive /
Compose / DraftLanding / Sidebar) all have rows. Production `@Observable` types
(MainSelectionModel, AppState, TranscriptSearchBus, ArchiveView's model usage,
CompletionViewModel→CompletionState, BackgroundTaskOutputStream, Transcript2SheetPresenter,
Transcript2Controller, InputDraftStore, GitProbe, ModelStore, AppActivationTracker,
NotificationService, OpenInAppService, RecentProjectsStore, SessionManager, Session,
SessionDraft, SessionRuntime + the 3 new trackers) all have rows. `MessagesChange.swift`
and `SessionRuntime+Start.swift` contain no `@Observable` *type* (only comments / the
extension) — correctly handled.

---

## 3. Are the ✗ rows real defects the plan FIXES? — Mostly yes; one class stays ✗

I traced every bare `✗` in the Conformant cell (not the "as-is ✗ → ✓" annotations) to
its Target Δ.

Cleanly fixed (✗ → ✓ at a mapped PR), verified against source:
- `BackgroundTaskButton` façade bypass — FACT `BackgroundTaskButton.swift:83`
  (`runtime.markTaskStoppedLocally`) → fixed PR4. ✓
- `ChatRestingBar` sizing pump — fixed PR5. ✓
- `SyntaxHighlightEngine` misnomer — FACT 5 sites inject `searchEngine`
  (DetailRouter:433, Chat:582, Compose:103, DraftLanding:126, Archive:78) → fixed PR2. ✓
- `NotificationService` dead inject — FACT `notifications`/`searchBus` injected at all 5
  hosts but 0 SwiftUI reader → fixed PR1. ✓
- `ClaudeCodeStats` DEAD — FACT 0 non-test consumers → deleted PR3. ✓
- `DirectoryCompletionItem` etc. — FACT 0 construction sites → deleted PR3. ✓
- `FileCompletionStore.invalidate*` dead methods → PR3. ✓
- `GitProbe` missing `@MainActor`, `ANSIAttributedBuilder`/`SyntaxTheme`/
  `PermissionMode+Color`/`Effort+Display` under `Models/` — layering nits → PR12. ✓
- `SidebarViewController` god-VC → PR9/PR10. ✓

**Issue D1 (FACT/INFERENCE, the sharpest finding) — five `.shared` stores stay ✗ at the
end of the plan.** `ModelStore` and `SlashCommandStore` carry Target Δ = **unchanged** and
a bare **✗** in the final Conformant cell (table-session-services-models.md:94,98);
`EffortDefaultStore`/`NewSessionDefaultsStore` are ✗ with only an *optional* fold;
`FileCompletionStore` keeps its ✗ ownership-inconsistency even after the dead-method
delete (`:95-97`). Under the user's explicit criterion — *"any class that stays ✗ at the
end = the design is still wrong"* — and the spec's own §6, **these rows remain
non-conformant after PR13 merges.** Two problems:

  (a) **Internal contradiction in how the same decision is scored.** The inputbar
  fragment marks the *consumers* of these same singletons as conformant ✓ with a
  "documented `.shared` Rule-11 exception" (table-inputbar-perm-completion.md:29
  `ModelEffortPicker`, :73-74 trigger rules, :82-83 the stores themselves marked ✓).
  So `FileCompletionStore`/`SlashCommandStore` are ✓ in one fragment and ✗ in another;
  `ModelStore`-via-`.shared` is ✓ at the reader and ✗ at the store. The deliverable
  cannot have it both ways.

  (b) **A deliberate-retain should be ✓-with-rationale, not ✗.** spec §11/DNT-8 sanctions
  `.shared` for `ModelStore` (spawns a CLI subprocess) and the completion caches
  (per-process). If the design *intends* to keep them, the conformant verdict is ✓ (a
  documented, owned exception), not ✗. A bare ✗ with Target Δ "unchanged" reads as "known
  wrong, not fixing it" — precisely the state the user flagged as a failed design.

  Fix (INFERENCE): make these rows ✓ with the rationale in-cell (mirroring how the
  inputbar fragment already scores their consumers), OR commit to the AppState fold and
  set a real PR. Do not leave a class ✗ + unchanged. Pick one.

**Issue D2 (FACT) — `CrossfadeController` ✗ is correctly handled.** It stays ✗ but is
explicitly NOT introduced (no row created; pr-plan.md:47,194; shell-routing defect #1).
The two existing crossfade state machines each place cleanly; the *abstraction over them*
is the defect, and the plan rejects the abstraction. This is the right call — a declared
"do not build this" is not a class that stays ✗ in the shipped tree. Acceptable.

---

## 4. Is every PR independently shippable & are dependency edges correct? — Yes

Spot-checked the two edges the prompt calls out, both correct:
- **un-erase before DetailContext:** PR6 (un-erase `AnyView` → concrete generic body) is a
  hard dependency of PR7 (`injectDetailEnvironment`), so a missed injection becomes a
  compile error (pr-plan.md:119,130; spec H-5). Ordering is stated and load-bearing. ✓
- **card-overlay before swap-coordinator:** PR5 (`permissionCardHost` as 4th sibling in
  `loadView`) is sequenced before PR13, which must treat it as the 4th sibling and keep
  transcript `.below topScrim` (pr-plan.md:22,112,182). FACT: `loadView` currently adds
  topScrim then composeOrBarHost (`ChatSessionViewController.swift:158,173`), and the swap
  inserts `.below topScrim` (`:356`) — the seam the plan preserves is real. ✓

Each PR states compiles + `make test-unit` green + revert restores prior behavior, and
the risk gradient (mechanical → card → DI → god-object splits → transcript-swap last) is
sound. PR13 is correctly placed last, behind the two reentry merge gates
(`TranscriptReentryLayoutCacheTests`, `TranscriptHostReentryLayoutCacheTests` — both FACT
present in the test tree) and is a verbatim move with an honest coverage-gap admission
(the same-session-crossfade finish-before-attach path is not covered by the two gates;
pr-plan.md:186, table-detail-vcs defect #2). That honesty is correct, not a flaw — but it
means `TranscriptSwapCoordinator`'s ✓ is *conditional* on a seam the gates do not fully
prove (see §5).

**Issue P1 (FACT, minor) — "★NEW" test labels collide with existing tests.** pr-plan.md:114
labels `PermissionCardWiringTests` and `DetailPaneTranscriptHitTestTests` as "★NEW" for
PR5, but both files already exist (`cctermTests/PermissionCardWiringTests.swift:1-127`
tests the *as-is* `ChatRestingBar` wiring; `DetailPaneTranscriptHitTestTests.swift:1-342`
exists). PR5 *updates* them (3-button → 4-closure overlay routing), it does not create
them. Mislabel only; the coverage intent is sound. Fix the label to "★UPDATED."

---

## 5. Is every touched row spec-conformant after its PR? — Yes, with one vocabulary breach

Regimes and channels check out against BOUNDARY-SPEC: the 3 fill-pane children stay
regime A (`[]` + 4-edge, canonicalized by `mountFillPaneHost`); the chat bar stays
regime B and is deliberately excluded from the helper (spec H-2, DNT-6); toolbar chips B′;
sheets D; the card is the documented A-sizing + passthrough hybrid (spec H-4). The FACT
citations the rows rest on are accurate (`composeOrBarHost: NSHostingView<AnyView>` at
`:97`; `currentSession` at `:75`; cutout transform via `composeOrBarHost` at `:235`;
`.below topScrim` at `:356`; `fadingOutTranscript` at `:116`).

**Issue R1 (FACT) — "A-hybrid" is not in the closed Host-regime set.** The Host-regime
vocabulary is `{A, B, B′, B″, C, D, E, —}` (spec §0:35). Three rows write the cell value
as **`A-hybrid`** (table-detail-vcs.md:28; table-inputbar-perm-completion.md:67;
pr-plan.md:116). spec §6 requires "every cell drawn from its closed vocabulary," so a cell
literally reading "A-hybrid" is out-of-vocabulary. The *substance* is fine — spec §4 H-4
and §7.8 reconcile the card to **regime A** (A sizing; the passthrough hit-testing is an
add-on, not a new regime). Fix: write the cell as **`A`** and move "+ passthrough
hit-testing (H-4)" into a footnote/annotation. As written, a strict closed-set checker
rejects the cell — minor, but it is the one place the conformance proof breaks its own
schema.

**Issue R2 (INFERENCE, minor) — `mountFillPaneHost` / `injectDetailEnvironment` filed as
DI-context/translator is a stretch.** spec §1 defines DI-context as "value bags of model +
consumed services" (`DetailContext`, `SidebarContext`). `mountFillPaneHost` is a
host-mounting helper (a boundary concern — it encodes regime A), and
`injectDetailEnvironment` is a SwiftUI `View` modifier. Neither is a value bag. They place
*fine* as free helpers, but "DI-context layer, Kind translator" is the loosest filing in
the deliverable. Not unplaceable; consider a "Helper" note or filing `mountFillPaneHost`
nearer the host rows. Cosmetic.

---

## 6. Over-engineering / wrong regimes — none found

The plan actively resists over-engineering: PR11 (grouping dedupe) is honestly downgraded
to "may legitimately be a no-op" (predicate already shared — FACT `isGroupableAssistant`);
`TurnUsageMeter` extraction, `Session` façade-collapse, `CrossfadeController`, and
Controller+Coordinator merge are all explicitly rejected (spec §5 DNT-8, fragments). The
3-tracker extraction (PR12) correctly notes the observed-nesting trap (`@Observable` held
by tracked prop, not a value extraction) — that is right, not gold-plating. No regime is
mis-assigned. The renderer scope is correctly left 100% `unchanged` behind the do-not-touch
wall.

---

## Summary of required fixes (all doc-level; no production class is unplaceable)

1. **D1 (must):** the five `.shared` stores (`ModelStore`, `SlashCommandStore`,
   `FileCompletionStore`, `EffortDefaultStore`, `NewSessionDefaultsStore`) must not stay
   `✗ + unchanged`. Either score the deliberate retains ✓-with-rationale (consistent with
   how the inputbar fragment already scores their consumers) or commit the AppState fold to
   a real PR. A class left ✗ at the end fails the user's criterion.
2. **C1/C2 (should):** add rows for the 4 DEBUG VCs + 2 DEBUG `@Observable` helpers; PR5's
   `PermissionSessionDemoViewController` migration is otherwise an unclaimed change.
3. **R1 (should):** replace the "A-hybrid" cell value with "A" (+ footnote) so it stays in
   the closed Host-regime set the spec's §6 enforces.
4. **S1 (minor):** fix the spec's dangling "§7 below" reference (point at `pr-plan.md`).
5. **P1 (minor):** relabel PR5's two "★NEW" tests as "★UPDATED" (both files already exist).
6. **R2 (cosmetic):** reconsider the DI-context/translator filing of `mountFillPaneHost` /
   `injectDetailEnvironment`.
