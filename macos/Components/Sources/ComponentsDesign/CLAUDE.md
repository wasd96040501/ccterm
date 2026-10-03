# ComponentsDesign

The style page: every `Components` component on one page, live, as the design sheet lays out its parts. `make design` opens it; `make test-ui FILTER=DesignPageSnapshotTests` renders it off screen.

- `DesignPageViewController` is the page: header, then each `Section` (heading, note, specimens), each `Specimen` a heading over a card. Auto Layout throughout — the column follows the window's width, 1160 at most, centred; the specimens in it don't.
- One `<Family>Specimen` per component family, returning its `Section` with real components built from fixture models. Add the section to `Design.sections()`; the window and the off-screen render both read it.
- Each specimen is its component in the host the app puts it in, at that host's size (`macos/Components/CLAUDE.md`, *The style page*), centred in its card; a host wider than the column is scaled down whole.
