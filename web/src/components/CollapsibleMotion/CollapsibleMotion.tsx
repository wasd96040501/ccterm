import React from 'react'
import { motion, AnimatePresence } from 'framer-motion'
import { useElementHeight } from '../../hooks/useElementHeight.ts'

const EXPAND_TRANSITION = { duration: 0.5, ease: [0.19, 1, 0.22, 1] as const }
const COLLAPSE_TRANSITION = { duration: 0.5, ease: [0.19, 1, 0.22, 1] as const }

interface CollapsibleMotionProps {
  open: boolean
  keepMounted?: boolean
  maxHeight?: number
  className?: string
  children: React.ReactNode
}

export function CollapsibleMotion({
  open,
  keepMounted = true,
  maxHeight,
  className,
  children,
}: CollapsibleMotionProps) {
  if (keepMounted) {
    return (
      <CollapsibleMotionMounted open={open} maxHeight={maxHeight} className={className}>
        {children}
      </CollapsibleMotionMounted>
    )
  }

  return (
    <AnimatePresence initial={false}>
      {open && (
        <motion.div
          initial={{ opacity: 0, height: 0 }}
          animate={{
            opacity: 1,
            height: 'auto',
            transition: EXPAND_TRANSITION,
          }}
          exit={{
            opacity: 0,
            height: 0,
            transition: COLLAPSE_TRANSITION,
          }}
          style={{ overflow: 'hidden' }}
          className={className}
        >
          {children}
        </motion.div>
      )}
    </AnimatePresence>
  )
}

function CollapsibleMotionMounted({
  open,
  maxHeight,
  className,
  children,
}: Omit<CollapsibleMotionProps, 'keepMounted'>) {
  const { elementHeightPx, elementRef } = useElementHeight()

  let targetHeight = 0
  if (open) {
    targetHeight = maxHeight != null ? Math.min(elementHeightPx, maxHeight) : elementHeightPx
  }

  return (
    <motion.div
      initial={false}
      animate={{
        height: targetHeight,
        opacity: open ? 1 : 0,
      }}
      transition={open ? EXPAND_TRANSITION : COLLAPSE_TRANSITION}
      className={open ? 'collapsible-open' : 'collapsible-closed'}
      style={{ pointerEvents: open ? 'auto' : 'none' }}
    >
      <div ref={elementRef} className={className}>
        {children}
      </div>
    </motion.div>
  )
}
