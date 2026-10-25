import { app, BrowserWindow, WebContentsView, session, ipcMain, protocol, net as electronNet, dialog } from 'electron'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { Router } from './ssh'
import { classify, classifyYouTube, YouTubeSweep, succeeded, Observation, redactURL, RouterStatus, safeURL, SSHOptions, strategySequence, ScanOptions, ScanTarget, scanTargets, scanStrategies, scanCompletion, coverageSummary, withinTimeout, ensureIsolation } from './core'

protocol.registerSchemesAsPrivileged([{ scheme: 'zator-ui', privileges: { standard: true, secure: true, supportFetchAPI: true } }])
app.commandLine.appendSwitch('disable-quic')
app.commandLine.appendSwitch('force-webrtc-ip-handling-policy', 'disable_non_proxied_udp')
app.commandLine.appendSwitch('host-resolver-rules', 'MAP * ~NOTFOUND, EXCLUDE 127.0.0.1')
if (process.argv.includes('--probe-integration') && process.env.ZATOR_PROBE_TEST_USER_DATA) app.setPath('userData', process.env.ZATOR_PROBE_TEST_USER_DATA)
let win: BrowserWindow
let preview: WebContentsView | undefined
let previewSession: Electron.Session | undefined
let controller: AbortController | undefined
let activeRouter: Router | undefined
let results: any[] = []
let quitting = false
let running: Promise<boolean> | undefined
let integrationFull = false
let manualWait: { index: number; finish: () => void } | undefined
function update(data: Record<string, unknown>) { if (process.argv.includes('--probe-integration') && data.error) console.log(`INTEGRATION_ERROR=${data.error}`); if (integrationFull && ['NEXT', 'ERROR', 'CANCELLED', 'CLEANUP_ERROR', 'REPORTING'].includes(String(data.state))) console.log(`FULLSCAN_PROGRESS=${JSON.stringify({ state: data.state, completed: data.completed, total: data.total, profile: data.profile, strategy: data.strategy, gv_strategy: data.gv_strategy, target: data.target, error: data.error })}`); if (Array.isArray(data.results)) data = { ...data, coverage: coverageSummary(data.results) }; if (win && !win.isDestroyed()) win.webContents.send('probe-update', data) }
let saving = Promise.resolve()
function saveResults(): Promise<void> {
  saving = saving.catch(() => {}).then(async () => {
    const path = join(app.getPath('userData'), 'last-report.json')
    await mkdir(app.getPath('userData'), { recursive: true })
    await writeFile(`${path}.tmp`, JSON.stringify(results, null, 2)); await rename(`${path}.tmp`, path)
    if (process.argv.includes('--probe-integration') && process.env.ZATOR_PROBE_TEST_REPORT) { const report = process.env.ZATOR_PROBE_TEST_REPORT; await writeFile(`${report}.tmp`, JSON.stringify(results, null, 2)); await rename(`${report}.tmp`, report) }
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
interface RunOptions extends ScanOptions { ssh: SSHOptions; timeout: number; manual?: boolean; youtubePair?: boolean; checkVideo?: boolean }
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
  wc.setAudioMuted(true)
  wc.setWebRTCIPHandlingPolicy('disable_non_proxied_udp')
  wc.setWindowOpenHandler(() => ({ action: 'deny' }))
  wc.on('will-navigate', (event, url) => { try { safeURL(url) } catch { event.preventDefault() } })
  win.contentView.addChildView(view); fit()
  await wc.loadURL('about:blank')
  const observation: Observation = { http_status: null, dom_loaded: false, fresh_connection: null, functional: null, auth_required: false, errors: [], requested_host: new URL(options.url).hostname }
  const requests = new Map<string, any>()
  const gatewayRequests = new Set<string>()
  const requiredHosts = new Set<string>()
  const videoHosts = new Set<string>()
  let mediaBytes = 0, socketFrames = 0, mainFrame = '', lastNetworkUpdate = 0
  wc.debugger.attach('1.3')
  await wc.debugger.sendCommand('Network.enable')
  await wc.debugger.sendCommand('Page.enable')
  const evaluate = async (expression: string, userGesture = false): Promise<any> => {
    // Electron executeJavaScript waits for load; CDP can inspect an already visible DOM earlier.
    const result = await wc.debugger.sendCommand('Runtime.evaluate', { expression, userGesture, returnByValue: true, awaitPromise: true })
    if (result.exceptionDetails) throw new Error('DOM_EVALUATION_FAILED')
    return result.result.value
  }
  mainFrame = (await wc.debugger.sendCommand('Page.getFrameTree')).frameTree.frame.id
  wc.debugger.on('message', (_event, method, p) => {
    if (method === 'Page.frameNavigated' && !p.frame.parentId) mainFrame = p.frame.id
    if (method === 'Network.requestWillBeSent' && requests.size < 1500) {
      requests.set(p.requestId, { url: redactURL(p.request.url), type: p.type, status: null, protocol: null, bytes: 0, error: null, started: p.timestamp, duration_ms: null })
      try { const host = new URL(p.request.url).hostname; if (host === 'googlevideo.com' || host.endsWith('.googlevideo.com')) videoHosts.add(host) } catch {}
    }
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
    if (method === 'Network.dataReceived') { const row = requests.get(p.requestId); if (row) { row.bytes += p.encodedDataLength; if (/^https:\/\/([a-z0-9-]+\.)?googlevideo\.com\//.test(row.url) && p.encodedDataLength > 0) { mediaBytes += p.encodedDataLength; requiredHosts.add(new URL(row.url).hostname) } } }
    if (method === 'Network.loadingFailed') {
      const row = requests.get(p.requestId)
      const error = /^net::ERR_[A-Z_]+$/.test(p.errorText) ? p.errorText : 'NETWORK_ERROR'
      if (row) row.error = error
      if (observation.errors.length < 100) observation.errors.push(error)
    }
    if (method === 'Network.webSocketCreated') { try { if (new URL(p.url).hostname === 'gateway.discord.gg') gatewayRequests.add(p.requestId) } catch {} }
    if (method === 'Network.webSocketFrameReceived' && gatewayRequests.has(p.requestId)) { socketFrames++; requiredHosts.add('gateway.discord.gg') }
    if (Date.now() - lastNetworkUpdate > 250) { lastNetworkUpdate = Date.now(); update({ network: [...requests.values()].slice(-50) }) }
  })
  const domReady = new Promise<void>(resolve => wc.once('dom-ready', () => { observation.dom_loaded = true; resolve() }))
  const deadline = Date.now() + options.timeout * 1000
  const bounded = <T>(work: Promise<T>) => withinTimeout(work, deadline - Date.now(), signal)
  const aborted = () => { if (!wc.isDestroyed()) { wc.stop(); wc.close() } }
  signal.addEventListener('abort', aborted, { once: true })
  try {
    const navigation = wc.loadURL(options.url).catch(error => { if (error.code === 'ERR_ABORTED') return domReady; observation.errors.push('NAVIGATION_FAILED') })
    await bounded(Promise.race([navigation, domReady]))
    if (signal.aborted) throw new Error('CANCELLED')
    const finalURL = new URL(wc.getURL())
    if (finalURL.protocol === 'https:') { const original = new URL(options.url).hostname; observation.requested_host = finalURL.hostname; observation.expected_origin = finalURL.hostname === original || finalURL.hostname.endsWith(`.${original}`) }
    if (!observation.dom_loaded) { observation.functional = options.selector || options.scenario !== 'generic_page' ? false : null; return { attempt_id: attempt, observation, requests: [...requests.values()] } }
    const auth = await bounded(evaluate(`!!document.querySelector('input[type="password"], iframe[src*="captcha"], #captcha') || /just a moment|captcha|verify you are human|sign in|войдите/i.test(document.title)`).catch(() => true))
    observation.auth_required = auth
    if (options.scenario === 'youtube_video') {
      if (options.youtubePair) {
        while (Date.now() < deadline) {
          observation.page_functional = await bounded(evaluate(`!!document.querySelector('ytd-app')`).catch(() => false))
          if (observation.page_functional) break
          await bounded(delay(250, signal))
        }
        if (options.checkVideo === false || !observation.page_functional || auth) {
          observation.functional = null
          observation.video_hosts = [...videoHosts]
          observation.required_hosts = [...requiredHosts]
          return { attempt_id: attempt, observation, requests: [...requests.values()], media_bytes: mediaBytes, websocket_frames: socketFrames }
        }
      }
      let start: number | null = null
      while (Date.now() < deadline) {
        const time: number | null = await bounded(evaluate(`(() => { const v=document.querySelector('video'); if (!v) return null; v.muted=true; if(v.paused) void v.play().catch(()=>{}); return !v.paused && v.readyState>=2 ? v.currentTime : null })()`, true).catch(() => null))
        if (typeof time === 'number') {
          if (start === null || time < start) start = time
          observation.playback_progress_seconds = time - start
          if (time - start >= 2 && mediaBytes > 0) { observation.functional = true; break }
        }
        await bounded(delay(500, signal))
      }
    } else if (options.selector) {
      let found: boolean | null = null
      for (let n = 0; n < 10; n++) {
        found = await bounded(evaluate(`!!document.querySelector(${JSON.stringify(options.selector)})`).catch(() => null))
        if (found !== false) break
        await bounded(delay(500, signal))
      }
      observation.functional = options.scenario === 'discord' ? (found && socketFrames > 0 ? true : null) : found
    }
    observation.required_hosts = [...requiredHosts]
    observation.video_hosts = [...videoHosts]
    return { attempt_id: attempt, observation, requests: [...requests.values()], media_bytes: mediaBytes, websocket_frames: socketFrames }
  } catch (e) {
    if (signal.aborted || (e as Error).message !== 'ATTEMPT_TIMEOUT') throw e
    wc.stop()
    observation.timed_out = true
    observation.required_hosts = [...requiredHosts]
    observation.video_hosts = [...videoHosts]
    observation.functional = options.selector || options.scenario !== 'generic_page' ? false : null
    return { attempt_id: attempt, observation, requests: [...requests.values()], media_bytes: mediaBytes, websocket_frames: socketFrames }
  } finally { signal.removeEventListener('abort', aborted) }
}

async function run(options: RunOptions) {
  if (controller) throw new Error('RUN_BUSY')
  const targets = scanTargets(options)
  if (!Number.isInteger(options.timeout) || options.timeout < 5 || options.timeout > 60) throw new Error('INVALID_TIMEOUT')
  const router = new Router(options.ssh)
  controller = new AbortController(); const signal = controller.signal
  activeRouter = router; results = []
  let finalState = 'IDLE', runError: string | undefined
  let cleanupError: string | undefined
  let heartbeat: ReturnType<typeof setInterval> | undefined, heartbeatError: Error | undefined, beating = false
  try {
    update({ state: 'PREPARING', results })
    const capabilities = await ensureIsolation(command => { if (command === 'prepare-transport') update({ state: 'REPAIRING', results }); return router.call(command, {}, signal) })
    const plan: (ScanTarget & { strategies: number[]; gvStrategies?: number[] })[] = []
    for (const target of targets) {
      if (target.scenario === 'youtube_video') {
        if (!capabilities.youtube_pair_supported) throw new Error('UPDATE_ROUTER_AGENT_REQUIRED: paired YouTube/GV')
        target.profile = 1
        plan.push({ ...target, strategies: scanStrategies(options, capabilities.profiles?.['1']), gvStrategies: scanStrategies(options, capabilities.profiles?.['2']) })
        continue
      }
      if (target.profile === 0) target.profile = (await router.call('resolve-profile', { hostname: new URL(target.url).hostname }, signal)).profile
      plan.push({ ...target, strategies: scanStrategies(options, capabilities.profiles?.[String(target.profile)]) })
    }
    const total = plan.reduce((sum, t) => sum + (t.gvStrategies ? 2 + t.strategies.length + t.gvStrategies.length : strategySequence(t.strategies).length), 0)
    let completed = 0
    for (const [targetIndex, target] of plan.entries()) {
      const attemptOptions = { ...options, ...target }
      const context = { target: redactURL(target.url), profile: target.profile, target_index: targetIndex + 1, target_count: plan.length, completed, total }
      update({ state: 'PREPARING', ...context, results })
      let status: RouterStatus = await router.call('start', { profile: target.profile, paired: !!target.gvStrategies }, signal)
      heartbeat = setInterval(async () => { if (beating || signal.aborted) return; beating = true; try { await router.call('heartbeat', {}, signal) } catch (e) { heartbeatError = e as Error; controller?.abort() } finally { beating = false } }, 15000)
      const port = await router.tunnel(status.proxy)
      const sequence = strategySequence(target.strategies)
      const pause = target.profile === 3 ? 30000 : 15000
      if (target.gvStrategies) {
        const sweep = new YouTubeSweep(target.strategies, target.gvStrategies)
        let first = true
        for (let pair = sweep.next(); pair; pair = sweep.next()) {
          if (signal.aborted) throw new Error('CANCELLED')
          await closePreview()
          const pairContext = { ...context, completed, strategy: pair.yt, gv_strategy: pair.gv }
          update({ state: pair.baseline ? 'BASELINE' : 'SWITCHING', ...pairContext, results })
          if (!first) status = await router.call('set-strategy', { strategy: pair.yt, gv_strategy: pair.gv }, signal)
          first = false
          const before: RouterStatus = await router.call('status', {}, signal)
          if (!router.tunnelAlive) throw new Error('SSH_FORWARDING_UNAVAILABLE')
          update({ state: 'LOADING', ...pairContext })
          const observed = await observe({ ...attemptOptions, youtubePair: true, checkVideo: pair.testGV }, port, signal)
          update({ state: 'ANALYZING', ...pairContext })
          let after: RouterStatus
          try {
            if (!router.tunnelAlive) throw new Error('SSH_FORWARDING_UNAVAILABLE')
            after = await router.call('telemetry', {}, signal)
          } catch (e) {
            results.push({ test_id: randomUUID(), site: redactURL(target.url), profile: 1, strategy: pair.yt, yt_strategy: pair.yt, gv_strategy: pair.gv, stage: 'page', scenario: target.scenario, ...observed, verdict: 'INVALID', reason: (e as Error).message })
            await saveResults(); throw e
          }
          const verdicts = classifyYouTube(before, after, observed.observation)
          const evidence = { ...observed, session_id: before.session_id, strategy_generation: before.strategy_generation, transport_generation_start: before.transport_generation, transport_generation_end: after.transport_generation, route_generation_start: before.route_generation, route_generation_end: after.route_generation, firewall_generation_start: before.firewall_generation, firewall_generation_end: after.firewall_generation, telemetry_reads: after.telemetry_reads, queue_number: before.queue.number, queue_counter_start: before.queue.counter, queue_counter_end: after.queue.counter, queue_delta: after.queue.counter - before.queue.counter, flows: after.flows || [], proof: after.proof }
          const row = { ...evidence, site: redactURL(target.url), scenario: target.scenario, mode: 'router_socks_tcp', protocol_scope: 'TCP_HTTPS_IPV4', yt_strategy: pair.yt, gv_strategy: pair.gv, paired: true, manual: null, tested: true }
          const oldLength = results.length
          if (pair.testYT || !succeeded(verdicts.page.verdict)) {
            results.push({ ...row, test_id: randomUUID(), profile: 1, strategy: pair.yt, stage: 'page', helper: !pair.testYT, ...verdicts.page, observation: { ...observed.observation, functional: observed.observation.page_functional ?? false, timed_out: observed.observation.page_functional ? false : observed.observation.timed_out, required_hosts: [] } })
            if (pair.testYT) completed++
          }
          if (verdicts.video && pair.testGV) {
            results.push({ ...row, test_id: randomUUID(), profile: 2, strategy: pair.gv, stage: 'video', ...verdicts.video }); completed++
          } else if (pair.baseline) {
            results.push({ ...row, test_id: randomUUID(), profile: 2, strategy: 0, stage: 'video', verdict: 'UNKNOWN', reason: 'VIDEO_NOT_TESTED_WITH_WORKING_PAGE', tested: false }); completed++
          }
          await saveResults()
          if (verdicts.page.verdict === 'INVALID' || verdicts.video?.verdict === 'INVALID') throw new Error(`SCAN_STOPPED_INVALID_TRANSPORT: ${verdicts.page.verdict === 'INVALID' ? verdicts.page.reason : verdicts.video?.reason}`)
          sweep.record(pair, verdicts.page.verdict, verdicts.video?.verdict ?? null)
          if (options.manual && results.length > oldLength) { update({ state: 'MANUAL', ...pairContext, completed, results }); await waitForManual(results.length - 1, signal) }
          update({ state: 'NEXT', ...pairContext, completed, results })
          if (sweep.next()) { update({ state: 'PAUSE', ...pairContext, completed, pause_seconds: 15 }); await delay(15000, signal) }
        }
        for (const strategy of sweep.uncheckedGV) {
          results.push({ test_id: randomUUID(), site: redactURL(target.url), profile: 2, strategy, scenario: target.scenario, stage: 'video', tested: false, verdict: 'UNKNOWN', reason: 'VIDEO_NOT_TESTED_WITH_WORKING_PAGE', mode: 'router_socks_tcp', protocol_scope: 'TCP_HTTPS_IPV4', manual: null }); completed++
        }
        await saveResults()
      } else {
      for (const [index, strategy] of sequence.entries()) {
        if (signal.aborted) throw new Error('CANCELLED')
        await closePreview()
        update({ state: strategy === 0 ? 'BASELINE' : 'SWITCHING', ...context, completed, strategy, results })
        if (index > 0) status = await router.call('set-strategy', { strategy }, signal)
        let result: any
        for (let retry = 0; retry < 2; retry++) {
          if (retry) { await closePreview(); status = await router.call('set-strategy', { strategy }, signal); update({ state: 'PAUSE', ...context, completed, strategy, pause_seconds: pause / 1000 }); await delay(pause, signal) }
          const before: RouterStatus = await router.call('status', {}, signal)
          if (!router.tunnelAlive) throw new Error('SSH_FORWARDING_UNAVAILABLE')
          update({ state: 'LOADING', ...context, completed, strategy, retry, results })
          const observed = await observe(attemptOptions, port, signal)
          update({ state: 'ANALYZING', ...context, completed, strategy, results })
          let after: RouterStatus
          try { if (!router.tunnelAlive) throw new Error('SSH_FORWARDING_UNAVAILABLE'); after = await router.call('telemetry', {}, signal) } catch (e) { result = { ...observed, verdict: 'INVALID', reason: (e as Error).message }; break }
          result = { ...observed, ...classify(before, after, observed.observation), session_id: before.session_id, strategy_generation: before.strategy_generation, transport_generation_start: before.transport_generation, transport_generation_end: after.transport_generation, route_generation_start: before.route_generation, route_generation_end: after.route_generation, firewall_generation_start: before.firewall_generation, firewall_generation_end: after.firewall_generation, telemetry_reads: after.telemetry_reads, queue_number: before.queue.number, queue_counter_start: before.queue.counter, queue_counter_end: after.queue.counter, queue_delta: after.queue.counter - before.queue.counter, flows: after.flows || [], proof: after.proof }
          if (result.reason !== 'RETRY_REQUIRED') break
          if (retry === 1) result = { ...result, verdict: 'FAIL', reason: 'DECLARED_SCENARIO_FAILED_TWICE' }
        }
        results.push({ test_id: randomUUID(), site: redactURL(target.url), profile: target.profile, strategy, scenario: target.scenario, mode: 'router_socks_tcp', protocol_scope: 'TCP_HTTPS_IPV4', ...result, manual: null })
        completed++
        await saveResults()
        if (options.manual && result.verdict !== 'INVALID') {
          update({ state: 'MANUAL', ...context, completed, strategy, results })
          await waitForManual(results.length - 1, signal)
        }
        update({ state: 'NEXT', ...context, completed, strategy, results })
        if (result.verdict === 'INVALID') throw new Error(`SCAN_STOPPED_INVALID_TRANSPORT: ${result.reason}`)
        if (index < sequence.length - 1) { update({ state: 'PAUSE', ...context, completed, strategy, pause_seconds: pause / 1000 }); await delay(pause, signal) }
      }
      }
      if (heartbeat) clearInterval(heartbeat)
      heartbeat = undefined
      await closePreview()
      await router.stop()
      if (targetIndex < plan.length - 1) { update({ state: 'PAUSE', ...context, completed, pause_seconds: 30 }); await delay(30000, signal) }
    }
    update({ state: 'REPORTING', completed, total, results })
  } catch (e) { finalState = signal.aborted && !heartbeatError ? 'CANCELLED' : 'ERROR'; runError = heartbeatError?.message || (e as Error).message }
  finally {
    if (heartbeat) clearInterval(heartbeat)
    try { await closePreview() } catch (e) { cleanupError = (e as Error).message }
    try { await router.stop() } catch (e) { cleanupError = (e as Error).message }
    controller = undefined; activeRouter = undefined
    update({ state: cleanupError ? 'CLEANUP_ERROR' : finalState, error: runError, cleanup_error: cleanupError, results })
  }
  return finalState === 'IDLE' && !cleanupError
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
    if (command === 'run') { if (controller) throw new Error('RUN_BUSY'); running = run(payload).catch(e => { update({ state: 'ERROR', error: e.message }); return false }); return }
    if (command === 'cancel') { controller?.abort(); return }
    if (command === 'manual') { if (Number.isInteger(payload.index) && results[payload.index] && ['passed', 'failed', 'unknown'].includes(payload.value)) { results[payload.index].manual = payload.value; await saveResults(); const waiting = manualWait; if (waiting && waiting.index === payload.index) waiting.finish(); update({ results }) }; return }
    if (command === 'export') {
      const picked = await dialog.showSaveDialog(win, { defaultPath: 'zator-probe.json', filters: [{ name: 'JSON', extensions: ['json'] }, { name: 'Markdown', extensions: ['md'] }] })
      if (!picked.canceled && picked.filePath) {
        const body = picked.filePath.toLowerCase().endsWith('.md') ? '# Zator Desktop Probe\n\nTCP/HTTPS IPv4, router_socks_tcp. Manual observations are separate.\n\n| Profile | Site | Strategy | Pair YT/GV | Stage | Tested | Verdict | Reason | Manual |\n|---|---|---|---|---|---|---|---|---|\n' + results.map(r => `| ${r.profile} | ${String(r.site).replace(/[|\r\n]/g, ' ')} | ${r.strategy || 'DIRECT'} | ${r.yt_strategy ?? '-'}/${r.gv_strategy ?? '-'} | ${r.stage || ''} | ${r.tested === false ? 'no' : 'yes'} | ${r.verdict} | ${String(r.reason).replace(/[|\r\n]/g, ' ')} | ${r.manual || ''} |`).join('\n') : JSON.stringify({ schema: '0.1', created: new Date().toISOString(), coverage: coverageSummary(results), results }, null, 2)
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
    const controls = await win.webContents.executeJavaScript(`(() => {
      const mode=document.getElementById('scan-mode'), all=document.getElementById('strategy-mode');
      mode.value='supersweep'; mode.dispatchEvent(new Event('change'));
      const sweep=document.getElementById('url').disabled && !document.getElementById('youtube-url').disabled && !document.getElementById('rkn-urls').disabled && !document.getElementById('sweep-options').hidden;
      mode.value='single'; mode.dispatchEvent(new Event('change')); all.value='all'; all.dispatchEvent(new Event('change'));
      const single=!document.getElementById('url').disabled && document.getElementById('youtube-url').disabled && document.getElementById('strategies').disabled;
      all.value='selected'; all.dispatchEvent(new Event('change'));
      return sweep && single && !document.getElementById('strategies').disabled;
    })()`)
    update({ state: 'PREPARING' })
    const safe = await win.webContents.executeJavaScript(`new Promise(resolve => setTimeout(async () => { try { await window.probe.command('cancel'); resolve(typeof require === 'undefined' && document.querySelector('#run').disabled && document.querySelector('#status').textContent.includes('Подготовка')) } catch { resolve(false) } }, 30))`)
    console.log(`UI_SMOKE=${safe && controls ? 'PASS' : 'FAIL'}`); app.exit(safe && controls ? 0 : 1)
  }
  if (process.argv.includes('--probe-integration')) {
    if (!process.env.ZATOR_PROBE_TEST_CONFIG || !process.env.ZATOR_PROBE_TEST_REPORT) throw new Error('TEST_PATHS_REQUIRED')
    const options = JSON.parse(await readFile(process.env.ZATOR_PROBE_TEST_CONFIG, 'utf8'))
    integrationFull = options.scanMode === 'supersweep'
    const expectedCapabilities = integrationFull ? await new Router(options.ssh).call('capabilities') : undefined
    const fields = { host: options.ssh.host, user: options.ssh.user, port: String(options.ssh.port), identity: options.ssh.identity, url: options.url, profile: String(options.profile), strategies: options.strategies.join(','), scenario: options.scenario, selector: options.selector, timeout: String(options.timeout) }
    const sweepFields = { 'youtube-url': options.youtubeURL, 'discord-url': options.discordURL, 'discord-selector': options.discordSelector, 'rkn-urls': options.rknURLs, 'rkn-selector': options.rknSelector }
    await win.webContents.executeJavaScript(`(() => { for (const [id,value] of Object.entries(${JSON.stringify(fields)})) document.getElementById(id).value=value; for (const [id,value] of Object.entries(${JSON.stringify(sweepFields)})) if (value !== undefined) document.getElementById(id).value=value; const mode=document.getElementById('scan-mode'); mode.value=${JSON.stringify(options.scanMode || 'single')}; mode.dispatchEvent(new Event('change')); document.getElementById('scenario').dispatchEvent(new Event('change')); document.getElementById('probe-form').requestSubmit() })()`)
    for (let n = 0; n < 30 && !running; n++) await new Promise(resolve => setTimeout(resolve, 100))
    if (!running) throw new Error('UI_FORM_DID_NOT_START')
    const finished = await running
    await writeFile(process.env.ZATOR_PROBE_TEST_REPORT, JSON.stringify(results, null, 2))
    if (process.env.ZATOR_PROBE_TEST_IMAGE) {
      try { await writeFile(process.env.ZATOR_PROBE_TEST_IMAGE, (await win.capturePage()).toPNG()) } catch { console.log('UI_CAPTURE=UNAVAILABLE') }
    }
    if (integrationFull) {
      const completion = scanCompletion(results, options, expectedCapabilities)
      const counts: Record<string, number> = {}
      for (const row of results) counts[row.verdict] = (counts[row.verdict] || 0) + 1
      const passed = finished && completion.missing.length === 0 && !results.some(r => r.verdict === 'INVALID')
      const summary = { completed: passed, ...completion, counts, rows: results.length, created: new Date().toISOString() }
      await writeFile(`${process.env.ZATOR_PROBE_TEST_REPORT}.summary.json`, JSON.stringify(summary, null, 2))
      console.log(`FULLSCAN_INTEGRATION=${passed ? 'PASS' : 'FAIL'} ${JSON.stringify(summary)}`)
      app.exit(passed ? 0 : 1); return
    }
    const passed = finished && (options.scenario === 'youtube_video'
      ? !results.some(r => r.verdict === 'INVALID') && [1, 2].every(profile => results.some(r => r.profile === profile && r.strategy > 0 && r.tested !== false && succeeded(r.verdict)))
      : results.length === 2 && results.every(r => r.verdict === 'OK'))
    console.log(`BROWSER_INTEGRATION=${passed ? 'PASS' : 'FAIL'} results=${results.map(r => `P${r.profile}/${r.strategy}:${r.verdict}:${r.reason}`).join(',')}`)
    app.exit(passed ? 0 : 1)
  }
}).catch(error => { console.error('APP_ERROR:', error.message); app.exit(1) })
app.on('before-quit', event => {
  if (quitting || !activeRouter) return
  event.preventDefault(); quitting = true; controller?.abort()
  void activeRouter.stop().finally(() => app.quit())
})
