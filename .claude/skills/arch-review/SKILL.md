---
name: arch-review
description: Review CCTerm's architecture from its structure map (`make arch`), not its source — parallel Opus reviewers that each read only the map for one part and judge whether units have one clear job, a narrow orthogonal surface that hides their details, sound data flow (@Published, AsyncStream, @Observable, callbacks, delegates), the AppKit conventions, and what can be simplified or deleted. Use whenever the user wants an architecture review or audit, asks whether a module / feature / layer is designed right or over-complicated, wants simplification or decoupling ideas, asks if code follows our conventions (规范), or says things like 架构评审, 架构合不合理, 能不能简化, 模块边界, 职责清不清晰 — even without naming this skill. Scope defaults to the core (app + package libraries); any module, directory or unit can be named.
---

# Architecture review from the structure map

Reviewers see only `make arch`'s map — never the Swift source. That is the point: the map carries exactly the architecture (who depends on whom, what flows where, what each unit exposes and to whom), so a reviewer judges structure instead of drifting into line-level nitpicks, and a whole module fits in one reviewer's head.

## 1. Read the request

- **Scope** — default `core` (app + every package library). Translate the user's words into a `SCOPE` for `make arch`: `app`, `kit` (TranscriptKit, TranscriptMedia, TranscriptWorkspace), `sdk` (AgentSDK), a path, a unit as the map names it (`AgentSDK/Session`), or a bare directory name (`sidebar`). Several → comma-separated.
- **Model** — reviewers run on `opus` unless the user names another model. Judging a module's boundaries takes the strongest model available; don't pick `sonnet` or `haiku` on your own. Honour an explicit user choice.
- **Focus** — if the user asked a specific question ("should LibraryStore be split?", "is TranscriptWorkspace's API clean?"), carry it verbatim as the focus question. Otherwise it's a full review.

## 2. Build the map

```bash
make arch SCOPE=<scope>
```

It rewrites `build/arch/` from the working tree every time, so always run it — never trust a map left over from earlier. Then read `build/arch/index.md` yourself (small: modules, unit table, cross-unit data flow, cycles, unreferenced types) and `wc -c build/arch/*.md` for unit file sizes. Don't read the unit files and don't read source — you're the coordinator, and the reviewers' independence from the code is what makes the review useful.

## 3. Plan shards

A shard is the set of unit files one reviewer reads.

- **Keep a module's units in one shard.** The module is the boundary whose surface and orthogonality are being judged; split it and nobody sees it whole. Only a module over ~45 KB of unit files gets split, along its top-level directories.
- **~45 KB of unit files per shard at most**; small modules share a shard with their closest neighbour (TranscriptMedia and TranscriptWorkspace go with TranscriptKit).
- **Count:** `core` → 3 (app · TranscriptKit family · AgentSDK). A scope under ~45 KB → 1 reviewer. More than 4 only if the user asks — each extra reviewer re-reads the index and the conventions, and adds a boundary no single reviewer sees.

Tell the user the plan in one line (shards, model), then launch.

## 4. Launch reviewers

Launch every reviewer in **one message** so they run in parallel: `subagent_type: "general-purpose"`, `model: <model>`, prompt = [references/reviewer.md](references/reviewer.md) with its placeholders filled.

Convention docs to hand each reviewer (docs, not code — they define "our conventions"):

| Shard contains | Docs |
|---|---|
| anything | `macos/CLAUDE.md` — the "AppKit conventions" part (skip the runloop tick model) |
| TranscriptKit / TranscriptMedia / TranscriptWorkspace | `macos/TranscriptKit/CLAUDE.md` + `macos/TranscriptKit/Sources/<Target>/CLAUDE.md` for each target in the shard |
| AgentSDK | `macos/AgentSDK/CLAUDE.md` |

## 5. Synthesize

When every reviewer has returned:

1. **Merge and dedupe** — findings about the same types or edge become one; keep the strongest evidence.
2. **Cross-shard pass (yours)** — using only `index.md`: link findings that meet at a boundary (the app over-consuming a package surface its reviewer called wide), and add system-level ones no shard owns — module import direction, unit cycles, unreferenced types, the same concept modelled in two modules.
3. **Filter** — drop findings whose evidence doesn't quote the map, and ones that restate a rule without a concrete change.
4. **Rank** by payoff (types, edges, public members, cycles that disappear) × confidence.

## 6. Report

Write the report to `build/arch/review.md` (it describes that exact map, and goes when the map is regenerated):

```markdown
# Architecture review — <scope> @ <commit from index.md>
<N> reviewers × <model> · map: build/arch/

## Answer            ← only when there was a focus question: the direct answer first
## Top changes       ← at most 5: the change, its payoff, units touched, confidence
## Unit semantics    ← table: unit | job in one sentence | surface | verdict (clear / blurry / overlaps X)
## Findings          ← grouped: Simplification · Surface & orthogonality · Data flow · Convention violations · Cycles
                       each: claim, evidence (quoted map lines), rule, proposal, payoff, confidence + how to confirm in code
## Blind spots       ← what the map couldn't show that would change a conclusion
```

Then reply in the terminal with the answer (if any), the top changes, and the report path. Offer once to verify chosen findings against the source — that's a separate step the user opts into, because every finding here is inferred from structure alone.
