// Renders design/transcript/index.html's live section in headless Chrome and
// writes each scene, each .lv-card and each part in a card (a composer, a New
// view, a tab bar, a prompt, a menu…) as a @2x PNG, light and dark, with
// <scheme>-parts.json giving each part's size in pt. The app's
// `DesignParity` (cctermTests) lays a native render of the same part beside it.
//
//   make design-shots        → /tmp/design-shots
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const out = "/tmp/design-shots";
mkdirSync(out, { recursive: true });
const port = 9333;
const chrome = spawn(
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  ["--headless=new", `--remote-debugging-port=${port}`, "--user-data-dir=/tmp/design-chrome", "--hide-scrollbars",
   "--force-device-scale-factor=2", "about:blank"],
  { stdio: "ignore" });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(200);
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    target = list.find((t) => t.type === "page");
  } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0;
const pending = new Map();
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true })).result.result.value;

async function shoot(name, selectorExpr) {
  const rect = await evaluate(`(() => { const el = ${selectorExpr}; if (!el) return null; el.scrollIntoView({block: 'center'}); const r = el.getBoundingClientRect(); return {x: r.x + scrollX, y: r.y + scrollY, width: r.width, height: r.height}; })()`);
  if (!rect || rect.width === 0) return console.log("missing", name);
  await sleep(150);
  const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true, clip: { ...rect, scale: 1 } });
  writeFileSync(`${out}/${name}.png`, Buffer.from(shot.result.data, "base64"));
  console.log(name, Math.round(rect.width), "x", Math.round(rect.height));
  return rect;
}

await send("Page.enable");
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", { width: 1500, height: 1000, deviceScaleFactor: 2, mobile: false });
for (const scheme of ["light", "dark"]) {
  await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: scheme }] });
  await send("Page.navigate", { url: `file://${root}/design/transcript/index.html` });
  await sleep(2500);
  const scenes = await evaluate(`[...document.querySelectorAll('[data-scene]')].map(b => b.dataset.scene)`);
  const sceneParts = [];
  for (const scene of scenes) {
    await evaluate(`document.querySelector('[data-scene="${scene}"]').click()`);
    await sleep(1500);
    const rect = await shoot(`${scheme}-scene-${scene}`, `document.getElementById('live')`);
    if (rect) sceneParts.push({ name: `${scheme}-scene-${scene}`, card: -1, kind: "scene", n: 0, cap: scene, width: rect.width, height: rect.height, text: "" });
  }
  // Each pop-up as the playground opens it from the New tab, at the width its
  // content gives it (the sheet's static figures are stretched by their captions).
  for (const which of ["model", "effort", "mode", "folder", "branch"]) {
    await evaluate(`document.querySelector('[data-scene="new"]').click()`);
    await sleep(800);
    await evaluate(`document.querySelector('#live [data-lv-menu="${which}"]').dispatchEvent(new MouseEvent('click', {bubbles: true}))`);
    await sleep(400);
    const name = `${scheme}-live-${which}`;
    const rect = await shoot(name, `[...document.querySelectorAll('.lv-menu')].find((m) => !m.classList.contains('static') && m.getClientRects().length)`);
    if (rect) sceneParts.push({ name, card: -1, kind: "live-menu", n: 0, cap: which, width: rect.width, height: rect.height, text: "" });
    await evaluate(`document.body.click()`);
    await sleep(200);
  }
  const cards = await evaluate(`[...document.querySelectorAll('.lv-card')].map((c, i) => {
    const t = (c.querySelector('.cap, .lv-cap, h4, figcaption, .ttl, b')?.textContent || c.textContent).trim().slice(0, 40);
    return {i, t};
  })`);
  for (const { i, t } of cards) {
    const slug = t.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 36);
    await shoot(`${scheme}-card-${String(i).padStart(2, "0")}-${slug}`, `document.querySelectorAll('.lv-card')[${i}]`);
  }
  await shoot(`${scheme}-matrix`, `document.getElementById('lv-matrix')`);
  await shoot(`${scheme}-menus`, `document.getElementById('lv-menus')`);

  // Each component on its own, at its pt size, for a native render of the same size.
  const kinds = { comp: ".lv-comp", new: ".lv-new", bar: ".tabbar", pst: ".pst", menu: ".lv-menu", alert: ".lv-alert", slash: ".lv-slash", side: ".lv-side" };
  const parts = await evaluate(`(() => {
    const kinds = ${JSON.stringify(kinds)};
    const out = [];
    document.querySelectorAll('.lv-card, #lv-menus figure').forEach((card, ci) => {
      for (const [kind, sel] of Object.entries(kinds)) {
        card.querySelectorAll(sel).forEach((el, n) => {
          const r = el.getBoundingClientRect();
          if (r.width === 0) return;
          const cap = (card.querySelector('.cap b, figcaption b')?.textContent || '').trim();
          out.push({ card: ci, kind, n, cap, width: r.width, height: r.height, text: el.innerText.replace(/\\s+/g, ' ').trim().slice(0, 160) });
        });
      }
    });
    return out;
  })()`);
  const manifest = [...sceneParts];
  for (const p of parts) {
    const name = `${scheme}-part-${String(p.card).padStart(2, "0")}-${p.kind}${p.n}`;
    await shoot(name, `document.querySelectorAll('.lv-card, #lv-menus figure')[${p.card}].querySelectorAll(${JSON.stringify(kinds[p.kind])})[${p.n}]`);
    manifest.push({ name, ...p });
  }
  writeFileSync(`${out}/${scheme}-parts.json`, JSON.stringify(manifest, null, 1));
}
ws.close();
chrome.kill();
