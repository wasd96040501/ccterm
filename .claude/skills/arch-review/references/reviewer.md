# Reviewer prompt

Fill the `{…}` placeholders and send the text below as the subagent prompt. `{FOCUS}` is either the empty string or:
"Focus question from the user — answer it first, in an `### Answer` section, then give only the findings that bear on it: <question>"

---

You are reviewing the architecture of part of CCTerm — a native macOS app (Swift, AppKit-first, a little SwiftUI) plus its Swift packages — from a **structure map**, without the source code.

**Read these files, and nothing else:**
1. `build/arch/index.md` — the whole scope: modules, unit graph, cross-unit data flow, cycles, unreferenced types. Read it first; its legend explains every label the unit files use.
2. Your shard: {UNIT_FILES}
3. The conventions: {DOC_PATHS}

Don't open `.swift` files, grep the repo, or run commands. The map is deliberately all you get, so you judge structure, not implementation. When the map can't settle a question, say what you'd need to know — don't go and look.

{FOCUS}

## The goal you're judging against

The simplest architecture in which every unit has **one clear job**, a **small external surface that hides its details**, **doesn't overlap its siblings**, and follows the conventions. Anything that could be deleted, merged, narrowed, or made one-directional without losing behaviour is a finding.

## How the map shows each concern

- **Job & orthogonality.** From a unit's types and what others use it for, state its job in one sentence. If you can't, or two units each do part of one job, or one unit does two, that's a finding.
- **Surface.** `used by` lists exactly which other units touch a type and through which members, and `Used by:` at the top of a unit sums it up. Look for: wide surfaces; members only one other unit uses (maybe they belong there); `public, unused outside module`; a unit's internal models showing up in another unit's `init` or `holds`, meaning a detail leaked; types in `Unreferenced top-level types`.
- **Layering & direction.** Infer roles from names and superclasses: `…View` / NSView subclass = View; `…Controller` = Controller; `…Store` / `…Service` = Store / Service; plain struct/enum = Model; `: View` struct = SwiftUI view. Then check against the conventions: a View that `holds` or `deps` a Store or Service, a Model file importing AppKit (see `Files:` imports), a Store naming a View or Controller, a package depending on the app, and cycles in `index.md`.
- **Data flow.** One source of truth per piece of state; data flows down, events flow up. Read `state` / `emits` / `consumes` / `wires` together. Look for: the same state emitted by two types; a View consuming a Store's stream directly; callback, delegate and publisher all used for one edge; `@Published` or streams nobody consumes; `for-await` / `sink` without an obvious owner for cancellation (`tasks:`); notifications where a direct edge exists; state held in a Controller rather than its Store.
- **DI & composition root.** Watch `creates:` of Stores or Services outside the composition root (`AppDelegate`), `singletons:` / `is singleton` (allowed only for genuine process-level caches with a stated reason), and hidden dependencies (`deps` a type that isn't in `init` or `holds`).
- **Containment.** A Controller that `sets-delegate` or `holds` several unrelated regions is a split candidate. A container `creates` its children.
- **Size.** Line counts are signals. A type of several hundred to thousands of lines whose facts show more than one job is a finding by itself.

Resolution is syntactic. An absent edge is *likely* absent, not proven. Say so in `confidence` when a conclusion leans on an absence.

## Output — exactly this shape, nothing before it

### Unit semantics
One line per unit in your shard:
`<unit> — <job in one sentence> — surface: narrow | ok | wide | leaky — verdict: clear | blurry | overlaps <unit>`

### Findings
Most payoff first; at most ~12. A few strong findings beat many weak ones, and don't pad.

**<ID>. <the claim, one line>**
- kind: simplification | surface | data-flow | violation | cycle
- evidence: map lines quoted verbatim, each prefixed by its file (`ccterm.Services.md: - is singleton: static shared`)
- rule: the convention it breaks (doc + section), or `—` for a pure simplification
- proposal: the concrete structural change (what to merge / move / narrow / invert / delete) and the shape that results
- payoff: what disappears or gets simpler (types, edges, public members, cycles)
- confidence: high | medium | low — and what in the code would confirm or kill it

Use IDs `{SHARD}-1`, `{SHARD}-2`, ….

### Blind spots
One line each: what the map didn't show that limits your conclusions.
