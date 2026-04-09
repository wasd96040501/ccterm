import { useLayoutEffect, useRef, useState, useCallback } from 'react'

export function useElementHeight() {
  const elementRef = useRef<HTMLDivElement>(null)
  const prevElementRef = useRef<HTMLDivElement | null>(null)
  const observerRef = useRef<ResizeObserver | null>(null)
  const [heightPx, setHeightPx] = useState(0)

  const measure = useCallback(() => {
    const el = elementRef.current
    if (el == null) return
    const h = el.scrollHeight
    if (h === 0) return
    setHeightPx((prev) => (prev === h ? prev : h))
  }, [])

  useLayoutEffect(() => {
    measure()

    const el = elementRef.current
    if (prevElementRef.current !== el) {
      if (prevElementRef.current && observerRef.current) {
        observerRef.current.unobserve(prevElementRef.current)
      }
      if (el) {
        if (!observerRef.current) {
          observerRef.current = new ResizeObserver(measure)
        }
        observerRef.current.observe(el)
      }
      prevElementRef.current = el
    }
  })

  useLayoutEffect(() => {
    return () => {
      if (prevElementRef.current && observerRef.current) {
        observerRef.current.unobserve(prevElementRef.current)
      }
      observerRef.current?.disconnect()
      prevElementRef.current = null
      observerRef.current = null
    }
  }, [])

  return { elementHeightPx: heightPx, elementRef }
}
