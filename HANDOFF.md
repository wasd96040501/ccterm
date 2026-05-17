# HANDOFF — input-bar picker UX alignment

The previous session shipped a partial fix that the user rejected as
"狗屎代码" because it made up its own UX decisions instead of mirroring
Claude.app. **The work on the model / effort / fast-mode / permission
pickers and the model-loading lifecycle is NOT done.** Pick it up from
here. The branch is `claude/loving-noyce-6b2731`; the last commit is
`wip(input-bar): de-translate picker labels, decouple model load, partial UX`.

## ⛔ Non-negotiable: reverse Claude.app BEFORE writing code

The user's exact words:

> 不是，你他妈的逆向 Claude.app 了吗？你他妈的直接就开始写？啥意思啊
>
> 我求你，你先列好，要对齐的预期行为是什么，然后再去写代码行不行啊。我求你了

Do not write a single line of picker code until you have looked at
Claude.app's renderer source. It's an Electron app on disk:

- App bundle: `/Applications/Claude.app`
- Source archive: `/Applications/Claude.app/Contents/Resources/app.asar`
- Unpack: `npx asar extract /Applications/Claude.app/Contents/Resources/app.asar /tmp/claude-app-extract`
  (or `asar` if installed globally)
- Renderer JS lives under `/tmp/claude-app-extract/.vite/renderer/main_window/assets/*.js` —
  search for `Permission`, `Effort`, `FastMode`, `ModelInfo`, `Default (recommended)`,
  etc. Minified but readable. Pretty-print with `prettier` if needed.
- Useful greps once extracted:
  - `grep -rln 'fastMode' /tmp/claude-app-extract`
  - `grep -rln 'supportedEffortLevels' /tmp/claude-app-extract`
  - `grep -rln 'Bypass permissions' /tmp/claude-app-extract`
  - color tokens often live in CSS / inline-style classes; search for
    `text-` / `--color-` near the strings above.

The user already shared two screenshots showing the picker open with
"Opus 4.7 1M · Extra high" selected (Claude.app reference) vs. our
broken-rendering version showing "Default · Extra high". Both screenshots
should still be in the prior conversation transcript. Match the
reference visually AND behaviorally.

**After you've read the relevant Claude.app source, write up the
expected behavior in this file (replace the "Open work items" section
below with concrete spec). Get the user's nod on the spec before
touching Swift.**

## What the previous session changed (and that's STILL in)

Committed in `98ad3bd`:

- `Models/PermissionMode.swift` — `title` / `shortTitle` returns raw
  English literals (no `String(localized:)`).
- `Models/Effort+Display.swift` — same: `title` is raw English.
- `Content/Chat/InputBarControls/ModelEffortPicker.swift`:
  - All in-popover labels ("Models" / "Effort" / "Fast mode" /
    "Enable fast mode" / "Default" / "Loading models…") are bare
    English literals.
  - `FastModeToggleRow` is now a whole-row `Button` so the click
    target isn't just the tiny `.switch`.
  - `resolveCurrentModel(value:in:)` static helper falls back to the
    first model when `handle.model` is nil (so feature-flag lookups
    don't read as "disabled by default").
  - Row taps for model / effort close the popover; toggle for fast
    mode keeps it open.
- `Content/Chat/InputBarControls/PermissionModePicker.swift` — popover
  section header is bare English literal.
- `Services/Session/SessionHandle2/SessionHandle2+Start.swift`
  bootstrap no longer pushes `initResp.models` into
  `ModelStore.shared`. Per-session `availableModels` snapshot is
  retained.
- `App/CCTermApp.swift` — `ModelStore.shared.prefetchIfNeeded()`
  invoked via `MainActor.assumeIsolated` instead of `Task { ... }` so
  it kicks off immediately on `init()`.
- `Localizable.xcstrings` — removed the strings the previous session
  had added for the picker; restored the `extractionState: "stale"`
  flag on existing keys (`Auto` / `High` / `Low` / `Medium` / `Max` /
  `Plan`).
- Tests:
  - `cctermTests/InputBarLabelsTests.swift` — pins permission /
    effort labels to their English literals.
  - `cctermTests/ModelEffortPickerResolverTests.swift` — covers the
    nil / unknown / exact / empty resolver cases.

All 39 unit tests pass; `make build` is clean.

## ❌ What is wrong / pending (verbatim from the user)

These are what the user yelled at the previous session about. They
are the alignment gaps — NOT a free hand to redesign. Treat each as a
question to answer by reading Claude.app.

1. **Model load on launch isn't observable.**
   > 你他妈的，在 app 启动的时候刷 model 了吗？他妈的我怎么看到没刷啊

   `ModelStore.prefetchIfNeeded()` short-circuits when the on-disk
   cache has any entries:
   `guard models.isEmpty, !isLoading else { return }`. The user
   expects a launch-time refresh every time. Behavior to design:
   when does Claude.app refetch the model list? Always at launch?
   On a TTL? Inspect.

2. **Effort + Fast mode must follow the active model.**
   > fast mode 以及 effort 的枚举都是绑定 model 的，这个你做了吗？

   `ModelEffortPopoverContent.supportedEffortLevels` and
   `fastModeSupported` are wired to the popover's
   `selectedModelValue`, which is `handle.model` (and falls back to
   first via the resolver). Confirm against Claude.app:
   - When no model is explicitly selected, what's the source of
     truth for effort / fast availability?
   - Does Claude.app auto-set `handle.model` once the catalog arrives,
     or keep it nil?

3. **Fast mode is permanently disabled in the current build.**
   > fast 现在还是无法选中，整个被置灰了，啥意思？

   The resolver returns the first catalog entry, which appears to be
   the CLI's "Default (recommended)" pseudo-model — and that entry
   reports `supportsFastMode == false`. Either filter the meta-entry
   out (probable, see #4) or resolve it to its underlying real model
   for feature-flag lookup. **Claude.app's behavior is the
   reference, not a guess.**

4. **Trigger shows "Default" instead of the real model.**
   > opus 就是 opus，你他妈的渲染成 default，什么狗屎玩意

   See the second screenshot the user posted: trigger reads
   `Default · Extra high` when the real default is Opus 4.7. The CLI's
   `models[]` includes a `value: "default"` entry with displayName
   `"Default (recommended)"` (or similar). Claude.app's reference
   screenshot has 5 rows (Opus 4.7 / Opus 4.7 1M / Sonnet 4.6 /
   Haiku 4.5 / Opus 4.6 Legacy) and the checkmark is on `Opus 4.7
   1M`. **Confirm via Claude.app source whether the meta-entry is
   hidden, or whether it's resolved to the underlying model**, and
   how the underlying model is identified.

5. **Variant suffixes (1M / Legacy) read as dim secondary.**

   See screenshot: `Opus 4.7 1M` renders with "1M" in a lower-contrast
   grey, and `Opus 4.6 Legacy` similarly. The session added a draft
   `ModelInfo.displayParts` helper but it's **not wired into the
   picker rows yet**. Confirm the exact list of dim markers from
   Claude.app source — don't enumerate them by guess.

6. **Permission-mode tint palette is made up.**
   > permission 的颜色你要对齐啊，别他妈的自己瞎几把编一个颜色

   `PermissionModePicker.modeTint` currently maps:

   | Mode | Current code | Source |
   |---|---|---|
   | `.default` / `.acceptEdits` / `.plan` | `.secondary` | invented |
   | `.auto` | `.accentColor` | invented |
   | `.bypassPermissions` | `.red` | invented |

   Replace with Claude.app's actual palette. Likely each mode has its
   own hex token in the renderer CSS. Grep for `bypassPermissions` or
   `plan` near color values.

7. **Context ring must always render — user does NOT want it hidden when empty.**
   > context ring 为空的时候，你他妈的怎么就不渲染了呢？你不要擅自做决策

   `Content/Chat/InputBarControls/ContextRingButton.swift` currently has

   ```swift
   if handle.contextWindowTokens > 0 {
       Button(...) { ProgressRingView(percent: percent) ... }
   }
   ```

   Drop the guard — always render. Decide what "empty" looks like
   (zero ring? dashed outline? "—"? Claude.app's empty state is the
   reference).

## Process the user requires

1. **Reverse-engineer Claude.app's renderer**. Don't paraphrase from
   memory or guess.
2. **Write the expected-behavior spec in this file**, replacing
   "Open work items" with a concrete spec keyed off Claude.app's
   actual behavior. Cite the file/line in `app.asar` where each rule
   came from.
3. **Wait for the user to confirm the spec**, then implement.
4. Run `make fmt && make test-unit && make build && open <built app>`
   after each change.
5. Snapshot tests live in `cctermTests` but `.task` does NOT fire
   reliably under offscreen `NSHostingController` — don't try to
   capture state-transition snapshots that way. See
   `cctermTests/CLAUDE.md` § "Snapshot tests".

## Files / hot spots

| Area | Path |
|---|---|
| Permission picker | [PermissionModePicker.swift](macos/ccterm/Content/Chat/InputBarControls/PermissionModePicker.swift) |
| Model / effort / fast-mode picker | [ModelEffortPicker.swift](macos/ccterm/Content/Chat/InputBarControls/ModelEffortPicker.swift) |
| Context ring button | [ContextRingButton.swift](macos/ccterm/Content/Chat/InputBarControls/ContextRingButton.swift) |
| Chrome row composition | [InputBarSessionChrome.swift](macos/ccterm/Content/Chat/InputBarControls/InputBarSessionChrome.swift) |
| Model display helpers | [ModelInfo+Display.swift](macos/ccterm/Models/ModelInfo+Display.swift) — has draft `isDefaultMeta` + `displayParts` (uncommitted intent, currently committed but unused) |
| Effort display | [Effort+Display.swift](macos/ccterm/Models/Effort+Display.swift) |
| Permission mode model | [PermissionMode.swift](macos/ccterm/Models/PermissionMode.swift) |
| Model store + prefetch | [ModelStore.swift](macos/ccterm/Services/ModelStore.swift) |
| App entry / prefetch trigger | [CCTermApp.swift](macos/ccterm/App/CCTermApp.swift) |
| Session bootstrap (no longer touches store) | [SessionHandle2+Start.swift](macos/ccterm/Services/Session/SessionHandle2/SessionHandle2+Start.swift) |
| Tests added this session | [InputBarLabelsTests.swift](macos/cctermTests/InputBarLabelsTests.swift), [ModelEffortPickerResolverTests.swift](macos/cctermTests/ModelEffortPickerResolverTests.swift) |

## Reference data — what the user showed last time

Two screenshots (full-pixel, in transcript) of the model picker open:

- Claude.app reference: 5 rows (`Opus 4.7`, `Opus 4.7 1M` ✓,
  `Sonnet 4.6`, `Haiku 4.5`, `Opus 4.6 Legacy`); "1M" and "Legacy"
  render in dim grey. Effort section has `Low / Medium / High /
  Extra high ✓ / Max`. Fast mode toggle row reads "Enable fast mode"
  with the switch greyed (because Opus 4.7 1M doesn't support it).
  Keyboard shortcut chips visible: `⇧⌘I` for Models, `⇧⌘E` for
  Effort, `1`–`5` for rows.
- Our app, broken: 3 rows (`Default` ✓, `Sonnet`, `Haiku`); no
  versions, fast mode permanently greyed, trigger reads
  `Default · Extra high`.

The user's CLI command echo (`/model claude-opus-4-7`,
`/model claude-opus-4-7[1m]`, etc.) suggests model `value`s carry the
full IDs (`claude-opus-4-7`, `claude-opus-4-7[1m]`, ...) and the
displayName may or may not include the version depending on CLI
version.

## Out-of-scope warnings

- **Don't touch session bootstrap / history / transcript code** —
  the previous session also looked at "first message disappears on
  switch-away-and-back" and the user said it's not this session's
  issue (`4 应该不是这次的问题，你先忽略`).
- **Don't add new feature flags / abstractions / "freeze popover
  width" modifiers.** The previous session tried that
  (`PopoverAnchorPin`) and was told it sacrificed UX. Click-to-close
  is the resolution; keep it. See `ModelEffortPicker` callbacks.
- **Don't re-introduce `String(localized:)` for picker labels.** They
  are CLI vocabulary and the user wants them in English verbatim.
- **No `forceXxxForTest()` seams or `#if DEBUG` UI branches.** See
  `CLAUDE.md` § Engineering principles.
