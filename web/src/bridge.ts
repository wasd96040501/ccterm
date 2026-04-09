import type { NativeEvent, WebEvent } from './types/bridge.ts'

type EventHandler = (event: NativeEvent) => void
let handler: EventHandler | null = null

function bridgeDispatch(type: string, json: string): void {
  try {
    const payload = JSON.parse(json)
    handler?.({ type, payload } as NativeEvent)
  } catch (e) {
    console.error('[bridge] Failed to decode:', e)
  }
}

export function onNativeEvent(fn: EventHandler): void {
  handler = fn
}

export function postToNative(event: WebEvent): void {
  window.webkit?.messageHandlers?.bridge?.postMessage(event)
}

declare global {
  interface Window {
    __bridge: (type: string, json: string) => void
    webkit?: {
      messageHandlers?: {
        bridge?: { postMessage: (body: unknown) => void }
      }
    }
  }
}

window.__bridge = bridgeDispatch
