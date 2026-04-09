# Protocol

Language-agnostic type definitions for the cross-platform bridge between native code and the web UI.

## Structure

- `bridge.schema.json` — JSON Schema for Native↔Web bridge events
- `message.schema.json` — JSON Schema for Claude Code CLI message types (Message2)

## How it works

The native app (macOS/Windows/Linux) hosts a WebView that renders the chat UI (see `web/`).
Communication between the native layer and the web layer uses a typed bridge protocol:

- **Native → Web**: `callAsyncJavaScript` calls `window.__bridge(type, json)`
- **Web → Native**: `window.webkit.messageHandlers.bridge.postMessage(event)` (macOS) or platform equivalent

Both directions use JSON payloads defined in `bridge.schema.json`.

## For new platform implementations

1. Read `bridge.schema.json` to understand the event types
2. Generate types for your language from the schema
3. Implement the bridge transport layer for your platform's WebView
4. The web UI (`web/`) is shared across all platforms — no changes needed
