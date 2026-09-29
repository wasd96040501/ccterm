// Transcript views — the sheet's engine: tiles, run rows (the sentence is
// built by the same rules 01-run.md states), documents, the split, and a
// scripted live turn. Plain browser JS, no build.
"use strict";

// MARK: - Geometry: Lamé curves on the 16-pt grid, as design/sidebar-icons

const r3 = (v) => Math.round(v * 1000) / 1000;
function lame(cx, cy, a, b, n, steps = 96) {
  const pts = [];
  for (let i = 0; i < steps; i++) {
    const t = (2 * Math.PI * i) / steps;
    const c = Math.cos(t), s = Math.sin(t);
    pts.push(`${r3(cx + a * Math.sign(c) * Math.abs(c) ** (2 / n))} ${r3(cy + b * Math.sign(s) * Math.abs(s) ** (2 / n))}`);
  }
  return `M${pts.join("L")}Z`;
}
const SQUIRCLE = lame(8, 8, 7.5, 7.5, 4);
const STAR = lame(8, 8, 4.4, 4.4, 0.8);
const dot = (x, y) => `<circle cx="${x}" cy="${y}" r=".55" fill="currentColor" stroke="none"/>`;

// One glyph per kind, drawn at SF Symbol weight on the tile.
const GLYPHS = {
  command: '<path d="M5 5.8l2.4 2.2L5 10.2M8.6 10.4h2.6"/>',
  change: '<path d="M5 11l.5-2.1 4.4-4.4 1.6 1.6-4.4 4.4zM8.9 5.5l1.6 1.6"/>',
  create: '<path d="M8 5.2v5.6M5.2 8h5.6"/>',
  read: '<path d="M5.2 5.6h5.6M5.2 8h5.6M5.2 10.4h3.4"/>',
  search: '<circle cx="7.3" cy="7.3" r="2.3"/><path d="M9 9l2 2"/>',
  web: '<circle cx="8" cy="8" r="3.2"/><path d="M4.8 8h6.4M8 4.8c-1.5 1.8-1.5 4.6 0 6.4M8 4.8c1.5 1.8 1.5 4.6 0 6.4"/>',
  agent: `<path d="${STAR}" fill="currentColor" stroke="none"/>`,
  workflow: `<path d="${lame(5.8, 5.8, 1.7, 1.7, 4, 48)}" fill="currentColor" stroke="none"/><path d="${lame(10.2, 10.2, 1.7, 1.7, 4, 48)}" fill="currentColor" stroke="none"/><path d="M5.8 7.6v1.4a1.2 1.2 0 0 0 1.2 1.2h1.4"/>`,
  tasks: '<path d="M4.8 6l.8.8 1.4-1.5M8.4 6h2.8M4.8 9.8l.8.8 1.4-1.5M8.4 9.8h2.8"/>',
  schedule: '<circle cx="8" cy="8" r="3.2"/><path d="M8 6.2V8l1.2.9"/>',
  message: '<path d="M4.6 7.8l6.6-3-3 6.6-.9-2.7z"/>',
  other: '<path d="M5.4 6.2h1.5a1 1 0 1 1 2 0h1.7v1.7a1 1 0 1 1 0 2v1.7H5.4z"/>',
  question: `<path d="M6.5 6.6a1.5 1.5 0 1 1 2.2 1.3c-.5.3-.7.6-.7 1.1v.2"/>${dot(8, 10.9)}`,
  plan: '<rect x="5" y="4.8" width="6" height="6.8" rx="1.2"/><path d="M6.8 7.2h2.4M6.8 9.2h2.4"/>',
  monitor: '<path d="M4.4 8.3h1.8l1-2.3 1.7 4.2 1-1.9h1.7"/>',
  session: `<path d="${lame(8, 7.4, 3.6, 2.8, 4, 48)}" fill="currentColor" stroke="none"/><path d="M5.6 9.6l-.6 2.2 2.4-1.6" fill="currentColor" stroke="none"/>`,
  local: '<path d="M9.8 4.8L6.2 11.2"/>',
  fail: `<path d="M8 5.2v3.4"/>${dot(8, 10.7)}`,
  stop: '<rect x="6" y="6" width="4" height="4" rx=".8" fill="currentColor" stroke="none"/>',
};

/** A kind's tile in a state (README "Tile"). 18-pt box so the 1.5-pt ring can
 *  sit on the outline; drawn with a −1 margin so the tile is 16 pt. */
function tile(kind, state = "done", opts = {}) {
  const stopped = state === "denied" || state === "interrupted";
  const failed = state === "failed";
  const ink = opts.ink || (failed ? "var(--red-text)" : stopped ? "var(--tertiary)" : "var(--secondary)");
  const glyph = failed ? GLYPHS.fail : stopped ? GLYPHS.stop : GLYPHS[kind] || GLYPHS.other;
  const fill = failed ? "var(--red-wash)" : opts.fill || "var(--tile)";
  let ring = "";
  if (state === "running") ring = `<path class="ring run-arc" pathLength="100" d="${SQUIRCLE}"/>`;
  if (state === "background") ring = `<path class="ring bg-arc" pathLength="100" d="${SQUIRCLE}"/>`;
  if (state === "waiting") ring = `<path class="ring wait-arc" d="${SQUIRCLE}"/>`;
  return (
    `<svg class="tile" width="18" height="18" viewBox="-1 -1 18 18" style="margin:-1px;color:${ink}" aria-hidden="true">` +
    `<path d="${SQUIRCLE}" fill="${fill}"/>` +
    `<g fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" opacity="${state === "streaming" ? 0.42 : 1}">${glyph}</g>` +
    `${ring}</svg>`
  );
}

const ICON = {
  chevron: '<svg class="chev" viewBox="0 0 12 12"><path d="M4.5 2.5L8 6l-3.5 3.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  go: '<svg class="go" viewBox="0 0 12 12"><path d="M4 8l4.5-4.5M4.8 3.5h3.7v3.7" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  back: '<svg width="11" height="11" viewBox="0 0 12 12"><path d="M4.5 3L2 5.5 4.5 8M2.3 5.5H7a3 3 0 0 1 0 6H6" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  info: '<svg width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5" fill="none" stroke="currentColor"/><path d="M6 5.3v3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="6" cy="3.6" r=".65" fill="currentColor"/></svg>',
  octagon: '<svg width="12" height="12" viewBox="0 0 12 12"><path d="M4 1h4l3 3v4l-3 3H4L1 8V4z" fill="none" stroke="currentColor"/><path d="M4.4 4.4l3.2 3.2M7.6 4.4L4.4 7.6" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></svg>',
  shield: '<svg width="11" height="12" viewBox="0 0 11 12"><path d="M5.5 1L1.5 2.6v3c0 2.6 1.7 4.4 4 5.4 2.3-1 4-2.8 4-5.4v-3z" fill="none" stroke="currentColor" stroke-width="1.1"/><path d="M5.5 3.6v3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="5.5" cy="8.3" r=".6" fill="currentColor"/></svg>',
  copy: '<svg width="13" height="13" viewBox="0 0 13 13"><rect x="4" y="4" width="7" height="7.5" rx="1.5" fill="none" stroke="currentColor"/><path d="M2.5 8.5V3a1.5 1.5 0 0 1 1.5-1.5h5" fill="none" stroke="currentColor"/></svg>',
  stopcircle: '<svg width="12" height="12" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5" fill="none" stroke="currentColor"/><rect x="4.2" y="4.2" width="3.6" height="3.6" rx=".6" fill="currentColor"/></svg>',
  x: '<svg width="8" height="8" viewBox="0 0 8 8"><path d="M1.5 1.5l5 5M6.5 1.5l-5 5" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
  pin: '<svg width="9" height="11" viewBox="0 0 9 11"><path d="M2 1h5l-.8 3.2L8 6H1l1.8-1.8z" fill="currentColor"/><path d="M4.5 6v4.2" stroke="currentColor" stroke-width="1.1"/></svg>',
  pinHollow: '<svg width="9" height="11" viewBox="0 0 9 11"><path d="M2 1.5h5l-.8 3L7.6 6H1.4l1.4-1.5z" fill="none" stroke="currentColor"/><path d="M4.5 6v4.2" stroke="currentColor" stroke-width="1.1"/></svg>',
};

// MARK: - Text helpers

const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const base = (p) => p.split("/").pop();
const folder = (p) => {
  const parts = p.split("/").slice(0, -1);
  return parts.length > 3 ? `${parts.slice(0, 2).join("/")}/…/${parts[parts.length - 1]}` : parts.join("/");
};
const firstLine = (s) => String(s).replace(/^\n+/, "").split("\n")[0];
const stripCd = (s) => String(s).replace(/^cd \S+ && /, "");
const lowerFirst = (s) => s.replace(/^([A-Z])/, (m) => m.toLowerCase());
const joinAnd = (xs) => (xs.length <= 1 ? xs.join("") : `${xs.slice(0, -1).join(", ")} and ${xs[xs.length - 1]}`);
function fmtDur(s) {
  s = Math.round(s);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60), r = s % 60;
  if (s < 600) return r ? `${m}m ${r}s` : `${m}m`;
  if (s < 3600) return `${m}m`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
const plural = (n, one, many) => (n === 1 ? one : many.replace("#", n));

// MARK: - Registry

const ITEMS = new Map(); // id → item
const RUNS = new Map(); // id → run
const COLUMNS = new Map(); // id → Column
let seq = 0;
const nid = (p) => `${p}${++seq}`;

function item(kind, tool, fields) {
  const it = { id: nid("i"), kind, tool, state: "done", ...fields };
  ITEMS.set(it.id, it);
  return it;
}
const bash = (desc, cmd, f = {}) => item("command", "Bash", { desc, cmd, ...f });
const edit = (path, add, del, f = {}) => item("change", "Edit", { path, add, del, ...f });
const write = (path, lines, f = {}) => item("create", "Write", { path, lines, ...f });
const read = (path, from, to, total, f = {}) => item("read", "Read", { path, from, to, total, ...f });
const grep = (pattern, where, files, f = {}) => item("search", "Grep", { pattern, where, files, ...f });
const webfetch = (url, code, f = {}) => item("web", "WebFetch", { url, code, ...f });
const websearch = (query, results, f = {}) => item("web", "WebSearch", { query, results, ...f });
const agentCall = (desc, type, tools, dur, f = {}) => item("agent", "Agent", { desc, type, tools, dur, ...f });
const taskCall = (label, f = {}) => item("tasks", "TaskUpdate", { label, ...f });
const clone = (it, f = {}) => {
  const { id, ...rest } = it;
  return item(it.kind, it.tool, { ...rest, ...f });
};
function run(items, f = {}) {
  const r = { id: nid("r"), items, open: false, all: false, ...f };
  RUNS.set(r.id, r);
  return r;
}

// MARK: - The run row: the sentence (01-run.md "The sentence")

const ORDER = ["change", "create", "command", "agent", "web", "search", "read", "tasks", "schedule", "message", "other"];
const fileLink = (it) => `<a class="file" data-open="${it.id}">${esc(base(it.path))}</a>`;

function namedFiles(items, verb, manyVerb) {
  const byPath = new Map();
  for (const it of items) if (!byPath.has(it.path)) byPath.set(it.path, it);
  const firsts = [...byPath.values()];
  if (!firsts.length) return null;
  return firsts.length <= 2 ? `${verb} ${joinAnd(firsts.map(fileLink))}` : `${manyVerb} ${firsts.length} files`;
}

/** Clauses count what took effect: a denied call did nothing, and a failed
 *  edit changed no file — those are only exceptions. */
function clauses(all) {
  const items = all.filter((i) => i.state !== "denied" && !(i.state === "failed" && (i.kind === "change" || i.kind === "create")));
  const of = (k) => items.filter((i) => i.kind === k);
  const out = [];
  const ch = namedFiles(of("change"), "Edited", "Edited");
  if (ch) out.push(ch);
  const cr = namedFiles(of("create"), "Created", "Created");
  if (cr) out.push(cr);
  const cm = of("command").length;
  if (cm) out.push(plural(cm, "Ran a command", "Ran # commands"));
  const ag = of("agent").length;
  if (ag) out.push(plural(ag, "Ran an agent", "Ran # agents"));
  const web = of("web");
  const searches = web.filter((i) => i.tool === "WebSearch").length;
  const fetches = web.length - searches;
  if (searches && fetches) out.push(`Searched the web and fetched ${plural(fetches, "a page", "# pages")}`);
  else if (searches) out.push("Searched the web");
  else if (fetches) out.push(plural(fetches, "Fetched a page", "Fetched # pages"));
  const se = of("search");
  if (se.length === 1) out.push(`Searched for <code>${esc(se[0].pattern)}</code>`);
  else if (se.length) out.push(`Searched ${se.length} times`);
  const rd = namedFiles(of("read"), "Read", "Read");
  if (rd) out.push(rd);
  if (of("tasks").length) out.push("Updated the task list");
  const sc = of("schedule").length;
  if (sc) out.push(plural(sc, "Scheduled a task", "Scheduled # tasks"));
  const ms = of("message").length;
  if (ms) out.push(plural(ms, "Sent a message", "Sent # messages"));
  const servers = new Map();
  for (const it of of("other")) servers.set(it.server, (servers.get(it.server) || 0) + 1);
  for (const [server, n] of servers) out.push(`Used ${esc(server)} ${plural(n, "once", "# times")}`);
  return out;
}

function sentence(items) {
  let cs = clauses(items);
  if (!cs.length) return plural(items.length, "1 call", "# calls");
  const extra = Math.max(0, cs.length - 3);
  cs = cs.slice(0, 3).map((c, i) => (i ? lowerFirst(c) : c));
  let s = cs.join(", ");
  if (extra) s += `, and ${extra} more`;
  return s;
}

/** The exceptions, set apart from the sentence: the sentence may be cut at
 *  the tail in a narrow editor, these never are. */
function exceptions(items) {
  const count = (st) => items.filter((i) => i.state === st).length;
  const out = [];
  const failed = count("failed");
  if (failed) out.push(`<span class="fail">${failed} failed</span>`);
  const denied = count("denied");
  if (denied) out.push(`${denied} denied`);
  if (count("interrupted")) out.push("Interrupted");
  const bg = count("background");
  if (bg) out.push(`${bg} in background`);
  return out.map((x) => `· ${x}`).join(" ");
}

/** A call named on its own — a run of one, or an item in a list. */
function callText(it, single) {
  switch (it.kind) {
    case "command":
      if (it.desc) return `${esc(it.desc)}<span class="mono">${esc(firstLine(stripCd(it.cmd)))}</span>`;
      return `<span class="mono cmdline">${esc(firstLine(it.cmd))}</span>`;
    case "change":
      return single ? `Edited ${fileLink(it)}` : `<span class="file">${esc(base(it.path))}</span><span class="mono">${esc(folder(it.path))}</span>`;
    case "create":
      return single ? `Created ${fileLink(it)}` : `<span class="file">${esc(base(it.path))}</span><span class="mono">${esc(folder(it.path))}</span>`;
    case "read":
      return single ? `Read ${fileLink(it)}` : `<span class="file">${esc(base(it.path))}</span><span class="mono">${esc(folder(it.path))}</span>`;
    case "search":
      return `${single ? "Searched for " : ""}<code>${esc(it.pattern)}</code><span class="mono">${it.where ? "in " + esc(it.where) : ""}</span>`;
    case "web":
      if (it.tool === "WebSearch") return `${single ? "Searched the web for " : ""}“${esc(it.query)}”`;
      return `${single ? "Fetched " : ""}<span class="file">${esc(new URL(it.url).host)}</span><span class="mono">${esc(new URL(it.url).pathname)}</span>`;
    case "agent":
      return `${esc(it.desc)}<span class="mono">${esc(it.type)}</span>`;
    default:
      return esc(it.label || it.tool);
  }
}

/** What a live call says it is doing (01-run.md "Live labels"). */
function liveText(it) {
  switch (it.kind) {
    case "command":
      return it.desc ? esc(it.desc) : `<span class="mono cmdline">${esc(it.partial ?? firstLine(it.cmd))}</span><span class="caret"></span>`;
    case "change": return `Editing <span class="file">${esc(base(it.path))}</span>`;
    case "create": return `Writing <span class="file">${esc(base(it.path))}</span>`;
    case "read": return `Reading <span class="file">${esc(base(it.path))}</span>`;
    case "search": return `Searching for <code>${esc(it.pattern)}</code>`;
    case "web": return it.tool === "WebSearch" ? `Searching the web for “${esc(it.query)}”` : `Fetching <span class="file">${esc(new URL(it.url).host)}</span>`;
    case "agent": return esc(it.desc);
    default: return esc(it.label || it.tool);
  }
}

function itemMeta(it) {
  const stat = () => (it.add != null ? `<span class="add">+${it.add}</span><span class="del">−${it.del}</span>` : "");
  switch (it.state) {
    case "failed": return '<span class="failw">Failed</span>';
    case "denied": return "Denied";
    case "interrupted": return "Interrupted";
    case "waiting": return "Needs approval";
    case "background": return "Background";
    case "running": return it.kind === "agent" && it.progress ? `${esc(it.progress)} · ${fmtDur(it.elapsed || 0)}` : fmtDur(it.elapsed || 0);
    case "streaming": return it.kind === "create" && it.streamLines ? `${it.streamLines} lines` : "";
  }
  if (it.bgDur) return `Background · ${it.bgDur}`;
  switch (it.kind) {
    case "change": return stat();
    case "create": return `New · ${it.lines} lines`;
    case "read": return it.image ? "Image" : `lines ${it.from}–${it.to}`;
    case "search": return plural(it.files, "1 file", "# files");
    case "web": return it.tool === "WebSearch" ? `${it.results} results` : String(it.code);
    case "agent": return `${it.tools} tools · ${fmtDur(it.dur)}`;
    default: return it.dur >= 10 ? fmtDur(it.dur) : "";
  }
}

const LIVE = new Set(["streaming", "waiting", "running"]);

function runTile(r) {
  const live = r.items.find((i) => LIVE.has(i.state));
  if (live) return tile(live.kind, live.state);
  const last = r.items[r.items.length - 1];
  // The tile shows how the run ended; the sentence counts what failed on the way.
  if (["failed", "denied", "interrupted"].includes(last.state)) return tile(last.kind, last.state);
  const kind = ORDER.find((k) => r.items.some((i) => i.kind === k)) || "other";
  const bg = r.items.some((i) => i.state === "background");
  return tile(kind, bg ? "background" : "done");
}

function runLine(r) {
  const waiting = r.items.find((i) => i.state === "waiting");
  const running = r.items.filter((i) => i.state === "running");
  const streaming = r.items.find((i) => i.state === "streaming");
  if (waiting) return { text: "Waiting for your approval", meta: "" };
  if (running.length > 1) {
    const same = running.every((i) => i.kind === running[0].kind);
    const oldest = Math.max(...running.map((i) => i.elapsed || 0));
    return { text: same && running[0].kind === "command" ? `Running ${running.length} commands` : `Running ${running.length} calls`, meta: fmtDur(oldest) };
  }
  if (running.length === 1) return { text: liveText(running[0]), meta: itemMeta(running[0]) };
  if (streaming) return { text: liveText(streaming), meta: itemMeta(streaming) };
  // Settled (or between calls): the sentence so far.
  if (r.items.length === 1) {
    const it = r.items[0];
    return { text: callText(it, true), exc: "", meta: itemMeta(it) };
  }
  let add = 0, del = 0, changed = false;
  for (const it of r.items) {
    if (it.kind === "change" && it.state === "done") { add += it.add; del += it.del; changed = true; }
    if (it.kind === "create" && it.state === "done") { add += it.lines; changed = true; }
  }
  const meta = [];
  if (changed) meta.push(`<span class="add">+${add}</span><span class="del">−${del}</span>`);
  if (r.dur >= 10) meta.push(fmtDur(r.dur));
  return { text: sentence(r.items), exc: exceptions(r.items), meta: meta.join("") };
}

function itemRow(it) {
  const tileState = it.state === "done" ? "done" : it.state;
  let h = `<div class="line" data-open="${it.id}">${tile(it.kind, tileState)}<span class="sum">${
    LIVE.has(it.state) && it.state !== "waiting" ? liveText(it) : callText(it, false)
  }</span><span class="meta">${itemMeta(it)}</span>${ICON.go}</div>`;
  if (it.state === "failed" && it.error) h += `<div class="err">${esc(it.error)}</div>`;
  return h;
}

const LIST_CAP = 12;

function approvalCard(it) {
  let what = "";
  if (it.kind === "command") what = `<pre>${esc(it.cmd)}</pre>`;
  else if (it.diff) what = `<div class="mini src">${sourceLines(it.diff, it.path, { compact: true })}</div>`;
  return `<div class="approval">
    <div class="head">${tile(it.kind, "waiting")}<span>${it.kind === "command" ? esc(it.desc || "Run a command") : `Edit ${esc(base(it.path))}`}</span></div>
    ${what}
    ${it.why ? `<div class="why">${esc(it.why)}</div>` : ""}
    <div class="buttons"><button class="btn plain">Always Allow ▾</button><button class="btn" data-deny="${it.id}">Deny<kbd>⎋</kbd></button><button class="btn primary" data-allow="${it.id}">Allow<kbd>⌘↩</kbd></button></div>
  </div>`;
}

function renderRun(r) {
  if (!r.items.length) return ""; // a run exists from its first call's first byte
  const single = r.items.length === 1;
  const { text, exc, meta } = runLine(r);
  const x = exc ? `<span class="exc">${exc}</span>` : "";
  const head = single
    ? `<div class="line" data-open="${r.items[0].id}">${runTile(r)}<span class="sum">${text}</span>${x}<span class="meta">${meta}</span>${ICON.go}</div>`
    : `<div class="line" data-toggle="${r.id}">${runTile(r)}<span class="sum">${text}</span>${x}<span class="meta">${meta}</span>${ICON.chevron}</div>`;
  let body = "";
  if (!single && r.open) {
    const shown = r.all ? r.items : r.items.slice(0, LIST_CAP);
    body = `<div class="items">${shown.map(itemRow).join("")}${
      shown.length < r.items.length ? `<div class="more" data-more="${r.id}">Show ${r.items.length - shown.length} more</div>` : ""
    }</div>`;
  }
  const waiting = r.items.find((i) => i.state === "waiting");
  return `<div class="run${r.open ? " open" : ""}">${head}${body}${waiting ? approvalCard(waiting) : ""}</div>`;
}

// MARK: - Other rows

function paragraphs(md) {
  return md.split(/\n\n/).map((p) => `<p>${inline(p)}</p>`).join("");
}
function inline(s) {
  return esc(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
}

const NEWS_KIND = { command: "command", agent: "agent", workflow: "workflow", monitor: "monitor", remote: "agent" };
function newsLine(n) {
  const failed = n.status === "failed" || n.status === "killed";
  const text = inline(n.summary).replace(/\b(failed|killed)\b/, '<span class="fail">$1</span>');
  return `<div class="line" data-open="${n.id}">${tile(NEWS_KIND[n.task] || "other", failed ? "failed" : "done")}<span class="sum">${text}</span><span class="meta">${esc(n.meta || "")}</span>${
    n.origin ? `<span class="go origin" title="Show the call that started it" data-origin="${n.origin}">↖</span>` : ICON.go
  }</div>`;
}
function renderNews(row) {
  if (row.news.length === 1) return newsLine(row.news[0]);
  const failed = row.news.filter((n) => n.status === "failed" || n.status === "killed").length;
  const text = `${row.news.length} background tasks finished${failed ? ` · <span class="fail">${failed} failed</span>` : ""}`;
  return `<div class="run${row.open ? " open" : ""}"><div class="line" data-toggle="${row.id}">${tile("command", "done")}<span class="sum">${text}</span><span class="meta"></span>${ICON.chevron}</div>${
    row.open ? `<div class="items">${row.news.map(newsLine).join("")}</div>` : ""
  }</div>`;
}

function renderRow(row) {
  switch (row.type) {
    case "user": return `<div class="user"><div class="bubble">${inline(row.text)}</div></div>`;
    case "text": {
      const html = paragraphs(row.text || " ");
      return `<div class="text">${row.streaming ? html.replace(/<\/p>$/, '<span class="caret"></span></p>') : html}</div>`;
    }
    case "run": return renderRun(row.run);
    case "news": return renderNews(row);
    case "slash": {
      // The output sits under the capsule, as Messages sets "Delivered" under a bubble.
      const more = row.long ? ` · <span class="link" data-open="${row.long}">Show all</span>` : "";
      const out = row.out ? `<div class="cap-out${row.err ? " err" : ""}">${esc(row.out)}${more}</div>` : "";
      return `<div class="capsule-row"><span class="capsule" title="${esc(row.full || row.name)}"><span class="sym">/</span><b>${esc(row.name.replace(/^\//, ""))}</b>${row.args ? " " + esc(row.args) : ""}</span>${out}</div>`;
    }
    case "shell": {
      const lines = row.item.out.length;
      const out = lines === 1 ? `<div class="cap-out">${esc(row.item.out[0])}</div>` : `<div class="cap-out">${lines} lines</div>`;
      return `<div class="capsule-row"><span class="capsule" data-open="${row.item.id}"><span class="sym">$</span><b>${esc(row.item.cmd)}</b>${lines === 1 ? "" : ICON.go.replace('class="go"', 'class="go" style="opacity:1;width:10px;height:10px"')}</span>${out}</div>`;
    }
    case "divider": return `<div class="divider"><span>${row.live ? `<span class="dtile">${tile("other", "running")}</span>` : ""}${row.text}${row.link ? `<span class="link" data-open="${row.link}">${row.linkText || "Summary"}</span>` : ""}</span></div>`;
    case "interrupt": return `<div class="interrupt">${ICON.stopcircle}Interrupted</div>`;
    case "voice": return `<div class="voice"><div class="who">${row.glyph}${esc(row.who)}</div><div class="vb">${paragraphs(row.text)}${row.more ? `<p><span class="more" data-open="${row.more}">More</span></p>` : ""}</div></div>`;
    case "question": return renderQuestion(row);
    case "plan": return `<div class="plan"><div class="ph">${tile("plan", row.live ? "waiting" : "done")}<span>Plan</span><span class="open" data-open="${row.doc}">Open ›</span></div><ol>${row.steps.map((s) => `<li>${inline(s)}</li>`).join("")}</ol>${
      row.live ? `<div class="buttons" style="display:flex;justify-content:flex-end;gap:8px;margin-top:8px"><button class="btn">Keep Planning</button><button class="btn primary">Approve<kbd>⌘↩</kbd></button></div>` : ""
    }</div>`;
    case "html": return row.html;
  }
  return "";
}

function renderQuestion(row) {
  const opts = row.options.map((o) => {
    const on = !row.live && o.label === row.answer;
    return `<div class="opt${on ? " on" : ""}${row.live ? " live" : ""}"><span class="radio"></span><span>${esc(o.label)}</span><span class="d">${esc(o.description)}</span></div>`;
  }).join("");
  return `<div class="qa">${tile("question", row.live ? "waiting" : "done")}<div><div class="hdr">${esc(row.header)}</div><div class="q">${esc(row.question)}</div>${opts}${
    row.live ? '<div class="submit"><button class="btn primary">Submit<kbd>⌘↩</kbd></button></div>' : ""
  }</div></div>`;
}

// MARK: - Columns: a transcript's rows, re-rendered a row at a time

class Column {
  constructor(el, rows) {
    this.id = nid("c");
    this.el = el;
    this.rows = rows;
    COLUMNS.set(this.id, this);
    el.dataset.column = this.id;
    for (const row of rows) this.adopt(row);
    this.render();
  }
  adopt(row) {
    row.id = row.id || nid("row");
    row.column = this.id;
    if (row.type === "run") { row.run.row = row; RUNS.set(row.run.id, row.run); }
    if (row.type === "news") RUNS.set(row.id, row);
  }
  render() {
    this.el.innerHTML = this.rows.map((row) => `<div class="row${row.tight ? " tight" : ""}" data-row="${row.id}">${renderRow(row)}</div>`).join("");
    markSelection();
  }
  update(row) {
    const el = this.el.querySelector(`[data-row="${row.id}"]`);
    if (el) el.innerHTML = renderRow(row);
    markSelection();
  }
  append(row) {
    this.adopt(row);
    this.rows.push(row);
    const div = document.createElement("div");
    div.className = `row${row.tight ? " tight" : ""}`;
    div.dataset.row = row.id;
    div.innerHTML = renderRow(row);
    this.el.appendChild(div);
  }
}

function rowOfItem(id) {
  for (const col of COLUMNS.values())
    for (const row of col.rows) {
      if (row.type === "run" && row.run.items.some((i) => i.id === id)) return { col, row };
      if (row.type === "news" && row.news.some((n) => n.id === id)) return { col, row };
      if (row.type === "shell" && row.item.id === id) return { col, row };
    }
  return null;
}
function refresh(id) {
  const hit = rowOfItem(id);
  if (hit) hit.col.update(hit.row);
  if (PLAY && PLAY.showing(id)) PLAY.renderDoc();
}

// MARK: - Syntax

const SWIFT_KW = new Set("import let var func return if else guard for in while switch case default private public internal fileprivate static final class struct enum extension protocol init self Self nil true false override lazy didSet willSet some any throws try await async where as is".split(" "));
function hlSwift(line) {
  // ⟦…⟧ marks the characters that changed within a line.
  return line.split(/(⟦[^⟧]*⟧)/).map((seg) => {
    const changed = seg.startsWith("⟦");
    const body = hlSwiftSeg(changed ? seg.slice(1, -1) : seg);
    return changed ? `<span class="hl">${body}</span>` : body;
  }).join("");
}
function hlSwiftSeg(s) {
  const re = /(\/\/.*$)|("(?:[^"\\]|\\.)*")|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)|(\s+)|(.)/g;
  let out = "", m, prev = "";
  while ((m = re.exec(s))) {
    const [tok, com, str, num, id] = m;
    if (com) out += `<span class="c">${esc(com)}</span>`;
    else if (str) out += `<span class="s">${esc(str)}</span>`;
    else if (num) out += `<span class="num">${num}</span>`;
    else if (id) {
      const next = s[re.lastIndex];
      if (SWIFT_KW.has(id)) out += `<span class="k">${id}</span>`;
      else if (/^[A-Z]/.test(id)) out += `<span class="ty">${id}</span>`;
      else if (prev === "." || next === "(") out += `<span class="fn">${id}</span>`;
      else out += id;
    } else out += esc(tok);
    if (!/^\s+$/.test(tok)) prev = tok;
  }
  return out;
}
function hlShell(cmd) {
  const m = cmd.match(/^(cd \S+ &&)\s*/);
  let pre = "", rest = cmd;
  if (m) { pre = `<span class="pre">${esc(m[1])}</span>\n`; rest = cmd.slice(m[0].length); }
  const re = /('[^']*'|"(?:[^"\\]|\\.)*")|(#.*$)|(&&|\|\||\||;|\$\()|(\$\w+)|(\S+)|(\s+)/gm;
  let out = "", atCmd = true, t;
  while ((t = re.exec(rest))) {
    const [tok, str, com, op, v, word] = t;
    if (str) { out += `<span class="s">${esc(str)}</span>`; atCmd = false; }
    else if (com) out += `<span class="c">${esc(com)}</span>`;
    else if (op) { out += esc(op); atCmd = true; }
    else if (v) out += `<span class="ty">${esc(v)}</span>`;
    else if (word) {
      if (atCmd && !word.includes("=")) { out += `<span class="fn">${esc(word)}</span>`; atCmd = false; }
      else out += esc(word);
    } else { out += esc(tok); if (tok.includes("\n")) atCmd = true; }
  }
  return pre + out;
}

// MARK: - Documents

function jumpBar(crumbs, extra = "", kind, state) {
  const cs = crumbs.map((c, i) => `<span class="c${i === crumbs.length - 1 ? " last" : ""}">${esc(c)}</span>`).join('<span class="sep">›</span>');
  return `<div class="jump">${kind ? tile(kind, state || "done") : ""}<span class="crumbs">${cs}</span>${extra}<span class="spacer"></span><span class="back" data-reveal="1">${ICON.back}Show in Transcript</span></div>`;
}
const pathCrumbs = (p) => {
  const parts = p.split("/");
  return parts.length > 4 ? [parts[0], parts[1], "…", parts[parts.length - 2], parts[parts.length - 1]] : parts;
};
function approvalBar(it, text) {
  return `<div class="approvalbar">${tile(it.kind, "waiting")}<b style="font-weight:600">${text}</b><span class="why">${esc(it.why || "")}</span><button class="btn" data-deny="${it.id}">Deny</button><button class="btn primary" data-allow="${it.id}">Allow</button></div>`;
}

function outLines(lines, badTest = /error:|fatal:|FAILED|Error \d/) {
  return `<div class="out mono">${lines.map((l, i) => `<span class="n${badTest.test(l) ? " bad" : ""}">${i + 1}</span><span class="t">${ansi(l)}</span>`).join("")}</div>`;
}
function ansi(l) {
  // Mapped SGR, as the output view would: bold, green, red.
  return esc(l).replace(/\x1b\[1;32m(.*?)\x1b\[0m/g, '<span class="ansi-green ansi-bold">$1</span>').replace(/\x1b\[31m(.*?)\x1b\[0m/g, '<span class="ansi-red">$1</span>');
}

function commandDoc(it) {
  const st = [];
  const title = it.local ? "You ran" : it.desc || "Command";
  if (it.state === "failed") st.push(`<span class="bad">Failed</span> · exit ${it.exit ?? 1}`);
  if (it.state === "running") st.push(`Running · ${fmtDur(it.elapsed || 0)}`);
  if (it.state === "background") st.push(`Running in background · ${fmtDur(it.elapsed || 0)}`);
  if (it.state === "waiting") st.push("Waiting for your approval");
  if (it.state === "denied") st.push("Denied");
  if (it.state === "interrupted") st.push("Interrupted");
  if (it.state === "streaming") st.push("Preparing");
  if (it.local) st.push("Local");
  if (it.bgDur) st.push(`Background · ${it.bgDur}`);
  else if (it.dur && ["done", "failed"].includes(it.state)) st.push(fmtDur(it.dur));
  if (it.sandboxOff) st.push(`<span class="warn">${ICON.shield}Sandbox off</span>`);
  let out = "";
  if (it.state === "streaming") out = "";
  else if (it.state === "running") out = `<div class="waiting">${tile("command", "running")}Output appears when the command finishes.</div>`;
  else if (it.state === "waiting" || it.state === "denied") out = "";
  else if (it.state === "background" && it.following) out = `${outLines(it.following)}<div class="footer-note"><span class="follow">${tile("command", "background")}Following ${esc(it.outputFile)}</span></div>`;
  else {
    if (it.note) out += `<div class="info">${ICON.info}${esc(it.note)}</div>`;
    out += it.out && it.out.length ? outLines(it.out) : '<div class="waiting">No output</div>';
    if (it.stderr && it.stderr.length) out += `<div class="out-head">stderr</div>${outLines(it.stderr, /./)}`;
    if (it.persisted) out += `<div class="footer-note">${ICON.info}Output was too long to keep here. The full output is in <span class="mono">${esc(it.persisted)}</span><button class="btn">Open</button></div>`;
  }
  const cmdText = it.state === "streaming" ? `${hlShell(it.partial || "")}<span class="caret"></span>` : hlShell(it.cmd);
  return `<div class="doc">${jumpBar([title.length > 40 ? title.slice(0, 39) + "…" : title], "", "command", it.state)}<div class="body">${
    it.state === "waiting" ? approvalBar(it, "Claude wants to run this command") : ""
  }<div class="cmd"><h4>${esc(title)}</h4><div class="status">${st.join(" · ")}</div><div class="card mono"><span class="dollar">$</span>${cmdText}<span class="copy">${ICON.copy}</span></div>${out}</div></div></div>`;
}

/** Diff rows: ["ctx", n, text] ["add", n, text] ["del", null, text] ["fold", label] ["note", text, bad?] */
function sourceLines(rows, path, opts = {}) {
  const swift = /\.swift$/.test(path || "");
  return rows.map((r) => {
    const [t, a, b] = r;
    if (t === "fold") return opts.compact ? "" : `<div class="fold"><span></span><span>⋯ ${esc(a)}</span></div>`;
    if (t === "note") return `<div class="note${b ? " bad" : ""}">${b ? ICON.octagon : ICON.info}${esc(a)}</div>`;
    const text = swift ? hlSwift(b) : esc(b).replace(/⟦|⟧/g, "");
    return `<div class="l ${t}"><span class="n">${a ?? ""}</span><span class="bar"></span><span class="t">${text || " "}</span></div>`;
  }).join("");
}

function changeDoc(it) {
  const stat = `<span class="jstat"><span class="add">+${it.add}</span> <span class="del">−${it.del}</span></span>`;
  const bar = it.state === "waiting" ? approvalBar(it, "Claude wants to make this edit") : "";
  return `<div class="doc">${jumpBar(pathCrumbs(it.path), stat, "change", it.state === "done" ? "done" : it.state)}<div class="body">${bar}<div class="src">${sourceLines(it.diff || [], it.path)}</div></div></div>`;
}
function createDoc(it) {
  const rows = it.code.split("\n").map((l, i) => ["ctx", i + 1, l]);
  return `<div class="doc">${jumpBar(pathCrumbs(it.path), `<span class="jstat">New · ${it.lines} lines</span>`, "create")}<div class="body"><div class="src new">${sourceLines(rows, it.path)}</div></div></div>`;
}
/** The file map stands for the whole file, the read slice filled: how much
 *  the agent saw, and where. It sits on the view, not on the scrolled text. */
function readDoc(it) {
  const rows = it.code.split("\n").map((l, i) => ["ctx", it.from + i, l]);
  const top = ((it.from - 1) / it.total) * 100;
  const h = Math.max(1.5, ((it.to - it.from + 1) / it.total) * 100);
  return `<div class="doc">${jumpBar(pathCrumbs(it.path), `<span class="jstat">Lines ${it.from}–${it.to} of ${it.total}</span>`, "read")}<div style="position:relative;min-height:0"><div class="body readbody" style="height:100%;padding-right:12px"><div class="src">${sourceLines(rows, it.path)}</div></div><div class="filemap" title="Lines ${it.from}–${it.to} of ${it.total}"><i style="top:${top}%;height:${h}%"></i></div></div></div>`;
}
function searchDoc(it) {
  const rows = it.matches.map(([p, n]) => `<div class="line" style="height:24px"><span class="sum"><span class="file">${esc(base(p))}</span><span class="mono">${esc(folder(p))}</span></span><span class="meta">${n}</span></div>`).join("");
  return `<div class="doc">${jumpBar([`Search: ${it.pattern}`], `<span class="jstat">${it.files} files</span>`, "search")}<div class="body"><div class="md"><h4>“${esc(it.pattern)}”</h4><div class="status">in ${esc(it.where || "the project")} · ${it.files} files</div>${rows}</div></div></div>`;
}
function markdownDoc(title, kind, status, md, extra = "") {
  return `<div class="doc">${jumpBar([title], "", kind)}<div class="body"><div class="md"><h4>${esc(title)}</h4><div class="status">${status}</div>${extra}${paragraphsMd(md)}</div></div></div>`;
}
function paragraphsMd(md) {
  return md.split(/\n\n/).map((p) => {
    if (/^- /.test(p)) return `<ul>${p.split("\n").map((l) => `<li>${inline(l.replace(/^- /, ""))}</li>`).join("")}</ul>`;
    return `<p>${inline(p)}</p>`;
  }).join("");
}
function agentDoc(it) {
  const status = it.state === "running" ? `${esc(it.type)} · ${esc(it.progress || "")} · ${fmtDur(it.elapsed || 0)}` : `${esc(it.type)} · ${it.tools} tools · ${fmtDur(it.dur)}`;
  const open = `<p><span class="btn" data-open="${it.sub}">Open Agent’s Transcript</span></p>`;
  return markdownDoc(it.desc, "agent", status, it.result || "The agent is still working.", it.sub ? open : "");
}
function checklistDoc(it) {
  const rows = it.list.map(([t, s]) => `<div class="ci${s === "done" ? " done" : ""}">${s === "doing" ? tile("tasks", "running") : '<span class="box"></span>'}<span>${esc(t)}</span></div>`).join("");
  return `<div class="doc">${jumpBar(["Task list"], "", "tasks")}<div class="body"><div class="check"><h4>Task list</h4>${rows}</div></div></div>`;
}
function transcriptDoc(it) {
  return `<div class="doc">${jumpBar([it.title], "", "agent")}<div class="body"><div class="transcript" data-subtranscript="${it.id}" style="max-width:600px;margin:0 auto;padding:16px 24px"></div></div></div>`;
}

function docFor(id) {
  const it = ITEMS.get(id);
  if (!it) return '<div class="empty">Nothing to show</div>';
  if (it.docKind === "markdown") return markdownDoc(it.title, it.docGlyph || "other", it.status || "", it.md);
  if (it.docKind === "transcript") return transcriptDoc(it);
  switch (it.kind) {
    case "command": return commandDoc(it);
    case "change": return changeDoc(it);
    case "create": return createDoc(it);
    case "read": return readDoc(it);
    case "search": return searchDoc(it);
    case "agent": return agentDoc(it);
    case "tasks": return checklistDoc(it);
    case "news": return it.origin ? docFor(it.origin) : markdownDoc(it.title, it.glyph, it.status || "", it.md);
  }
  return '<div class="empty">No document</div>';
}
function mountDoc(el, id) {
  el.innerHTML = docFor(id);
  const sub = el.querySelector("[data-subtranscript]");
  if (sub) new Column(sub, ITEMS.get(id).rows());
}
function docTitle(id) {
  const it = ITEMS.get(id);
  if (!it) return "";
  if (it.title) return it.title;
  if (it.kind === "command") return it.local ? `$ ${it.cmd}` : it.desc || firstLine(it.cmd);
  if (it.path) return base(it.path);
  if (it.kind === "search") return `“${it.pattern}”`;
  if (it.kind === "agent") return it.desc;
  if (it.kind === "tasks") return "Task list";
  if (it.kind === "news") return it.origin ? docTitle(it.origin) : it.title;
  return it.tool;
}
