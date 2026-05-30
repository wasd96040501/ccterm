'use strict';
// 运行：node --test design/icon/spiral-gradient.test.js
const test = require('node:test');
const assert = require('node:assert');
const S = require('./spiral-gradient.js');

const C = S.consts;
const dot = (ax, ay, bx, by) => ax * bx + ay * by;
const rgbDist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);

//==================== ① 螺线几何锚点 ====================
test('spiral passes through the drawn quarter-turn anchors', () => {
  const s0 = S.spiralPoint(0);
  assert.ok(Math.hypot(s0.x - 400, s0.y - 323.607) < 1e-6, 'θ=0 → 外起点 (400,323.607)');
  const s1 = S.spiralPoint(Math.PI / 2);
  assert.ok(Math.hypot(s1.x - 152.786, s1.y - 76.393) < 0.05, 'θ=π/2 → (152.786,76.393)');
  const s2 = S.spiralPoint(Math.PI);
  assert.ok(Math.hypot(s2.x - 0, s2.y - 229.180) < 0.1, 'θ=π → (0,229.180)');
});

test('tangent is the analytic derivative (finite-difference check)', () => {
  const th = 1.3, e = 1e-5;
  const a = S.spiralPoint(th - e), b = S.spiralPoint(th + e), T = S.spiralTangent(th);
  const fdx = (b.x - a.x) / (2 * e), fdy = (b.y - a.y) / (2 * e);
  assert.ok(Math.hypot(fdx - T.x, fdy - T.y) < 1e-3, 'S′(θ) 与数值导数一致');
});

//==================== ② 弧长 ∝ 半径（线性分布的依据）====================
test('arc length is linear in radius: ℓ(θ) = √(1+b²)/b · (r₀ − r)', () => {
  const coeff = Math.sqrt(1 + C.Bspi * C.Bspi) / C.Bspi;
  for (const th of [0.5, 2, 5, 9]) {
    const expected = coeff * (C.R0 - S.radiusAt(th));
    assert.ok(Math.abs(S.arcLen(th) - expected) < 1e-6, `θ=${th}`);
  }
});

//==================== ③ 法足：垂直性 ====================
test('every foot satisfies ⟨p − S(θ*), S′(θ*)⟩ ≈ 0 (perpendicular)', () => {
  for (const p of [[150, 200], [90, 280], [200, 150], [60, 255], [300, 132]]) {
    const feet = S.findFeet(p[0], p[1]);
    assert.ok(feet.length > 0, `(${p}) 至少一个法足`);
    for (const f of feet) {
      const sp = S.spiralPoint(f.theta), T = S.spiralTangent(f.theta);
      const num = dot(p[0] - sp.x, p[1] - sp.y, T.x, T.y);
      const cosA = num / (Math.hypot(p[0] - sp.x, p[1] - sp.y) * Math.hypot(T.x, T.y) + 1e-9);
      assert.ok(Math.abs(cosA) < 0.03, `(${p}) θ=${f.theta.toFixed(3)} cos=${cosA.toFixed(4)}`);
    }
  }
});

//==================== ④ 两向法足都要（单向 bug 的回归测试）====================
test('findFeet returns BOTH local minima and maxima (not single-direction)', () => {
  // 内部点应同时存在 near(min) 与 far(max) 法足
  for (const p of [[150, 200], [120, 240], [180, 230]]) {
    const feet = S.findFeet(p[0], p[1]);
    assert.ok(feet.some(f => f.kind === 'min'), `(${p}) 应有局部极小`);
    assert.ok(feet.some(f => f.kind === 'max'), `(${p}) 应有局部极大（否则就是单向 bug）`);
  }
});

test('minima and maxima interleave (Rolle): counts differ by ≤ 2', () => {
  for (const p of [[150, 200], [90, 280], [130, 220]]) {
    const feet = S.findFeet(p[0], p[1]);
    const nMin = feet.filter(f => f.kind === 'min').length;
    const nMax = feet.filter(f => f.kind === 'max').length;
    assert.ok(Math.abs(nMin - nMax) <= 2, `(${p}) min=${nMin} max=${nMax}`);
  }
});

test('the global-nearest spiral point is among the returned minima', () => {
  for (const p of [[150, 200], [90, 280], [70, 255]]) {
    const feet = S.findFeet(p[0], p[1]);
    // 网格全局最近
    let best = Infinity, bestTh = 0;
    for (let j = 0; j <= 400; j++) {
      const th = j * C.THMAX / 400, sp = S.spiralPoint(th);
      const d = Math.hypot(sp.x - p[0], sp.y - p[1]);
      if (d < best) { best = d; bestTh = th; }
    }
    const near = feet.filter(f => f.kind === 'min').reduce((m, f) => f.d < m.d ? f : m, { d: Infinity });
    assert.ok(near.d <= best + 1.0, `(${p}) 最近极小 d=${near.d?.toFixed(2)} vs 网格最近 ${best.toFixed(2)}`);
  }
});

//==================== ⑤ Oklab 往返 ====================
test('Oklab round-trip hex → Oklab → sRGB ≈ identity', () => {
  for (const hex of ['#440154', '#21918c', '#fde725', '#bd0026', '#f6eff7', '#1a1814']) {
    const ok = S.hexToOklab(hex);
    const rgb = S.oklabToRGB(ok[0], ok[1], ok[2]);
    const orig = [parseInt(hex.slice(1, 3), 16), parseInt(hex.slice(3, 5), 16), parseInt(hex.slice(5, 7), 16)];
    assert.ok(rgbDist(rgb, orig) <= 2, `${hex} → ${rgb} (Δ=${rgbDist(rgb, orig).toFixed(2)})`);
  }
});

test('rampOklab endpoints hit the stops; midpoint is between', () => {
  const stops = ['#000000', '#808080', '#ffffff'].map(S.hexToOklab);
  assert.deepStrictEqual(S.rampOklab(stops, 0), stops[0]);
  assert.deepStrictEqual(S.rampOklab(stops, 1), stops[2]);
  const mid = S.rampOklab(stops, 0.5);
  assert.ok(mid[0] > stops[0][0] && mid[0] < stops[2][0], 'L 居中');
});

//==================== ⑥ ψ 分布 ====================
test('ψ is monotone increasing with θ, in [0,1], both distributions', () => {
  for (const dist of ['lin', 'ang']) {
    let prev = -1;
    for (let th = 0; th <= C.THMAX; th += C.THMAX / 50) {
      const v = S.psi(th, dist);
      assert.ok(v >= 0 && v <= 1, `${dist} ψ∈[0,1]`);
      assert.ok(v >= prev - 1e-9, `${dist} 单调`);
      prev = v;
    }
    assert.ok(S.psi(0, dist) < 0.02, `${dist} ψ(0)≈0`);
  }
});

//==================== ⑦ 混合：单法足返回该足色 ====================
test('blendFeet with a single foot returns that foot color', () => {
  const stops = ['#000004', '#bb3754', '#fcffa4'].map(S.hexToOklab);
  const f = [{ theta: 1.0, d: 10, r: S.radiusAt(1.0), kind: 'min' }];
  const got = S.blendFeet(f, stops, { q: 0.6, dist: 'lin', eps: 0.05 });
  const want = S.oklabToRGB.apply(null, S.rampOklab(stops, S.psi(1.0, 'lin')));
  assert.ok(rgbDist(got, want) <= 1, `${got} vs ${want}`);
});

//==================== ⑧ 连续性（不平滑 bug 的回归测试）====================
// 沿穿过星形的直线密采样取色，相邻 0.4px 之间不应出现颜色突跳（真正的不连续）。
test('color is continuous along a line crossing the star (no discontinuity)', () => {
  const stops = ['#440154', '#3b528b', '#21918c', '#5ec962', '#fde725'].map(S.hexToOklab);
  const opts = { q: 0.4, dist: 'ang', eps: 0.5, rEye: 12 };   // 锁定的渲染参数
  const lines = [
    { y: 255.279, x0: 40, x1: 185, horiz: true },   // 过极点 P 的水平线
    { x: 110.557, y0: 175, y1: 335, horiz: false },  // 过 P 的竖直线
    { y: 230, x0: 40, x1: 190, horiz: true },        // 偏离 P 的水平线
  ];
  let worst = 0, worstAt = null;
  for (const ln of lines) {
    let prev = null;
    const N = 380, step = ln.horiz ? (ln.x1 - ln.x0) / N : (ln.y1 - ln.y0) / N;
    for (let i = 0; i <= N; i++) {
      const px = ln.horiz ? ln.x0 + i * step : ln.x;
      const py = ln.horiz ? ln.y : ln.y0 + i * step;
      const c = S.colorAt(px, py, stops, opts);
      if (c && prev) { const d = rgbDist(c, prev); if (d > worst) { worst = d; worstAt = [px.toFixed(1), py.toFixed(1)]; } }
      prev = c;
    }
  }
  // 步长内的 sRGB 欧氏跳变阈值：纯平滑渐变远小于此；真正的硬边会 > 此值。
  assert.ok(worst < 22, `相邻取样最大跳变 ${worst.toFixed(1)} @ ${worstAt}（应 < 22，过大=不连续）`);
});
