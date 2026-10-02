// Live sessions — the New tab, the + on every tab bar, the composer
// (08-live.md). A window with a sidebar and editor groups; every session is a
// small state machine that follows the CLI's rules for what applies when.
// Loads after preview.js and preview-sheet.js and reuses their rows.
"use strict";

// MARK: - The catalog (initialize's models / commands, CLI 2.1.286)

const EFFORTS = [["low", "Low"], ["medium", "Medium"], ["high", "High"], ["xhigh", "Extra High"], ["max", "Max"]];
const ALL5 = EFFORTS.map((e) => e[0]);
const NO_X = ["low", "medium", "high", "max"];
const MODELS = [
  { v: "default", label: "Default (recommended)", short: "Opus 5.5", sub: "Opus 5.5", eff: ALL5, fast: true, auto: true },
  { v: "opus", label: "Opus 5.5", eff: ALL5, fast: true, auto: true },
  { v: "fable", label: "Fable 5.1", eff: ALL5, auto: true },
  { v: "sonnet", label: "Sonnet 5.5", eff: ALL5, auto: true },
  { v: "haiku", label: "Haiku 4.5", eff: [], auto: false },
  { v: "opus-5", label: "Opus 5", other: true, eff: ALL5, fast: true, auto: true },
  { v: "sonnet-5", label: "Sonnet 5", other: true, eff: ALL5, auto: true },
  { v: "fable-5", label: "Fable 5", other: true, eff: ALL5, auto: true },
  { v: "opus-4-8", label: "Opus 4.8", other: true, eff: ALL5, fast: true, auto: true, refused: "Opus 4.8 isn't available to your organization." },
  { v: "opus-4-7", label: "Opus 4.7", other: true, eff: ALL5, auto: true },
  { v: "opus-4-6", label: "Opus 4.6", other: true, eff: NO_X, auto: true },
  { v: "sonnet-4-6", label: "Sonnet 4.6", other: true, eff: NO_X, auto: true },
];
const MODEL = (v) => MODELS.find((m) => m.v === v);
const shortName = (v) => MODEL(v).short || MODEL(v).label;

const MODES = [
  { v: "default", label: "Ask Permissions", short: "Ask", sub: "Asks before edits and commands" },
  { v: "acceptEdits", label: "Accept Edits", short: "Accept Edits", sub: "Edits files without asking; asks before commands" },
  { v: "plan", label: "Plan", short: "Plan", sub: "Reads and plans; changes nothing" },
  { v: "auto", label: "Auto", short: "Auto", sub: "Approves safe actions, asks when unsure" },
  { v: "dontAsk", label: "Don't Ask", short: "Don't Ask", sub: "Runs only what's already allowed" },
  { v: "bypassPermissions", label: "Bypass Permissions", short: "Bypass", sub: "Runs everything without asking", danger: true },
];
const MODE = (v) => MODES.find((m) => m.v === v);
const CYCLE = ["default", "acceptEdits", "plan", "auto"]; // ⇧⇥, the CLI's own order

const FOLDERS = [
  { name: "ccterm", path: "~/dev/ccterm", branch: "main" },
  { name: "ghostty", path: "~/dev/ghostty", branch: "main" },
  { name: "claude-notes", path: "~/notes/claude-notes", branch: null },
  { name: "dotfiles", path: "~/dotfiles", branch: "master" },
];
const ACCOUNTS = ["Claude Max", "Work Relay"];
const COMMANDS = [
  ["model", "[model]", "Set the AI model for this session"],
  ["effort", "[low|medium|high|xhigh|max]", "Set how hard Claude thinks"],
  ["compact", "[instructions]", "Clear history but keep a summary in context"],
  ["context", "", "Show what's in the context window"],
  ["clear", "", "Start a new conversation in this session"],
  ["review", "[PR]", "Review a pull request"],
  ["dataviz", "[request]", "Charts, dashboards and data visualizations"],
  ["fast", "[on|off]", "Toggle fast mode"],
];

// Settings a viewer can flip on the sheet (they're app settings, not session state).
const LV_SETTINGS = { allowBypass: false, accounts: 1 };
// The last choices made in a New tab — the next New tab starts from them.
const LAST = { model: "default", effort: "high", mode: "auto", fast: false, draft: "" };

// MARK: - Glyphs (16-pt grid, SF Symbol weight)

const svg16 = (body, cls = "g", extra = "") => `<svg class="${cls}" viewBox="0 0 16 16" aria-hidden="true"${extra}><g fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">${body}</g></svg>`;
const SHIELD = "M8 2.8l-4.3 1.7v3.2c0 2.6 1.8 4.4 4.3 5.4 2.5-1 4.3-2.8 4.3-5.4V4.5z";
const MODE_GLYPH = {
  default: `<path d="${SHIELD}"/>`,
  acceptEdits: GLYPHS.change,
  plan: GLYPHS.plan,
  auto: `<path d="${lame(7, 9, 3.6, 3.6, 0.75, 48)}" fill="currentColor" stroke="none"/><path d="${lame(12, 4.2, 1.7, 1.7, 0.75, 32)}" fill="currentColor" stroke="none"/>`,
  dontAsk: '<circle cx="8" cy="8" r="4.6"/><path d="M4.9 11.1l6.2-6.2"/>',
  bypassPermissions: `<path d="${SHIELD}"/><path d="M8 5.6v3"/>${dot(8, 10.6)}`,
};
const LV = {
  chev: '<svg class="cv" viewBox="0 0 8 8"><path d="M1.5 3l2.5 2.5L6.5 3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  chev2: '<svg class="chev2" viewBox="0 0 12 12"><path d="M3 4.8L6 7.8l3-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  plus: '<svg width="10" height="10" viewBox="0 0 10 10"><path d="M5 1v8M1 5h8" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>',
  up: '<svg viewBox="0 0 14 14"><path d="M7 11.5V3M3.2 6.6L7 2.8l3.8 3.8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  stop: '<svg viewBox="0 0 10 10"><rect x="0.5" y="0.5" width="9" height="9" rx="2" fill="currentColor"/></svg>',
  check: '<svg class="ck" viewBox="0 0 10 10"><path d="M1.5 5.4l2.3 2.3L8.6 2.4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  clock: '<svg class="pend" viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="none" stroke="currentColor" stroke-width="1.1"/><path d="M5 2.8V5l1.5 1" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round"/></svg>',
  bolt: '<svg class="bolt" viewBox="0 0 10 12"><path d="M6.2.8L1.4 7h3.1l-.8 4.2L8.6 5H5.4z" fill="currentColor"/></svg>',
  sub: '<svg width="7" height="9" viewBox="0 0 7 9"><path d="M1.5 1l4 3.5-4 3.5" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  folder: '<path d="M2.8 5.2V4.4c0-.6.4-1 1-1h2.6l1.2 1.4h4.6c.6 0 1 .4 1 1v5.8c0 .6-.4 1-1 1H3.8c-.6 0-1-.4-1-1z"/>',
  branch: '<svg width="9" height="10" viewBox="0 0 9 10"><circle cx="2.2" cy="2" r="1.2" fill="none" stroke="currentColor"/><circle cx="2.2" cy="8" r="1.2" fill="none" stroke="currentColor"/><circle cx="6.8" cy="3.4" r="1.2" fill="none" stroke="currentColor"/><path d="M2.2 3.2v3.6M6.8 4.6c0 1.6-4.6 1-4.6 2.2" fill="none" stroke="currentColor"/></svg>',
};
// The glyph fills the middle of its 16-pt box; the crop sets it at its own size.
const sessionGlyph = (size, color = "var(--coral)") => `<svg width="${size}" height="${size}" viewBox="3.6 3.4 8.8 9" style="color:${color}" aria-hidden="true">${GLYPHS.session}</svg>`;

/** The effort glyph: five bars rising, filled to the level — the composer's one ornament. */
function bars(level) {
  const n = level ? ALL5.indexOf(level) + 1 : 0;
  let s = "";
  for (let i = 0; i < 5; i++) {
    const h = 3 + i * 2.25;
    s += `<rect x="${1 + i * 2.9}" y="${13 - h}" width="2" height="${h}" rx=".8" fill="currentColor" opacity="${i < n ? 1 : 0.28}"/>`;
  }
  return `<svg class="g" viewBox="0 0 16 16" aria-hidden="true">${s}</svg>`;
}
const arcMark = () => '<svg class="arcmark" viewBox="0 0 12 12"><circle class="bgc" cx="6" cy="6" r="4.6"/><circle class="fgc" cx="6" cy="6" r="4.6"/></svg>';
function ringHTML(p) {
  return `<span class="ring" data-lv="context" title="${Math.round(p * 200)}k / 200k tokens — click for /context"><svg viewBox="0 0 14 14"><circle class="bgc" cx="7" cy="7" r="5.5"/><circle class="fgc" cx="7" cy="7" r="5.5" pathLength="100" stroke-dasharray="${Math.round(p * 100)} 100"/></svg>${Math.round(p * 100)} %</span>`;
}

// MARK: - A session: the draft before Send, the CLI's state after

const LIVE_STATES = new Set(["starting", "responding", "waiting", "compacting"]);
const WORKING = new Set(["responding", "waiting", "compacting"]);
const SESSIONS = new Map();

function draft(o = {}) {
  const s = {
    id: nid("s"), state: "new", folder: FOLDERS[0], worktree: false, account: 0,
    model: LAST.model, effort: LAST.effort, mode: LAST.mode, fast: LAST.fast,
    pendingModel: null, pendingFast: null, title: "New Session", rows: [], ctx: 0, err: "", text: "", token: null, ...o,
  };
  SESSIONS.set(s.id, s);
  return s;
}
const isNew = (s) => s.state === "new";
const shownModel = (s) => s.pendingModel || s.model;
const shownFast = (s) => (s.pendingFast != null ? s.pendingFast : s.fast);
/** The effort that will run: the CLI runs an unsupported level as High. */
function effectiveEffort(s) {
  const m = MODEL(shownModel(s));
  if (!m.eff.length) return null;
  return m.eff.includes(s.effort) ? s.effort : "high";
}

// MARK: - Choosing: each control knows when its change lands (08-live.md "Settings × state")

function chooseModel(s, v) {
  const m = MODEL(v);
  const before = { model: s.model, pending: s.pendingModel };
  if (isNew(s) || s.state === "rest" || s.state === "failed" || s.state === "starting") {
    s.model = v; s.pendingModel = null; // a flag on launch / resume, or held until initialize
  } else if (WORKING.has(s.state)) {
    s.pendingModel = v === s.model ? null : v; // applies after this turn
  } else {
    // Idle: set_model now; the CLI checks entitlement (≈ 1.5 s), then echoes /model.
    s.model = v;
    setTimeout(() => {
      if (m.refused) {
        s.model = before.model; s.err = m.refused; s.fastCascade = false; LW.refresh(s); return;
      }
      echoModel(s, v);
    }, 1500);
  }
  // Cascades: Fast needs a fast model; Auto needs a model with Auto.
  if (!m.fast && shownFast(s)) setFast(s, false, true);
  if (!m.auto && s.mode === "auto") { s.mode = "default"; flashLater(s, "mode"); }
  s.err = "";
  if (isNew(s)) LAST.model = v;
  flashLater(s, "model");
  LW.refresh(s);
}
function echoModel(s, v) {
  appendRow(s, { type: "slash", name: "/model", args: v, out: `Set model to ${MODEL(v).short || MODEL(v).label}` });
}
function setFast(s, on, quiet) {
  if (WORKING.has(s.state)) s.pendingFast = on === s.fast ? null : on;
  else s.fast = on;
  if (on && s.mode === "auto") { s.mode = "default"; flashLater(s, "mode"); }
  if (isNew(s)) LAST.fast = on;
  if (!quiet) LW.refresh(s);
}
function chooseEffort(s, v) {
  s.effort = v; // apply_flag_settings: from the next request, mid-turn included
  if (isNew(s)) LAST.effort = v;
  flashLater(s, "effort");
  LW.refresh(s);
}
function chooseMode(s, v) {
  s.mode = v; // set_permission_mode: now
  if (isNew(s)) LAST.mode = v;
  flashLater(s, "mode");
  LW.refresh(s);
}
function modeAvailable(s, v) {
  const m = MODEL(shownModel(s));
  if (v === "auto" && shownFast(s)) return "Unavailable while Fast Mode is on";
  if (v === "auto" && !m.auto) return `Not on ${m.short || m.label}`;
  if (v === "bypassPermissions" && !LV_SETTINGS.allowBypass) return "Allow it in Settings › General";
  return null;
}
function cycleMode(s) {
  let i = CYCLE.indexOf(s.mode);
  for (let k = 0; k < CYCLE.length; k++) {
    i = (i + 1) % CYCLE.length;
    if (!modeAvailable(s, CYCLE[i])) return chooseMode(s, CYCLE[i]);
  }
}
let FLASH = null;
function flashLater(s, which) { FLASH = { sid: s.id, which }; }

// MARK: - Menus

function menuItems(kind, s) {
  if (kind === "model") {
    const cur = shownModel(s);
    const top = MODELS.filter((m) => !m.other).map((m) => ({ label: m.label, sub: m.sub, checked: cur === m.v, act: () => chooseModel(s, m.v) }));
    const other = MODELS.filter((m) => m.other).map((m) => ({ label: m.label, checked: cur === m.v, act: () => chooseModel(s, m.v) }));
    const fm = MODEL(cur);
    const fastReason = fm.fast ? "Faster output on Opus · billed as extra usage" : "Opus 5.5, Opus 5 and Opus 4.8 only";
    return [
      ...(WORKING.has(s.state) ? [{ header: "Applies after this turn" }] : []),
      ...top,
      { sep: true },
      { label: "Other Models", submenu: other, checked: other.some((o) => o.checked) },
      { sep: true },
      { label: "Fast Mode", glyph: LV.bolt.replace('class="bolt"', 'class="g" style="padding:1px 2px"'), sub: fastReason, checked: shownFast(s), disabled: !fm.fast, act: () => setFast(s, !shownFast(s)) },
    ];
  }
  if (kind === "effort") {
    const m = MODEL(shownModel(s));
    const eff = effectiveEffort(s);
    return [
      { header: `Effort · ${m.short || m.label}` },
      ...EFFORTS.map(([v, label]) => {
        const ok = m.eff.includes(v);
        return { label, glyph: bars(v), checked: eff === v, disabled: !ok, sub: !ok ? `Not on ${m.short || m.label}` : v === "high" ? "Default" : v === "max" ? "This session only" : null, act: () => chooseEffort(s, v) };
      }),
    ];
  }
  if (kind === "mode") {
    const items = MODES.map((md) => {
      const why = modeAvailable(s, md.v);
      return { label: md.label, glyph: svg16(MODE_GLYPH[md.v]), sub: why || md.sub, disabled: !!why, danger: md.danger, checked: s.mode === md.v, act: () => chooseMode(s, md.v) };
    });
    return [{ header: "Permission Mode", key: "⇧⇥" }, ...items.slice(0, 5), { sep: true }, items[5]];
  }
  if (kind === "folder") {
    return [
      { header: "Recent" },
      ...FOLDERS.map((f) => ({ label: f.name, glyph: svg16(LV.folder), k: f.path, checked: s.folder === f, act: () => { if (s.folder !== f) s.worktree = false; s.folder = f; LW.refresh(s); } })),
      { sep: true },
      { label: "Choose Folder…", k: "⌘O", act: () => {} },
      { sep: true },
      { label: "New Worktree", sub: s.folder.branch ? "Claude works on a new branch in .claude/worktrees" : "Not a git repository", checked: s.worktree, disabled: !s.folder.branch, act: () => { s.worktree = !s.worktree; LW.refresh(s); } },
    ];
  }
  if (kind === "account") {
    return [{ header: "Account" }, ...ACCOUNTS.map((a, i) => ({ label: a, sub: i ? "relay.example.com · API key" : "Subscription · claude.ai", checked: s.account === i, act: () => { s.account = i; LW.refresh(s); } }))];
  }
  return [];
}

function menuHTML(items, opts = {}) {
  const anyGlyph = items.some((i) => i.glyph);
  return `<div class="lv-menu${opts.static ? " static" : ""}" role="menu">${items.map((it, i) => {
    if (it.sep) return '<div class="msep"></div>';
    if (it.header) return `<div class="mh"><span>${esc(it.header)}</span>${it.key ? `<kbd>${it.key}</kbd>` : ""}</div>`;
    const cls = ["mi", anyGlyph ? "" : "nog", it.disabled ? "dis" : "", it.danger ? "danger" : "", opts.hl === i ? "hl" : ""].join(" ");
    return `<div class="${cls}" data-mi="${i}">${it.checked ? LV.check : "<span></span>"}${anyGlyph ? it.glyph || "<span></span>" : ""}<span class="l">${esc(it.label)}</span>${
      it.submenu ? `<span class="k">${LV.sub}</span>` : it.k ? `<span class="k">${esc(it.k)}</span>` : "<span></span>"
    }${it.sub ? `<span class="s">${esc(it.sub)}</span>` : ""}</div>`;
  }).join("")}</div>`;
}

const MENU = {
  el: null, sub: null, items: null, chip: null,
  open(chip, kind, s) {
    this.close();
    this.items = menuItems(kind, s);
    this.chip = chip;
    chip.classList.add("open");
    const host = document.createElement("div");
    host.innerHTML = menuHTML(this.items);
    this.el = host.firstElementChild;
    document.body.appendChild(this.el);
    this.place(this.el, chip.getBoundingClientRect(), chip.closest(".lv-new") ? "below" : "auto");
    this.el.addEventListener("click", (e) => {
      const mi = e.target.closest("[data-mi]");
      if (!mi) return;
      const it = this.items[+mi.dataset.mi];
      if (it.disabled || it.submenu) return;
      this.close();
      it.act();
    });
    this.el.addEventListener("mouseover", (e) => {
      const mi = e.target.closest("[data-mi]");
      if (!mi) return;
      const it = this.items[+mi.dataset.mi];
      if (it.submenu) this.openSub(mi, it.submenu);
      else if (this.sub && !this.sub.contains(e.target)) { this.sub.remove(); this.sub = null; }
    });
  },
  openSub(row, items) {
    if (this.sub) this.sub.remove();
    const host = document.createElement("div");
    host.innerHTML = menuHTML(items);
    this.sub = host.firstElementChild;
    document.body.appendChild(this.sub);
    const r = row.getBoundingClientRect();
    const w = this.sub.offsetWidth;
    const left = r.right + 4 + w > innerWidth ? r.left - w - 4 : r.right + 4;
    this.sub.style.left = `${left}px`;
    this.sub.style.top = `${Math.min(r.top - 5, innerHeight - this.sub.offsetHeight - 8)}px`;
    this.sub.addEventListener("click", (e) => {
      const mi = e.target.closest("[data-mi]");
      if (!mi || items[+mi.dataset.mi].disabled) return;
      const it = items[+mi.dataset.mi];
      this.close();
      it.act();
    });
  },
  place(el, r, dir) {
    const h = el.offsetHeight, w = el.offsetWidth;
    const below = dir === "below" || (dir === "auto" && r.top - h - 6 < 8);
    el.style.top = `${below ? r.bottom + 4 : r.top - h - 4}px`;
    el.style.left = `${Math.max(8, Math.min(r.left - 4, innerWidth - w - 8))}px`;
  },
  close() {
    if (this.el) this.el.remove();
    if (this.sub) this.sub.remove();
    if (this.chip) this.chip.classList.remove("open");
    this.el = this.sub = this.chip = null;
  },
};

// MARK: - The composer: one component, both tabs (08-live.md "The composer")

function chip(kind, s, inner, opts = {}) {
  return `<button class="chip${opts.danger ? " danger" : ""}" data-lv-menu="${kind}" data-sid="${s.id}"${opts.disabled ? " disabled" : ""}${opts.title ? ` title="${esc(opts.title)}"` : ""}>${inner}${opts.disabled ? "" : LV.chev}</button>`;
}
function accHTML(s, o = {}) {
  const m = MODEL(shownModel(s));
  const eff = effectiveEffort(s);
  const md = MODE(s.mode);
  const pending = s.pendingModel || s.pendingFast != null;
  const working = WORKING.has(s.state);
  const hasText = o.text != null ? !!o.text : !!(s.text || s.token);
  let h = "";
  h += chip("model", s, `${shownFast(s) ? LV.bolt : ""}<span>${esc(m.short || m.label)}</span>${pending ? LV.clock : ""}`, { title: pending ? "Switches after this turn" : "" });
  h += eff ? chip("effort", s, `${bars(eff)}<span>${EFFORTS.find((e) => e[0] === eff)[1]}</span>`) : chip("effort", s, `${bars(null)}<span>—</span>`, { disabled: true, title: `${m.label} doesn't take an effort level` });
  h += chip("mode", s, `${svg16(MODE_GLYPH[md.v])}<span>${esc(md.short)}</span>`, { danger: md.danger });
  if (isNew(s) && LV_SETTINGS.accounts > 1) h += chip("account", s, `<span>${esc(ACCOUNTS[s.account])}</span>`);
  h += '<span class="sp"></span>';
  // The status slot: empty unless something is out of the ordinary.
  if (s.state === "starting") h += `<span class="lv-status">${tile("other", "running")}Starting Claude…</span>`;
  else if (s.state === "compacting") h += `<span class="lv-status">${tile("other", "running")}Compacting…</span>`;
  else if (s.state === "waiting") h += '<span class="lv-status coral" data-lv="to-request">Waiting for you ↑</span>';
  else if (s.state === "rest") h += '<span class="lv-status">Will resume when you send</span>';
  if (s.ctx >= 0.5) h += ringHTML(s.ctx);
  const stoppable = working || s.state === "starting";
  if (stoppable) h += `<button class="act-btn stop" data-lv="stop" data-sid="${s.id}" title="${s.state === "starting" ? "Cancel" : "Stop"} ⌘.">${LV.stop}</button>`;
  if (!stoppable || hasText) h += `<button class="act-btn" data-lv="send" data-sid="${s.id}" title="${working ? "Queue" : "Send"} ↩"${hasText ? "" : " disabled"}>${LV.up}</button>`;
  return h;
}
function composerHTML(s, o = {}) {
  const ph = isNew(s) ? "Ask Claude to…" : "Message Claude";
  const tok = s.token ? cmdToken("/", s.token) : "";
  const banner = s.state === "failed"
    ? `<div class="lv-banner"><b>Claude exited (code 1)</b><span class="why">${esc(s.stderr || "API Error: 529 overloaded_error · retries exhausted")}</span><button class="btn plain">Show Log</button><button class="btn" data-lv="restart" data-sid="${s.id}">Restart</button></div>`
    : "";
  return `${banner}<div class="lv-comp${o.focus ? " focus" : ""}" data-sid="${s.id}">
    <div class="lv-field">${tok}<textarea rows="1" placeholder="${ph}" data-sid="${s.id}"${o.static ? " readonly tabindex=-1" : ""}>${esc(o.text != null ? o.text : s.text || "")}</textarea></div>
    <div class="lv-acc">${accHTML(s, o)}</div>
  </div><div class="lv-err">${esc(s.err || "")}</div>`;
}
function heroHTML(s) {
  const f = s.folder;
  const where = [f.path, f.branch ? `${LV.branch} ${esc(f.branch)}` : ""].filter(Boolean).join(" · ");
  return `<div class="lv-hero"><div class="lv-glyph">${sessionGlyph(32)}</div>
    <button class="lv-folder" data-lv-menu="folder" data-sid="${s.id}">${esc(f.name)}${LV.chev2}</button>
    <div class="lv-path">${where}${s.worktree ? ' · <span class="wt">new worktree</span>' : ""}</div></div>`;
}
const hintHTML = () => '<div class="lv-hint"><span><kbd>↩</kbd>Send</span><span><kbd>⇧↩</kbd>New Line</span><span><kbd>⇧⇥</kbd>Mode</span><span><kbd>/</kbd>Commands</span></div>';

function slashHTML(q, on = 0, opts = {}) {
  const list = COMMANDS.filter(([n]) => n.startsWith(q));
  if (!list.length) return "";
  return `<div class="lv-slash${opts.static ? " static" : ""}">${list.map(([n, h, d], i) => `<div class="sl${i === on ? " on" : ""}" data-slash="${n}"><span class="n"><span class="sig">/</span>${n}</span><span class="h">${esc(h)}</span><span class="d">${esc(d)}</span></div>`).join("")}</div>`;
}

// MARK: - The window

const LW = {
  root: null, groups: [], focus: 0, empty: null, panes: new Map(), sideSel: null,

  mount(root) {
    this.root = root;
    root.classList.add("window", "lv-win");
    root.tabIndex = -1;
    root.innerHTML = `
      <div class="titlebar"><div class="lights"><i></i><i></i><i></i></div>
        <div><div class="ttl" data-ttl></div><div class="sub" data-sub></div></div><span class="spacer"></span>
        <div class="seg" role="group"><button data-lv="split" aria-pressed="false">Split</button></div></div>
      <div class="lv-body"><aside class="lv-side" data-side></aside><div class="lv-editors" data-editors></div></div>`;
    root.addEventListener("keydown", (e) => this.key(e));
    root.addEventListener("click", (e) => this.click(e));
    root.addEventListener("input", (e) => this.input(e));
    root.addEventListener("focusin", (e) => { const c = e.target.closest(".lv-comp"); if (c) c.classList.add("focus"); const g = e.target.closest(".lv-group"); if (g) this.setFocus(+g.dataset.g); });
    root.addEventListener("focusout", (e) => { const c = e.target.closest(".lv-comp"); if (c) c.classList.remove("focus"); });
  },

  // Tabs ------------------------------------------------------------------
  tabsAll() { return this.groups.flatMap((g) => g.tabs); },
  activeTab(gi = this.focus) { const g = this.groups[gi]; return g && g.tabs.find((t) => t.id === g.active); },
  newTab(gi = this.focus) {
    if (!this.tabsAll().length) return this.render(true); // the New view is already here
    const g = this.groups[gi] || this.groups[0];
    // An untouched New tab in this group is selected instead of a second one.
    const idle = g.tabs.find((t) => isNew(t.s) && !t.s.text && !t.s.token);
    if (idle) { g.active = idle.id; return this.render(true); }
    const from = this.activeTab(gi);
    const s = draft({ folder: from ? from.s.folder : FOLDERS[0], text: LAST.draft });
    LAST.draft = "";
    const t = { id: nid("t"), s };
    const at = g.tabs.findIndex((x) => x.id === g.active);
    g.tabs.splice(at + 1, 0, t);
    g.active = t.id;
    this.focus = this.groups.indexOf(g);
    this.render(true);
  },
  openSession(s) {
    for (const [gi, g] of this.groups.entries()) {
      const t = g.tabs.find((x) => x.s === s);
      if (t) { g.active = t.id; this.focus = gi; return this.render(); }
    }
    if (this.empty) { LAST.draft = this.empty.s.text; this.panes.delete("empty"); }
    if (!this.groups.length) this.groups.push({ tabs: [], active: null });
    const g = this.groups[this.focus] || this.groups[0];
    const t = { id: nid("t"), s };
    g.tabs.push(t);
    g.active = t.id;
    this.empty = null;
    this.render();
  },
  closeTab(id) {
    for (const [gi, g] of this.groups.entries()) {
      const i = g.tabs.findIndex((t) => t.id === id);
      if (i < 0) continue;
      const [t] = g.tabs.splice(i, 1);
      // A live session outlives its tab; a New tab's draft text goes to the next one.
      if (isNew(t.s) && t.s.text) LAST.draft = t.s.text;
      this.panes.delete(t.id);
      if (g.active === id) g.active = (g.tabs[i] || g.tabs[i - 1] || {}).id || null;
      if (!g.tabs.length && this.groups.length > 1) { this.groups.splice(gi, 1); this.focus = 0; }
      break;
    }
    this.render();
  },
  setFocus(gi) {
    if (this.focus === gi) return;
    this.focus = gi;
    this.root.querySelectorAll(".lv-group").forEach((el) => el.classList.toggle("focused", +el.dataset.g === gi));
    this.renderTitle();
  },

  // Rendering ---------------------------------------------------------------
  render(focusField) {
    MENU.close();
    const ed = this.root.querySelector("[data-editors]");
    const noTabs = !this.tabsAll().length;
    this.root.querySelector('[data-lv="split"]').setAttribute("aria-pressed", String(this.groups.length > 1));
    if (noTabs) {
      // No tabs, no bar: the editor area is a New tab without its tab.
      if (!this.empty) this.empty = { id: "empty", s: draft({ text: LAST.draft }) };
      ed.innerHTML = '<div class="lv-group focused" data-g="0" style="grid-template-rows:minmax(0,1fr)"><div class="lv-paneholder"></div></div>';
      ed.querySelector(".lv-paneholder").appendChild(this.pane(this.empty));
    } else {
      ed.innerHTML = this.groups.map((g, gi) => `<div class="lv-group${gi === this.focus ? " focused" : ""}" data-g="${gi}">${this.tabbar(g, gi)}<div class="lv-paneholder"></div></div>`).join("");
      this.groups.forEach((g, gi) => {
        const t = g.tabs.find((x) => x.id === g.active);
        const holder = ed.querySelector(`[data-g="${gi}"] .lv-paneholder`);
        if (t) holder.appendChild(this.pane(t));
        else holder.innerHTML = this.emptyGroup();
      });
    }
    this.renderSide();
    this.renderTitle();
    this.sizeFields();
    if (focusField) {
      const t = noTabs ? this.empty : this.activeTab();
      const ta = t && this.panes.get(t.id) && this.panes.get(t.id).querySelector("textarea");
      if (ta) ta.focus({ preventScroll: true });
    }
  },
  emptyGroup() { return '<div class="empty">No tabs</div>'; },
  tabbar(g, gi) {
    return `<div class="tabbar">${g.tabs.map((t) => {
      const s = t.s;
      let act = "";
      if (s.state === "starting" || s.state === "responding" || s.state === "compacting") act = arcMark();
      else if (s.state === "waiting") act = '<span class="dotmark coral"></span>';
      else if (s.state === "failed") act = '<span class="dotmark red"></span>';
      const title = s.title.length > 40 ? s.title.slice(0, 39) + "…" : s.title;
      return `<div class="tab${t.id === g.active ? " on" : ""}" data-lv-tab="${t.id}" data-g="${gi}" title="${esc(s.title)}">${act ? `<span class="act">${act}</span>` : ""}<span class="x" data-lv-close="${t.id}">${ICON.x}</span><span>${esc(title)}</span></div>`;
    }).join("")}<button class="lv-plus" data-lv="plus" data-g="${gi}" aria-label="New Tab">${LV.plus}<span class="lv-tip">New Tab<kbd>⌘T</kbd></span></button></div>`;
  },
  /** A tab's page, built once and kept — so a field keeps its text and focus. */
  pane(t) {
    let el = this.panes.get(t.id);
    const kind = isNew(t.s) ? "new" : "sess";
    if (el && el.dataset.kind === kind) { this.fill(el, t.s); return el; }
    el = document.createElement("div");
    el.dataset.kind = kind;
    el.dataset.sid = t.s.id;
    if (kind === "new") {
      el.className = "lv-new";
      el.innerHTML = `${heroHTML(t.s)}<div class="lv-compwrap" style="width:min(640px,100%);position:relative">${composerHTML(t.s)}</div>${hintHTML()}`;
    } else {
      el.className = "lv-sess";
      el.innerHTML = `<div class="lv-scroll"><div class="transcript"></div></div><div class="lv-dock">${composerHTML(t.s)}</div>`;
      t.s.column = new Column(el.querySelector(".transcript"), t.s.rows);
      requestAnimationFrame(() => { const sc = el.querySelector(".lv-scroll"); sc.scrollTop = sc.scrollHeight; });
    }
    this.panes.set(t.id, el);
    return el;
  },
  /** Re-render only the parts of a page that state changes: hero, banner, accessory row. */
  fill(el, s) {
    if (el.dataset.kind === "new") {
      el.querySelector(".lv-hero").outerHTML = heroHTML(s);
      el.querySelector(".lv-hint").style.opacity = s.text || s.token ? 0 : 1;
    }
    const dock = el.querySelector(".lv-dock") || el.querySelector(".lv-compwrap");
    const banner = dock.querySelector(".lv-banner");
    if (s.state === "failed" && !banner) dock.insertAdjacentHTML("afterbegin", composerHTML(s).split('<div class="lv-comp')[0]);
    if (s.state !== "failed" && banner) banner.remove();
    const field = dock.querySelector(".lv-field");
    const tok = field.querySelector(".cmdtok");
    if (s.token && !tok) field.insertAdjacentHTML("afterbegin", cmdToken("/", s.token));
    if (!s.token && tok) tok.remove();
    dock.querySelector(".lv-acc").innerHTML = accHTML(s);
    dock.querySelector(".lv-err").textContent = s.err || "";
    if (FLASH && FLASH.sid === s.id) {
      const c = dock.querySelector(`[data-lv-menu="${FLASH.which}"]`);
      if (c) { c.classList.remove("flash"); void c.offsetWidth; c.classList.add("flash"); }
      FLASH = null;
    }
  },
  refresh(s) {
    for (const t of [...this.tabsAll(), this.empty].filter(Boolean)) {
      if (t.s !== s) continue;
      const el = this.panes.get(t.id);
      if (el && el.isConnected) this.fill(el, s);
    }
    // Tab marks and titles.
    this.root.querySelectorAll(".lv-group > .tabbar").forEach((bar) => {
      const gi = +bar.parentElement.dataset.g;
      const tmp = document.createElement("div");
      tmp.innerHTML = this.tabbar(this.groups[gi], gi);
      bar.replaceWith(tmp.firstElementChild);
    });
    this.renderSide();
    this.renderTitle();
  },
  renderTitle() {
    const t = this.tabsAll().length ? this.activeTab() : this.empty;
    const s = t && t.s;
    this.root.querySelector("[data-ttl]").textContent = s ? s.folder.name : "ccterm";
    this.root.querySelector("[data-sub]").textContent = s ? (isNew(s) ? "New Session" : s.folder.branch || "") : "";
  },
  renderSide() {
    const side = this.root.querySelector("[data-side]");
    const active = this.activeTab();
    const live = [...SESSIONS.values()].filter((s) => !isNew(s) && !s.spec);
    side.innerHTML = FOLDERS.slice(0, 2).map((f) => {
      const rows = live.filter((s) => s.folder === f);
      return `<div class="grp">${esc(f.name)}</div>${rows.map((s) => {
        let mark = "";
        if (s.state === "starting" || s.state === "responding" || s.state === "compacting") mark = arcMark();
        else if (s.state === "waiting") mark = '<span class="dotmark coral"></span>';
        else if (s.state === "failed") mark = '<span class="dotmark red"></span>';
        else if (s.state === "idle") mark = '<span class="dotmark" style="background:var(--tertiary)"></span>';
        return `<div class="it${active && active.s === s ? " on" : ""}" data-lv-side="${s.id}">${sessionGlyph(12)}<span class="t">${esc(s.title)}</span><span class="mark">${mark}</span></div>`;
      }).join("") || '<div class="it" style="color:var(--tertiary)">No sessions</div>'}`;
    }).join("");
  },
  sizeFields() {
    this.root.querySelectorAll(".lv-field textarea").forEach((ta) => { ta.style.height = "auto"; ta.style.height = `${Math.min(176, ta.scrollHeight)}px`; });
  },

  // Events --------------------------------------------------------------
  sessionOf(el) { const id = el.closest("[data-sid]") && el.closest("[data-sid]").dataset.sid; return SESSIONS.get(id); },
  click(e) {
    const t = e.target;
    const menu = t.closest("[data-lv-menu]");
    if (menu && !menu.disabled) {
      e.stopPropagation();
      if (MENU.chip === menu) return MENU.close();
      return MENU.open(menu, menu.dataset.lvMenu, SESSIONS.get(menu.dataset.sid));
    }
    const close = t.closest("[data-lv-close]");
    if (close) { e.stopPropagation(); return this.closeTab(close.dataset.lvClose); }
    const tab = t.closest("[data-lv-tab]");
    if (tab) { const g = this.groups[+tab.dataset.g]; g.active = tab.dataset.lvTab; this.focus = +tab.dataset.g; return this.render(); }
    const side = t.closest("[data-lv-side]");
    if (side) return this.openSession(SESSIONS.get(side.dataset.lvSide));
    const sl = t.closest("[data-slash]");
    if (sl) return this.complete(this.sessionOf(sl), sl.dataset.slash);
    const a = t.closest("[data-lv]");
    if (!a) {
      const comp = t.closest(".lv-comp");
      if (comp && !t.closest("button")) comp.querySelector("textarea").focus();
      return;
    }
    const s = a.dataset.sid ? SESSIONS.get(a.dataset.sid) : this.sessionOf(a);
    switch (a.dataset.lv) {
      case "plus": e.stopPropagation(); this.focus = +a.dataset.g; return this.newTab(+a.dataset.g);
      case "send": return this.send(s);
      case "stop": return stop(s);
      case "restart": return restart(s);
      case "split": return this.split();
      case "to-request": { const el = this.panes.get(this.activeTab().id).querySelector(".approval"); if (el) el.scrollIntoView({ block: "center", behavior: "smooth" }); return; }
      case "context": return;
    }
  },
  input(e) {
    const ta = e.target.closest("textarea");
    if (!ta) return;
    const s = SESSIONS.get(ta.dataset.sid);
    s.text = ta.value;
    // "/name " at the start of an empty field becomes the token.
    const m = !s.token && /^\/([a-z-]+)\s$/.exec(ta.value);
    if (m && COMMANDS.some(([n]) => n === m[1])) return this.complete(s, m[1]);
    this.sizeFields();
    this.slash(s, ta);
    this.fillAcc(s);
  },
  fillAcc(s) {
    for (const el of this.panes.values()) if (el.dataset.sid === s.id && el.isConnected) {
      el.querySelector(".lv-acc").innerHTML = accHTML(s);
      const hint = el.querySelector(".lv-hint");
      if (hint) hint.style.opacity = s.text || s.token ? 0 : 1;
    }
  },
  slash(s, ta) {
    const comp = ta.closest(".lv-comp");
    const old = comp.querySelector(".lv-slash");
    if (old) old.remove();
    const m = !s.token && /^\/([a-z-]*)$/.exec(ta.value);
    s.slashOn = m ? s.slashOn || 0 : 0;
    if (m) comp.insertAdjacentHTML("afterbegin", slashHTML(m[1], s.slashOn));
  },
  complete(s, name) {
    s.token = name;
    s.text = "";
    for (const el of this.panes.values()) if (el.dataset.sid === s.id) {
      const ta = el.querySelector("textarea");
      ta.value = "";
      const sl = el.querySelector(".lv-slash");
      if (sl) sl.remove();
      this.fill(el, s);
      ta.focus();
    }
  },
  key(e) {
    // ⌘T is the browser's; ⌃T stands in for it here.
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "t") { e.preventDefault(); return this.newTab(); }
    const ta = e.target.closest && e.target.closest("textarea");
    const s = ta ? SESSIONS.get(ta.dataset.sid) : (this.activeTab() || this.empty || {}).s;
    if (!s) return;
    if (e.metaKey && e.key === ".") { e.preventDefault(); return stop(s); }
    if (!ta) return;
    const sl = ta.closest(".lv-comp").querySelector(".lv-slash");
    if (sl) {
      const rows = [...sl.querySelectorAll(".sl")];
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        s.slashOn = (s.slashOn + (e.key === "ArrowDown" ? 1 : rows.length - 1)) % rows.length;
        return this.slash(s, ta);
      }
      if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); return this.complete(s, rows[s.slashOn].dataset.slash); }
      if (e.key === "Escape") { e.preventDefault(); sl.remove(); return; }
    }
    if (e.key === "Tab" && e.shiftKey) { e.preventDefault(); return cycleMode(s); }
    if (e.key === "Backspace" && s.token && ta.selectionStart === 0 && ta.selectionEnd === 0) { e.preventDefault(); s.token = null; return this.refresh(s); }
    if (e.key === "Enter" && !e.shiftKey && !e.metaKey) { e.preventDefault(); return this.send(s); }
  },
  send(s) {
    const text = (s.token ? `/${s.token}${s.text ? " " + s.text : ""}` : s.text).trim();
    if (!text) return;
    const row = s.token ? { type: "slash", name: `/${s.token}`, args: s.text.trim() } : { type: "user", text };
    s.text = ""; s.token = null; s.err = "";
    for (const el of this.panes.values()) if (el.dataset.sid === s.id) el.querySelector("textarea").value = "";
    if (isNew(s)) return this.launch(s, row, text);
    if (WORKING.has(s.state) || s.state === "starting") return queue(s, row);
    if (s.state === "rest" || s.state === "failed") return resume(s, row);
    this.refresh(s);
    startTurn(s, row);
  },
  /** Send in a New tab: the page becomes the session in place; the composer glides down. */
  launch(s, row, text) {
    let t = this.tabsAll().find((x) => x.s === s);
    const fromEmpty = !t;
    const oldPane = this.panes.get(t ? t.id : "empty");
    const before = oldPane && oldPane.querySelector(".lv-comp").getBoundingClientRect();
    if (fromEmpty) {
      t = { id: nid("t"), s };
      if (!this.groups.length) this.groups.push({ tabs: [], active: null });
      this.groups[0].tabs.push(t);
      this.groups[0].active = t.id;
      this.empty = null;
      this.panes.delete("empty");
    }
    s.state = "starting";
    s.wasAt = "new";
    s.title = text.split("\n")[0];
    LAST.model = s.model; LAST.effort = s.effort; LAST.mode = s.mode; LAST.fast = s.fast;
    s.rows.push({ type: "html", html: heldBubble(text, "start"), held: row });
    this.render(true);
    const after = this.panes.get(t.id).querySelector(".lv-comp");
    if (before && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      const a = after.getBoundingClientRect();
      after.animate([{ transform: `translate(${before.left - a.left}px, ${before.top - a.top}px)`, width: `${before.width}px` }, { transform: "none", width: `${a.width}px` }], { duration: 300, easing: "cubic-bezier(.2,.8,.2,1)" });
    }
    setTimeout(() => {
      if (s.state !== "starting") return;
      const i = s.rows.findIndex((r) => r.held);
      const held = s.rows[i].held;
      s.rows.splice(i, 1);
      s.column.render();
      startTurn(s, held);
    }, 1400);
  },
  split() {
    if (this.groups.length > 1) {
      const [, g2] = this.groups;
      this.groups[0].tabs.push(...g2.tabs);
      this.groups.length = 1;
      this.focus = 0;
    } else {
      if (!this.groups.length || !this.tabsAll().length) return;
      const s = SEED.notes();
      const t = { id: nid("t"), s };
      this.groups.push({ tabs: [t], active: t.id });
      this.focus = 1;
    }
    this.render();
  },
};

// MARK: - A turn, scripted (01-run.md's live states)

class Stopped extends Error {}
const pause = (s, ms) => new Promise((res, rej) => {
  const t0 = Date.now();
  const tick = () => { if (s.turn && s.turn.stopped) return rej(new Stopped()); if (Date.now() - t0 >= ms) return res(); setTimeout(tick, 60); };
  tick();
});
function appendRow(s, row) {
  s.rows.push(row);
  if (s.column) {
    s.column.append(row);
    const sc = s.column.el.closest(".lv-scroll");
    if (sc) sc.scrollTop = sc.scrollHeight;
  }
}
function updRow(s, row) {
  if (s.column) s.column.update(row);
  const sc = s.column && s.column.el.closest(".lv-scroll");
  if (sc && sc.scrollHeight - sc.scrollTop - sc.clientHeight < 120) sc.scrollTop = sc.scrollHeight;
}
function heldBubble(text, why, id) {
  const q = why === "start" ? "<span>Sent when Claude is ready</span>" : `<span>Queued</span><span class="link" data-lv="unqueue" data-q="${id}">Withdraw</span>`;
  return `<div class="qrow"><div class="bubble">${inline(text)}</div><div class="q">${q}</div></div>`;
}
function queue(s, row) {
  const id = nid("q");
  const text = row.type === "slash" ? `${row.name} ${row.args}`.trim() : row.text;
  appendRow(s, { type: "html", html: heldBubble(text, "queue", id), queued: row, qid: id });
  LW.refresh(s);
}
document.addEventListener("click", (e) => {
  const u = e.target.closest('[data-lv="unqueue"]');
  if (!u) return;
  for (const s of SESSIONS.values()) {
    const i = s.rows.findIndex((r) => r.qid === u.dataset.q);
    if (i >= 0) { s.rows.splice(i, 1); s.column.render(); } // cancel_async_message
  }
});
/** At a tool boundary the CLI takes queued prompts into the running turn. */
function takeQueued(s) {
  for (const row of s.rows) if (row.queued) {
    Object.assign(row, row.queued.type === "slash" ? row.queued : { type: "user", text: row.queued.text });
    delete row.queued; delete row.html;
    updRow(s, row);
  }
}
async function stream(s, text) {
  const row = { type: "text", text: "", streaming: true };
  appendRow(s, row);
  s.turn.streaming = row;
  for (const w of text.split(/(?<= )/)) { await pause(s, 40); row.text += w; updRow(s, row); }
  row.streaming = false;
  s.turn.streaming = null;
  updRow(s, row);
}
function setState(s, state) { s.state = state; LW.refresh(s); }

async function startTurn(s, row) {
  if (row) appendRow(s, row);
  s.turn = { stopped: false, items: [] };
  setState(s, "responding");
  if (row && row.type === "slash") {
    try { return await command(s, row); } catch (err) { if (!(err instanceof Stopped)) throw err; return endTurn(s, true); }
  }
  return startTurnBody(s);
}
async function startTurnBody(s) {
  try {
    await pause(s, 500);
    await stream(s, "I'll look at how the run row sets its summary first.");
    const R = run([]);
    const rr = { type: "run", run: R };
    appendRow(s, rr);
    const step = async (it, state, ms, extra = {}) => { Object.assign(it, { state }, extra); updRow(s, rr); if (ms) await pause(s, ms); };
    const add = (it) => { R.items.push(it); s.turn.items.push(it); };
    const r1 = read("macos/ccterm/Content/Transcript/RunRowView.swift", 1, 96, 96, { code: "final class RunRowView: NSView { … }", state: "streaming" });
    add(r1); await step(r1, "streaming", 400); await step(r1, "running", 400); await step(r1, "done", 0);
    takeQueued(s);
    if (s.mode === "plan") {
      await pause(s, 300);
      await stream(s, "Plan mode — here's what I'd do: change `summary.font` to 12 pt in `RunRowView`, update its snapshot test, rebuild. Approve and I'll start.");
      return endTurn(s);
    }
    const diff = [["ctx", 41, "        summary.lineBreakMode = .byTruncatingTail"], ["del", null, "        summary.font = .systemFont(ofSize: ⟦13⟧)"], ["add", 42, "        summary.font = .systemFont(ofSize: ⟦12⟧)"]];
    const e1 = edit("macos/ccterm/Content/Transcript/RunRowView.swift", 1, 1, { state: "streaming", diff, why: "Edits need approval in Ask Permissions mode." });
    add(e1); await step(e1, "streaming", 600);
    if (s.mode === "default") {
      await step(e1, "waiting", 0);
      setState(s, "waiting");
      const d = await new Promise((res) => {
        LIVE_DECISION = (dec, id) => { if (id === e1.id) { LIVE_DECISION = null; res(dec); } };
        LIVE_DECISION.id = e1.id;
        s.turn.onStop = () => { LIVE_DECISION = null; res("stop"); };
      });
      if (d === "stop") throw new Stopped();
      setState(s, "responding");
      if (d === "deny") { await step(e1, "denied", 300); await stream(s, "Understood — I'll leave the font as it is."); return endTurn(s); }
    } else if (s.mode === "dontAsk") {
      await step(e1, "denied", 300);
      await stream(s, "Edits aren't allowed in this session's Don't Ask mode, so I've stopped here.");
      return endTurn(s);
    }
    await step(e1, "running", 300); await step(e1, "done", 0);
    takeQueued(s);
    const b1 = bash("Build the app", "cd ~/dev/ccterm && make build", { state: "running", elapsed: 0 });
    add(b1);
    const timer = setInterval(() => { b1.elapsed++; updRow(s, rr); }, 1000);
    try { await step(b1, "running", 5200); } finally { clearInterval(timer); }
    await step(b1, "done", 0, { dur: 5, out: ["** BUILD SUCCEEDED **"] });
    takeQueued(s);
    await pause(s, 300);
    await stream(s, "Done — the summary is 12 pt and the app builds.");
    endTurn(s);
  } catch (err) {
    if (!(err instanceof Stopped)) throw err;
    // Interrupted: running calls take the state, a reply in progress takes the mark.
    for (const it of s.turn.items) if (LIVE.has(it.state)) it.state = "interrupted";
    for (const r of s.rows) if (r.type === "run") updRow(s, r);
    if (s.turn.streaming) { s.turn.streaming.streaming = false; updRow(s, s.turn.streaming); appendRow(s, { type: "interrupt", tight: true }); }
    endTurn(s);
  }
}
/** A typed command: the CLI runs it; the chips follow its echo. /compact is its divider (05-local.md). */
async function command(s, row) {
  const arg = (row.args || "").trim().toLowerCase();
  if (row.name === "/compact") {
    s.rows.splice(s.rows.indexOf(row), 1);
    s.column.render();
    const div = { type: "divider", text: "Compacting…", live: true };
    appendRow(s, div);
    setState(s, "compacting");
    await pause(s, 2200);
    Object.assign(div, { live: false, text: `Conversation compacted · ${Math.round(s.ctx * 200)}k → 14k tokens` });
    updRow(s, div);
    s.ctx = 0;
    return endTurn(s, true);
  }
  await pause(s, 400);
  const m = MODELS.find((x) => x.v === arg || x.label.toLowerCase() === arg || (x.short || "").toLowerCase() === arg);
  const e = EFFORTS.find(([v, l]) => v === arg || l.toLowerCase() === arg);
  if (row.name === "/model" && m) { s.model = m.v; row.out = `Set model to ${m.short || m.label}`; flashLater(s, "model"); }
  else if (row.name === "/model") { row.out = `Unknown model: ${row.args}`; row.err = true; }
  else if (row.name === "/effort" && e) { s.effort = e[0]; row.out = `Set effort level to ${e[0]}`; flashLater(s, "effort"); }
  else if (row.name === "/effort") { row.out = `Unknown effort level: ${row.args}`; row.err = true; }
  updRow(s, row);
  if (row.name === "/model" || row.name === "/effort" || row.name === "/context") return endTurn(s, true);
  return startTurnBody(s);
}
function endTurn(s, quiet) {
  s.turn = null;
  // What waited for the turn's end lands now: the model, then Fast.
  if (s.pendingModel) { const v = s.pendingModel; s.model = v; s.pendingModel = null; echoModel(s, v); }
  if (s.pendingFast != null) { s.fast = s.pendingFast; s.pendingFast = null; }
  if (!quiet) s.ctx = Math.min(0.93, s.ctx + 0.17);
  setState(s, "idle");
  if (!s.named) {
    s.named = true;
    setTimeout(() => { s.title = "Smaller run-row summary"; LW.refresh(s); }, 900); // session_title_changed
  }
  // Prompts still queued run next.
  const q = s.rows.find((r) => r.queued);
  if (q) { setTimeout(() => { takeQueued(s); startTurn(s, null); }, 400); }
}
function stop(s) {
  if (s.state === "starting") { // cancels the launch; the prompt goes back to the field
    const i = s.rows.findIndex((r) => r.held);
    if (i >= 0) {
      const h = s.rows.splice(i, 1)[0].held;
      s.text = h.type === "slash" ? `${h.name} ${h.args}`.trim() : h.text;
    }
    s.state = s.wasAt || "rest";
    if (s.state === "new") s.title = "New Session";
    LW.panes.forEach((el, id) => { if (el.dataset.sid === s.id) LW.panes.delete(id); });
    LW.render(true);
    return;
  }
  if (!s.turn) return;
  s.turn.stopped = true;
  if (s.turn.onStop) s.turn.onStop();
}
function resume(s, row) {
  s.state = "starting";
  s.wasAt = "rest";
  appendRow(s, { type: "html", html: heldBubble(row.type === "slash" ? `${row.name} ${row.args}` : row.text, "start"), held: row });
  LW.refresh(s);
  setTimeout(() => {
    if (s.state !== "starting") return;
    const i = s.rows.findIndex((r) => r.held);
    s.rows.splice(i, 1);
    s.column.render();
    startTurn(s, row);
  }, 1200);
}
function restart(s) {
  s.state = "starting";
  LW.refresh(s);
  setTimeout(() => setState(s, "idle"), 1200);
}

// MARK: - Seeds and scenarios

const SEED = {
  rest() {
    const s = draft({ state: "rest", title: "Row gap and tool rows", model: "sonnet", effort: "xhigh", mode: "acceptEdits", named: true });
    s.rows = [
      { type: "user", text: "The rows feel cramped in a narrow split. Make the gap between transcript rows configurable." },
      { type: "run", run: run([clone(a1), clone(a2), clone(b1), clone(b5)], { dur: 31 }) },
      { type: "text", text: "Done — `TranscriptView.rowSpacing` is public and defaults to 14; the tests pass." },
    ];
    return s;
  },
  notes() {
    const s = draft({ state: "rest", folder: FOLDERS[1], title: "Tab bar accessory", named: true, model: "opus", effort: "high", mode: "default" });
    s.rows = [{ type: "user", text: "How does Ghostty draw the + at the end of its tab bar?" }, { type: "run", run: run([grep("addTabButton", "macos", 3, { matches: [] }), clone(a3)]) }, { type: "text", text: "It's a titlebar accessory view after the tab group — a borderless round button with a tooltip." }];
    return s;
  },
};
function reset(scene) {
  for (const s of SESSIONS.values()) if (s.turn) s.turn.stopped = true;
  if (LIVE_DECISION) LIVE_DECISION = null;
  for (const [id, s] of SESSIONS) if (!s.spec) SESSIONS.delete(id);
  LW.panes.clear();
  LW.groups = [];
  LW.empty = null;
  LW.focus = 0;
  Object.assign(LAST, { model: "default", effort: "high", mode: "auto", fast: false, draft: "" });
  const tab = (s) => ({ id: nid("t"), s });
  const one = (...ss) => { const ts = ss.map(tab); LW.groups = [{ tabs: ts, active: ts[ts.length - 1].id }]; return ts; };
  const go = (s, mode) => { s.state = "idle"; s.mode = mode; s.named = true; setTimeout(() => startTurn(s, { type: "user", text: "Make the summary 12 pt and rebuild." }), 300); };
  switch (scene) {
    case "empty": SEED.rest(); SEED.notes(); break;
    case "new": { const r = SEED.rest(); SEED.notes(); one(r, draft()); break; }
    case "responding": { const r = SEED.rest(); SEED.notes(); one(r); go(r, "acceptEdits"); break; }
    case "waiting": { const r = SEED.rest(); r.model = "opus"; r.effort = "high"; SEED.notes(); one(r); go(r, "default"); break; }
    case "rest": { const r = SEED.rest(); SEED.notes(); one(r); break; }
    case "failed": { const r = SEED.rest(); r.state = "failed"; SEED.notes(); one(r); break; }
    case "split": { const r = SEED.rest(); const n = SEED.notes(); LW.groups = [{ tabs: [tab(r)], active: null }, { tabs: [tab(n), tab(draft({ folder: FOLDERS[1] }))], active: null }]; LW.groups[0].active = LW.groups[0].tabs[0].id; LW.groups[1].active = LW.groups[1].tabs[1].id; LW.focus = 1; break; }
  }
  LW.render(scene === "empty" || scene === "new");
  document.querySelectorAll("[data-scene]").forEach((b) => b.classList.toggle("on", b.dataset.scene === scene));
}

// MARK: - Specimens

function specS(o) { return draft({ spec: true, ...o }); }
function card(caption, inner, plain) {
  return `<div class="lv-card"><div class="cap">${caption}</div><div class="stage${plain ? " plain" : ""}">${inner}</div></div>`;
}
function staticComposer(o, so = {}) { return `<div style="position:relative">${composerHTML(specS(o), { static: true, ...so })}</div>`; }

function buildLiveSpecimens() {
  // Tab bars
  const tb = (tabs, hover) => `<div class="tabbar spec-bar">${tabs.map(([t, on, act]) => `<div class="tab${on ? " on" : ""}">${act ? `<span class="act">${act}</span>` : ""}<span class="x">${ICON.x}</span><span>${esc(t)}</span></div>`).join("")}<button class="lv-plus${hover ? " hover" : ""}">${LV.plus}<span class="lv-tip">New Tab<kbd>⌘T</kbd></span></button></div>`;
  document.getElementById("lv-tabs").innerHTML = [
    card("<b>The + on every tab bar</b>24-pt circle, quaternary fill, trailing. Hover lifts it one step and, after the usual tooltip delay, says <i>New Tab ⌘T</i>.", tb([["Row gap and tool rows", true], ["Fix gutter overflow", false]], true) + '<div style="height:28px"></div>', true),
    card("<b>Activity in the tab — exceptions only</b>The sidebar's marks in the close button's slot: working, waiting for you (coral), failed (red). Idle and at rest show nothing; hover shows ×.", tb([["Smaller run-row summary", false, arcMark()], ["Review the diff", true, '<span class="dotmark coral"></span>'], ["Nightly build", false, '<span class="dotmark red"></span>'], ["New Session", false]]), true),
  ].join("");

  // New view, small
  const nv = specS({ folder: FOLDERS[0] });
  const nv2 = specS({ folder: FOLDERS[0], worktree: true });
  LV_SETTINGS.accounts = 2;
  const nvA = composerHTML(nv2, { static: true });
  LV_SETTINGS.accounts = 1;
  document.getElementById("lv-newview").innerHTML = [
    card("<b>The New view</b>The folder is the title — the one choice that can't change after Send. The session glyph, coral with a soft halo, is the page's only colour.", `<div class="lv-new" style="padding:28px 8px 22px">${heroHTML(nv)}<div style="width:100%">${composerHTML(nv, { static: true })}</div>${hintHTML()}</div>`),
    card("<b>New worktree · two accounts</b>Launch-only choices live only here. The account chip appears only when Settings has more than one.", `<div class="lv-new" style="padding:28px 8px 22px">${heroHTML(nv2)}<div style="width:100%">${nvA}</div></div>`),
  ].join("");

  // Composer states
  const cs = [
    ["<b>Idle</b>Plain: three controls and Send. The arrow lights when there is text.", { state: "idle", model: "sonnet", effort: "xhigh", mode: "acceptEdits" }, { text: "Now run the snapshot tests", focus: true }],
    ["<b>Responding · a model chosen mid-turn</b>The chip takes the new name with a clock: it switches after this turn. Text in the field shows Stop and Queue.", { state: "responding", model: "opus", pendingModel: "sonnet", effort: "high", mode: "auto" }, { text: "Also update the docs" }],
    ["<b>Waiting for you</b>Coral, the one time: the request is off screen; click scrolls to it.", { state: "waiting", model: "opus", effort: "high", mode: "default" }, {}],
    ["<b>Starting</b>The launch's login-shell probe can take seconds; the prompt waits, dim, in its bubble.", { state: "starting", model: "opus", effort: "high", mode: "auto" }, {}],
    ["<b>At rest</b>The chips are the session's last settings; resume passes them as flags.", { state: "rest", model: "sonnet", effort: "xhigh", mode: "acceptEdits" }, {}],
    ["<b>Failed</b>A red wash over the card, stderr's last line, Restart. Send restarts too.", { state: "failed", model: "opus", effort: "high", mode: "auto" }, {}],
    ["<b>Haiku · Fast · Bypass</b>No effort on Haiku: the chip stays, disabled. Fast is a bolt. Bypass is the one red mode.", { state: "idle", model: "haiku", mode: "bypassPermissions" }, {}],
    ["<b>Fast on Opus · context past half</b>The ring appears at 50 % and opens /context.", { state: "idle", model: "opus", fast: true, effort: "max", mode: "acceptEdits", ctx: 0.72 }, {}],
    ["<b>Refused</b>The control reverts; the reason is one red line under the card.", { state: "idle", model: "opus", effort: "high", mode: "auto", err: "Opus 4.8 isn't available to your organization." }, {}],
    ["<b>A command, completed</b>The field draws the same token as the transcript's bubble.", { state: "idle", model: "opus", effort: "high", mode: "auto", token: "review" }, { text: "#327" }],
  ];
  document.getElementById("lv-composers").innerHTML = cs.map(([c, o, so]) => card(c, staticComposer(o, so))).join("");

  // Menus
  const idle = specS({ state: "idle", model: "opus", effort: "high", mode: "auto" });
  const busy = specS({ state: "responding", model: "opus", pendingModel: "sonnet", effort: "high", mode: "auto" });
  const s46 = specS({ state: "idle", model: "sonnet-4-6", effort: "xhigh", mode: "default" });
  const fast = specS({ state: "idle", model: "opus", fast: true, effort: "high", mode: "acceptEdits" });
  const hk = specS({ state: "idle", model: "haiku", mode: "default" });
  const fig = (cap, html) => `<figure><figcaption>${cap}</figcaption>${html}</figure>`;
  document.getElementById("lv-menus").innerHTML = `<div class="lv-menus">${[
    fig("<b>Model · idle</b>Applied now (≈ 1.5 s); the /model bubble follows.", menuHTML(menuItems("model", idle), { static: true })),
    fig("<b>Model · while Claude works</b>The header says when.", menuHTML(menuItems("model", busy), { static: true })),
    fig("<b>Effort · Sonnet 4.6</b>Extra High isn't on this model: it runs as High, and says why.", menuHTML(menuItems("effort", s46), { static: true })),
    fig("<b>Permission mode · Fast on</b>Auto is greyed with its reason; Bypass waits on Settings.", menuHTML(menuItems("mode", fast), { static: true })),
    fig("<b>Permission mode · Haiku</b>", menuHTML(menuItems("mode", hk), { static: true })),
    fig("<b>Folder</b>The New view's title menu.", menuHTML(menuItems("folder", idle), { static: true })),
    fig("<b>Commands</b>Above the card; ↑ ↓ move, ↩ or ⇥ completes.", `<div style="width:420px">${slashHTML("", 0, { static: true })}</div>`),
  ].join("")}</div>`;
}

// MARK: - The matrix (08-live.md "Settings × state")

function buildMatrix() {
  const W = (t) => `<span class="when">${LV.clock.replace('class="pend"', 'class="pend" style="width:10px;height:10px"')} ${t}</span>`;
  const cols = [["New tab", "a draft · launch flags"], ["Starting", "launching"], ["Idle", "control requests"], ["Responding", ""], ["Waiting for you", ""], ["At rest", "flags on resume"], ["Failed", "flags on restart"]];
  const rows = [
    ["grp", "Launch-only"],
    ["Folder", '<span class="y">choose</span> · <code>cwd</code>', '<span class="no">fixed</span>', '<span class="no">fixed</span>', '<span class="no">fixed</span>', '<span class="no">fixed</span>', '<span class="no">fixed</span>', '<span class="no">fixed</span>'],
    ["Worktree", '<span class="y">toggle</span> · <code>--worktree</code>', "—", "—", "—", "—", "—", "—"],
    ["Account", '<span class="y">choose</span> (&gt; 1) · env', "—", "—", "—", "—", "—", "—"],
    ["grp", "Steerable"],
    ["Model", '<span class="y">choose</span> · <code>--model</code>', '<span class="y">choose</span> · held', '<span class="y">now</span> · <code>set_model</code> ≈ 1.5 s', W("after this turn"), W("after this turn"), '<span class="y">choose</span> · <code>--model</code>', '<span class="y">choose</span> · <code>--model</code>'],
    ["Fast", '<span class="y">toggle</span> · <code>fastMode</code>', "held", '<span class="y">now</span> · <code>apply_flag_settings</code>', W("after this turn"), W("after this turn"), "flag", "flag"],
    ["Effort", '<span class="y">choose</span> · <code>--effort</code>', "held", '<span class="y">next request</span> · <code>apply_flag_settings</code>', '<span class="y">next request</span>', '<span class="y">next request</span>', "<code>--effort</code>", "<code>--effort</code>"],
    ["Mode", '<span class="y">choose</span> · <code>--permission-mode</code>', "held", '<span class="y">now</span> · <code>set_permission_mode</code>', '<span class="y">now</span>', '<span class="y">now</span> — the request stays', "<code>--permission-mode</code>", "<code>--permission-mode</code>"],
    ["grp", "Actions"],
    ["Send ↩", '<span class="y">launches</span>', "held, dim", '<span class="y">sends</span>', '<span class="y">queues</span>', '<span class="y">queues</span>', "resumes, then sends", "restarts, then sends"],
    ["Stop ⌘.", "—", "cancels the launch", "—", "<code>interrupt</code>", "<code>interrupt</code> · request withdrawn", "—", "—"],
  ];
  document.getElementById("lv-matrix").innerHTML = `<div class="matrix-wrap"><table class="matrix"><thead><tr><th></th>${cols.map(([c, sub], i) => `<th class="${i === 1 ? "half" : ""}">${c}<span class="sub">${sub}</span></th>`).join("")}</tr></thead><tbody>${rows.map((r) =>
    r[0] === "grp" ? `<tr class="grp"><th colspan="8">${r[1]}</th></tr>` : `<tr><th>${r[0]}</th>${r.slice(1).map((c, i) => `<td class="${i === 1 ? "half" : ""}">${c}</td>`).join("")}</tr>`
  ).join("")}</tbody></table></div>`;
}

// MARK: - Boot

document.addEventListener("click", (e) => { if (MENU.el && !MENU.el.contains(e.target) && !(MENU.sub && MENU.sub.contains(e.target))) MENU.close(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && MENU.el) MENU.close(); });
window.addEventListener("scroll", () => MENU.close(), { passive: true });
document.addEventListener("DOMContentLoaded", () => {
  LW.mount(document.getElementById("live"));
  reset("empty");
  document.querySelectorAll("[data-scene]").forEach((b) => b.addEventListener("click", () => reset(b.dataset.scene)));
  const bp = document.getElementById("lv-allow-bypass");
  bp.addEventListener("change", () => { LV_SETTINGS.allowBypass = bp.checked; });
  buildLiveSpecimens();
  buildMatrix();
});
