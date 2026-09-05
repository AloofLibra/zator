import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const webuiDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../webui')

const digest = (name) =>
  createHash('sha256').update(readFileSync(path.join(webuiDir, name))).digest('hex').slice(0, 8)

let html = readFileSync(path.join(webuiDir, 'index.html'), 'utf8')

// classic-скрипт обязан идти в конец body: app.js монтируется синхронно в #app
html = html.replace(/<script[^>]*src="[^"]*app\.js[^"]*"[^>]*><\/script>\s*/g, '')
html = html.replace(/<link[^>]*rel="stylesheet"[^>]*>\s*/g, '')
html = html.replace('</head>', `  <link rel="stylesheet" href="styles.css?v=${digest('styles.css')}">\n</head>`)
html = html.replace('</body>', `  <script src="app.js?v=${digest('app.js')}"></script>\n</body>`)
html = html.replace(/(<link[^>]*href=")favicon\.svg([^"]*")/,
  `$1favicon.svg?v=${digest('favicon.svg')}$2`)

writeFileSync(path.join(webuiDir, 'index.html'), html)
console.log(`app.js?v=${digest('app.js')}`)
console.log(`styles.css?v=${digest('styles.css')}`)
