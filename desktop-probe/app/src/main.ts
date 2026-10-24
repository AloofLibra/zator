import { app, BrowserWindow, WebContentsView, session, ipcMain, protocol, net as electronNet, dialog } from 'electron'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { Router } from './ssh'
import { classify, Observation, redactURL, RouterStatus, safeURL, SSHOptions, strategySequence } from './core'

protocol.registerSchemesAsPrivileged([{ scheme: 'zator-ui', privileges: { standard: true, secure: true, supportFetchAPI: true } }])
app.commandLine.appendSwitch('disable-quic')
app.commandLine.appendSwitch('force-webrtc-ip-handling-policy', 'disable_non_proxied_udp')
app.commandLine.appendSwitch('host-resolver-rules', 'MAP * ~NOTFOUND, EXCLUDE 127.0.0.1')
let win: BrowserWindow
let preview: WebContentsView | undefined
let previewSession: Electron.Session | undefined
let controller: AbortController | undefined
let activeRouter: Router | undefined
let results: any[] = []
let quitting = false
let running: Promise<void> | undefined
let manualWait: { index: number; finish: () => void } | undefined
function update(data: unknown) { if (win && !win.isDestroyed()) win.webContents.send('probe-update', data) }
let saving = Promise.resolve()
function saveResults(): Promise<void> {
  saving = saving.catch(() => {}).then(async () => {
    const path = join(app.getPath('userData'), 'last-report.json')
    await mkdir(app.getPath('userData'), { recursive: true })
    await writeFile(`${path}.tmp`, JSON.stringify(results, null, 2)); await rename(`${path}.tmp`, path)
  })
  return saving
}
function fit() { if (!preview) return; const [w, h] = win.getContentSize(); preview.setBounds({ x: 410, y: 0, width: Math.max(100, w - 410), height: h }) }
async function closePreview() {
  const old = preview, ses = previewSession; preview = undefined; previewSession = undefined
  if (!old) return
  if (win && !win.isDestroyed()) win.contentView.removeChildView(old)
  if (!old.webContents.isDestroyed()) { old.webContents.stop(); if (old.webContents.debugger.isAttached()) old.webContents.debugger.detach(); old.webContents.close() }
  if (ses) { await ses.closeAllConnections(); await ses.clearStorageData() }
}
function delay(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => { const done = () => { signal.removeEventListener('abort', abort); resolve() }; const timer = setTimeout(done, ms); const abort = () => { clearTimeout(timer); reject(new Error('CANCELLED')) }; signal.addEventListener('abort', abort, { once: true }); if (signal.aborted) abort() })
}
interface RunOptions { ssh: SSHOptions; url: string; profile: number; strategies: number[]; scenario: 'generic_page' | 'youtube_video' | 'discord'; selector: string; timeout: number; manual?: boolean }
function waitForManual(index: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const finish = () => { clearTimeout(timer); signal.removeEventListener('abort', abort); manualWait = undefined; resolve() }
    const abort = () => { clearTimeout(timer); manualWait = undefined; reject(new Error('CANCELLED')) }
    const timer = setTimeout(finish, 300000)
    manualWait = { index, finish }; signal.addEventListener('abort', abort, { once: true }); if (signal.aborted) abort()
  })
}

async function observe(options: RunOptions, proxyPort: number, signal: AbortSignal) {
  await closePreview()
  const attempt = randomUUID()
  const ses = session.fromPartition(`probe-${attempt}`, { cache: false })
  previewSession = ses
  await ses.setProxy({ mode: 'fixed_servers', proxyRules: `socks5://127.0.0.1:${proxyPort}`, proxyBypassRules: '<-loopback>' })
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false))
  ses.setPermissionCheckHandler(() => false)
  ses.on('will-download', event => event.preventDefault())
  ses.webRequest.onBeforeRequest((details, callback) => {
    try { const u = new URL(details.url); callback({ cancel: !['https:', 'wss:', 'data:', 'blob:', 'about:'].includes(u.protocol) }) } catch { callback({ cancel: true }) }
  })
  preview = new WebContentsView({ webPreferences: { session: ses, nodeIntegration: false, contextIsolation: true, sandbox: true, webSecurity: true, allowRunningInsecureContent: false } })
  const view = preview, wc = view.webContents
  wc.setWebRTCIPHandlingPolicy('disable_non_proxied_udp')
  wc.setWindowOpenHandler(() => ({ action: 'deny' }))
  wc.on('will-navigate', (event, url) => { try { safeURL(url) } catch { event.preventDefault() } })
  win.contentView.addChildView(view); fit()
  await wc.loadURL('about:blank')
  const observation: Observation = { http_status: null, dom_loaded: false, fresh_connection: null, functional: null, auth_required: false, errors: [], requested_host: new URL(options.url).hostname }
  const requests = new Map<string, any>()
  const gatewayRequests = new Set<string>()
  let mediaBytes = 0, socketFrames = 0, mainFrame = '', lastNetworkUpdate = 0
  wc.debugger.attach('1.3')
  await wc.debugger.sendCommand('Network.enable')
  await wc.debugger.sendCommand('Page.enable')
  mainFrame = (await wc.debugger.sendCommand('Page.getFrameTree')).frameTree.frame.id
  wc.debugger.on('message', (_event, method, p) => {
    if (method === 'Page.frameNavigated' && !p.frame.parentId) mainFrame = p.frame.id
    if (method === 'Network.requestWillBeSent' && requests.size < 1500) requests.set(p.requestId, { url: redactURL(p.request.url), type: p.type, status: null, protocol: null, bytes: 0, error: null, started: p.timestamp, duration_ms: null })
    if (requests.size >= 1500) observation.evidence_complete = false
    if (method === 'Network.responseReceived') {
      const row = requests.get(p.requestId)
      if (row) { row.status = p.response.status; row.protocol = p.response.protocol; row.tls = p.response.securityDetails?.protocol || null }
      if (p.type === 'Document' && p.frameId === mainFrame) { observation.http_status = p.response.status; observation.fresh_connection = p.response.connectionReused === false }
    }
    if (method === 'Network.loadingFinished') {
      const row = requests.get(p.requestId)
      if (row) { row.bytes = p.encodedDataLength; row.duration_ms = Math.round((p.timestamp - row.started) * 1000) }
    }
    if (method === 'Network.dataReceived') { const row = requests.get(p.requestId); if (row) { row.bytes += p.encodedDataLength; if (/^https:\/\/([a-z0-9-]+\.)?googlevideo\.com\//.test(row.url)) mediaBytes += p.encodedDataLength } }
    if (method === 'Network.loadingFailed') {
      const row = requests.get(p.requestId)
      const error = /^net::ERR_[A-Z_]+$/.test(p.errorText) ? p.errorText : 'NETWORK_ERROR'
      if (row) row.error = error
      if (observation.errors.length < 100) observation.errors.push(error)
    }
    if (method === 'Network.webSocketCreated') { try { if (new URL(p.url).hostname === 'gateway.discord.gg') gatewayRequests.add(p.requestId) } catch {} }
    if (method === 'Network.webSocketFrameReceived' && gatewayRequests.has(p.requestId)) socketFrames++
    if (Date.now() - lastNetworkUpdate > 250) { lastNetworkUpdate = Date.now(); update({ network: [...requests.values()].slice(-50) }) }
  })
  wc.on('dom-ready', () => { observation.dom_loaded = true })
  const aborted = () => { if (!wc.isDestroyed()) { wc.stop(); wc.close() } }
  signal.addEventListener('abort', aborted, { once: true })
  try {
    const navigation = wc.loadURL(options.url).catch(() => { observation.errors.push('NAVIGATION_FAILED') })
    await Promise.race([navigation, delay(options.timeout * 1000, signal)])
    if (signal.aborted) throw new Error('CANCELLED')
    const finalURL = new URL(wc.getURL())
    if (finalURL.protocol === 'https:') { const original = new URL(options.url).hostname; observation.requested_host = finalURL.hostname; observation.expected_origin = finalURL.hostname === original || finalURL.hostname.endsWith(`.${original}`) }
    if (!observation.dom_loaded) { observation.functional = options.selector || options.scenario !== 'generic_page' ? false : null; return { attempt_id: attempt, observation, requests: [...requests.values()] } }
    const auth = await wc.executeJavaScript(`!!document.querySelector('input[type="password"], iframe[src*="captcha"], #captcha') || /just a moment|captcha|verify you are human|sign in|войдите/i.test(document.title)`).catch(() => true)
    observation.auth_required = auth
    if (options.scenario === 'youtube_video') {
      await wc.executeJavaScript(`(() => { const v=document.querySelector('video'); if (!v) return false; v.muted=true; return v.play().then(()=>true).catch(()=>false) })()`, true).catch(() => false)
      const time = () => wc.executeJavaScript(`(() => { const v=document.querySelector('video'); return v && !v.paused ? v.currentTime : null })()`)
      const start = await time().catch(() => null)
      await delay(5000, signal)
      const end = await time().catch(() => null)
      observation.functional = typeof start === 'number' && typeof end === 'number' && end - start >= 1 && mediaBytes > 0 ? true : null
    } else if (options.selector) {
      let found: boolean | null = null
      for (let n = 0; n < 10; n++) {
        found = await wc.executeJavaScript(`!!document.querySelector(${JSON.stringify(options.selector)})`).catch(() => null)
        if (found !== false) break
        await delay(500, signal)
      }
      observation.functional = options.scenario === 'discord' ? (found && socketFrames > 0 ? true : null) : found
    }
    return { attempt_id: attempt, observation, requests: [...requests.values()], media_bytes: mediaBytes, websocket_frames: socketFrames }
  } finally { signal.removeEventListener('abort', aborted) }
}

async function run(options: RunOptions) {
  if (controller) throw new Error('RUN_BUSY')
  options.url = safeURL(options.url)
  if (![0, 1, 2, 3, 4].includes(options.profile) || !['generic_page', 'youtube_video', 'discord'].includes(options.scenario) || typeof options.selector !== 'string' || options.selector.length > 128 || !Number.isInteger(options.timeout) || options.timeout < 5 || options.timeout > 60 || !Array.isArray(options.strategies) || options.strategies.length > 64 || options.strategies.some(n => !Number.isInteger(n) || n < 1)) throw new Error('INVALID_OPTIONS')
  const router = new Router(options.ssh)
  controller = new AbortController(); const signal = controller.signal
  activeRouter = router; results = []
  let heartbeat: ReturnType<typeof setInterval> | undefined, heartbeatError: Error | undefined, beating = false
  try {
    update({ state: 'PREPARING', results })
    if (options.profile === 0) options.profile = (await router.call('resolve-profile', { hostname: new URL(options.url).hostname }, signal)).profile
    const capabilities = await router.call('capabilities', {}, signal)
    const available = capabilities.profiles?.[String(options.profile)]
    if (!Array.isArray(available) || !capabilities.isolation?.available || options.strategies.some(n => !available.includes(n))) throw new Error('PROFILE_OR_ISOLATION_UNAVAILABLE')
    let status: RouterStatus = await router.call('start', { profile: options.profile }, signal)
    heartbeat = setInterval(async () => { if (beating || signal.aborted) return; beating = true; try { await router.call('heartbeat', {}, signal) } catch (e) { heartbeatError = e as Error; controller?.abort() } finally { beating = false } }, 15000)
    const port = await router.tunnel(status.proxy)
    const sequence = strategySequence(options.strategies)
    const pause = options.profile === 3 ? 30000 : 15000
    for (const [index, strategy] of sequence.entries()) {
      if (signal.aborted) throw new Error('CANCELLED')
      await closePreview()
      update({ state: strategy === 0 ? 'BASELINE' : 'SWITCHING', strategy, results })
      if (index > 0) status = await router.call('set-strategy', { strategy }, signal)
      let result: any
      for (let retry = 0; retry < 2; retry++) {
        if (retry) { await closePreview(); status = await router.call('set-strategy', { strategy }, signal); await delay(pause, signal) }
        const before: RouterStatus = await router.call('status', {}, signal)
        if (!router.tunnelAlive) throw new Error('SSH_FORWARDING_UNAVAILABLE')
        update({ state: 'LOADING', strategy, retry, results })
        const observed = await observe(options, port, signal)
        update({ state: 'ANALYZING', strategy, results })
        let after: RouterStatus
        try { if (!router.tunnelAlive) throw new Error('SSH_FORWARDING_UNAVAILABLE'); after = await router.call('telemetry', {}, signal) } catch (e) { result = { ...observed, verdict: 'INVALID', reason: (e as Error).message }; break }
        result = { ...observed, ...classify(before, after, observed.observation), session_id: before.session_id, strategy_generation: before.strategy_generation, transport_generation_start: before.transport_generation, transport_generation_end: after.transport_generation, route_generation_start: before.route_generation, route_generation_end: after.route_generation, firewall_generation_start: before.firewall_generation, firewall_generation_end: after.firewall_generation, queue_number: before.queue.number, queue_counter_start: before.queue.counter, queue_counter_end: after.queue.counter, queue_delta: after.queue.counter - before.queue.counter, flows: after.flows || [], proof: after.proof }
        if (result.reason !== 'RETRY_REQUIRED') break
        if (retry === 1) result = { ...result, verdict: 'FAIL', reason: 'DECLARED_SCENARIO_FAILED_TWICE' }
      }
      results.push({ test_id: randomUUID(), site: redactURL(options.url), profile: options.profile, strategy, scenario: options.scenario, mode: 'router_socks_tcp', protocol_scope: 'TCP_HTTPS_IPV4', ...result, manual: null })
      await saveResults()
      if (options.manual && result.verdict !== 'INVALID') {
        update({ state: 'MANUAL', strategy, results })
        await waitForManual(results.length - 1, signal)
      }
      update({ state: 'NEXT', strategy, results })
      if (result.verdict === 'INVALID') break
      if (index < sequence.length - 1) await delay(pause, signal)
    }
    update({ state: 'REPORTING', results })
  } catch (e) { update({ state: signal.aborted && !heartbeatError ? 'CANCELLED' : 'ERROR', error: heartbeatError?.message || (e as Error).message, results }) }
  finally {
    if (heartbeat) clearInterval(heartbeat)
    let cleanupError: string | undefined
    try { await closePreview() } catch (e) { cleanupError = (e as Error).message }
    try { await router.stop() } catch (e) { cleanupError = (e as Error).message }
    controller = undefined; activeRouter = undefined
    update({ state: cleanupError ? 'CLEANUP_ERROR' : 'IDLE', cleanup_error: cleanupError, results })
  }
}

app.whenReady().then(async () => {
  protocol.handle('zator-ui', request => {
    const name = new URL(request.url).pathname.slice(1)
    if (!['index.html', 'renderer.js', 'style.css'].includes(name)) return new Response('', { status: 404 })
    return electronNet.fetch(pathToFileURL(join(__dirname, name)).href)
  })
  win = new BrowserWindow({ width: 1320, height: 820, minWidth: 900, minHeight: 600, webPreferences: { preload: join(__dirname, 'preload.js'), nodeIntegration: false, contextIsolation: true, sandbox: true } })
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  win.webContents.on('will-navigate', e => e.preventDefault())
  win.webContents.session.setPermissionRequestHandler((_wc, _permission, callback) => callback(false))
  ipcMain.handle('probe-command', async (event, command, payload) => {
    if (event.sender !== win.webContents || event.senderFrame !== win.webContents.mainFrame || event.senderFrame.url !== 'zator-ui://app/index.html') throw new Error('IPC_DENIED')
    if (command === 'run') { if (controller) throw new Error('RUN_BUSY'); running = run(payload).catch(e => update({ state: 'ERROR', error: e.message })); return }
    if (command === 'cancel') { controller?.abort(); return }
    if (command === 'manual') { if (Number.isInteger(payload.index) && results[payload.index] && ['passed', 'failed', 'unknown'].includes(payload.value)) { results[payload.index].manual = payload.value; await saveResults(); const waiting = manualWait; if (waiting && waiting.index === payload.index) waiting.finish(); update({ results }) }; return }
    if (command === 'export') {
      const picked = await dialog.showSaveDialog(win, { defaultPath: 'zator-probe.json', filters: [{ name: 'JSON', extensions: ['json'] }, { name: 'Markdown', extensions: ['md'] }] })
      if (!picked.canceled && picked.filePath) {
        const body = picked.filePath.toLowerCase().endsWith('.md') ? '# Zator Desktop Probe\n\nTCP/HTTPS IPv4, router_socks_tcp. Manual observations are separate.\n\n| Strategy | Verdict | Reason | Manual |\n|---|---|---|---|\n' + results.map(r => `| ${r.strategy || 'DIRECT'} | ${r.verdict} | ${String(r.reason).replace(/[|\r\n]/g, ' ')} | ${r.manual || ''} |`).join('\n') : JSON.stringify({ schema: '0.1', created: new Date().toISOString(), results }, null, 2)
        await writeFile(picked.filePath, body)
      }; return
    }
    if (command === 'screenshot' && preview && !preview.webContents.isDestroyed()) {
      const picked = await dialog.showSaveDialog(win, { defaultPath: 'probe.png', filters: [{ name: 'PNG', extensions: ['png'] }] })
      if (!picked.canceled && picked.filePath && preview) await writeFile(picked.filePath, (await preview.webContents.capturePage()).toPNG())
      return
    }
    throw new Error('UNKNOWN_COMMAND')
  })
  win.on('resize', fit)
  win.on('closed', () => { controller?.abort(); app.quit() })
  await win.loadURL('zator-ui://app/index.html')
  try { const previous = JSON.parse(await readFile(join(app.getPath('userData'), 'last-report.json'), 'utf8')); if (Array.isArray(previous)) { results = previous; update({ results }) } } catch { /* First launch has no local report. */ }
  if (process.argv.includes('--probe-smoke')) {
    update({ state: 'PREPARING' })
    const safe = await win.webContents.executeJavaScript(`new Promise(resolve => setTimeout(async () => { try { await window.probe.command('cancel'); resolve(typeof require === 'undefined' && document.querySelector('#run').disabled && document.querySelector('#status').textContent.includes('Подготовка')) } catch { resolve(false) } }, 30))`)
    console.log(`UI_SMOKE=${safe ? 'PASS' : 'FAIL'}`); app.exit(safe ? 0 : 1)
  }
  if (process.argv.includes('--probe-integration')) {
    if (!process.env.ZATOR_PROBE_TEST_CONFIG || !process.env.ZATOR_PROBE_TEST_REPORT) throw new Error('TEST_PATHS_REQUIRED')
    const options = JSON.parse(await readFile(process.env.ZATOR_PROBE_TEST_CONFIG, 'utf8'))
    const fields = { host: options.ssh.host, user: options.ssh.user, port: String(options.ssh.port), identity: options.ssh.identity, url: options.url, profile: String(options.profile), strategies: options.strategies.join(','), scenario: options.scenario, selector: options.selector, timeout: String(options.timeout) }
    await win.webContents.executeJavaScript(`(() => { for (const [id,value] of Object.entries(${JSON.stringify(fields)})) document.getElementById(id).value=value; document.getElementById('probe-form').requestSubmit() })()`)
    for (let n = 0; n < 30 && !running; n++) await new Promise(resolve => setTimeout(resolve, 100))
    if (!running) throw new Error('UI_FORM_DID_NOT_START')
    await running
    await writeFile(process.env.ZATOR_PROBE_TEST_REPORT, JSON.stringify(results, null, 2))
    if (process.env.ZATOR_PROBE_TEST_IMAGE) {
      try { await writeFile(process.env.ZATOR_PROBE_TEST_IMAGE, (await win.capturePage()).toPNG()) } catch { console.log('UI_CAPTURE=UNAVAILABLE') }
    }
    const passed = results.length === 2 && results.every(r => r.verdict === 'OK')
    console.log(`BROWSER_INTEGRATION=${passed ? 'PASS' : 'FAIL'} results=${results.map(r => `${r.strategy}:${r.verdict}:${r.reason}`).join(',')}`)
    app.exit(passed ? 0 : 1)
  }
}).catch(error => { console.error('APP_ERROR:', error.message); app.exit(1) })
app.on('before-quit', event => {
  if (quitting || !activeRouter) return
  event.preventDefault(); quitting = true; controller?.abort()
  void activeRouter.stop().finally(() => app.quit())
})
