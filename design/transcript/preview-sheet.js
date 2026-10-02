// Transcript views — the sheet: sample content (a session in this repo), the
// playground window and its split, the live replay, and every specimen.
"use strict";

// MARK: - Sample content

const TV = "macos/TranscriptKit/Sources/TranscriptKit/TranscriptView.swift";
const TVT = "macos/TranscriptKit/Tests/TranscriptKitTests/TranscriptViewTests.swift";
const TEST_CMD = "cd ~/dev/ccterm && make test-kit FILTER=TranscriptViewTests";

const TV_DIFF = [
  ["fold", "319 lines"],
  ["ctx", 320, "    /// get half of it against the document's edges. Two consequences worth"],
  ["ctx", 321, "    /// knowing before reading a number out of `rect(ofRow:)`: a row rect is its"],
  ["ctx", 322, "    /// content plus this, and a `scrollToRow` position lands that rect, so"],
  ["ctx", 323, "    /// `.bottom` leaves the half gap showing below the row."],
  ["del", null, "    ⟦private static let⟧ rowSpacing: CGFloat = 14"],
  ["add", 324, "    ⟦public var⟧ rowSpacing: CGFloat = 14 ⟦{⟧"],
  ["add", 325, "        didSet { tableView.intercellSpacing = NSSize(width: 0, height: rowSpacing) }"],
  ["add", 326, "    }"],
  ["ctx", 327, ""],
  ["ctx", 328, "    private lazy var tableView: TranscriptTableView = {"],
  ["ctx", 329, "        let table = TranscriptTableView()"],
  ["ctx", 330, "        table.headerView = nil"],
  ["ctx", 331, "        table.backgroundColor = .clear"],
  ["del", null, "        table.intercellSpacing = NSSize(width: 0, height: ⟦Self.⟧rowSpacing)"],
  ["add", 332, "        table.intercellSpacing = NSSize(width: 0, height: rowSpacing)"],
  ["ctx", 333, "        table.usesAutomaticRowHeights = false"],
  ["ctx", 334, "        table.selectionHighlightStyle = .none"],
  ["ctx", 335, "        return table"],
  ["fold", "577 lines"],
];
const TVT_DIFF = [
  ["fold", "84 lines"],
  ["ctx", 85, "    func testRowsAreRowSpacingApart() {"],
  ["ctx", 86, "        let (view, _) = mountTranscript(rows: 2)"],
  ["ctx", 87, "        let gap = view.rect(ofRow: 1).minY - view.rect(ofRow: 0).maxY"],
  ["del", null, "        XCTAssertEqual(gap, ⟦TranscriptView⟧.rowSpacing)"],
  ["add", 88, "        XCTAssertEqual(gap, ⟦view⟧.rowSpacing)"],
  ["ctx", 89, "    }"],
  ["ctx", 90, ""],
  ["ctx", 91, "    func testRowSpacingChangeRelaysOut() {"],
  ["fold", "253 lines"],
];
const FAIL_OUT = [
  "Building for debugging...",
  "[1/6] Write swift-version--58304C5D6DBC2206.txt",
  "[3/6] Compiling TranscriptKitTests TranscriptViewTests.swift",
  "TranscriptViewTests.swift:88:44: error: 'rowSpacing' is inaccessible due to 'private' protection level",
  "        XCTAssertEqual(gap, TranscriptView.rowSpacing)",
  "                                           ^",
  "TranscriptView.swift:324:24: note: 'rowSpacing' declared here",
  "error: fatalError",
  "make: *** [test-kit] Error 1",
];
const PASS_OUT = [
  "Building for debugging...",
  "Build complete! (4.12s)",
  "Test Suite 'Selected tests' started at 2026-09-29 11:42:07.114.",
  "Test Suite 'TranscriptViewTests' started at 2026-09-29 11:42:07.115.",
  "Test Case '-[TranscriptKitTests.TranscriptViewTests testAnchorSurvivesPrepend]' passed (0.412 seconds).",
  "Test Case '-[TranscriptKitTests.TranscriptViewTests testRowSpacingChangeRelaysOut]' passed (0.207 seconds).",
  "Test Case '-[TranscriptKitTests.TranscriptViewTests testRowsAreRowSpacingApart]' passed (0.198 seconds).",
  "…",
  "Test Suite 'TranscriptViewTests' passed at 2026-09-29 11:42:25.344.",
  "\t Executed 42 tests, with 0 failures (0 unexpected) in 18.214 (18.230) seconds",
];
const READ_CODE = `    /// The gap between two rows.
    ///
    /// A row's box is exactly its content — a document's first paragraph starts
    /// at the top edge and a hosted bubble ends at the bottom one — so nothing
    /// inside a row contributes to the gap, and the table adds all of it.
    ///
    /// Wider than the 12 two paragraphs of one document sit apart
    /// (\`MarkdownBlockBuilder.blockSpacing\`), because a row boundary is where
    /// the speaker changes and the hard-edged things that live in rows —
    /// bubbles, cards, images — have no glyph leading around them to read as
    /// part of the gap.
    ///
    /// \`NSTableView\` splits it — the cell sits centred in a row rect this much
    /// taller, so consecutive rows are \`rowSpacing\` apart and the first and last
    /// get half of it against the document's edges.
    private static let rowSpacing: CGFloat = 14

    private lazy var tableView: TranscriptTableView = {
        let table = TranscriptTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        table.usesAutomaticRowHeights = false
        table.selectionHighlightStyle = .none
        return table
    }()`;
const NEW_CODE = `import AgentSDK
import Foundation

/// The sentence a run row reads: a verb and a count per kind of work, in a
/// fixed order, three at most.
nonisolated struct RunSummary: Equatable {
    var clauses: [Clause]
    var failed: Int
    var denied: Int

    enum Clause: Equatable {
        case edited([String], count: Int)
        case created([String], count: Int)
        case ran(commands: Int)
        case read([String], count: Int)
    }

    init(calls: [ToolUseBlock], outcomes: [String: Bool]) {
        clauses = []
        failed = outcomes.values.filter { !$0 }.count
        denied = 0
    }

    /// Files are named when there are two or fewer.
    static let namedFileLimit = 2
    static let clauseLimit = 3
}`;

// The playground session.
const a1 = grep("rowSpacing", "macos/TranscriptKit", 4, { matches: [[TV, 3], [TVT, 2], ["macos/TranscriptKit/Sources/TranscriptKit/TranscriptTableView.swift", 1], ["macos/cctermTests/EditorAreaTests.swift", 1]] });
const a2 = read(TV, 300, 325, 912, { code: READ_CODE });
const a3 = read(TVT, 1, 120, 344, { code: "import XCTest\n@testable import TranscriptKit\n\n@MainActor\nfinal class TranscriptViewTests: XCTestCase {\n    // …" });
const b1 = edit(TV, 4, 2, { diff: TV_DIFF });
const b2 = bash("Build the package", "cd ~/dev/ccterm && swift build --package-path macos/TranscriptKit", { dur: 6, out: ["Building for debugging...", "[4/9] Compiling TranscriptKit TranscriptView.swift", "Build complete! (5.87s)"] });
const b3 = bash("Run the TranscriptView tests", TEST_CMD, { state: "failed", exit: 2, dur: 14, out: FAIL_OUT, error: FAIL_OUT[3] });
const b4 = edit(TVT, 1, 1, { diff: TVT_DIFF });
const b5 = bash("Run the TranscriptView tests", TEST_CMD, { dur: 21, out: PASS_OUT });
const b6 = bash("Build the demo app", "swift build --package-path macos/TranscriptKit --product TranscriptKitDemo -c release", {
  bgDur: "2m 4s", dur: 124, out: ["Building for production...", "[212/214] Linking TranscriptKitDemo", "Build complete! (124.02s)"],
});
const agentSub = { id: nid("sub"), docKind: "transcript", title: "Find hard-coded row gaps", rows: () => [
  { type: "user", text: "Find every place in the repo that hard-codes the transcript's 14-pt row gap." },
  { type: "run", run: run([grep("14", "macos", 23, { matches: [] }), read("macos/cctermTests/EditorAreaTests.swift", 60, 140, 402, { code: "" }), grep("rowSpacing", "macos", 4, { matches: [] })], { dur: 38 }) },
  { type: "text", text: "One test hard-codes it: `EditorAreaTests.testATabAppearsAtItsFinalSize` compares a row rect to `rowHeight + 14`." },
] };
ITEMS.set(agentSub.id, agentSub);
const c1 = agentCall("Find hard-coded row gaps", "Explore", 9, 71, {
  sub: agentSub.id,
  result: "One place hard-codes the gap outside `TranscriptView`:\n\n- `macos/cctermTests/EditorAreaTests.swift:118` — `XCTAssertEqual(rect.height, rowHeight + 14)`\n\nEverything else reads `rowSpacing`. The test checks the default, so it stays correct as long as the default is 14.",
});
const shell1 = bash(null, "git status --short", { local: true, dur: 0, out: [" M macos/TranscriptKit/Sources/TranscriptKit/TranscriptView.swift", " M macos/TranscriptKit/Tests/TranscriptKitTests/TranscriptViewTests.swift", "?? design/transcript/", "?? macos/ccterm/Content/Transcript/RunSummary.swift"] });
const newsBuild = { id: nid("n"), kind: "news", task: "command", status: "completed", summary: "Background command “Build the demo app” completed (exit code 0)", meta: "2m 4s", origin: b6.id };
ITEMS.set(newsBuild.id, newsBuild);
const compactDoc = { id: nid("d"), docKind: "markdown", title: "Summary", docGlyph: "other", status: "What the model continued from · 14k tokens", md: "This session is being continued from a previous conversation that ran out of context.\n\n**Primary request.** Make the transcript's row gap configurable, keep the default at 14 pt, and keep the tests green.\n\n**Done.** `TranscriptView.rowSpacing` is a public instance property whose `didSet` re-applies `intercellSpacing`. `TranscriptViewTests` reads it from the view. A release build of the demo succeeded.\n\n**Open.** The user asked to make tool rows one step smaller than body text." };
ITEMS.set(compactDoc.id, compactDoc);

function playgroundRows() {
  return [
    { type: "user", text: "The rows feel cramped in a narrow split. Can you make the gap between transcript rows configurable, and run the tests?" },
    { type: "text", text: "I'll look at how `TranscriptView` spaces its rows first." },
    { type: "run", run: run([a1, a2, a3], { dur: 4 }) },
    { type: "text", text: "`rowSpacing` is a private static constant, and `intercellSpacing` is set from it once. I'll make it an instance property that re-applies the spacing when it changes, then update the test that pins it." },
    { type: "run", run: run([b1, b2, b3, b4, b5, b6], { dur: 48 }) },
    { type: "text", text: "Done — `TranscriptView.rowSpacing` is now public and defaults to 14, and all 42 TranscriptView tests pass. A release build of the demo is running in the background." },
    { type: "slash", name: "/effort", args: "high", out: "Set effort level to high" },
    { type: "news", news: [newsBuild] },
    { type: "user", text: "Have an agent check whether anything else hard-codes the 14." },
    { type: "run", run: run([c1], { dur: 71 }) },
    { type: "text", text: "The agent found one more: `EditorAreaTests` compares a row rect to `rowHeight + 14`. I'll leave it — it tests the default." },
    { type: "divider", text: "Conversation compacted · 168k → 14k tokens", link: compactDoc.id },
    { type: "user", text: "Now make the tool rows one step smaller than body text." },
    { type: "text", text: "Sure. The run row's summary is set at 13 pt, one step below the 14-pt body, so the change is in" },
    { type: "interrupt", tight: true },
    { type: "shell", item: shell1 },
  ];
}

// MARK: - Playground: two editors, tabs, selection, history-free

class Playground {
  constructor(root) {
    this.root = root;
    this.tabs = []; // { id, pinned }
    this.active = null;
    this.selected = null;
    root.innerHTML = `
      <div class="titlebar"><div class="lights"><i></i><i></i><i></i></div>
        <div><div class="ttl">ccterm</div><div class="sub">transcript-views-design</div></div><span class="spacer"></span>
        <div class="seg" role="group"><button data-replay aria-pressed="false">▶︎ Replay a live turn</button></div></div>
      <div class="editors">
        <div class="editor"><div class="tabbar"><div class="tab on"><span>Row gap and tool rows</span><span class="pin">${ICON.pin}</span></div></div><div class="pane" data-left><div class="transcript"></div></div></div>
        <div class="editor"><div class="tabbar" data-tabs></div><div class="pane" data-right></div></div>
      </div>`;
    this.left = root.querySelector("[data-left]");
    this.column = new Column(this.left.querySelector(".transcript"), playgroundRows());
    this.right = root.querySelector("[data-right]");
    this.tabbar = root.querySelector("[data-tabs]");
    root.tabIndex = 0;
    root.addEventListener("keydown", (e) => this.key(e));
  }
  showing(id) { return this.active === id; }
  open(id, pin) {
    const existing = this.tabs.find((t) => t.id === id);
    if (existing) { if (pin) existing.pinned = true; }
    else {
      const temp = this.tabs.findIndex((t) => !t.pinned);
      const tab = { id, pinned: !!pin };
      if (temp >= 0) this.tabs[temp] = tab; // replaced where it stands
      else this.tabs.push(tab);
    }
    this.active = id;
    this.selected = id;
    this.root.querySelector(".editors").classList.add("split");
    this.renderTabs();
    this.renderDoc();
    markSelection();
  }
  close(id) {
    const i = this.tabs.findIndex((t) => t.id === id);
    if (i < 0) return;
    this.tabs.splice(i, 1);
    if (this.active === id) this.active = (this.tabs[i] || this.tabs[i - 1] || {}).id || null;
    this.selected = this.active;
    if (!this.tabs.length) this.root.querySelector(".editors").classList.remove("split");
    this.renderTabs();
    this.renderDoc();
    markSelection();
  }
  togglePin(id) {
    const tab = this.tabs.find((t) => t.id === id);
    if (!tab) return;
    if (tab.pinned) { this.tabs.forEach((t) => (t.pinned = true)); tab.pinned = false; }
    else tab.pinned = true;
    this.renderTabs();
  }
  renderTabs() {
    this.tabbar.innerHTML = this.tabs.map((t) => {
      const title = docTitle(t.id);
      return `<div class="tab${t.id === this.active ? " on" : ""}${t.pinned ? "" : " temp"}" data-tab="${t.id}"><span class="x" data-close="${t.id}">${ICON.x}</span><span>${esc(title.length > 32 ? title.slice(0, 31) + "…" : title)}</span><span class="pin" data-pin="${t.id}">${t.pinned ? ICON.pin : ICON.pinHollow}</span></div>`;
    }).join("");
  }
  renderDoc() {
    if (!this.active) { this.right.innerHTML = ""; return; }
    const top = this.right.scrollTop;
    mountDoc(this.right, this.active);
    this.right.firstElementChild.style.height = "100%";
    const body = this.right.querySelector(".body");
    if (body) body.scrollTop = top;
  }
  reveal(id) {
    const hit = rowOfItem(id);
    if (hit && hit.row.type === "run" && !hit.row.run.open && hit.row.run.items.length > 1) {
      hit.row.run.open = true;
      hit.col.update(hit.row);
    }
    const el = this.left.querySelector(`.line[data-open="${id}"]`);
    if (!el) return;
    el.scrollIntoView({ block: "center", behavior: "smooth" });
    el.classList.remove("flash");
    void el.offsetWidth;
    el.classList.add("flash");
  }
  /** Every openable thing in reading order — ↑/↓ walk it, into closed runs. */
  order() {
    const ids = [];
    for (const row of this.column.rows) {
      if (row.type === "run") ids.push(...row.run.items.map((i) => i.id));
      if (row.type === "news") ids.push(...row.news.map((n) => n.id));
      if (row.type === "shell") ids.push(row.item.id);
    }
    return ids;
  }
  key(e) {
    if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
    e.preventDefault();
    const ids = this.order();
    const at = ids.indexOf(this.selected);
    const next = ids[Math.max(0, Math.min(ids.length - 1, at < 0 ? 0 : at + (e.key === "ArrowDown" ? 1 : -1)))];
    const hit = rowOfItem(next);
    if (hit && hit.row.type === "run" && hit.row.run.items.length > 1 && !hit.row.run.open) { hit.row.run.open = true; hit.col.update(hit.row); }
    this.open(next, false);
    const el = this.left.querySelector(`.line[data-open="${next}"]`);
    if (el) el.scrollIntoView({ block: "nearest" });
  }
}
let PLAY = null;

function markSelection() {
  document.querySelectorAll(".line.selected").forEach((el) => el.classList.remove("selected"));
  if (PLAY && PLAY.selected) PLAY.left.querySelectorAll(`.line[data-open="${PLAY.selected}"]`).forEach((el) => el.classList.add("selected"));
  if (DRAWER.id) document.querySelectorAll(`.specimens .line[data-open="${DRAWER.id}"]`).forEach((el) => el.classList.add("selected"));
}

// MARK: - Drawer: "beside" for the specimens outside the playground

const DRAWER = {
  id: null,
  el: null,
  open(id) {
    this.id = id;
    this.el.querySelector("[data-dtitle]").textContent = docTitle(id);
    const host = this.el.querySelector("[data-dbody]");
    mountDoc(host, id);
    host.firstElementChild.style.height = "100%";
    this.el.classList.add("on");
    markSelection();
  },
  close() { this.id = null; this.el.classList.remove("on"); markSelection(); },
};

// MARK: - Events

document.addEventListener("click", (e) => {
  const t = e.target.closest("[data-allow],[data-deny],[data-close],[data-pin],[data-tab],[data-origin],[data-reveal],[data-more],[data-open],[data-toggle],[data-replay],[data-theme-set],[data-dclose]");
  if (!t) return;
  const inPlay = PLAY && PLAY.root.contains(t);
  if (t.dataset.allow || t.dataset.deny) { LIVE_DECISION && LIVE_DECISION(t.dataset.allow ? "allow" : "deny", t.dataset.allow || t.dataset.deny); return; }
  if (t.dataset.close) { e.stopPropagation(); PLAY.close(t.dataset.close); return; }
  if (t.dataset.pin) { e.stopPropagation(); PLAY.togglePin(t.dataset.pin); return; }
  if (t.dataset.tab) { PLAY.active = PLAY.selected = t.dataset.tab; PLAY.renderTabs(); PLAY.renderDoc(); markSelection(); return; }
  if (t.dataset.origin) { e.stopPropagation(); if (inPlay) PLAY.reveal(t.dataset.origin); return; }
  if (t.dataset.reveal) {
    if (PLAY && PLAY.root.contains(t)) PLAY.reveal(PLAY.active);
    else { const id = DRAWER.id; DRAWER.close(); revealSpecimen(id); }
    return;
  }
  if (t.dataset.more) { const r = RUNS.get(t.dataset.more); r.all = true; refreshRun(r); return; }
  if (t.dataset.open) {
    e.stopPropagation();
    if (inPlay && !PLAY.right.contains(t)) PLAY.open(t.dataset.open, false);
    else if (inPlay) PLAY.open(t.dataset.open, false);
    else DRAWER.open(t.dataset.open);
    return;
  }
  if (t.dataset.toggle) {
    const r = RUNS.get(t.dataset.toggle);
    const open = !r.open;
    if (e.altKey) {
      // ⌥-click: every run in this transcript, the Finder outline convention.
      const col = COLUMNS.get(t.closest("[data-column]").dataset.column);
      for (const row of col.rows) { if (row.type === "run" && row.run.items.length > 1) row.run.open = open; if (row.type === "news" && row.news.length > 1) row.open = open; }
      col.render();
    } else { r.open = open; refreshRun(r); }
    return;
  }
  if (t.dataset.replay != null) { replay(); return; }
  if (t.dataset.themeSet != null) { setTheme(t.dataset.themeSet); return; }
  if (t.dataset.dclose != null) DRAWER.close();
});
document.addEventListener("dblclick", (e) => {
  const t = e.target.closest("[data-open],[data-tab]");
  if (!t || !PLAY || !PLAY.root.contains(t)) return;
  if (t.dataset.tab) { PLAY.tabs.find((x) => x.id === t.dataset.tab).pinned = true; PLAY.renderTabs(); return; }
  PLAY.open(t.dataset.open, true);
});
document.addEventListener("keydown", (e) => {
  // The approval's keys: ⌘↩ allows, ⎋ denies (01-run.md "Waiting for you").
  if (LIVE_DECISION && e.key === "Enter" && e.metaKey) { e.preventDefault(); LIVE_DECISION("allow", LIVE_DECISION.id); return; }
  if (LIVE_DECISION && e.key === "Escape") { e.preventDefault(); LIVE_DECISION("deny", LIVE_DECISION.id); return; }
  if (e.key === "Escape" && DRAWER.id) DRAWER.close();
});

function refreshRun(r) {
  const row = r.row || r; // a news row is its own run
  const col = COLUMNS.get(row.column);
  if (col) col.update(row);
}
function revealSpecimen(id) {
  const el = document.querySelector(`.specimens .line[data-open="${id}"]`);
  if (!el) return;
  el.scrollIntoView({ block: "center", behavior: "smooth" });
  el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash");
}

function setTheme(v) {
  if (v === "auto") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.dataset.theme = v;
  document.querySelectorAll("[data-theme-set]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.themeSet === v)));
}

// MARK: - Live replay (01-run.md "Live", 02-command.md "Live")

let LIVE_DECISION = null;
let replaying = false;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function replay() {
  if (replaying) return;
  replaying = true;
  const btn = PLAY.root.querySelector("[data-replay]");
  btn.setAttribute("aria-pressed", "true");
  btn.textContent = "Replaying…";
  const col = PLAY.column;
  const pane = PLAY.left;
  const follow = () => { pane.scrollTop = pane.scrollHeight; };
  const add = (row) => { col.append(row); follow(); return row; };
  const upd = (row) => { col.update(row); follow(); };
  const tick = (row, items) => setInterval(() => { for (const it of items()) it.elapsed = (it.elapsed || 0) + 1; upd(row); for (const it of items()) if (PLAY.showing(it.id)) PLAY.renderDoc(); }, 400);
  async function stream(row, text) {
    row.streaming = true; row.text = "";
    for (const w of text.split(/(?<= )/)) { row.text += w; upd(row); await sleep(45); }
    row.streaming = false; upd(row);
  }
  async function set(it, row, state, extra = {}) { Object.assign(it, { state }, extra); upd(row); if (PLAY.showing(it.id)) PLAY.renderDoc(); }

  add({ type: "user", text: "Make the summary 12 pt and rebuild." });
  await sleep(500);
  await stream(add({ type: "text", text: "" }), "I'll change the summary's font and rebuild.");
  await sleep(300);

  // A run: a read, an edit that needs approval, a build, two in parallel.
  const R = run([]);
  const row = add({ type: "run", run: R });
  const l1 = read("macos/ccterm/Content/Transcript/RunRowView.swift", 1, 96, 96, { code: "import AppKit\n\n/// One run: a tile, a sentence, its meta.\nfinal class RunRowView: NSView {\n    private let summary = NSTextField(labelWithString: \"\")\n    // …\n}", state: "streaming" });
  R.items.push(l1); upd(row); await sleep(500);
  await set(l1, row, "running"); await sleep(500);
  await set(l1, row, "done");

  const diff = [["ctx", 41, "        summary.lineBreakMode = .byTruncatingTail"], ["del", null, "        summary.font = .systemFont(ofSize: ⟦13⟧)"], ["add", 42, "        summary.font = .systemFont(ofSize: ⟦12⟧)"], ["ctx", 43, "        summary.textColor = .secondaryLabelColor"]];
  const l2 = edit("macos/ccterm/Content/Transcript/RunRowView.swift", 1, 1, { state: "streaming", diff, why: "Edits need approval in Default mode." });
  R.items.push(l2); upd(row); await sleep(700);
  await set(l2, row, "waiting");
  btn.textContent = "Waiting for you — Allow or Deny in the transcript";
  const decision = await new Promise((resolve) => {
    LIVE_DECISION = (d, id) => { if (id === l2.id) { LIVE_DECISION = null; resolve(d); } };
    LIVE_DECISION.id = l2.id;
  });
  btn.textContent = "Replaying…";
  if (decision === "deny") {
    await set(l2, row, "denied");
    await sleep(400);
    await stream(add({ type: "text", text: "" }), "Understood — I'll leave the font as it is.");
    return done();
  }
  await set(l2, row, "running"); await sleep(300);
  await set(l2, row, "done");

  const buildCmd = "cd ~/dev/ccterm && make build";
  const l3 = bash(null, buildCmd, { state: "streaming", partial: "" });
  R.items.push(l3);
  for (let i = 0; i <= buildCmd.length; i += 3) { l3.partial = buildCmd.slice(0, i); upd(row); await sleep(40); }
  l3.desc = "Build the app";
  l3.elapsed = 0;
  await set(l3, row, "running");
  let timer = tick(row, () => R.items.filter((i) => i.state === "running"));
  await sleep(2800);
  await set(l3, row, "done", { dur: l3.elapsed, out: ["** BUILD SUCCEEDED **"] });

  const l4 = bash("Run the unit tests", "make test-unit FILTER=RunRowViewTests", { state: "running", elapsed: 0 });
  const l5 = bash("Check formatting", "make fmt-check", { state: "running", elapsed: 0 });
  R.items.push(l4, l5); upd(row);
  await sleep(1600);
  await set(l5, row, "done", { dur: l5.elapsed, out: ["All files formatted."] });
  await sleep(1800);
  clearInterval(timer);
  await set(l4, row, "failed", { dur: l4.elapsed, exit: 65, error: "RunRowViewSnapshotTests.swift:31: error: snapshot differs from reference (summary font 12 ≠ 13)", out: ["Test Suite 'RunRowViewTests' started", "RunRowViewSnapshotTests.swift:31: error: snapshot differs from reference (summary font 12 ≠ 13)", "** TEST FAILED **"] });
  R.dur = 12;
  upd(row);
  await sleep(500);
  await stream(add({ type: "text", text: "" }), "One snapshot still expects 13 pt. I'll update it and run the tests again.");

  const M = run([]);
  const row2 = add({ type: "run", run: M });
  const l6 = edit("macos/cctermTests/RunRowViewSnapshotTests.swift", 1, 1, { state: "running", diff: [["ctx", 30, "        let row = RunRowView(run: .sample)"], ["del", null, "        assertSummaryFont(row, size: ⟦13⟧)"], ["add", 31, "        assertSummaryFont(row, size: ⟦12⟧)"]] });
  M.items.push(l6); upd(row2); await sleep(500);
  await set(l6, row2, "done");
  const l7 = bash("Run the unit tests", "make test-unit FILTER=RunRowViewTests", { state: "running", elapsed: 0 });
  M.items.push(l7); upd(row2);
  timer = tick(row2, () => M.items.filter((i) => i.state === "running"));
  await sleep(2400);
  clearInterval(timer);
  await set(l7, row2, "done", { dur: l7.elapsed, out: ["Executed 6 tests, with 0 failures (0 unexpected) in 2.101 (2.114) seconds"] });
  const l8 = bash("Build release", "make release", { state: "background", elapsed: 0, outputFile: "/tmp/claude/tasks/b7x.output", following: ["Building for production...", "[88/214] Compiling ccterm RunRowView.swift"] });
  M.items.push(l8); M.dur = 11; upd(row2);
  await sleep(400);
  await stream(add({ type: "text", text: "" }), "All green. A release build is running in the background.");
  await sleep(2600);
  l8.state = "done"; l8.bgDur = "1m 48s"; l8.dur = 108; l8.out = ["Building for production...", "Build complete! (108.40s)"];
  upd(row2);
  if (PLAY.showing(l8.id)) PLAY.renderDoc();
  const n = { id: nid("n"), kind: "news", task: "command", status: "completed", summary: "Background command “Build release” completed (exit code 0)", meta: "1m 48s", origin: l8.id };
  ITEMS.set(n.id, n);
  add({ type: "news", news: [n] });
  return done();

  function done() {
    replaying = false;
    btn.setAttribute("aria-pressed", "false");
    btn.textContent = "▶︎ Replay a live turn";
  }
}

// MARK: - Specimens

function spec(caption, rows) { return { caption, rows }; }
function specimens(el, list) {
  el.classList.add("specimens");
  el.innerHTML = list.map((s, i) => `<div class="spec"><div class="cap">${s.caption}</div><div class="col transcript" style="padding:0" data-spec="${i}"></div></div>`).join("");
  list.forEach((s, i) => new Column(el.querySelector(`[data-spec="${i}"]`), s.rows));
}
const R1 = (it, f) => ({ type: "run", run: run([it], f) });
const RN = (items, f) => ({ type: "run", run: run(items, f) });

function buildSheet() {
  // 1 · Run rows, settled
  specimens(document.getElementById("run-settled"), [
    spec("<b>Run of one · command</b>The description, then the command in mono. Click opens it beside.", [R1(clone(b5))]),
    spec("<b>Run of one · no description</b>3.4 % of commands", [R1(bash(null, "ls macos/TranscriptKit/Sources", { out: ["TranscriptKit", "TranscriptKitDemo", "TranscriptMedia", "TranscriptWorkspace"] }))]),
    spec("<b>Run of one · change</b>", [R1(clone(b1))]),
    spec("<b>Run of one · new file</b>", [R1(write("macos/ccterm/Content/Transcript/RunSummary.swift", 38, { code: NEW_CODE }))]),
    spec("<b>Run of one · read</b>60 % of reads are a slice", [R1(clone(a2))]),
    spec("<b>Run of one · search · agent</b>", [R1(clone(a1)), R1(clone(c1))]),
    spec("<b>A run</b>Files named when ≤ 2 — and they are links. Duration only past the median (≥ 10 s).", [RN([clone(b1), clone(b2), clone(b3), clone(b4), clone(b5)], { dur: 48 })]),
    spec("<b>Expanded</b>Items sit flush under their line, 24 pt each — the second level is tighter than the first. A failed item is its red tile; why it failed is in its document. Consecutive edits of one file are one item.", [RN([clone(b1), clone(b2), clone(b3), clone(b4), clone(b5)], { dur: 48, open: true })]),
    spec("<b>Ended in failure</b>The tile shows how the run ended; the sentence counts failures on the way.", [RN([clone(b4), clone(b3)], { dur: 16 })]),
    spec("<b>Five kinds</b>Three clauses, then “and N more”.", [RN([clone(b1), clone(b2), clone(b5), websearch("NSTableView intercellSpacing", 8), clone(a1), clone(a2), taskCall("Completed: Make rowSpacing public", { list: [["Read how rows are spaced", "done"], ["Make rowSpacing public", "done"], ["Update the test", "doing"], ["Build the demo", "todo"]] })], { dur: 63 })]),
    spec("<b>A long run</b>Twelve items, then the rest on request (98.3 % of runs fit in twelve).", [RN(longRun(), { dur: 1920, open: true })]),
    spec("<b>Denied · interrupted</b>Stop square when the run ended that way.", [
      RN([clone(a2), edit(TV, 4, 2, { state: "denied", diff: TV_DIFF })], { dur: 3 }),
      RN([clone(b2), bash("Run the full test suite", "make test-unit", { state: "interrupted", dur: 34, out: ["Test Suite 'All tests' started"] })], { dur: 40 }),
    ]),
  ]);

  // 1 · Run rows, live
  const streamCmd = bash(null, "make test-kit FILTER=Transcr", { state: "streaming", partial: "make test-kit FILTER=Transcr" });
  const streamWrite = write("macos/ccterm/Content/Transcript/RunSummary.swift", 38, { state: "streaming", streamLines: 24, code: NEW_CODE });
  const running = bash("Run the TranscriptView tests", TEST_CMD, { state: "running", elapsed: 12 });
  const par1 = bash("Run the unit tests", "make test-unit", { state: "running", elapsed: 31 });
  const par2 = bash("Run the package tests", "make test-kit", { state: "running", elapsed: 18 });
  const waitCmd = bash("Remove the build cache", "rm -rf macos/build/test-dd", { state: "waiting", why: "rm -rf needs approval: it deletes files." });
  const waitEdit = edit(TV, 4, 2, { state: "waiting", diff: TV_DIFF.filter((r) => r[0] !== "fold").slice(3, 9), why: "Edits need approval in Default mode." });
  const agentLive = agentCall("Review the diff", "general-purpose", 8, 0, { state: "running", elapsed: 42, progress: "Reading LibraryStore.swift · 8 tools", result: "" });
  const bgItem = bash("Build the demo app", b6.cmd, { state: "background", elapsed: 95, outputFile: "/tmp/claude/tasks/b6.output", following: ["Building for production...", "[131/214] Compiling TranscriptKit RowCache.swift", "[132/214] Compiling TranscriptKit RowCacheEntry.swift"] });
  const liveSpecs = [
    spec("<b>Input streaming · command</b>No description yet: the command as it arrives.", [RN([clone(a2), streamCmd])]),
    spec("<b>Input streaming · new file</b>Lines count up as content streams.", [RN([streamWrite])]),
    spec("<b>Running</b>The tile's outline travels; elapsed ticks. Same 28 pt as settled.", [RN([clone(b1), running])]),
    spec("<b>Two in parallel</b>", [RN([clone(b1), par1, par2], { open: true })]),
    spec("<b>Waiting for you · command</b>The one time a run grows. Coral: stopped until you look.", [RN([clone(a2), waitCmd])]),
    spec("<b>Waiting for you · change</b>The one place a diff is inline — the decision is here.", [RN([waitEdit])]),
    spec("<b>Between calls</b>The model is thinking: the sentence so far, nothing moving.", [RN([clone(a1), clone(a2), clone(b1)])]),
    spec("<b>In background · agent running</b>", [RN([clone(b5), bgItem]), R1(agentLive)]),
  ];
  specimens(document.getElementById("run-live"), liveSpecs);
  setInterval(() => {
    for (const it of [running, par1, par2, agentLive, bgItem]) it.elapsed++;
    streamWrite.streamLines = streamWrite.streamLines >= 38 ? 6 : streamWrite.streamLines + 2;
    for (const it of [running, par1, agentLive, bgItem, streamWrite]) refresh(it.id);
  }, 1000);

  // Tile grid
  const kinds = ["command", "change", "create", "read", "search", "web", "agent", "tasks", "schedule", "message", "other"];
  const states = [["done", "done"], ["streaming", "preparing"], ["running", "running"], ["background", "background"], ["waiting", "waiting for you"], ["failed", "failed"], ["denied", "denied · interrupted"]];
  document.getElementById("tiles").innerHTML = `<div class="specimens"><div class="tilegrid"><span></span>${states.map(([, l]) => `<span class="h" style="text-align:center">${l}</span>`).join("")}${kinds
    .map((k) => `<span>${k}</span>${states.map(([s]) => `<span class="cell">${tile(k, s)}</span>`).join("")}`).join("")}</div></div>`;

  // 2 · Command documents
  const docs2 = [
    ["Failed", clone(b3, { sandboxOff: false })],
    ["Output with warnings — stdout and stderr are one stream, in the order printed", bash("Build the package", "cd macos/TranscriptKit && swift build", { dur: 6, out: ["Building for debugging...", "TranscriptView.swift:88:9: warning: variable 'count' was never mutated", "[4/9] Compiling TranscriptKit TranscriptView.swift", "Build complete! (5.87s)"] })],
    ["Succeeded · a note on the exit code · sandbox off", bash("Find the old constant", "grep -rn 'Self.rowSpacing' macos", { state: "done", dur: 0, out: [], note: "No matches found (exit code 1 means grep found nothing).", sandboxOff: true })],
    ["Running — output arrives with the result", bash("Run the TranscriptView tests", TEST_CMD, { state: "running", elapsed: 12 })],
    ["Waiting for you", bash("Remove the build cache", "rm -rf macos/build/test-dd", { state: "waiting", why: "rm -rf needs approval: it deletes files." })],
    ["In background — following its output file", bgItem],
    ["Output too long to keep", bash("Dump the unified log", "make logs LEVEL=debug | head -2000", { dur: 4, out: ["2026-09-29 11:40:02.114 ccterm[5012] <Info> TranscriptViewController: load started", "2026-09-29 11:40:02.120 ccterm[5012] <Debug> RowCache: warm 30 rows", "…"], persisted: "~/.claude/tool-results/bp7e6ce4y.txt" })],
  ];
  docFrames(document.getElementById("command-docs"), docs2);

  // 3 · File documents
  docFrames(document.getElementById("file-docs"), [
    ["Change — in place, with folds and the characters that changed", clone(b1)],
    ["New file — no wash; one green bar says “all new”", write("macos/ccterm/Content/Transcript/RunSummary.swift", 38, { code: NEW_CODE })],
    ["Read — the file map on the right: what it saw, and where", clone(a2)],
    ["Change that failed — the proposed diff under the error", edit(TVT, 1, 1, { state: "failed", diff: [["note", "String to replace not found in file.", true], ...TVT_DIFF] })],
  ]);

  // 4 · Background news
  const nAgent = news("agent", "completed", "Agent “Review the diff” finished", "14 tools · 2m 10s", { title: "Review the diff", glyph: "agent", status: "general-purpose · 14 tools · 2m 10s · worktree .claude/worktrees/review · review-diff", md: "The change is correct. Two notes:\n\n- `rowSpacing`'s `didSet` runs before the table exists when set in `init`; the lazy table reads it on creation, so that's fine.\n- `TranscriptKit/CLAUDE.md` §1 says public API mirrors `NSTableView` — `intercellSpacing` is AppKit's name for this. Consider naming it that." });
  const nFail = news("command", "failed", "Background command “Build” failed (exit code 1)", "6m", { origin: clone(b3).id });
  const nFlow = news("workflow", "completed", "Workflow “review-changes” finished", "8 of 9 agents · 1 failed", { title: "review-changes", glyph: "workflow", status: "9 agents · 8 done · 1 failed", md: "**Failures**\n\nreview:perf — timed out after 10m\n\n**Result**\n\nThree findings confirmed; see the diagnostics file for each agent's report." });
  const nMon = news("monitor", null, "Monitor “CI” saw: test-kit passed on #315", "", { title: "CI", glyph: "monitor", status: "Monitor event", md: "test-kit passed on #315 (8m 12s)." });
  specimens(document.getElementById("news"), [
    spec("<b>An agent finished</b>Click: its result beside. ↖ on hover: the call that started it.", [{ type: "news", news: [nAgent] }]),
    spec("<b>A command failed</b>", [{ type: "news", news: [nFail] }]),
    spec("<b>A workflow · a monitor</b>", [{ type: "news", news: [nFlow] }, { type: "news", news: [nMon] }]),
    spec("<b>Consecutive news is one row</b>", [{ type: "news", news: [clone(nAgent), clone(nFail), clone(nMon)], open: false }]),
    spec("<b>The call that started it</b>Running in background, then settled by its notification.", [RN([clone(b2), clone(bgItem)]), RN([clone(b2), clone(b6)])]),
  ]);

  // 5 · Local commands, dividers, interruption
  const ctxDoc = { id: nid("d"), docKind: "markdown", title: "/context", docGlyph: "local", status: "Local command output", md: "Context usage: 61k / 200k tokens (31%)\n\n- System prompt: 3.1k\n- Tools: 14.2k\n- Messages: 43.9k" };
  ITEMS.set(ctxDoc.id, ctxDoc);
  specimens(document.getElementById("local"), [
    spec("<b>Slash command</b>Your message, so your bubble; only the command is a token — an inset of the bubble's own blue. Its output sits under it, like <i>Delivered</i>.", [{ type: "slash", name: "/model", args: "opus", out: "Set model to opus" }]),
    spec("<b>With an error · a skill</b>", [{ type: "slash", name: "/effort", args: "maximum", out: "Unknown effort level: maximum", err: true }, { type: "slash", name: "/skill-creator", full: "/skill-creator:skill-creator", args: "" }]),
    spec("<b>A skill with a prompt</b>The arguments are a prompt, so they read and wrap as one.", [{ type: "slash", name: "/dataviz", args: "Pull the latest code. This PR is only about designing live-session interaction — the New tab, the + on every tab bar, and the composer." }]),
    spec("<b>Long output</b>/context, /usage: cut, the rest beside.", [{ type: "slash", name: "/context", out: "61k / 200k tokens (31%)", long: ctxDoc.id }]),
    spec("<b>/compact</b>Command, output and boundary fold into one divider.", [{ type: "divider", text: "Conversation compacted · 168k → 14k tokens", link: compactDoc.id }, { type: "divider", text: "Compacted automatically · 191k → 22k tokens", link: compactDoc.id }]),
    spec("<b>Compacting, live</b>", [{ type: "divider", text: "Compacting…", live: true }]),
    spec("<b>/exit, then resumed · a long gap</b>Messages' rule: a divider when more than an hour passes.", [{ type: "divider", text: "Resumed · Tue 14:02" }, { type: "divider", text: "Yesterday 18:40" }]),
    spec("<b>! command</b>The same bubble, the command in mono. Several lines of output: the line under it says how many and opens them beside.", [{ type: "shell", item: clone(shell1) }, { type: "shell", item: bash(null, "git branch --show-current", { local: true, out: ["transcript-views-design"] }) }]),
    spec("<b>Interrupted while writing</b>Attached to the reply, not a row of its own.", [{ type: "text", text: "Sure. The run row's summary is set at 13 pt, one step below the 14-pt body, so the change is in" }, { type: "interrupt", tight: true }]),
    spec("<b>Interrupted during a call</b>The call's state; nothing else.", [RN([clone(b2), bash("Run the full test suite", "make test-unit", { state: "interrupted", out: [] })], { dur: 40 })]),
  ]);

  // 6 · Messages from other agents
  const conv = tile("session", "done", { fill: "transparent", ink: "var(--coral)" });
  const flow = tile("workflow", "done", { fill: "transparent", ink: "var(--indigo)" });
  const puzzle = tile("other", "done", { fill: "transparent", ink: "var(--gray)" });
  const report = news("agent", "completed", "**Explore · Find hard-coded row gaps** reported", "", { title: "Explore · Find hard-coded row gaps", glyph: "agent", status: "", md: "Found three call sites of `rowSpacing`:\n\n- `TranscriptView.swift:324` — the declaration\n- `TranscriptView.swift:332` — `intercellSpacing`\n- `TranscriptViewTests.swift:88` — the test\n\nAnd one hard-coded 14 in `EditorAreaTests.swift:118`." });
  specimens(document.getElementById("voices"), [
    spec("<b>A subagent's report</b>Work, like a diff: one line. Click: the report beside.", [{ type: "news", news: [report] }]),
    spec("<b>Another session</b>The conversation glyph, coral.", [{ type: "voice", glyph: conv, who: "Session “Squash merge admin”", text: "PR #314 is merged. You can rebase onto main." }]),
    spec("<b>The coordinator · a plugin</b>", [{ type: "voice", glyph: flow, who: "Coordinator", text: "Hold the transcript work until the review lands." }, { type: "voice", glyph: puzzle, who: "Plugin “ralph-loop”", text: "Continue with the next item on the list." }]),
  ]);

  // 7 · Tools that talk
  const tasksItem = taskCall("Completed: Make rowSpacing public", { list: [["Read how rows are spaced", "done"], ["Make rowSpacing public", "done"], ["Update the test", "doing"], ["Build the demo", "todo"]] });
  const planDoc = { id: nid("d"), docKind: "markdown", title: "Plan", docGlyph: "plan", status: "~/.claude/plans/row-gap.md", md: "1. Make `rowSpacing` a public instance property with a `didSet` that re-applies `intercellSpacing`.\n\n2. Read it from the view in `TranscriptViewTests`.\n\n3. Leave `EditorAreaTests` on the default.\n\n4. Build the demo and look at a narrow split." };
  ITEMS.set(planDoc.id, planDoc);
  const q = { header: "Row gap", question: "What should the default gap between rows be?", options: [{ label: "14 pt", description: "Today's value" }, { label: "12 pt", description: "Same as between paragraphs" }, { label: "16 pt", description: "Roomier" }], answer: "14 pt" };
  const qLong = {
    questions: [
      { header: "Scope", question: "The gap is hard-coded in two places besides the view. Which of them should read the new property, and which should keep their own value?", options: [
        { label: "Both read rowSpacing", description: "TranscriptView and EditorArea always agree, and a change in one place moves both. The tests that pin 14 pt need updating." },
        { label: "Only TranscriptView", description: "EditorArea keeps its own 14 pt for now; the two can drift, which is fine while it has no transcript of its own." },
        { label: "Neither — a theme value", description: "Move the gap into the theme, which both read. Most work, and the theme has no spacing values yet." },
      ] },
      { header: "Checks", question: "What should run before the PR?", multiSelect: true, options: [
        { label: "Unit tests", description: "make test-unit and make test-kit" },
        { label: "Snapshot of a narrow split", description: "TranscriptSnapshotTests at 320 pt" },
        { label: "The demo app", description: "make demo-kit, to look at it by hand" },
      ] },
    ],
  };
  const planSteps = ["Make `rowSpacing` a public instance property with a `didSet` that re-applies `intercellSpacing`.", "Read it from the view in `TranscriptViewTests`.", "Leave `EditorAreaTests` on the default.", "Build the demo and look at a narrow split.", "Open a PR."];
  specimens(document.getElementById("talk"), [
    spec("<b>A question, answered</b>Question and answer kept together.", [{ type: "question", ...q }]),
    spec("<b>A question, waiting</b>Each option two lines — the label, its description under it. Then the answers the CLI adds: <i>Other</i>, typed in place, and <i>Chat About This</i>.", [{ type: "question", ...q, live: true }]),
    spec("<b>Two questions, long options, waiting</b>Long descriptions wrap under their label; nothing is cut. A multi-select question says so and uses checkboxes.", [{ type: "question", ...qLong, live: true }]),
    spec("<b>Answered with Other · talked over</b>A typed answer is the chosen one, marked <i>Other</i>. <i>Chat About This</i> answers nothing: the card says so, and the conversation goes on under it.", [{ type: "question", ...q, answer: null, other: "13 pt — between the two" }, { type: "question", ...q, chat: true }]),
    spec("<b>A plan</b>TranscriptKit's markdown, whole — it is addressed to you.", [{ type: "plan", steps: planSteps, doc: planDoc.id }]),
    spec("<b>A plan, waiting</b>", [{ type: "plan", steps: planSteps, doc: planDoc.id, live: true }]),
    spec("<b>Task list</b>Stays in the run; opens the list as it stood.", [R1(tasksItem)]),
  ]);

  // The window.
  PLAY = new Playground(document.getElementById("playground"));
  DRAWER.el = document.getElementById("drawer");
  chart();
}

function news(task, status, summary, meta, f) {
  const n = { id: nid("n"), kind: "news", task, status, summary, meta, ...f };
  ITEMS.set(n.id, n);
  return n;
}
function longRun() {
  const out = [];
  for (let i = 0; i < 97; i++) {
    if (i % 9 === 4) out.push(edit(TV, 1 + (i % 3), i % 2, { diff: TV_DIFF, path: i % 18 === 4 ? TV : TVT }));
    else if (i % 13 === 7) out.push(clone(a2));
    else out.push(bash(["Check the CI run", "Tail the test log", "Wait for the build", "Poll the PR checks"][i % 4], ["gh run view 18214 --log-failed | tail -40", "tail -n 60 /tmp/test.log", "sleep 30 && ls macos/build", "gh pr checks 315"][i % 4], { dur: 12, out: ["…"] }));
  }
  return out;
}
function docFrames(el, list) {
  el.classList.add("docs");
  el.innerHTML = list.map(([cap], i) => `<div class="docframe"><div class="cap"><b>${esc(cap.split(" — ")[0])}</b>${cap.includes(" — ") ? " — " + esc(cap.split(" — ").slice(1).join(" — ")) : ""}</div><div data-doc="${i}"></div></div>`).join("");
  list.forEach(([, it], i) => {
    const host = el.querySelector(`[data-doc="${i}"]`);
    mountDoc(host, it.id);
  });
}

// MARK: - Chart: calls per run (single series, hover per bar)

function chart() {
  const data = [8098, 3363, 1358, 703, 443, 408, 233, 168, 117, 76, 62, 56, 37, 36, 27, 13, 13, 9, 11, 14, 104];
  const total = data.reduce((a, b) => a + b, 0);
  const W = 720, H = 180, L = 36, B = 22, bw = (W - L) / data.length;
  const max = 9000;
  const y = (v) => H - B - (v / max) * (H - B - 8);
  let s = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Runs by number of calls">`;
  for (const g of [0, 3000, 6000, 9000]) s += `<line class="grid" x1="${L}" x2="${W}" y1="${y(g)}" y2="${y(g)}"/><text class="axis" x="${L - 6}" y="${y(g) + 3}" text-anchor="end">${g ? g / 1000 + "k" : 0}</text>`;
  data.forEach((v, i) => {
    const x = L + i * bw + 1, w = bw - 2, top = y(v), h = Math.max(1, H - B - top);
    const label = i === 20 ? "21+" : String(i + 1);
    const d = `M${x} ${H - B}V${top + Math.min(4, h)}a${Math.min(4, h)} ${Math.min(4, h)} 0 0 1 ${Math.min(4, h)} -${Math.min(4, h)}H${x + w - Math.min(4, h)}a${Math.min(4, h)} ${Math.min(4, h)} 0 0 1 ${Math.min(4, h)} ${Math.min(4, h)}V${H - B}Z`;
    s += `<path class="bar${i >= 12 ? " over" : ""}" d="${d}" data-tip="${label} call${i ? "s" : ""}: ${v.toLocaleString()} runs (${((v / total) * 100).toFixed(1)} %)"/>`;
    if (i % 2 === 0 || i === 20) s += `<text class="axis" x="${x + w / 2}" y="${H - 6}" text-anchor="middle">${label}</text>`;
  });
  const cx = L + 12 * bw;
  s += `<line class="mark" x1="${cx}" x2="${cx}" y1="14" y2="${H - B}"/><text class="marklabel" x="${cx + 6}" y="24">List cap: 12 items — 98.3 % of runs fit</text>`;
  s += `<text class="marklabel" x="${L + bw + 8}" y="${y(8098) + 12}">53 % are a single call</text></svg>`;
  const host = document.getElementById("chart");
  host.insertAdjacentHTML("beforeend", s + '<div class="tip"></div>');
  const tip = host.querySelector(".tip");
  host.querySelectorAll("[data-tip]").forEach((b) => {
    b.addEventListener("mouseenter", () => { tip.textContent = b.dataset.tip; tip.style.opacity = 1; });
    b.addEventListener("mousemove", (e) => { const r = host.getBoundingClientRect(); tip.style.left = `${e.clientX - r.left + 12}px`; tip.style.top = `${e.clientY - r.top - 30}px`; });
    b.addEventListener("mouseleave", () => { tip.style.opacity = 0; });
  });
}

document.addEventListener("DOMContentLoaded", buildSheet);
