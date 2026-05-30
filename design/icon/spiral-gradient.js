/*
 * spiral-gradient.js — 螺线法投影渐变的纯数学核心（无 DOM）
 *
 * 既能被浏览器 <script src> 直接加载（file:// 下也可，因为是经典脚本而非 ES module），
 * 也能被 Node 以 require() 引入做单测。详见 spiral-gradient.test.js。
 *
 * 颜色模型（两阶段）：
 *   ① 沿螺线定色：对数螺线 S(θ)=P+r₀e^{−bθ}(cos(α−θ),sin(α−θ))，b=ln φ /(π/2)；
 *      色阶 c:[0,1]→Oklab 按 ψ(θ) 分布——线性 ψ=1−r/r₀（按弧长=按半径），
 *      非线性 ψ=θ/θ_max（按转角，自相似）。
 *   ② 任意点 p 取色：取所有「p→S(θ*) ⟂ 切线」的法足 ⟨p−S(θ*),S′(θ*)⟩=0
 *      —— 局部极小与局部极大都要（两向，否则不平滑）—— 按 wᵢ=r(θᵢ)^q/dᵢ 在 Oklab 中加权混合。
 *      r^q 抑制尾部，使螺眼附近无穷多法足之和收敛。
 */
(function (root) {
  'use strict';

  //==================== 几何（锁定 #163 默认参数）====================
  var P = { x: 110.557, y: 255.279 };
  var e1 = { x: 0.8506508, y: -0.5257311 };
  var e2 = { x: 0.5257311, y: 0.8506508 };
  var D = { x: 309.438, y: 132.362 };
  var m = 112, k = 1.02, rDec = 16;
  var rCirc = m * k;
  var tg = m * (1 - Math.sqrt(k * k - 1));
  function lin(a, b) { return { x: P.x + a * e1.x + b * e2.x, y: P.y + a * e1.y + b * e2.y }; }
  var TIPS = [lin(tg, 0), lin(0, tg), lin(-tg, 0), lin(0, -tg)];
  var CC = [lin(m, m), lin(-m, m), lin(-m, -m), lin(m, -m)];

  //==================== 黄金对数螺线（解析，匹配画布上的螺线）====================
  var PHI = (1 + Math.sqrt(5)) / 2;
  var Bspi = Math.log(PHI) / (Math.PI / 2);            // ≈ 0.30635
  var R0 = Math.hypot(400 - P.x, 323.607 - P.y);       // 外起点半径 ≈ 297.40
  var ALPHA = Math.atan2(323.607 - P.y, 400 - P.x);    // 外起点角  ≈ 0.2318
  var THMAX = Math.log(R0 / 0.8) / Bspi;               // 盘到 r≈0.8px

  function radiusAt(th) { return R0 * Math.exp(-Bspi * th); }
  function spiralPoint(th) {
    var rho = radiusAt(th), phi = ALPHA - th;
    return { x: P.x + rho * Math.cos(phi), y: P.y + rho * Math.sin(phi) };
  }
  function spiralTangent(th) {
    var rho = radiusAt(th), phi = ALPHA - th, cp = Math.cos(phi), sp = Math.sin(phi);
    return { x: rho * (-Bspi * cp + sp), y: rho * (-Bspi * sp - cp) }; // S'(θ)
  }
  // 弧长闭式（∝ 半径）：ℓ(θ)=(√(1+b²)/b)(r₀−r)
  function arcLen(th) { return Math.sqrt(1 + Bspi * Bspi) / Bspi * (R0 - radiusAt(th)); }

  //==================== 预采样螺线（与像素无关，仅算一次）====================
  var NS = 1100;
  var sX = new Float64Array(NS + 1), sY = new Float64Array(NS + 1);
  var tX = new Float64Array(NS + 1), tY = new Float64Array(NS + 1);
  var sTh = new Float64Array(NS + 1);
  (function buildSamples() {
    for (var j = 0; j <= NS; j++) {
      var th = j * THMAX / NS, rho = R0 * Math.exp(-Bspi * th), phi = ALPHA - th;
      var cp = Math.cos(phi), sp = Math.sin(phi);
      sTh[j] = th;
      sX[j] = P.x + rho * cp; sY[j] = P.y + rho * sp;
      tX[j] = rho * (-Bspi * cp + sp); tY[j] = rho * (-Bspi * sp - cp);
    }
  })();

  //==================== 阶段二：法足（两向都取）====================
  // h(θ)=(S(θ)−p)·S'(θ)=D(θ)·D'(θ)；零点 = 垂直法足。
  //   −→+ 为距离局部极小（near foot），+→− 为局部极大（far foot）。两者都返回。
  function footAt(jLo, fr, px, py, kind) {
    var th = sTh[jLo] + fr * (sTh[jLo + 1] - sTh[jLo]);
    var fx = sX[jLo] + fr * (sX[jLo + 1] - sX[jLo]);
    var fy = sY[jLo] + fr * (sY[jLo + 1] - sY[jLo]);
    return { theta: th, x: fx, y: fy, d: Math.hypot(fx - px, fy - py), r: R0 * Math.exp(-Bspi * th), kind: kind };
  }
  function findFeet(px, py) {
    var feet = [];
    var h0 = (sX[0] - px) * tX[0] + (sY[0] - py) * tY[0];
    if (h0 > 0) feet.push({ theta: 0, x: sX[0], y: sY[0], d: Math.hypot(sX[0] - px, sY[0] - py), r: R0, kind: 'min' }); // 外端边界极小
    for (var j = 1; j <= NS; j++) {
      var h1 = (sX[j] - px) * tX[j] + (sY[j] - py) * tY[j];
      if (h0 < 0 && h1 >= 0) feet.push(footAt(j - 1, h0 / (h0 - h1), px, py, 'min'));
      else if (h0 > 0 && h1 <= 0) feet.push(footAt(j - 1, h0 / (h0 - h1), px, py, 'max'));
      h0 = h1;
    }
    return feet;
  }

  //==================== 阶段一：分布 ψ(θ) ====================
  function psi(th, dist) {
    var v = dist === 'lin' ? (1 - Math.exp(-Bspi * th)) : (th / THMAX);
    return v < 0 ? 0 : v > 1 ? 1 : v;
  }

  //==================== Oklab ====================
  function srgbToLin(c) { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  function hexLin(hex) { return [srgbToLin(parseInt(hex.slice(1, 3), 16)), srgbToLin(parseInt(hex.slice(3, 5), 16)), srgbToLin(parseInt(hex.slice(5, 7), 16))]; }
  function linToOklab(r, g, b) {
    var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    var mm = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return [0.2104542553 * l + 0.7936177850 * mm - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * mm + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * mm - 0.8086757660 * s];
  }
  function oklabToRGB(L, a, b) {
    var l_ = L + 0.3963377774 * a + 0.2158037573 * b;
    var m_ = L - 0.1055613458 * a - 0.0638541728 * b;
    var s_ = L - 0.0894841775 * a - 1.2914855480 * b;
    var l = l_ * l_ * l_, mm = m_ * m_ * m_, s = s_ * s_ * s_;
    var r = 4.0767416621 * l - 3.3077115913 * mm + 0.2309699292 * s;
    var g = -1.2684380046 * l + 2.6097574011 * mm - 0.3413193965 * s;
    var bb = -0.0041960863 * l - 0.7034186147 * mm + 1.7076147010 * s;
    function e(c) { c = c < 0 ? 0 : c > 1 ? 1 : c; return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055; }
    return [Math.round(e(r) * 255), Math.round(e(g) * 255), Math.round(e(bb) * 255)];
  }
  function hexToOklab(h) { var c = hexLin(h); return linToOklab(c[0], c[1], c[2]); }
  function rampOklab(stopsOk, p) {
    p = p < 0 ? 0 : p > 1 ? 1 : p;
    var n = stopsOk.length - 1, s = p * n, i = Math.min(Math.floor(s), n - 1), fr = s - i;
    var A = stopsOk[i], B = stopsOk[i + 1];
    return [A[0] + (B[0] - A[0]) * fr, A[1] + (B[1] - A[1]) * fr, A[2] + (B[2] - A[2]) * fr];
  }

  //==================== 混合 + 取色 ====================
  // wᵢ = r(θᵢ)^q / max(dᵢ, eps)；在 Oklab 内加权平均；两向（极小+极大）法足都参与。
  function blendFeetOklab(feet, stopsOk, opts) {
    var q = opts.q, dist = opts.dist, eps = opts.eps == null ? 0.05 : opts.eps;
    var L = 0, A = 0, B = 0, W = 0;
    for (var i = 0; i < feet.length; i++) {
      var f = feet[i];
      var w = Math.pow(f.r, q) / Math.max(f.d, eps);
      var col = rampOklab(stopsOk, psi(f.theta, dist));
      L += w * col[0]; A += w * col[1]; B += w * col[2]; W += w;
    }
    if (W === 0) return null;
    return [L / W, A / W, B / W];
  }
  // 螺眼是奇点（d_i→r_i，q<1 时权重和发散）：半径 R_eye 内平滑过渡到极限色 c(1)。
  function colorFromFeet(feet, px, py, stopsOk, opts) {
    var base = blendFeetOklab(feet, stopsOk, opts);
    if (base == null) return null;
    var rEye = opts.rEye == null ? 7 : opts.rEye;
    var u = Math.hypot(px - P.x, py - P.y);
    if (u < rEye) {
      var t = u / rEye; t = t * t * (3 - 2 * t);                 // smoothstep
      var pole = rampOklab(stopsOk, 1);                          // c(1) = 螺线收敛色
      base = [pole[0] + (base[0] - pole[0]) * t, pole[1] + (base[1] - pole[1]) * t, pole[2] + (base[2] - pole[2]) * t];
    }
    return oklabToRGB(base[0], base[1], base[2]);
  }
  function blendFeet(feet, stopsOk, opts) { var ok = blendFeetOklab(feet, stopsOk, opts); return ok && oklabToRGB(ok[0], ok[1], ok[2]); }
  function colorAt(px, py, stopsOk, opts) { return colorFromFeet(findFeet(px, py), px, py, stopsOk, opts); }

  var API = {
    consts: { P: P, e1: e1, e2: e2, m: m, k: k, rCirc: rCirc, tg: tg, TIPS: TIPS, CC: CC, D: D, rDec: rDec,
              PHI: PHI, Bspi: Bspi, R0: R0, ALPHA: ALPHA, THMAX: THMAX, NS: NS },
    radiusAt: radiusAt, spiralPoint: spiralPoint, spiralTangent: spiralTangent, arcLen: arcLen,
    findFeet: findFeet, psi: psi,
    hexLin: hexLin, linToOklab: linToOklab, oklabToRGB: oklabToRGB, hexToOklab: hexToOklab, rampOklab: rampOklab,
    blendFeetOklab: blendFeetOklab, blendFeet: blendFeet, colorFromFeet: colorFromFeet, colorAt: colorAt,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = API;
  else root.SpiralGrad = API;
})(typeof window !== 'undefined' ? window : this);
