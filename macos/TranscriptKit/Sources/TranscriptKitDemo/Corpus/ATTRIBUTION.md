# Corpus

Real markdown, vendored so `swift run TranscriptKitDemo` needs no network, and
used by `StressCorpus` to build a transcript of arbitrary length.

Real rather than generated, for the same reason `DemoMessage.script` is: what a
cold load has to stay responsive through is *actual* documents — long fenced
code, tables, link-dense prose, deeply nested lists — and generated filler is
uniform in exactly the dimension that decides how expensive a row is to typeset.
Two sources, so the mix is not one author's habits:

| Files | Source | License |
|---|---|---|
| `evolution-*.md` | [swiftlang/swift-evolution](https://github.com/swiftlang/swift-evolution) proposals | Apache-2.0 |
| `tspl-*.md` | [swiftlang/swift-book](https://github.com/swiftlang/swift-book), *The Swift Programming Language* | Apache-2.0 |

Proposals bring tables, blockquotes and dense inline links; the book's chapters
bring headings every few paragraphs and very long code fences. Between them a
row's cost varies by more than an order of magnitude, which is what makes the
chunk timings on the control panel mean anything.

Unmodified — `StressCorpus` splits them at `##` boundaries at runtime rather than
the files being pre-cut, so re-fetching a newer copy is a download and nothing
else. Neither target ships in a product; this directory is the demo executable's
alone.
