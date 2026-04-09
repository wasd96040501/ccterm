/**
 * Development server: serves the built bundle + HTML with fixture data.
 * Usage: bun run dev-server.ts
 */
import { readFileSync, existsSync } from 'fs'
import { fixtureMessages } from './dev-fixture.ts'

// Use generated fixtures if available, otherwise fall back to hand-written ones
const generatedPath = import.meta.dirname + '/scripts/fixtures.json'
const messages = existsSync(generatedPath)
  ? JSON.parse(readFileSync(generatedPath, 'utf-8'))
  : fixtureMessages
const messagesJson = JSON.stringify(messages)

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>CCTerm Chat - Dev</title>
  <style>
    html, body { margin: 0; padding: 0; height: 100%; }
  </style>
  <link rel="stylesheet" href="/index.css" />
</head>
<body>
  <div id="root"></div>
  <script src="/index.js"></script>
  <script>
    fetch('/api/fixtures').then(function(r) { return r.json(); }).then(function(msgs) {
      window.__bridge('setMessages', JSON.stringify({ conversationId: 'conv-1', messages: msgs }));
      window.__bridge('switchConversation', JSON.stringify({ conversationId: 'conv-1' }));
    });
  </script>
</body>
</html>`

const server = Bun.serve({
  hostname: '127.0.0.1',
  port: 3459,
  async fetch(req) {
    const url = new URL(req.url)
    const path = url.pathname

    if (path === '/' || path === '/index.html') {
      return new Response(HTML, { headers: { 'Content-Type': 'text/html' } })
    }

    if (path === '/api/fixtures') {
      return new Response(messagesJson, { headers: { 'Content-Type': 'application/json' } })
    }

    const filePath = './dist' + path
    const file = Bun.file(filePath)
    if (await file.exists()) {
      return new Response(file)
    }

    return new Response('Not found', { status: 404 })
  },
})

console.log(`Dev server running at http://localhost:${server.port}`)
