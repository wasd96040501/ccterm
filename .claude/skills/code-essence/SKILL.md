---
name: code-essence
description: Distills a system, flow, or subsystem into a minimal, faithful code skeleton written in the project's own language — the smallest piece of real-looking code from which a programmer can see at a glance what happens, calibrated to the reader's existing knowledge. Use when the user wants to understand how some code works and asks for its essence / core / distilled / compressed form rather than a prose explanation or a diagram. Triggers include "show me the essence of X", "compress this flow", "what's the minimal code that captures how Y works", "distill this subsystem".
argument-hint: [what you want to understand]
disable-model-invocation: true
allowed-tools: Read Grep Glob
---

# Code Essence

Programmers don't understand systems by looking at pictures — they read code. A diagram is a lossy translation *out* of the one notation they're fluent in. So when someone wants to understand how some code works, don't draw it and don't narrate it in prose: hand them **code**.

Specifically: the smallest piece of real-looking code, in the project's own language, from which they can see at a glance what happens. Distill the system to its load-bearing spine, then cut everything whose removal wouldn't change the reader's conclusion — and stop one cut before meaning is lost. **One token more is too much; one less is too little.**

But *smallest* is measured against **the reader, not you**. Once you know the code, you can no longer feel what it's like not to — the *curse of knowledge* — so a distillation pitched at your own altitude reads as noise to anyone standing lower. A faithful, perfectly minimal skeleton that the reader can't parse has failed just as hard as a diagram. So this is not a one-shot transmission: find out where the reader stands, aim one rung above *them*, and leave the loop open so they can tell you when a line turns to noise.

## What you produce

A short, faithful code distillation — not pseudocode, not a diagram, not prose. It reads like the real codebase (real type names, real method names, the project's real language), but every incidental line is gone. The reader skims it top to bottom and *gets it*.

## Principles

- **Explain by navigation, not transmission.** You cannot compute the right altitude up front — knowing the code corrupts your sense of not-knowing it. So treat the first distillation as a *probe*: anchor on what the reader already has, aim one rung above *them*, and keep the loop open so they can signal when a line stops landing. Adjust and re-emit. This is the rule the others serve.
- **Faithful, not invented.** Read the actual source first. Use the real identifiers and the true sequence. A distillation with invented names is a lie that reads like truth — worse than useless.
- **The project's language.** Detect the codebase's primary language and emit in it (Swift project → Swift; Go → Go; TS → TS). The reader is fluent in it; meet them there. Never fall back to generic pseudocode.
- **The spine only.** Keep the minimal set of types / calls / edges whose *sequence is the answer* to the one question asked. If removing an element doesn't change the answer, it isn't on the spine.
- **Bodies collapse to one line.** Replace an implementation with a single evocative line or `// …`. Keep a real body only when the body *is* the point (a specific ordering, an invariant, one tricky line).
- **Comments are load-bearing or absent.** Add a comment only where the code can't show the *why* — an invariant, an ordering constraint, a surprising edge, a direction. Never narrate what the next line plainly says.
- **Structure is code, not prose-in-comments.** Express assembly, routing, and relationships with real constructs — constructor calls, `switch`, assignment, type signatures — never with comment lines that *describe* them. A `// A holds B; on X it swaps to C` is narration wearing a code costume: it sidesteps the language (so the reader can't sanity-check it) and quietly invites infidelity (prose can be hand-waved; a call can't). Write the call that does it. The moment you reach for a comment to convey shape, the shape belonged in code.
- **Minimality is relative to the reader, not you.** "One token more is too much" is measured against *this reader's* knowledge. A primitive they don't yet have is load-bearing context for them, even though it's invisible to you; conversely, an anchor an expert doesn't need is itself noise. So the subtraction test is reader-relative: delete each line and ask "does *this reader* now conclude something different?" — not "do I?" If no, it stays deleted.
- **Anchor before you climb.** Build on something the reader is near-certain to already own. The first time a primitive *above* their floor appears, introduce it in one line by analogy to something *below* it, then use the real name from then on. An analogy aimed at knowledge the reader lacks helps nothing.

## What to keep vs. cut

| Keep — load-bearing | Cut — incidental |
|---|---|
| Real type / method names | Error handling, logging, retries (unless they ARE the point) |
| Type relationships & ownership (who holds what) | Boilerplate: inits, protocol conformances, getters/setters |
| Sequence **and direction** of the key operations | Implementation bodies → one line |
| The one invariant that governs each element | Concrete values, formatting, styling |
| The hot path that answers the asked question | Branches off the spine |

## Workflow

1. **Find the reader's floor — calibrate first.** Before distilling, establish what the reader already owns; everything gets built on it. If the request reveals their level (fluent jargon → high floor; "I've never touched X" → low floor), use that. If it's genuinely unknown, ask **one** diagnostic question — never "do you know X?" (yes-biased, zero signal), but a probe whose answer reveals the anchor: *"What's the closest thing you've built — a web frontend? a CLI? — so I can anchor on it?"* Do not guess silently and aim high; the curse of knowledge guarantees you will.
2. **Pin the question.** What exactly does the reader want to see — a lifecycle? a data flow? a control path? an ownership graph? A distillation answers *one* question; scope to it.
3. **Read the real code.** Grep and read the actual source. Note the real names and the true ordering. Faithfulness is non-negotiable — do not distill from memory or guesswork.
4. **Find the spine.** The minimal set of elements whose sequence is the answer. Discard anything whose removal leaves the answer intact.
5. **Distill — at one rung above the floor.** Write it in the project's language, ordered as a narrative. Anchor on what the reader has; introduce each primitive above their floor once, by analogy, before using its real name. Aim one level above where the reader stands — not at your own altitude (high two rungs = noise; level = nothing learned). Collapse bodies, keep only load-bearing comments.
6. **Subtract — relative to this reader.** Apply the reader-relative subtraction test to every line. Stop when one more cut would lose meaning *for them*.
7. **Leave the loop open.** You can't confirm the altitude was right without the reader's signal, so invite it (see Output), and be ready to re-emit one rung higher or lower.

## Worked example

**Question:** "How does a `POST /orders` request get persisted?" *(project language: TypeScript)*

The real handler sprawls across ~80 lines: a router with middleware, a try/catch, Zod parsing, a logger, a DTO mapper, a repository, transaction plumbing, an event bus, metrics. The spine is four steps:

```ts
router.post("/orders", auth, async (req, res) => {
  const order = OrderSchema.parse(req.body);                 // bad input rejected here, nowhere else
  const saved = await db.tx(t => orders.insert(t, order));   // one transaction == the atomic boundary
  events.emit("order.created", saved);                       // every downstream effect hangs off this
  res.status(201).json(saved);
});
```

Cut: the logger, the metrics, the DTO mapper (a field rename), the try/catch (a generic error middleware handles it). Each was removed because knowing it exists doesn't change *how an order gets persisted* — validate, one transaction, emit, respond.

## Output

Lead with the distilled code block(s) — the code is the deliverable, not its description. Keep framing prose to a sentence or two. If an elision needs a legend, give it one line. If the system has genuinely separable facets (e.g. structure vs. control flow vs. data flow), use a small number of short blocks, each a "scene," rather than one block that mixes concerns.

**Close the loop.** End by making the reader's level observable: invite them to point at the first line that stopped making sense, and offer to re-emit one rung higher (terser, fewer anchors — for an expert) or one rung lower (lower floor, more anchors). The first distillation is a probe, not the final answer.
