// Сборка архивов развёртывания zator: zator-{core,webui,full}.tar.gz.
//
// Пути внутри архива относительно $ZATOR_ROOT (/opt/zator) и зеркалят карту
// развёртывания z2r.sh (get_repo + webui_install_files) — держать синхронно
// с ним. Спецзаписи вне корня: _root/z2r.sh -> /opt/z2r.sh и
// _payload/<rel> -> /opt/zator/.deploy-payload/<rel> (офлайн-источник для
// z2r_download_project_file, в /opt/zapret2 автоматически не ставится).
//
// Классы файлов (основа защит при развёртывании):
//   auto           — всегда заменять;
//   keep-if-exists — класть только если на устройстве отсутствует
//                    (пользовательские списки и custom_tls.bin);
//   payload        — только в .deploy-payload;
//   meta           — extra_strats/cache/deploy/{version.env,manifest.*},
//                    в сверке не участвуют, deploy перезаписывает сам.
//
// Архив не содержит runtime-состояние: остальной extra_strats/cache и
// lists/autohostlist.txt. Текстовые файлы нормализуются в LF, бинарники
// (NUL в первых 8КБ) не трогаются. Права 0755/0644, заголовки tar с
// uid/gid/mtime 0 — при фиксированном --version сборка детерминирована.
//
// Запуск (в webui-src): npm run pack [-- --variant=core|webui|full|all]
//   [-- --version=<tag>] [-- --out <dir>] [-- --repo owner/name]
// Результат в webui-src/dist/: на каждый вариант .tar.gz, .sha256
// (формат sha256sum -c), .manifest.json, .manifest.tsv (шелл-читаемый,
// путь|dest|class|sha256|size|exec); при --variant=all ещё latest.json —
// лёгкий указатель сборки с размерами для проверки свободного места.

import { gzipSync } from 'node:zlib'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync } from 'node:child_process'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')

const args = new Map()
{
  const argv = process.argv.slice(2)
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (!arg.startsWith('--')) continue
    const eq = arg.indexOf('=')
    if (eq > 0) {
      args.set(arg.slice(2, eq), arg.slice(eq + 1))
    } else {
      const key = arg.slice(2)
      const next = argv[i + 1]
      if (next !== undefined && !next.startsWith('--')) {
        args.set(key, next)
        i++
      } else {
        args.set(key, '')
      }
    }
  }
}

const pad2 = (n) => String(n).padStart(2, '0')
const now = new Date()
const stamp = `${now.getUTCFullYear()}${pad2(now.getUTCMonth() + 1)}${pad2(now.getUTCDate())}-${pad2(now.getUTCHours())}${pad2(now.getUTCMinutes())}`

function stampToDateShort(value) {
  const m = value.match(/^(?:deploy|stable)-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})$/)
  if (!m) return null
  return `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}`
}

const version = args.get('version') || `stable-${stamp}`
// при фиксированном --version=stable-... даты берутся из номера — сборка детерминирована
const dateShort = stampToDateShort(version)
  || `${now.getUTCFullYear()}-${pad2(now.getUTCMonth() + 1)}-${pad2(now.getUTCDate())} ${pad2(now.getUTCHours())}:${pad2(now.getUTCMinutes())}`
const variantArg = args.get('variant') || 'all'
const outDir = resolve(repoRoot, args.get('out') || join('webui-src', 'dist'))

let commit = 'unknown'
try {
  commit = execSync('git rev-parse --short HEAD', { cwd: repoRoot }).toString().trim()
} catch { /* сборка вне git-репозитория */ }

function detectRepo() {
  const fromArg = args.get('repo')
  if (fromArg) return fromRepoValue(fromArg)
  const envRepo = process.env.GITHUB_REPOSITORY
  if (envRepo) return fromRepoValue(envRepo)
  try {
    const url = execSync('git remote get-url origin', { cwd: repoRoot }).toString().trim()
    const m = url.match(/[:/]([^/:]+\/[^/]+?)(?:\.git)?$/)
    return m ? m[1] : null
  } catch { return null }
}
function fromRepoValue(value) {
  return value.includes('/') ? value.replace(/\.git$/, '') : null
}
const repoSlug = detectRepo()

const ALL_VARIANTS = ['core', 'webui', 'full']
if (variantArg !== 'all' && !ALL_VARIANTS.includes(variantArg)) {
  console.error(`неизвестный --variant=${variantArg} (core|webui|full|all)`)
  process.exit(1)
}
const buildVariants = variantArg === 'all' ? ALL_VARIANTS : [variantArg]

// Философия упаковки (по требованию автора): авто-обход всего + список
// исключений. Забыли убрать из исключений — уедет лишний безвредный файл;
// жёсткая карта при забытой правке молча теряла файлы релиза.
const AUTO_EXCLUDE = new Set([
  'lists/autohostlist.txt', // runtime-файл устройства, в релиз не пакуется
  'extra_strats/TCP/GV', // апстрим #7: numbered GV-стратегии не подключены ни конфигом, ни z2r.sh
])

function walkRepo(rel, { recursive = true } = {}) {
  const out = []
  if (!existsSync(join(repoRoot, rel))) return out
  for (const name of readdirSync(join(repoRoot, rel)).sort()) {
    const relPath = `${rel}/${name}`
    if (AUTO_EXCLUDE.has(relPath)) continue
    if (recursive && statSync(join(repoRoot, relPath)).isDirectory()) {
      if (relPath === 'extra_strats/cache') continue // runtime
      out.push(...walkRepo(relPath, { recursive }))
      continue
    }
    out.push(relPath)
  }
  return out
}

// repo lib/ -> $ZATOR_ROOT/z2r_lib: весь каталог.
const LIB_FILES = walkRepo('lib', { recursive: false })
if (LIB_FILES.length === 0) {
  console.error('lib/: каталог пуст?')
  process.exit(1)
}

// repo lists/ -> $ZATOR_ROOT/lists: весь каталог.
const LISTS = walkRepo('lists', { recursive: false })
if (LISTS.length === 0) {
  console.error('lists/: каталог пуст?')
  process.exit(1)
}

// repo extra_strats/ (вложенные) -> плоские имена get_repo по механическому
// правилу «каталоги через _ + имя файла со строчной первой буквы»;
// исключения — в OVERRIDES (забыли — уедет лишний файл с чуть другим именем).
// Имена-исключения зашиты в config.default и KEEP_IF_EXISTS — держать
// точь-в-точь; незнакомые файлы едут по механическому правилу.
const EXTRA_STRAT_OVERRIDES = new Map([
  ['extra_strats/TCP/RKN/Custom.txt', 'extra_strats/TCP_Custom.txt'],
  ['extra_strats/TCP/RKN/Discord.txt', 'extra_strats/TCP_Discord.txt'],
  ['extra_strats/TCP/RKN/Domains_By_Substring.txt', 'extra_strats/TCP_RKN_domains_by_substring.txt'],
])
function extraStratFlat(repoPath) {
  if (EXTRA_STRAT_OVERRIDES.has(repoPath)) return EXTRA_STRAT_OVERRIDES.get(repoPath)
  const parts = repoPath.split('/')
  parts.shift() // ведущий extra_strats в плоское имя не входит
  const file = parts.pop()
  return `extra_strats/${[...parts, file[0].toLowerCase() + file.slice(1)].join('_')}`
}
const EXTRA_STRATS = walkRepo('extra_strats').map((p) => [p, extraStratFlat(p)])

const KEEP_IF_EXISTS = new Set([
  'lists/netrogat.txt',
  'lists/netrogat_substrings.txt',
  'extra_strats/TCP_Custom.txt',
  'extra_strats/TCP_RKN_domains_by_substring.txt',
  'files/fake/custom_tls.bin',
])

const DEPLOY_CACHE = 'extra_strats/cache/deploy'

function defaultDest(archivePath) {
  if (archivePath === '_root/z2r.sh') return '/opt/z2r.sh'
  if (archivePath.startsWith('_payload/')) {
    return `/opt/zator/.deploy-payload/${archivePath.slice('_payload/'.length)}`
  }
  return `/opt/zator/${archivePath}`
}

const specs = []
function add(archivePath, repoPath, { executable = false, cls = 'auto', comp = 'core', dest } = {}) {
  if (KEEP_IF_EXISTS.has(archivePath)) cls = 'keep-if-exists'
  specs.push({ archivePath, repoPath, executable, cls, comp, dest: dest || defaultDest(archivePath) })
}

const webuiCgi = readdirSync(join(repoRoot, 'webui', 'cgi-bin')).sort()
const blockcheckZ4r = readdirSync(join(repoRoot, 'blockcheck2.d', 'z4r')).sort()

for (const repoPath of LIB_FILES) add(`z2r_lib/${basename(repoPath)}`, repoPath)
for (const name of readdirSync(join(repoRoot, 'lua')).sort()) {
  add(`lua/${name}`, `lua/${name}`, { executable: name === 'strategy-validator.sh' })
}
for (const repoPath of LISTS) add(`lists/${basename(repoPath)}`, repoPath)
for (const [from, to] of EXTRA_STRATS) add(to, from)
add('extra_strats/cache/orchestra/locked.lua', 'orchestra/locked.lua')
for (const repoPath of walkRepo('firewall', { recursive: false })) {
  add(repoPath, repoPath, { executable: true })
}
add('adaptive/90-zator-adaptive-learning', 'adaptive/90-zator-adaptive-learning', { executable: true })
add('adaptive/probe-once.sh', 'adaptive/probe-once.sh', { executable: true })
for (const repoPath of walkRepo('data', { recursive: true })) {
  add(repoPath, repoPath)
}
for (const name of readdirSync(join(repoRoot, 'fake')).sort()) {
  add(`files/fake/${name}`, `fake/${name}`)
}

add('_root/z2r.sh', 'z2r.sh', { executable: true })
add('_payload/config.default', 'config.default', { cls: 'payload' })
add('_payload/fake_files.tar.gz', 'fake_files.tar.gz', { cls: 'payload' })
add('_payload/Entware/keenetic-policy.sh', 'Entware/keenetic-policy.sh', { cls: 'payload', executable: true })
add('_payload/Entware/z2r-strategy-validator', 'Entware/z2r-strategy-validator', { cls: 'payload', executable: true })
add('_payload/init.d/openwrt/z2r-strategy-validator', 'init.d/openwrt/z2r-strategy-validator', { cls: 'payload', executable: true })
add('_payload/Entware/z2r-adaptive-controller', 'Entware/z2r-adaptive-controller', { cls: 'payload', executable: true })
add('_payload/init.d/openwrt/z2r-adaptive-controller', 'init.d/openwrt/z2r-adaptive-controller', { cls: 'payload', executable: true })
add('_payload/Entware/zapret', 'Entware/zapret', { cls: 'payload', executable: true })
for (const name of blockcheckZ4r) {
  add(`_payload/blockcheck2.d/z4r/${name}`, `blockcheck2.d/z4r/${name}`, {
    cls: 'payload', executable: name.endsWith('.sh'),
  })
}

add('webui/run-webui.sh', 'webui/run-webui.sh', { executable: true, comp: 'webui' })
for (const name of webuiCgi) {
  add(`webui/cgi-bin/${name}`, `webui/cgi-bin/${name}`, { executable: true, comp: 'webui' })
}
for (const [wwwName, repoName] of [
  ['index.html', 'index.html'], ['styles.css', 'styles.css'],
  ['app.js', 'app.js'], ['favicon.svg', 'favicon.svg'],
]) {
  add(`webui/www/${wwwName}`, `webui/${repoName}`, { comp: 'webui' })
}

// raw-путь установки (webui_install_files в z2r.sh) качает cgi пофайлово:
// каталог и его список обязаны совпадать, иначе новый *.cgi есть в релизе,
// но не доезжает до raw-установок. z2r.sh — единственный источник списка.
function parseZ2rWebuiFetchList() {
  const src = readFileSync(join(repoRoot, 'z2r.sh'), 'utf8')
  const body = src.match(/webui_install_files\(\) \{([\s\S]*?)\n\}/)
  if (!body) {
    console.error('z2r.sh: не найдена webui_install_files')
    process.exit(1)
  }
  return [...body[1].matchAll(/webui_repo_fetch "([^"]+)"/g)].map((m) => m[1])
}
{
  const rawList = parseZ2rWebuiFetchList()
  const cgiSet = new Set(webuiCgi.map((name) => `cgi-bin/${name}`))
  const rootSet = new Set(['index.html', 'styles.css', 'app.js', 'favicon.svg', 'run-webui.sh'])
  const rawCgi = []
  for (const rel of rawList) {
    if (rel.startsWith('cgi-bin/')) {
      rawCgi.push(rel)
      if (!cgiSet.has(rel)) {
        console.error(`z2r.sh webui_install_files качает webui/${rel}, которого нет в webui/cgi-bin`)
        process.exit(1)
      }
    } else if (!rootSet.has(rel)) {
      console.error(`z2r.sh webui_install_files качает неизвестный webui/${rel}`)
      process.exit(1)
    }
  }
  for (const rel of cgiSet) {
    if (!rawCgi.includes(rel)) {
      console.error(`webui/${rel} есть в репозитории, но отсутствует в webui_install_files (z2r.sh) — raw-установки его не получат`)
      process.exit(1)
    }
  }
}

function isBinary(buf) {
  return buf.subarray(0, 8192).includes(0)
}

function readDeployContent(repoPath) {
  const raw = readFileSync(join(repoRoot, repoPath))
  if (isBinary(raw)) return raw
  return Buffer.from(raw.toString('utf8').replace(/\r\n/g, '\n'), 'utf8')
}

const sha256 = (data) => createHash('sha256').update(data).digest('hex')

for (const spec of specs) {
  try {
    const body = readDeployContent(spec.repoPath)
    spec.body = body
    spec.sha256 = sha256(body)
    spec.size = body.length
  } catch {
    console.error(`отсутствует исходник: ${spec.repoPath}`)
    process.exit(1)
  }
}

const contentSha = (component) => sha256(
  specs.filter((s) => s.comp === component).map((s) => s.sha256).join(''),
)
const zatorSha = contentSha('core')
const webuiSha = contentSha('webui')

function versionEnv() {
  return [
    `ZATOR_VERSION="${version}"`,
    `ZATOR_DATE="${dateShort}"`,
    `ZATOR_COMMIT="${commit}"`,
    `ZATOR_SHA="${zatorSha}"`,
    `WEBUI_VERSION="${version}"`,
    `WEBUI_DATE="${dateShort}"`,
    `WEBUI_SHA="${webuiSha}"`,
    'TRACKING="latest"',
    '',
  ].join('\n')
}

// --- минимальный ustar-писатель (без внешних зависимостей) ---

function octal(value, length) {
  return `${value.toString(8).padStart(length - 1, '0')}\0`
}

function splitName(name) {
  if (name.length <= 100) return { name, prefix: '' }
  const slash = name.lastIndexOf('/', name.length - 101)
  if (slash < 0) throw new Error(`слишком длинный путь: ${name}`)
  return { name: name.slice(slash + 1), prefix: name.slice(0, slash) }
}

function tarHeader(entry) {
  const head = Buffer.alloc(512)
  const { name, prefix } = splitName(entry.name)
  head.write(name, 0)
  head.write(octal(entry.mode ?? 0o644, 8), 100)
  head.write(octal(0, 8), 108)
  head.write(octal(0, 8), 116)
  head.write(octal(entry.size ?? 0, 12), 124)
  head.write(octal(0, 12), 136)
  head.write('        ', 148)
  head.write(entry.type, 156)
  if (entry.linkname) head.write(entry.linkname, 157)
  head.write('ustar\0', 257)
  head.write('00', 263)
  head.write('root', 265)
  head.write('root', 297)
  if (prefix) head.write(prefix, 345)
  let sum = 0
  for (const byte of head) sum += byte
  head.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148)
  return head
}

function tarEntry(entry) {
  const blocks = [tarHeader(entry)]
  if (entry.body) {
    blocks.push(entry.body)
    const tail = (512 - (entry.body.length % 512)) % 512
    if (tail) blocks.push(Buffer.alloc(tail))
  }
  return Buffer.concat(blocks)
}

// --- сборка варианта ---

function buildVariant(variant) {
  const picked = specs.filter((s) => variant === 'full' || s.comp === variant)
  const manifestRows = picked.map((s) => [s.archivePath, s.dest, s.cls, s.sha256, s.size, s.executable ? 1 : 0].join('|'))
  const manifestTsvBuf = Buffer.from(`# path|dest|class|sha256|size|exec\n${manifestRows.join('\n')}\n`, 'utf8')
  const versionEnvBuf = Buffer.from(versionEnv(), 'utf8')

  const manifest = {
    generatedBy: 'pack-zator-tar.mjs',
    version,
    buildDate: `${dateShort} UTC`,
    commit,
    variant,
    zatorSha,
    webuiSha,
    entries: picked.map((s) => ({ path: s.archivePath, dest: s.dest, class: s.cls, sha256: s.sha256, size: s.size })),
    totals: { unpackedBytes: 0, files: picked.length },
  }
  // unpackedBytes без учёта manifest.json: его размер зависит от totals
  manifest.totals.unpackedBytes = picked.reduce((sum, s) => sum + s.size, 0)
    + versionEnvBuf.length + manifestTsvBuf.length
  const manifestJsonBuf = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8')

  const metaEntries = [
    { archivePath: `${DEPLOY_CACHE}/version.env`, body: versionEnvBuf },
    { archivePath: `${DEPLOY_CACHE}/manifest.tsv`, body: manifestTsvBuf },
    { archivePath: `${DEPLOY_CACHE}/manifest.json`, body: manifestJsonBuf },
  ]
  for (const meta of metaEntries) {
    meta.sha256 = sha256(meta.body)
    meta.size = meta.body.length
  }

  const allPaths = [...picked.map((s) => s.archivePath), ...metaEntries.map((m) => m.archivePath)]
  const dirs = new Set()
  for (const p of allPaths) {
    let dir = dirname(p)
    while (dir && dir !== '.') {
      dirs.add(dir)
      dir = dirname(dir)
    }
  }

  const entries = []
  for (const dir of [...dirs].sort()) {
    entries.push(tarEntry({ name: `${dir}/`, type: '5', mode: 0o755 }))
  }
  for (const s of picked) {
    entries.push(tarEntry({ name: s.archivePath, type: '0', mode: s.executable ? 0o755 : 0o644, size: s.size, body: s.body }))
  }
  for (const m of metaEntries) {
    entries.push(tarEntry({ name: m.archivePath, type: '0', mode: 0o644, size: m.size, body: m.body }))
  }
  if (variant !== 'core') {
    entries.push(tarEntry({ name: 'webui/www/cgi-bin', type: '2', mode: 0o777, linkname: '../cgi-bin' }))
  }

  let tar = Buffer.concat(entries)
  tar = Buffer.concat([tar, Buffer.alloc(10240 - ((tar.length + 1024) % 10240) + 1024)])
  const gz = gzipSync(tar, { mtime: 0 })
  const gzSha = sha256(gz)

  const name = `zator-${variant}`
  mkdirSync(outDir, { recursive: true })
  writeFileSync(join(outDir, `${name}.tar.gz`), gz)
  writeFileSync(join(outDir, `${name}.sha256`), `${gzSha}  ${name}.tar.gz\n`)
  writeFileSync(join(outDir, `${name}.manifest.json`), `${JSON.stringify(manifest, null, 2)}\n`)
  writeFileSync(join(outDir, `${name}.manifest.tsv`), manifestTsvBuf)

  return { variant, name: `${name}.tar.gz`, size: gz.length, sha256: gzSha, unpackedSize: manifest.totals.unpackedBytes, files: picked.length, dirs: dirs.size }
}

const results = buildVariants.map(buildVariant)

if (variantArg === 'all') {
  const assets = {}
  for (const r of results) {
    assets[r.variant] = {
      name: r.name, size: r.size, sha256: r.sha256, unpackedSize: r.unpackedSize,
      ...(repoSlug ? { url: `https://github.com/${repoSlug}/releases/download/latest/${r.name}` } : {}),
    }
  }
  const latest = {
    schemaVersion: 1,
    release: version,
    buildDate: `${dateShort} UTC`,
    commit,
    zatorSha,
    webuiSha,
    zatorDate: dateShort,
    webuiDate: dateShort,
    assets,
  }
  writeFileSync(join(outDir, 'latest.json'), `${JSON.stringify(latest, null, 2)}\n`)
}

console.log(`version: ${version}  commit: ${commit}  repo: ${repoSlug || '-'}`)
for (const r of results) {
  console.log(`${r.variant}: files ${r.files}, dirs ${r.dirs}, gz ${(r.size / 1024).toFixed(0)} KB, unpacked ${(r.unpackedSize / 1024).toFixed(0)} KB, sha256 ${r.sha256.slice(0, 12)}...`)
}
console.log(`out: ${outDir}`)
