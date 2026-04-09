import type { PlanCommentDTO } from '../stores/planFullScreenStore.ts'

/**
 * Compute cumulative text offsets for a Range within a container.
 * Walks all text nodes in DOM order, counting characters.
 */
export function computeTextOffsets(
  container: HTMLElement,
  range: Range
): { startOffset: number; endOffset: number } {
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT)
  let offset = 0
  let start = -1
  let end = -1
  while (walker.nextNode()) {
    const node = walker.currentNode as Text
    if (node === range.startContainer) start = offset + range.startOffset
    if (node === range.endContainer) {
      end = offset + range.endOffset
      break
    }
    offset += node.length
  }
  return { startOffset: start, endOffset: end }
}

/**
 * Convert cumulative text offsets back to a DOM Range.
 */
export function offsetsToRange(
  container: HTMLElement,
  startOffset: number,
  endOffset: number
): Range | null {
  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT)
  let offset = 0
  let startNode: Text | null = null
  let startLocal = 0
  let endNode: Text | null = null
  let endLocal = 0

  while (walker.nextNode()) {
    const node = walker.currentNode as Text
    const nodeEnd = offset + node.length

    if (!startNode && startOffset >= offset && startOffset <= nodeEnd) {
      startNode = node
      startLocal = startOffset - offset
    }
    if (endOffset >= offset && endOffset <= nodeEnd) {
      endNode = node
      endLocal = endOffset - offset
      break
    }
    offset += node.length
  }

  if (!startNode || !endNode) return null

  try {
    const range = new Range()
    range.setStart(startNode, startLocal)
    range.setEnd(endNode, endLocal)
    return range
  } catch {
    return null
  }
}

/**
 * Get the cumulative text offset at a screen point using caretRangeFromPoint.
 */
export function getTextOffsetAtPoint(
  container: HTMLElement,
  x: number,
  y: number
): number {
  const caretRange = document.caretRangeFromPoint(x, y)
  if (!caretRange || !container.contains(caretRange.startContainer)) return -1

  const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT)
  let offset = 0
  while (walker.nextNode()) {
    const node = walker.currentNode as Text
    if (node === caretRange.startContainer) {
      return offset + caretRange.startOffset
    }
    offset += node.length
  }
  return -1
}

/**
 * Find the comment at a given text offset. Prefers shortest range (most specific).
 */
export function findCommentAtOffset(
  offset: number,
  comments: PlanCommentDTO[]
): PlanCommentDTO | null {
  if (offset < 0) return null
  const hits = comments
    .filter(
      (c) =>
        c.isInline &&
        c.startOffset != null &&
        c.endOffset != null &&
        offset >= c.startOffset! &&
        offset < c.endOffset!
    )
    .sort((a, b) => (a.endOffset! - a.startOffset!) - (b.endOffset! - b.startOffset!))
  return hits[0] ?? null
}

/**
 * Apply CSS Custom Highlight API highlights for inline comments.
 */
export function applyCommentHighlights(
  container: HTMLElement,
  comments: PlanCommentDTO[]
): void {
  const inlineComments = comments.filter((c) => c.isInline)
  CSS.highlights.delete('plan-comments')
  CSS.highlights.delete('plan-comment-hover')

  // Force WKWebView repaint — delete alone doesn't trigger visual update
  container.style.opacity = '0.999'
  requestAnimationFrame(() => { container.style.opacity = '' })

  if (inlineComments.length === 0) return

  const ranges = inlineComments
    .map((c) => offsetsToRange(container, c.startOffset!, c.endOffset!))
    .filter(Boolean) as Range[]

  if (ranges.length > 0) {
    CSS.highlights.set('plan-comments', new Highlight(...ranges))
  }
}

// MARK: - Search (reuse pattern from searchHighlight.ts)

let searchRanges: Range[] = []
let searchIndex = -1
let lastSearchQuery = ''

function collectTextNodes(root: Node): Text[] {
  const nodes: Text[] = []
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  while (walker.nextNode()) {
    nodes.push(walker.currentNode as Text)
  }
  return nodes
}

export function handlePlanSearch(
  container: HTMLElement,
  query: string,
  direction: 'reset' | 'next' | 'prev'
): { total: number; current: number } {
  if (!query) {
    CSS.highlights.delete('search-results')
    CSS.highlights.delete('search-current')
    searchRanges = []
    searchIndex = -1
    lastSearchQuery = ''
    return { total: 0, current: 0 }
  }

  if (direction === 'reset' || query !== lastSearchQuery) {
    CSS.highlights.delete('search-results')
    CSS.highlights.delete('search-current')
    searchRanges = []
    searchIndex = -1
    lastSearchQuery = query

    const lowerQuery = query.toLowerCase()
    const textNodes = collectTextNodes(container)

    for (const node of textNodes) {
      const text = node.textContent?.toLowerCase() ?? ''
      let start = 0
      while ((start = text.indexOf(lowerQuery, start)) !== -1) {
        const range = new Range()
        range.setStart(node, start)
        range.setEnd(node, start + query.length)
        searchRanges.push(range)
        start += query.length
      }
    }

    if (searchRanges.length > 0) {
      CSS.highlights.set('search-results', new Highlight(...searchRanges))
      searchIndex = 0
      highlightSearchCurrent()
    }
  } else if (direction === 'next' && searchRanges.length > 0) {
    searchIndex = (searchIndex + 1) % searchRanges.length
    highlightSearchCurrent()
  } else if (direction === 'prev' && searchRanges.length > 0) {
    searchIndex = (searchIndex - 1 + searchRanges.length) % searchRanges.length
    highlightSearchCurrent()
  }

  return {
    total: searchRanges.length,
    current: searchRanges.length > 0 ? searchIndex + 1 : 0,
  }
}

function highlightSearchCurrent(): void {
  if (searchIndex < 0 || searchIndex >= searchRanges.length) return
  const range = searchRanges[searchIndex]!
  CSS.highlights.set('search-current', new Highlight(range))

  const rect = range.getBoundingClientRect()
  const margin = 80
  if (rect.top < margin || rect.bottom > window.innerHeight - margin) {
    const el = range.startContainer.parentElement
    el?.scrollIntoView({ block: 'center', behavior: 'smooth' })
  }
}
