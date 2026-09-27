// A quick, dependency-free stand-in for how macOS presents an icon: the art
// clipped to the continuous-corner squircle, inset on the 1024 grid (body =
// 824) with a soft drop shadow. Good enough to judge composition and colour
// on a contact sheet; the final check is `ictool` rendering the real .icon.

import { CANVAS } from "../pixel"

/** Superellipse (n = 5) — visually indistinguishable from Apple's squircle at icon sizes. */
export function squirclePath(x: number, y: number, size: number, n = 5, steps = 256): string {
  const r = size / 2
  const cx = x + r
  const cy = y + r
  const pts: string[] = []
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2
    const c = Math.cos(t)
    const s = Math.sin(t)
    const px = cx + r * Math.sign(c) * Math.abs(c) ** (2 / n)
    const py = cy + r * Math.sign(s) * Math.abs(s) ** (2 / n)
    pts.push(`${px.toFixed(2)} ${py.toFixed(2)}`)
  }
  return `M${pts.join("L")}Z`
}

let seq = 0

/**
 * Place `art` (content authored on the 1024 canvas) as a macOS app icon whose
 * full 1024 tile occupies `size` user units at (x, y).
 */
export function mockIcon(art: string, x: number, y: number, size: number): string {
  const id = `m${seq++}`
  const body = (824 / 1024) * CANVAS
  const inset = (CANVAS - body) / 2
  const k = size / CANVAS
  const shape = squirclePath(inset, inset, body)
  return (
    `<g transform="translate(${x} ${y}) scale(${k})">` +
    `<defs><clipPath id="${id}c"><path d="${shape}"/></clipPath>` +
    `<filter id="${id}s" x="-20%" y="-20%" width="140%" height="140%">` +
    `<feGaussianBlur stdDeviation="14"/></filter></defs>` +
    `<path d="${shape}" fill="#000" opacity="0.28" transform="translate(0 12)" filter="url(#${id}s)"/>` +
    // Art is authored full-bleed on 1024; macOS shows it inside the 824 body.
    `<g clip-path="url(#${id}c)"><g transform="translate(${inset} ${inset}) scale(${body / CANVAS})">${art}</g></g>` +
    // Hairline rim, like the system's edge highlight.
    `<path d="${shape}" fill="none" stroke="#fff" stroke-opacity="0.10" stroke-width="3"/>` +
    `</g>`
  )
}
