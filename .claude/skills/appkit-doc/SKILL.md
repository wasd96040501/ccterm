---
name: appkit-doc
description: Look up an AppKit symbol's authoritative documentation — class overview, every property/method with its meaning, and a single member's full declaration, parameters, and discussion — straight from Apple's official DocC data. Use this WHENEVER you're writing, reviewing, or reasoning about AppKit code and need to be sure about a symbol: what a class is for, what fields/methods it has and what each does, a method's exact signature and parameters, a property's default value, or which enum case to pass. Reach for it instead of recalling from memory any time you touch an NS-prefixed AppKit type (NSStackView, NSViewController, NSTableView, NSView, NSResponder, NSWindow, …) and there's any doubt about a name, signature, default, or behavior. Prefer this over guessing or web search — it returns first-party Apple docs as clean Markdown.
---

# AppKit symbol lookup

CCTerm is pure AppKit. When you touch an AppKit type and aren't 100% sure of a
name, signature, default, or behavior, look it up instead of guessing — a wrong
selector or a misremembered default silently compiles into a bug. This skill
pulls the answer from Apple's own documentation data.

## How to use it

One command, driven through the project's `make` entry point:

```bash
make appkit-doc SYMBOL=<Class>            # class overview + all members
make appkit-doc SYMBOL=<Class>.<member>   # one member's full docs
```

The output is Markdown printed to stdout — read it directly.

### Two query shapes, two purposes

**Class query** — `SYMBOL=NSStackView`. Use when you're orienting: "what is this
class, and what does it offer?" You get the class abstract, the full Overview /
Discussion prose, availability, and **every property and method grouped under
Apple's own topic headings, each with a one-line summary**. This is how you
discover which member you need.

**Member query** — `SYMBOL=NSStackView.orientation` or
`SYMBOL=NSStackView.setCustomSpacing`. Use when you know the member and need the
detail: the **exact Swift declaration**, each **parameter explained**, the
multi-paragraph **Discussion** (defaults, edge cases, exceptions), and a
**See Also** list of related members to pivot to. This is what you cite before
writing the call.

The member name is the bare Swift name — `orientation`, `addSubview`,
`setCustomSpacing`. You don't need the argument signature; the tool resolves
`setCustomSpacing` to `setCustomSpacing(_:after:)` on its own. Passing the full
signature also works if you already have it.

## Typical flow

Orient with a class query, then drill into the member you landed on:

```bash
make appkit-doc SYMBOL=NSStackView                 # → sees `distribution`, `spacing`, `setVisibilityPriority`…
make appkit-doc SYMBOL=NSStackView.distribution    # → enum cases, defaults, discussion
```

If you already know the member, skip straight to the member query.

## Notes

- **Only AppKit symbols.** The tool is scoped to the AppKit framework. It won't
  resolve Foundation (`NSString`), SwiftUI, or Combine types.
- **Names are case-sensitive** and match Apple's spelling: `NSStackView`, not
  `nsstackview` or `NSStackview`. If a class query returns "no symbol," fix the
  capitalization. If a member query says "no member," run the class query first
  and read the exact member name off the member list.
- **First-party, cached.** Output is Apple's official DocC data, cached under
  `/tmp` — so repeat lookups of the same symbol are instant. The cache is
  disposable (cleared on reboot) and refills on the next fetch.
