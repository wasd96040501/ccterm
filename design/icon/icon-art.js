// icon-art.js — single source of truth for the CCTerm app-icon geometry.
//
// DOM-free and dependency-free. Loaded two ways off the same file:
//   • the design page (icon-capsule.html) pulls it in as a classic <script>
//     (works over file://) and reads window.IconArt to draw the blueprint
//     and the live preview;
//   • the exporter (js/scripts/export-appicon.ts) imports it under Bun and
//     calls IconArt.svg(...) to emit a real vector, then rasterises that SVG
//     with @resvg/resvg-js.
//
// Because both paths share this one module, editing the geometry here updates
// the on-screen design AND the exported PNGs — nothing is duplicated.

(function () {
  const rad = (d) => (d * Math.PI) / 180;

  // Apple continuous-corner squircle (figma-squircle math, equal smoothing).
  function squirclePath(side, R, smoothing) {
    const budget = side / 2;
    R = Math.min(R, budget);
    let cs = smoothing;
    let p = (1 + cs) * R;
    const maxCS = budget / R - 1;
    cs = Math.min(cs, maxCS);
    p = Math.min(p, budget);
    const arcMeasure = 90 * (1 - cs);
    const arc = Math.sin(rad(arcMeasure / 2)) * R * Math.SQRT2;
    const angleAlpha = (90 - arcMeasure) / 2;
    const p3p4 = R * Math.tan(rad(angleAlpha / 2));
    const angleBeta = 45 * cs;
    const c = p3p4 * Math.cos(rad(angleBeta));
    const d = c * Math.tan(rad(angleBeta));
    const b = (p - arc - c - d) / 3;
    const a = 2 * b;
    const W = side, H = side, n = (v) => (+v).toFixed(4);
    return `M ${n(W - p)} 0 ` +
      `c ${n(a)} 0 ${n(a + b)} 0 ${n(a + b + c)} ${n(d)} ` +
      `a ${n(R)} ${n(R)} 0 0 1 ${n(arc)} ${n(arc)} ` +
      `c ${n(d)} ${n(c)} ${n(d)} ${n(b + c)} ${n(d)} ${n(a + b + c)} ` +
      `L ${n(W)} ${n(H - p)} ` +
      `c 0 ${n(a)} 0 ${n(a + b)} ${n(-d)} ${n(a + b + c)} ` +
      `a ${n(R)} ${n(R)} 0 0 1 ${n(-arc)} ${n(arc)} ` +
      `c ${n(-c)} ${n(d)} ${n(-(b + c))} ${n(d)} ${n(-(a + b + c))} ${n(d)} ` +
      `L ${n(p)} ${n(H)} ` +
      `c ${n(-a)} 0 ${n(-(a + b))} 0 ${n(-(a + b + c))} ${n(-d)} ` +
      `a ${n(R)} ${n(R)} 0 0 1 ${n(-arc)} ${n(-arc)} ` +
      `c ${n(-d)} ${n(-c)} ${n(-d)} ${n(-(b + c))} ${n(-d)} ${n(-(a + b + c))} ` +
      `L 0 ${n(p)} ` +
      `c 0 ${n(-a)} 0 ${n(-(a + b))} ${n(d)} ${n(-(a + b + c))} ` +
      `a ${n(R)} ${n(R)} 0 0 1 ${n(arc)} ${n(-arc)} ` +
      `c ${n(c)} ${n(-d)} ${n(b + c)} ${n(-d)} ${n(a + b + c)} ${n(-d)} Z`;
  }

  // ---- fixed geometry (design units; the body square is BODY × BODY) ----
  const BODY = 400;
  const SQUIRCLE_R = (BODY * 185.4) / 824; // 0.225 · body
  const SQUIRCLE_SMOOTHING = 0.6;
  const SQUIRCLE = squirclePath(BODY, SQUIRCLE_R, SQUIRCLE_SMOOTHING);

  // Spiral reference square = the squircle's largest inscribed square ("middle
  // square", side 347.279). The whole golden construction is scaled about the
  // icon centre by S so it never reaches into the rounded-off corners.
  const CENTER = { x: BODY / 2, y: BODY / 2 };
  const REF = 347.279;
  const S = REF / BODY; // ≈ 0.8682
  const sc = (p) => ({ x: CENTER.x + S * (p.x - CENTER.x), y: CENTER.y + S * (p.y - CENTER.y) });
  const P = sc({ x: 110.557, y: 255.279 }); // pole (scaled)
  const D = sc({ x: 309.438, y: 132.362 }); // capsule centre (scaled)
  const e1 = { x: 0.8506508, y: -0.5257311 }; // axis 1 = P→D direction
  const e2 = { x: 0.5257311, y: 0.8506508 };
  const CAP_ANGLE = (Math.atan2(e1.y, e1.x) * 180) / Math.PI; // ≈ -31.7175°
  // Lengths are scaled by S too, so the star/capsule shrink with the frame.
  const lin = (a1, a2) => ({
    x: P.x + a1 * S * e1.x + a2 * S * e2.x,
    y: P.y + a1 * S * e1.y + a2 * S * e2.y,
  });

  const DEFAULTS = { m: 112, k: 1.02, capLen: 128, capThk: 12 };
  const clampK = (k) => Math.min(Math.max(k, 1.02), Math.SQRT2);
  const f2 = (v) => v.toFixed(2);

  // Resolve all driven geometry for a given slider state.
  function geometry(params) {
    const p = Object.assign({}, DEFAULTS, params);
    const k = clampK(p.k);
    const m = p.m, capLen = p.capLen, capThk = p.capThk;
    const r = m * k;
    const rS = r * S;
    const t = m * (1 - Math.sqrt(k * k - 1));

    const tipPts = [lin(t, 0), lin(0, t), lin(-t, 0), lin(0, -t)];
    const tips = tipPts.map((q) => `${f2(q.x)},${f2(q.y)}`).join(" ");

    const centers = [lin(m, m), lin(-m, m), lin(-m, -m), lin(m, -m)];
    const circles = centers.map((c) => ({ cx: f2(c.x), cy: f2(c.y), r: f2(rS) }));

    const capL = capLen * S, capT = capThk * S;
    const capsule = {
      x: f2(D.x - capL / 2), y: f2(D.y - capT / 2),
      width: f2(capL), height: f2(capT), rx: f2(capT / 2), ry: f2(capT / 2),
    };
    const capTransform = `rotate(${CAP_ANGLE.toFixed(3)} ${D.x} ${D.y})`;

    return {
      squircle: SQUIRCLE, tips, circles, capsule, capTransform,
      metrics: { rS, tS: t * S, capL, capT, k, m, capLen, capThk, flat: capLen / capThk },
    };
  }

  // Standalone vector for export: full-bleed body (viewBox 0 0 BODY BODY → the
  // squircle fills the whole canvas), NO drop shadow (macOS/Dock add their own).
  function svg(params, opts) {
    const g = geometry(params);
    const size = opts && opts.size;
    const dim = size ? ` width="${size}" height="${size}"` : "";
    const circ = g.circles
      .map((c) => `<circle cx="${c.cx}" cy="${c.cy}" r="${c.r}" fill="#000000"/>`)
      .join("\n      ");
    const cap = g.capsule;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${BODY} ${BODY}"${dim}>
  <defs>
    <clipPath id="sq" clipPathUnits="userSpaceOnUse"><path d="${g.squircle}"/></clipPath>
    <mask id="star" maskUnits="userSpaceOnUse" x="-60" y="-60" width="520" height="520">
      <polygon points="${g.tips}" fill="#FFFFFF"/>
      ${circ}
    </mask>
  </defs>
  <path d="${g.squircle}" fill="#FFFFFF"/>
  <g clip-path="url(#sq)">
    <rect x="-60" y="-60" width="520" height="520" fill="#000000" mask="url(#star)"/>
    <g transform="${g.capTransform}"><rect x="${cap.x}" y="${cap.y}" width="${cap.width}" height="${cap.height}" rx="${cap.rx}" ry="${cap.ry}" fill="#000000"/></g>
  </g>
</svg>
`;
  }

  const IconArt = {
    squirclePath, geometry, svg,
    SQUIRCLE, BODY, SQUIRCLE_R, SQUIRCLE_SMOOTHING, REF, S, CENTER, P, D, e1, e2, CAP_ANGLE, DEFAULTS,
  };
  globalThis.IconArt = IconArt;
})();
