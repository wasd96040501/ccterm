// Build all JSCore bundles into `macos/ccterm/Resources/`.
//
// Each entry below is one `Bun.build` pass. Output filename equals the bundle
// folder name + `.js` so the Swift side's `Bundle.main.url(forResource:withExtension:)`
// lookup stays stable.
//
// To add a new bundle:
//   1. Create `js/bundles/<name>/index.ts` exposing the JS surface you want from Swift.
//   2. Add `{ name: "<name>" }` to `BUNDLES` below.
//   3. Run `make js-bundles` (or `make build`); the artifact lands in Resources/.

import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))
const JS_ROOT = resolve(HERE, "..")
const REPO_ROOT = resolve(JS_ROOT, "..")
const OUT_DIR = resolve(REPO_ROOT, "macos/ccterm/Resources")

const BUNDLES = [{ name: "hljs-jscore" }] as const

for (const { name } of BUNDLES) {
  const entry = resolve(JS_ROOT, "bundles", name, "index.ts")
  const result = await Bun.build({
    entrypoints: [entry],
    outdir: OUT_DIR,
    naming: `${name}.js`,
    minify: true,
    target: "browser",
    format: "iife",
  })
  if (!result.success) {
    console.error(`Bundle "${name}" failed:`)
    for (const log of result.logs) console.error(log)
    process.exit(1)
  }
  console.log(`Built ${name}.js → ${OUT_DIR}/${name}.js`)
}
