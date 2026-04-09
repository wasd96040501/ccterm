/**
 * E2E performance benchmark for Chat Content View.
 *
 * Measures: initial render, first paint, scroll FPS, conversation switch,
 * message append, and JS heap usage across different workload sizes.
 *
 * Run: bun run bench
 */

import { test } from '@playwright/test'
import { readFileSync } from 'fs'
import { join } from 'path'
import { generateMessages } from './generate-fixtures'

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const WORKLOADS = [
  { name: '50msg', count: 50 },
  { name: '200msg', count: 200 },
  { name: '1000msg', count: 1000 },
  { name: '3000msg', count: 3000 },
]

const RUNS_PER_WORKLOAD = 3
const VIEWPORT = { width: 900, height: 700 }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const distDir = join(import.meta.dirname, '..', 'dist')

const MIME: Record<string, string> = {
  '.js': 'application/javascript',
  '.css': 'text/css',
  '.html': 'text/html',
}

const BENCH_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <style>html, body { margin: 0; padding: 0; height: 100%; }</style>
  <link rel="stylesheet" href="/index.css" />
</head>
<body>
  <div id="root"></div>
  <script src="/index.js"></script>
</body>
</html>`

async function setupRoutes(page: import('@playwright/test').Page) {
  await page.route('**/*', (route) => {
    const url = new URL(route.request().url())
    const path = url.pathname
    if (path === '/' || path === '/index.html') {
      return route.fulfill({ body: BENCH_HTML, contentType: 'text/html' })
    }
    try {
      const filePath = join(distDir, path)
      const body = readFileSync(filePath)
      const ext = path.substring(path.lastIndexOf('.'))
      return route.fulfill({ body, contentType: MIME[ext] || 'application/octet-stream' })
    } catch {
      return route.fulfill({ status: 404, body: 'Not found' })
    }
  })
}

function median(arr: number[]): number {
  const sorted = [...arr].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

function percentile(arr: number[], p: number): number {
  const sorted = [...arr].sort((a, b) => a - b)
  const idx = Math.ceil((p / 100) * sorted.length) - 1
  return sorted[Math.max(0, idx)]
}

interface BenchResult {
  workload: string
  initRenderMs: number
  firstPaintMs: number
  scrollP50Ms: number
  scrollP95Ms: number
  scrollP99Ms: number
  scrollMaxMs: number
  longFrames: number
  switchConvMs: number
  switchBackMs: number
  appendMsgMs: number
  heapUsedMB: number
}

// ---------------------------------------------------------------------------
// In-page helpers
// ---------------------------------------------------------------------------

/**
 * Observe #root (always exists) for any DOM mutation from React commit,
 * then wait one more rAF for paint.
 *
 * Returns { commitMs, paintMs }.
 */
const INJECT_DOM_WAIT_HELPER = `
  window.__waitForDomUpdate = function() {
    return new Promise((resolve) => {
      const target = document.getElementById('root');
      if (!target) { resolve({ commitMs: -1, paintMs: -1 }); return; }

      const start = performance.now();
      const observer = new MutationObserver(() => {
        const commitMs = performance.now() - start;
        observer.disconnect();
        requestAnimationFrame(() => {
          resolve({ commitMs, paintMs: performance.now() - start });
        });
      });
      observer.observe(target, { childList: true, subtree: true, characterData: true });

      setTimeout(() => {
        observer.disconnect();
        resolve({ commitMs: -1, paintMs: -1 });
      }, 10000);
    });
  };
`

/**
 * Simpler paint-only timing: measure from call to rAF+rAF.
 * Used as fallback and for init render where we know React hasn't mounted yet.
 */
const INJECT_PAINT_TIMER = `
  window.__measurePaint = function(actionFn) {
    return new Promise((resolve) => {
      const start = performance.now();
      actionFn();
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          resolve(performance.now() - start);
        });
      });
    });
  };
`

// ---------------------------------------------------------------------------
// In-page helper: continuous scroll frame measurement
// ---------------------------------------------------------------------------

const INJECT_SCROLL_BENCH = `
  window.__runScrollBench = function(durationMs) {
    return new Promise((resolve) => {
      const el = document.querySelector('.message-list');
      if (!el) { resolve([]); return; }

      const totalScroll = el.scrollHeight - el.clientHeight;
      const frames = [];
      const startTime = performance.now();
      let lastFrame = startTime;

      el.scrollTop = 0;

      function tick() {
        const now = performance.now();
        frames.push(now - lastFrame);
        lastFrame = now;

        const elapsed = now - startTime;
        if (elapsed >= durationMs) {
          resolve(frames.slice(1)); // drop first frame (warmup)
          return;
        }

        // Continuous smooth scroll: advance proportionally
        el.scrollTop = totalScroll * (elapsed / durationMs);
        requestAnimationFrame(tick);
      }

      requestAnimationFrame(tick);
    });
  };
`

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

test.describe('Chat Content View Benchmark', () => {
  test.setTimeout(300_000)

  test('run all workloads', async ({ browser }) => {
    const allResults: BenchResult[] = []

    for (const workload of WORKLOADS) {
      const messages = generateMessages(workload.count, 0)
      const messagesJson = JSON.stringify(messages)
      const runResults: BenchResult[] = []

      for (let run = 0; run < RUNS_PER_WORKLOAD; run++) {
        // Fresh page per run to isolate GC / state
        const page = await browser.newPage({ viewport: VIEWPORT })

        let cdp: import('@playwright/test').CDPSession | null = null
        try {
          cdp = await page.context().newCDPSession(page)
          await cdp.send('Performance.enable')
        } catch {
          cdp = null
        }

        await setupRoutes(page)
        await page.goto('http://localhost/')
        await page.waitForSelector('#root', { timeout: 5000 })
        await page.waitForTimeout(100)

        // Inject all helpers
        await page.evaluate(INJECT_DOM_WAIT_HELPER)
        await page.evaluate(INJECT_PAINT_TIMER)
        await page.evaluate(INJECT_SCROLL_BENCH)

        // ---- 1. Initial render ----
        // #root exists but .message-list doesn't yet.
        // Observe #root for React mounting MessageList, then wait rAF for paint.
        const initTiming = await page.evaluate(async (json) => {
          const w = window as any
          const waitPromise = w.__waitForDomUpdate()
          const msgs = JSON.parse(json)
          w.__bridge('setMessages', JSON.stringify({ conversationId: 'bench-conv', messages: msgs }))
          w.__bridge('switchConversation', JSON.stringify({ conversationId: 'bench-conv' }))
          return await waitPromise
        }, messagesJson)
        const initRenderMs = initTiming.commitMs
        const firstPaintMs = initTiming.paintMs

        // Wait for content to fully settle
        await page.waitForTimeout(300)

        // ---- 2. Scroll performance ----
        const scrollDuration = Math.min(2000, 500 + workload.count)
        const frames: number[] = await page.evaluate(
          (ms) => (window as any).__runScrollBench(ms),
          scrollDuration,
        )
        const scrollFrames = frames.filter(f => f > 0 && f < 200)

        // ---- 3. Conversation switch ----
        // Same message count but seed=1 for different content,
        // ensuring React actually updates the DOM.
        const otherMessages = generateMessages(workload.count, 1)
        await page.evaluate((json) => {
          ;(window as any).__bridge('setMessages', JSON.stringify({ conversationId: 'bench-conv-other', messages: JSON.parse(json) }))
        }, JSON.stringify(otherMessages))
        await page.waitForTimeout(50)

        // Re-inject observer (fresh closure)
        await page.evaluate(INJECT_DOM_WAIT_HELPER)

        const switchTiming = await page.evaluate(async () => {
          const w = window as any
          const waitPromise = w.__waitForDomUpdate()
          w.__bridge('switchConversation', JSON.stringify({ conversationId: 'bench-conv-other' }))
          return await waitPromise
        })
        const switchConvMs = switchTiming.paintMs

        // ---- 3b. Switch back (DOM cache hit) ----
        await page.evaluate(INJECT_DOM_WAIT_HELPER)
        const switchBackTiming = await page.evaluate(async () => {
          const w = window as any
          const waitPromise = w.__waitForDomUpdate()
          w.__bridge('switchConversation', JSON.stringify({ conversationId: 'bench-conv' }))
          return await waitPromise
        })
        const switchBackMs = switchBackTiming.paintMs
        await page.waitForTimeout(100)

        // ---- 4. Append message ----
        await page.evaluate(INJECT_DOM_WAIT_HELPER)
        const appendTiming = await page.evaluate(async () => {
          const w = window as any
          const waitPromise = w.__waitForDomUpdate()
          w.__bridge('appendMessages', JSON.stringify({
            conversationId: 'bench-conv',
            messages: [{
              type: 'assistant',
              id: `bench-append-${Date.now()}`,
              content: 'Appended message for benchmark. Contains **Markdown** and `code`.',
              timestamp: Date.now(),
            }]
          }))
          return await waitPromise
        })
        const appendMsgMs = appendTiming.paintMs

        // ---- 5. JS Heap ----
        let heapUsedMB = 0
        if (cdp) {
          await cdp.send('HeapProfiler.collectGarbage')
          await page.waitForTimeout(100)
          const metrics = await cdp.send('Performance.getMetrics')
          const heap = metrics.metrics.find((m: any) => m.name === 'JSHeapUsedSize')
          heapUsedMB = heap ? heap.value / (1024 * 1024) : 0
        }

        runResults.push({
          workload: workload.name,
          initRenderMs,
          firstPaintMs,
          scrollP50Ms: scrollFrames.length > 0 ? percentile(scrollFrames, 50) : 0,
          scrollP95Ms: scrollFrames.length > 0 ? percentile(scrollFrames, 95) : 0,
          scrollP99Ms: scrollFrames.length > 0 ? percentile(scrollFrames, 99) : 0,
          scrollMaxMs: scrollFrames.length > 0 ? Math.max(...scrollFrames) : 0,
          longFrames: scrollFrames.filter(f => f > 16.67).length,
          switchConvMs,
          switchBackMs,
          appendMsgMs,
          heapUsedMB,
        })

        await page.close()
      }

      const medianResult: BenchResult = {
        workload: workload.name,
        initRenderMs: median(runResults.map(r => r.initRenderMs)),
        firstPaintMs: median(runResults.map(r => r.firstPaintMs)),
        scrollP50Ms: median(runResults.map(r => r.scrollP50Ms)),
        scrollP95Ms: median(runResults.map(r => r.scrollP95Ms)),
        scrollP99Ms: median(runResults.map(r => r.scrollP99Ms)),
        scrollMaxMs: median(runResults.map(r => r.scrollMaxMs)),
        longFrames: median(runResults.map(r => r.longFrames)),
        switchConvMs: median(runResults.map(r => r.switchConvMs)),
        switchBackMs: median(runResults.map(r => r.switchBackMs)),
        appendMsgMs: median(runResults.map(r => r.appendMsgMs)),
        heapUsedMB: median(runResults.map(r => r.heapUsedMB)),
      }

      allResults.push(medianResult)
    }

    printReport(allResults)
  })
})

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

function printReport(results: BenchResult[]) {
  const fmt = (v: number, unit: string, decimals = 1) =>
    `${v.toFixed(decimals)}${unit}`

  console.log('\n')
  console.log('='.repeat(80))
  console.log('  Chat Content View — E2E Benchmark Report')
  console.log('='.repeat(80))

  const header = ['Metric', ...results.map(r => r.workload)]
  const rows: string[][] = [
    ['Init render (commit)', ...results.map(r => fmt(r.initRenderMs, 'ms'))],
    ['Init render (paint)', ...results.map(r => fmt(r.firstPaintMs, 'ms'))],
    ['Scroll P50', ...results.map(r => fmt(r.scrollP50Ms, 'ms'))],
    ['Scroll P95', ...results.map(r => fmt(r.scrollP95Ms, 'ms'))],
    ['Scroll P99', ...results.map(r => fmt(r.scrollP99Ms, 'ms'))],
    ['Scroll max', ...results.map(r => fmt(r.scrollMaxMs, 'ms'))],
    ['Long frames (>16.7ms)', ...results.map(r => String(Math.round(r.longFrames)))],
    ['Conv switch (paint)', ...results.map(r => fmt(r.switchConvMs, 'ms'))],
    ['Conv switch back (cached)', ...results.map(r => fmt(r.switchBackMs, 'ms'))],
    ['Msg append (paint)', ...results.map(r => fmt(r.appendMsgMs, 'ms'))],
    ['JS Heap (after GC)', ...results.map(r => fmt(r.heapUsedMB, 'MB'))],
  ]

  const allRows = [header, ...rows]
  const colWidths = header.map((_, ci) =>
    Math.max(...allRows.map(row => (row[ci] || '').length)) + 2
  )

  const separator = colWidths.map(w => '-'.repeat(w)).join('+')

  console.log('')
  console.log(header.map((h, i) => h.padEnd(colWidths[i])).join('|'))
  console.log(separator)
  for (const row of rows) {
    console.log(row.map((cell, i) => cell.padEnd(colWidths[i])).join('|'))
  }
  console.log('')
  console.log('='.repeat(80))
  console.log(`  Viewport: ${VIEWPORT.width}x${VIEWPORT.height}  |  Runs per workload: ${RUNS_PER_WORKLOAD}  |  Values: median`)
  console.log('='.repeat(80))
  console.log('')
}
