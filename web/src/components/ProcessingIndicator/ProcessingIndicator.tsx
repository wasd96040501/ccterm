import React, { useState, useEffect } from 'react'
import { motion } from 'framer-motion'

interface ProcessingIndicatorProps {
  active: boolean
  interrupted: boolean
}

const DISAPPEAR_DELAY = 800
const LAYOUT_TRANSITION = { duration: 0.3, ease: [0, 0, 0.58, 1] as const }

export const ProcessingIndicator = React.memo(function ProcessingIndicator({ active, interrupted }: ProcessingIndicatorProps) {
  const [visible, setVisible] = useState(active)

  useEffect(() => {
    if (active) {
      setVisible(true)
      return
    }
    if (interrupted) {
      setVisible(false)
      return
    }
    const timer = setTimeout(() => setVisible(false), DISAPPEAR_DELAY)
    return () => clearTimeout(timer)
  }, [active, interrupted])

  return (
    <motion.div
      layout
      transition={{ layout: LAYOUT_TRANSITION }}
      className={`processing-indicator${visible ? ' active' : ''}`}
    >
      <div className="processing-dot">
        <div className="blob-container">
          <div className="blob b1" />
          <div className="blob b2" />
          <div className="blob b3" />
          <div className="blob b4" />
        </div>
      </div>
    </motion.div>
  )
})
