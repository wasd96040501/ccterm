# ComponentsDesign

The style page: every `Components` component on one page, live, as the design sheet lays out its parts. `make design` opens it; `make test-ui FILTER=DesignPageSnapshotTests` renders it off screen.

- `DesignPageViewController` is the page: header, then each `Section` (heading, note, specimens), each `Specimen` a heading over a card. Auto Layout throughout — the column follows the window's width, 1160 at most, centred.
- One `<Family>Specimen` per component family, returning its `Section` with real components built from fixture models. Add the section to `Design.sections()`; the window and the off-screen render both read it.
- A specimen whose component has no height of its own (a scroll view) gives its card one; every other card takes its component's fitting height.
