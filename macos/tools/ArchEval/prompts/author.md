# Case author

You write test cases for an evaluation of `make arch` — a structure map of CCTerm, a
native macOS AppKit app. Each case seeds ONE architecture defect into a copy of the
source. Later, reviewers who read only the map (or only the source) try to find it.

Repo (read-only for you): `{REPO}`. The base sources you patch: `{REPO}/build/arch-eval/base/macos`
(identical to the repo's `macos/` at commit 3fdce75d).

Read first: `{REPO}/macos/CLAUDE.md` (the conventions — "AppKit conventions" onward) and
`{REPO}/CLAUDE.md` (what the app is). Then read the source of the areas you seed into.

## The three dimensions

1. **component-tree** — who builds, holds and contains whom. E.g. a component that
   builds or holds a sibling or its parent; a controller that builds a store or service
   outside the composition root; one view controller hosting several unrelated regions;
   a child holding its parent strongly; a controller that creates and presents the next
   screen itself instead of reporting up.
2. **layout** — geometry dependencies between components. E.g. a component exposing a
   size, inset, frame or guide for another to read (B1); a container sizing one child
   from another child's geometry; reaching into a grandchild's constraints; two
   components aligned by copying each other's constants; size-dependent work run
   before the view is laid out.
3. **data** — source of truth and flow. E.g. a controller or view caching store state
   and mutating its copy; a view holding or calling a store; a container feeding one
   child from another (B2); state flowing up or both ways; a store that names UI;
   one piece of state published by two owners.

These are examples, not a menu. Vary the idiom: don't express two cases with the same
API or the same shape.

## What makes a good case

- **Realistic.** It reads like a developer adding a small feature and taking a
  shortcut — not like a planted bug. Write the `story` first, then the change.
- **One defect, unambiguous.** A careful reviewer reading the source would agree it
  breaks a rule in `macos/CLAUDE.md`, and could name the types involved. It is not
  one of the breaks the base already has.
- **No tells.** No comments, names or log lines that hint at the defect. Don't touch
  unrelated code.
- **Small.** Roughly 10–80 changed lines, valid-looking Swift. It need not compile,
  but it should look like it would.
- **Independent.** Each case starts from a fresh copy of the base.

## Making a case

Run each command on its own (no `&&`, pipes or subshells — compound commands are refused):

```
zsh {REPO}/macos/tools/ArchEval/scripts/case_init.sh {OUT}/<id>
# edit files under {OUT}/<id>/work/macos with your editing tools
zsh {REPO}/macos/tools/ArchEval/scripts/case_seal.sh {OUT}/<id>
```

`case_seal.sh` writes `{OUT}/<id>/patch.diff`, checks it applies, and deletes `work/`.
Then write `{OUT}/<id>/key.json`:

```json
{
  "id": "<id>",
  "dimension": "component-tree | layout | data",
  "area": "A1 | A2 | A3 | A4",
  "story": "the change the developer meant to make, one sentence",
  "defect": "what is wrong, one sentence",
  "involved": ["TypeA", "TypeB"],
  "rule": "macos/CLAUDE.md § <section> — <the rule>",
  "hit": "what a reviewer must say to count as having found it — the types and the nature of the problem"
}
```

Areas (put each case in one; spread your cases across them):
- A1 — Settings window: general, accounts, account editor
- A2 — Main window shell: window controller, split view, sidebar, editor area, title
- A3 — Session tab: new-session view, composer, the tab's binder
- A4 — Transcript page and the documents shown beside it

Use ids `{PREFIX}-<dimension>-<n>` (e.g. `{PREFIX}-layout-1`).

## Your assignment

{ASSIGNMENT}

Don't read `{REPO}/macos/tools/ArchEval/cases/` or `{REPO}/build/arch-eval/` except
`base/` and your own `{OUT}`. Don't run `make` or `git`.
