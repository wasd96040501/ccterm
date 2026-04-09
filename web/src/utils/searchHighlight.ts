/**
 * Search engine using CSS Custom Highlight API.
 * Finds text matches via TreeWalker, highlights via CSS.highlights,
 * and navigates between matches with scrollIntoView.
 */

import { postToNative } from '../bridge.ts'

// State
let allRanges: Range[] = []
let currentIndex = -1
let lastQuery = ''

// MARK: - Public API

/** Search for query, navigate, or clear. Called from bridge event handler. */
export function handleSearch(query: string, direction: 'reset' | 'next' | 'prev'): void {
  if (!query) {
    clear()
    postResult()
    return
  }

  if (direction === 'reset' || query !== lastQuery) {
    performSearch(query)
    // Start from the match closest to viewport center
    if (allRanges.length > 0) {
      currentIndex = findClosestToViewport()
      highlightCurrent()
    }
  } else if (direction === 'next') {
    navigateNext()
  } else if (direction === 'prev') {
    navigatePrev()
  }

  postResult()
}

// MARK: - Search

function performSearch(query: string): void {
  CSS.highlights.clear()
  allRanges = []
  currentIndex = -1
  lastQuery = query

  const lowerQuery = query.toLowerCase()
  const textNodes = collectTextNodes(document.body)

  for (const node of textNodes) {
    const text = node.textContent?.toLowerCase() ?? ''
    let start = 0
    while ((start = text.indexOf(lowerQuery, start)) !== -1) {
      const range = new Range()
      range.setStart(node, start)
      range.setEnd(node, start + query.length)
      allRanges.push(range)
      start += query.length
    }
  }

  if (allRanges.length > 0) {
    CSS.highlights.set('search-results', new Highlight(...allRanges))
  }
}

// MARK: - Navigation

function navigateNext(): void {
  if (allRanges.length === 0) return
  currentIndex = (currentIndex + 1) % allRanges.length
  highlightCurrent()
}

function navigatePrev(): void {
  if (allRanges.length === 0) return
  currentIndex = (currentIndex - 1 + allRanges.length) % allRanges.length
  highlightCurrent()
}

function highlightCurrent(): void {
  if (currentIndex < 0 || currentIndex >= allRanges.length) return

  const range = allRanges[currentIndex]!
  CSS.highlights.set('search-current', new Highlight(range))

  // Scroll the current match into view
  const rect = range.getBoundingClientRect()
  const margin = 80
  if (rect.top < margin || rect.bottom > window.innerHeight - margin) {
    const el = range.startContainer.parentElement
    el?.scrollIntoView({ block: 'center', behavior: 'smooth' })
  }
}

// MARK: - Helpers

function collectTextNodes(root: Node): Text[] {
  const nodes: Text[] = []
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (node.parentElement?.closest('.collapsible-closed')) {
        return NodeFilter.FILTER_REJECT
      }
      return NodeFilter.FILTER_ACCEPT
    },
  })
  while (walker.nextNode()) {
    nodes.push(walker.currentNode as Text)
  }
  return nodes
}

function findClosestToViewport(): number {
  const centerY = window.innerHeight / 2
  let closest = 0
  let minDist = Infinity

  for (let i = 0; i < allRanges.length; i++) {
    const rect = allRanges[i]!.getBoundingClientRect()
    const dist = Math.abs(rect.top - centerY)
    if (dist < minDist) {
      minDist = dist
      closest = i
    }
  }

  return closest
}

function clear(): void {
  CSS.highlights.clear()
  allRanges = []
  currentIndex = -1
  lastQuery = ''
}

function postResult(): void {
  postToNative({
    type: 'searchResult',
    total: allRanges.length,
    current: allRanges.length > 0 ? currentIndex + 1 : 0,
  })
}
