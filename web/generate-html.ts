/**
 * Generate HTML loader files for each web entry point.
 * Output goes to dist/ alongside the JS/CSS bundles.
 */

const entries = [
  { name: "chat-react", js: "index.js", css: "index.css", style: "height: 100%; overflow: hidden;" },
  { name: "plan-fullscreen-react", js: "plan-fullscreen.js", css: "plan-fullscreen.css" },
  { name: "diff-react", js: "diff.js", css: "diff.css" },
  { name: "bash-react", js: "bash.js", css: "bash.css" },
];

for (const entry of entries) {
  const extraStyle = entry.style ? ` ${entry.style}` : "";
  const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link rel="stylesheet" href="${entry.css}">
<style>html, body { margin: 0; padding: 0;${extraStyle} background: transparent; }</style>
</head>
<body>
<div id="root"></div>
<script src="${entry.js}"></script>
</body>
</html>
`;
  await Bun.write(`dist/${entry.name}.html`, html);
}

console.log(`Generated ${entries.length} HTML files`);
