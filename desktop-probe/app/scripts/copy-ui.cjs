const { copyFileSync } = require('node:fs')
for (const name of ['index.html', 'style.css']) copyFileSync(`src/${name}`, `dist/${name}`)
