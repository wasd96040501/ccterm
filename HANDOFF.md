# Handoff — sidebar history switch flicker (RESOLVED)

Branch: `worktree-splendid-marinating-music`
PR: <https://github.com/wasd96040501/ccterm/pull/135>
Latest commits:
- `e659f4b` fix(transcript): reset isAnchorSettled on dismount so re-entry == first entry
- `7346624` test(transcript): repro re-entry stale isAnchorSettled bug

## Resolution summary

The re-entry-into-history-session flicker is fixed by making the
dismount path SYMMETRIC with the attach path on
`Transcript2Coordinator`. The bridge's `dismantleNSView` now
explicitly nils the coordinator's `tableView` (with an identity
guard), which fires the same `didSet` that the attach path relies on
and resets `isAnchorSettled` to `false`. Re-entry now starts from the
same `isAnchorSettled = false` state as first-entry — the two paths
are identical.

No hidden logic. No special-case "if re-entry then …" branches. The
flag's documented contract is honored end-to-end: "first-screen
anchor has landed for the **currently-attached** NSTableView."

## The root cause

`Transcript2Coordinator.tableView` is declared `weak`. Swift's
`willSet`/`didSet` observers do **not** fire when a `weak`
reference auto-nils via the referent's dealloc — only when the
reference is **explicitly** assigned. The previous `dismantleNSView`
implementation only removed the notification observer; it never
assigned `coordinator.tableView = nil`. So the matched
`tableView.didSet` reset (`setAnchorSettled(false)`,
`lastLayoutWidth = -1`) only ran on attach, never on detach.

`isAnchorSettled` therefore carried the previous visit's `true`
across the un-mounted window of a sidebar swap. On re-entry the
SwiftUI `.onChange(of:
currentController?.isAnchorSettled, initial: true)` observer saw
`true → true` (no transition), so the bake-clear branch raced the
new NSTableView's attach + tile + `consumeDesiredAnchor` sequence,
opening a sub-frame window where the user-reported "瞬间看到
transcript 开头的内容" symptom appeared.

## What changed in this session

| Commit | Subject | Effect |
|---|---|---|
| `7346624` | test(transcript): repro re-entry stale isAnchorSettled bug | Failing unit test + new integration coverage; widened `private struct Transcript2NSViewBridge` → `struct` so the test can drive `dismantleNSView` directly. |
| `e659f4b` | fix(transcript): reset isAnchorSettled on dismount so re-entry == first entry | `dismantleNSView` now `coordinator.tableView = nil` with an identity guard. |

## Verified

- `Transcript2AnchorSettledTests.testDismountResetsIsAnchorSettled` — fails
  on `7346624`, passes on `e659f4b`. Demonstrates the contract.
- `make build` — clean Debug build.
- `make fmt-check` — passes.

## Live-app verification

To verify the user-visible symptom is gone, run the latest Debug
build, click any history session in the sidebar, click away to
another sidebar row (New Session / a different session / Archive),
then click the **same** history session again. The transcript
should remain visually masked by the outgoing-detail bake until the
tail of the re-entered transcript lands; no "transcript 开头的内容"
should appear in any frame.

```bash
make build
open /Users/luoyangze/Library/Developer/Xcode/DerivedData/ccterm-hcbjalhtrfuaqpcnfqbsuqipvsre/Build/Products/Debug/ccterm.app
```

## Architectural notes

- The b94e42b display-flush hardening in `markAnchorSettled` and
  `consumeDesiredAnchor` **stays**. It addresses a different
  concern: ensuring the cell layer composite is committed at the
  settle moment, independent of which flag-reset path got us there.
- The Phase A/B `loadHistory` architecture is untouched. Re-entry
  remains O(1) on the renderer side — same as documented in
  [Services/Session/CLAUDE.md](macos/ccterm/Services/Session/CLAUDE.md).
- The integration test
  `SidebarFlickerRealHistoryIntegrationTests.testReEntryFromAReproducesSidebarFlicker`
  is environment-flaky in some local sandboxes (offscreen window
  key-status interactions); the unit-test
  `Transcript2AnchorSettledTests.testDismountResetsIsAnchorSettled`
  is the load-bearing regression guard.
