# Adversarial verification: design-target-data-flow.md

Status: read-only verification. No production code changed. Every claim below is
checked against source at file:line. FACT = read in code. INFERENCE = my read.

## Verdict: **sound-with-fixes**

The design is overwhelmingly correct and, crucially, **defensive in the right
direction** — its entire thesis is "don't 'clean' the deliberately-imperative
edges away," which is exactly the failure mode an over-eager unidirectional
refactor would hit. It does **not** weaken any §2 transcript perf-contract item,
does **not** touch the §2.19 attach contract, and does **not** violate a runloop
tick invariant. Its "current mechanism" premises are accurate at the cited
call sites (modulo trivial line drift and one path-prefix error). The genuine
issues are all in the *parity framing* of two deletions and a few precision nits,
not in the spine of the proposal.

No BLOCKERS. The perf contract is fully preserved.

---

## What I verified as TRUE (FACT)

- **Selection spine (§0.1, §3.1).** `MainSelectionModel.select(_:)` sets the
  `@Observable` then synchronously notifies the single observer
  (`MainSelectionModel.swift:53-57`); `selectionObserver` is the lone
  `@ObservationIgnored weak` back-edge (`:45`); `promote(to:)` is the
  unchanged-value re-fire (`:72-79`); direct `selection =` is documented as
  pre-mount/test only (`:30-32`). The doc comment (`:4-17`) gives the
  tick-ordering rationale verbatim. **The §3.1 "keep imperative" argument is
  correct.**
- **`pendingPermissions` (§3.5) is already clean.** Read via
  `session.pendingPermissions.first` (`InputBarChrome.swift:143`), write via
  `session.respond(to:decision:)` (`:146-152`); `Session.respond` at
  `Session.swift:687`, `pendingPermissions` forwarder at `:333`. No cached copy.
  The design's "exemplar, do not touch" verdict is right. **The card geometry is
  correctly scoped OUT** — the data-flow doc does not propose the card-over-bar
  overlay, so the feasibility risk in the brief (would an overlay move the
  bar/inset?) **does not apply to this document**; it's deferred to
  survey-permission-cards §7.
- **Draft-clear-on-send (§3.3).** `InputBarView2.handleSend` clears the draft
  imperatively (`draftStore.clear(key)` at `InputBarView2.swift:471`) before
  `onSubmit` (`:473`), with the reactive path being
  `.onChange(of: text) { scheduleDraftSave() }` (`:206`). The teardown-proof
  rationale holds.
- **`setLoading` + observation task (§3.4).** Initial sync at
  `ChatSessionViewController.swift:428`; the bespoke `withObservationTracking`
  re-arm loop at `:525-541`; `turnUsage` already uses the closure-sink shape
  (`onTurnUsageChange` at `:438-440`). The "two disjoint render targets, not a
  both-channels violation" reading is correct, and the optional closure-sink
  unification genuinely matches `onTurnUsageChange`.
- **Rect-reporting (§3.2).** `onAttachRect`/`onPillRect` closures at
  `ChatSessionViewController.swift:557-565` → `applyScrimCutouts` (`:231-234`);
  the "local to this VC, no cross-VC consumer" comment is at `:96-101`. The
  "single reader → keep as closures, don't promote to a model field" call is
  right under Rule 1.
- **DI bag (§3.7).** The 7-arg fan-out is real: `searchEngine`/`searchBus`/
  `notifications` + 4 others re-declared across the router
  (`DetailRouterViewController.swift:74-128`, makeChild repeats the call 4×
  `:370-402`) and every child VC (`ChatSessionViewController.swift:124-141`,
  `ComposeSessionViewController.swift:37-58`,
  `DraftSessionLandingViewController.swift:29-54`). The 6-line `.environment`
  block is copy-pasted (router `:430-435`, compose `:100-105`, landing
  `:123-128`).
- **The two dropped env injections ARE dead (§3.7).** Grepped:
  `@Environment(NotificationService` → **0 consumers**;
  `@Environment(TranscriptSearchBus` → **0 consumers**. `notifications` reaches
  its consumer via `notifications.onActivateSession` push owned by the router
  (`DetailRouterViewController.swift:162`) + `notifications.bootstrap()` (`:173`);
  `searchBus` reaches the toolbar bridge via `MainWindowController.swift:405-436`.
  **Dropping `.environment(notifications)` / `.environment(searchBus)` is a true
  no-op.**
- **`searchEngine` is mis-named (§3.7/§4 rename).** It is a
  `SyntaxHighlightEngine` injected under the `\.syntaxEngine` env key
  (`DetailRouterViewController.swift:433`), consumed by `DiffView.swift:35,474`.
  Rename to `syntaxEngine` is pure clarity, no behavior.
- **`BackgroundTaskButton` pierces the façade (§4.1).** It reaches
  `session.runtime` directly (`BackgroundTaskButton.swift:81`) and calls
  `runtime.markTaskStoppedLocally(taskId:)` (`:83`), bypassing `Session`. The
  proposed `Session.stopBackgroundTask` forwarder faithfully mirrors the existing
  `Session.requestContextUsage` phase-aware forwarder (`Session.swift:393-402`,
  guard-runtime-else-noop). **The fix is correct and in the product, not a test.**
- **Ownership split (§3.8).** `searchBus` + `selectionModel` live on
  `AppDelegate` (`AppDelegate.swift:31`, `:79`); the other 8 on `AppState`
  (`AppState.swift:7-14`, including `notificationService` at `:13`).
  `MainSelectionModel` is genuinely NOT on `AppState`, so the "can't inject
  AppState whole" rejection (§5.5) is correct.

---

## MAJORS (should fix before treating §8 "parity guarantee" as airtight)

### M1 — The completion-path deletion (§3.6) is NOT "provably-dead-code" the way §8 claims.

§3.6 and §8(2) bucket the directory-completion deletion as "grep-verified zero
consumers/constructors, so removal cannot alter runtime behavior." That is only
half true:

- `DirectoryCompletionItem(` has **0 construction sites** (FACT — grep) — so the
  *items* never appear. Good.
- **But the surrounding UI plumbing is live wiring, not dead code.**
  `onDeleteRecent` is still referenced and wired through live views:
  `InputBarView2.swift:254` passes it, `CompletionListView.swift:7` declares it,
  `:192` invokes it. The "recent pill" branch and `onDeleteRecent` closure are
  reachable code that simply never *fires* because no recent items are produced.

Deleting reachable-but-never-triggered wiring is still behavior-preserving **in
practice**, but it is a *behavioral* argument ("the branch can't be entered
because its data source is empty"), not the *structural* "zero consumers"
argument §8 asserts. The distinction matters for the parity guarantee: a
reviewer who trusts "provably dead → removal is a no-op by construction" will not
re-derive the empty-data-source reasoning. **Fix:** re-label §3.6 / §8(2) for the
completion path as "behavior-preserving deletion of never-triggered wiring
(verified: no `DirectoryCompletionItem` constructor; the recent branch's data
source is always empty)", and keep it as its own commit gated on
`BuiltinSlashCommandTests` + completion tests (the design already says this in
R5 — so the risk is acknowledged; only the §8 label overstates it).

### M2 — §8 "merge gates remain the regression net" omits the completion path's actual gate coverage gap.

The deletion in §3.6 removes `validateAndConfirmFromInput` / `tryConfirmFromInput`
/ `hasInputValidation` (FACT: present only in `CompletionViewModel.swift`, no
external callers). These are input-validation entry points. The cited gates
(`BuiltinSlashCommandTests`, completion tests) exercise slash/@ completion and
builtin dispatch — they do **not** obviously cover an "input validation on
confirm" path, because nothing live drives it. That's consistent with the code
being dead, but it means the *gate* won't catch a mistaken over-deletion that
also nicks a live confirm path. **Fix (low-cost):** before deleting, grep-confirm
each removed symbol has zero callers outside `CompletionViewModel.swift` (I
confirmed `validateAndConfirmFromInput` / `tryConfirmFromInput` /
`hasInputValidation` have none), and note in the commit that the deletion's
safety rests on call-site absence, not on a test.

---

## MINORS (precision / hygiene; none block)

- **m1 — Path prefix is wrong throughout.** The design cites
  `ChatSessionViewController.swift:NNN` and the ownership tree implies it sits
  under `Content/Chat/`. It is actually at **`App/AppKit/ChatSessionViewController.swift`**
  (FACT). The §2 chat CLAUDE.md table also lists it among AppKit shell VCs, which
  matches its real location. Cosmetic, but a reader following the citations will
  miss the file. Same for any "…/Content/Chat/ChatSessionViewController" implication.
- **m2 — Line-number drift (harmless).** Cited ranges are 1-9 lines off from
  current source: `:557-566`→actual `:557-565`; `:525-541`→`:525-541` (ok);
  `:438-442`→`:438-440`; `:96-101` (ok); InputBarView2 `:467-473`→clear at `:471`,
  onSubmit at `:473`. The structural claims are all correct; only the exact spans
  drift. Not worth re-pinning unless the doc is regenerated.
- **m3 — `stopBackgroundTask` forwarder drops a return value (safe, worth noting).**
  `markTaskStoppedLocally` is `@discardableResult -> Bool`
  (`SessionRuntime+Tasks.swift:123-124`). The button's existing `stopAction`
  closure already discards it (`BackgroundTaskButton.swift:82-84`), so the
  proposed forwarder returning `Void` is parity-safe. The design's before→after
  snippet is faithful. (Just call out that the `Bool` is intentionally dropped, to
  pre-empt a "you lost the return" review comment.)
- **m4 — §3.7 says the consumed env set is exactly
  `{SessionManager, RecentProjectsStore, InputDraftStore, \.syntaxEngine}`.**
  Verified (FACT): `@Environment(SessionManager)` in ArchiveView, Compose,
  InputBarChrome, DraftLanding; `@Environment(RecentProjectsStore)` +
  `@Environment(SessionManager)` in NewSessionConfigurator;
  `@Environment(InputDraftStore)` in InputBarView2; `\.syntaxEngine` in DiffView.
  The claim is correct. (Stating it here because it's load-bearing for the "drop 2
  dead injections" no-op argument and the design asserts it without the grep — now
  confirmed.)
- **m5 — The optional §3.4 `isRunning` closure-sink is correctly gated, but note
  one subtlety.** The current task body re-arms via `withCheckedContinuation` +
  `withObservationTracking` (`ChatSessionViewController.swift:527-540`) and guards
  `currentSession === session` (`:537`). A closure-sink replacement must preserve
  that **identity guard** (the sink fires for the runtime regardless of which
  session is currently presented) and the **initial** `setLoading(session.isRunning)`
  on attach (`:428`). The design's after-snippet keeps the
  `currentSession === session` guard — good. Just don't lose the initial sync; the
  design says it's preserved (§3.4 parity) but the snippet only shows the sink, not
  the attach-time call. Keep `:428` intact.

---

## What I ENDORSE (don't second-guess these)

1. **Refusing to delete `selectionObserver` / make the router reactive (§3.1, §5.3).**
   The tick-ordering rationale is real and doc-pinned; reactive observation would
   fragment the switch across frames. Correct call.
2. **Keeping `setLoading` imperative (§3.4)** — disjoint render targets, exact-flip
   push; not a both-channels violation. Correct.
3. **Keeping rect-reporting as closures (§3.2)** — single reader, synchronous, no
   phantom cross-VC dependency. Promoting to a model field would be the
   over-engineering the brief forbids.
4. **`DetailContext` + `injectChatEnvironment` collapse (§3.7)** — highest-value,
   lowest-risk structural win; pure plumbing; the two dropped env injections are
   verifiably dead. This is the real clarity payoff and earns its keep.
5. **`Session.stopBackgroundTask` forwarder (§4.1)** — the one genuine
   unidirectional violation, fixed in the product via the existing forwarder
   pattern. Correct and minimal.
6. **Leaving the singletons (`ModelStore`/`EffortDefaultStore`/`NewSessionDefaultsStore`,
   the two completion stores) as `.shared` (§3.8, §5.6)** — explicitly resisting
   ceremony-DI. This is the right "do not over-engineer" judgment.
7. **Rejecting a global store / chat ViewModel (§5.1, §5.2)** — both would
   reintroduce shadow-copy/sync and (for the store) break the synchronous
   closure-push the §2 perf contract depends on. Correct.
8. **Refusing to merge Controller+Coordinator (§5.7)** — explicitly load-bearing
   per NativeTranscript2 §1.1. Correctly out of scope.

---

## Perf-contract safety check (explicit, per the brief)

- **NativeTranscript2 §2 (all items):** untouched. No proposal alters
  `layoutCache`, `apply`/`Change`, `makeLayout` off-main, the backfill pipeline,
  the cell layer policy, or any §2.x technique. **No weakening. No BLOCKER.**
- **§2.19 single-width attach contract:** untouched. The `factory.make` →
  settle → `bindData` → `scrollToTail` choreography and its two merge gates
  (`TranscriptReentryLayoutCacheTests`, `TranscriptHostReentryLayoutCacheTests`)
  are in the §7 do-not-touch list and nothing in §3 reorders the attach path.
- **Runloop tick invariants (root CLAUDE.md):** the design's whole Rule 6 is built
  *on* the tick model and preserves every source-phase-ordered edge (selection
  notify, transcript attach, draft-clear-before-teardown). The optional §3.4
  closure-sink is the only change that touches runtime wiring, is explicitly
  optional/gated, and fires synchronously at the mutation site (same phase as the
  current observation re-arm's eventual `setLoading`).

`breaksPerfContract = false`. `regressesFunctionality = false` (M1/M2 are framing
fixes, not regressions). `overEngineered = false` (the design actively resists
over-engineering and rejects 7 tempting abstractions).
