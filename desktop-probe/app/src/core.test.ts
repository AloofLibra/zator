import { test } from 'node:test'
import assert from 'node:assert/strict'
import { classify, classifyYouTube, YouTubeSweep, Observation, redactURL, RouterStatus, safeURL, validateSSH, strategySequence, scanTargets, scanStrategies, coverageSummary, ScanOptions, withinTimeout, ensureIsolation, Capabilities } from './core'

test('preflight restores missing transport once and rechecks isolation', async () => {
  const calls: string[] = []
  const broken: Capabilities = { session_active: false, prepare_transport_supported: true, isolation: { available: false, reason: 'TRANSPORT_CHANGED' } }
  const ready: Capabilities = { ...broken, isolation: { available: true } }
  const result = await ensureIsolation(async command => { calls.push(command); return calls.length === 1 ? broken : command === 'prepare-transport' ? {} : ready })
  assert.equal(result.isolation?.available, true)
  assert.deepEqual(calls, ['capabilities', 'prepare-transport', 'capabilities'])
  calls.length = 0
  await ensureIsolation(async command => { calls.push(command); return ready })
  assert.deepEqual(calls, ['capabilities'])
})
test('preflight never repairs active sessions or configuration failures and does not loop on failed repair', async () => {
  for (const [capabilities, error] of [
    [{ session_active: true, isolation: { available: false, reason: 'TRANSPORT_CHANGED' } }, /SESSION_BUSY/],
    [{ isolation: { available: false, reason: 'MARK_COLLISION' } }, /ISOLATION_UNAVAILABLE/],
    [{ isolation: { available: false, reason: 'TRANSPORT_CHANGED' } }, /UPDATE_ROUTER_AGENT_REQUIRED/]
  ] as [Capabilities, RegExp][]) {
    const calls: string[] = []
    await assert.rejects(ensureIsolation(async command => { calls.push(command); return capabilities }), error)
    assert.deepEqual(calls, ['capabilities'])
  }
  const calls: string[] = []
  await assert.rejects(ensureIsolation(async command => { calls.push(command); return { session_active: false, prepare_transport_supported: true, isolation: { available: false, reason: 'TRANSPORT_CHANGED' } } }), /ISOLATION_UNAVAILABLE/)
  assert.deepEqual(calls, ['capabilities', 'prepare-transport', 'capabilities'])
})

const scan: ScanOptions = { url: 'https://example.org/', profile: 3, scenario: 'generic_page', selector: 'body', strategies: [1], scanMode: 'supersweep', youtubeURL: 'https://www.youtube.com/watch?v=test', discordURL: 'https://discord.com/app', discordSelector: '#app-mount', rknURLs: 'https://example.org/\nhttps://example.net/\nhttps://example.org/', rknSelector: 'body' }
test('supersweep combines YouTube/GV into one target and keeps every RKN domain', () => {
  const targets = scanTargets(scan)
  assert.deepEqual(targets.map(t => t.profile), [1, 4, 3, 3])
  assert.deepEqual(targets.map(t => t.scenario), ['youtube_video', 'discord', 'generic_page', 'generic_page'])
  assert.deepEqual(scanStrategies(scan, [1, 2, 3]), [1, 2, 3])
  assert.deepEqual(scanStrategies({ ...scan, scanMode: 'single', strategyMode: 'all' }, [1, 2]), [1, 2])
  assert.deepEqual(scanStrategies({ ...scan, scanMode: 'single' }, [1, 2]), [1])
  assert.deepEqual(scanTargets({ ...scan, scanMode: 'single' }), [{ url: scan.url, profile: 3, scenario: 'generic_page', selector: 'body' }])
})
test('paired sweep retains an untested GV after page failure and finishes GV with a successful YT', () => {
  const sweep = new YouTubeSweep([1, 2, 3], [1, 2, 3])
  sweep.record(sweep.next()!, 'FAIL', null)
  assert.deepEqual([sweep.next()!.yt, sweep.next()!.gv], [1, 1])
  sweep.record(sweep.next()!, 'OK', 'OK')
  assert.deepEqual([sweep.next()!.yt, sweep.next()!.gv], [2, 2])
  sweep.record(sweep.next()!, 'FAIL', null)
  assert.deepEqual([sweep.next()!.yt, sweep.next()!.gv], [3, 2])
  sweep.record(sweep.next()!, 'OK', 'OK')
  const helper = sweep.next()!
  assert.equal(helper.testYT, false); assert.equal(helper.gv, 3); assert.ok([1, 3].includes(helper.yt))
  sweep.record(helper, 'OK', 'FAIL')
  assert.equal(sweep.next(), undefined); assert.deepEqual(sweep.uncheckedGV, [])
})
test('no working page leaves GV untested; a missing player never advances GV or loops forever', () => {
  const failed = new YouTubeSweep([1, 2], [1, 2])
  for (let pair = failed.next(); pair; pair = failed.next()) failed.record(pair, 'FAIL', null)
  assert.deepEqual(failed.uncheckedGV, [1, 2])
  const noPlayer = new YouTubeSweep([1], [1, 2])
  noPlayer.record(noPlayer.next()!, 'FAIL', null)
  noPlayer.record(noPlayer.next()!, 'OK', null)
  assert.equal(noPlayer.next()!.testYT, false)
  noPlayer.record(noPlayer.next()!, 'OK', null)
  assert.equal(noPlayer.next(), undefined); assert.deepEqual(noPlayer.uncheckedGV, [1, 2])
})
test('remaining YT are checked after GV finishes and a failed helper is replaced', () => {
  const sweep = new YouTubeSweep([1, 2], [1])
  sweep.record(sweep.next()!, 'FAIL', null); sweep.record(sweep.next()!, 'OK', 'OK')
  assert.equal(sweep.next()!.testGV, false); assert.equal(sweep.next()!.gv, 1)
  sweep.record(sweep.next()!, 'OK', null); assert.equal(sweep.next(), undefined)
  const helpers = new YouTubeSweep([1, 2], [1, 2, 3])
  helpers.record(helpers.next()!, 'FAIL', null)
  helpers.record(helpers.next()!, 'OK', 'OK'); helpers.record(helpers.next()!, 'OK', 'OK')
  const first = helpers.next()!.yt; helpers.record(helpers.next()!, 'FAIL', null)
  assert.notEqual(helpers.next()!.yt, first); assert.equal(helpers.next()!.gv, 3)
})
test('scan validation rejects missing, unsafe, excessive and unsupported targets before starting', () => {
  for (const bad of [{ rknURLs: '' }, { youtubeURL: 'http://youtube.com/' }, { discordURL: 'https://user:pass@discord.com/' }, { rknURLs: Array.from({ length: 33 }, (_, n) => `https://site${n}.org/`).join('\n') }]) assert.throws(() => scanTargets({ ...scan, ...bad }))
  for (const available of [undefined, [], [0], [1, '2']]) assert.throws(() => scanStrategies(scan, available))
  assert.throws(() => scanStrategies({ ...scan, scanMode: 'single', strategies: [99] }, [1, 2]))
  assert.throws(() => scanStrategies({ ...scan, scanMode: 'single', strategies: [] }, [1, 2]))
})
test('coverage ranks green domains, keeps profiles separate and never treats warnings or baselines as winners', () => {
  const rows = [
    { profile: 3, strategy: 1, site: 'a', verdict: 'OK' }, { profile: 3, strategy: 1, site: 'b', verdict: 'WARN' },
    { profile: 3, strategy: 2, site: 'a', verdict: 'OK' }, { profile: 3, strategy: 2, site: 'b', verdict: 'OK' },
    { profile: 3, strategy: 0, site: 'b', verdict: 'OK' }, { profile: 1, strategy: 1, site: 'a', verdict: 'UNKNOWN' }
  ]
  assert.deepEqual(coverageSummary(rows), [{ profile: 1, strategy: 1, green: 0, checked: 1 }, { profile: 3, strategy: 2, green: 2, checked: 2 }, { profile: 3, strategy: 1, green: 1, checked: 2 }])
  assert.deepEqual(coverageSummary(rows.slice(0, 1)), [{ profile: 3, strategy: 1, green: 1, checked: 1 }])
})

const before: RouterStatus = { ok: true, session_id: 'one', strategy: 1, strategy_generation: 2, transport_generation: 'four', route_generation: 0, firewall_generation: 0, proxy: { host: '127.0.0.1', port: 41081, alive: true }, queue: { number: 65534, counter: 10, alive: true }, proof: { connection_match: 'verified', strategy_invocation: 'verified', route: 'kernel_route_verified' } }
const after = { ...before, queue: { ...before.queue, counter: 20 } }
const observed: Observation = { http_status: 200, dom_loaded: true, fresh_connection: true, functional: true, auth_required: false, errors: [] }
test('attempt timeout and definitive navigation failure skip retries without bypassing isolation checks', () => {
  const timeout = { ...observed, http_status: null, dom_loaded: false, functional: false, timed_out: true }
  assert.deepEqual(classify(before, after, timeout), { verdict: 'FAIL', reason: 'ATTEMPT_TIMEOUT' })
  assert.equal(classify(before, after, { ...timeout, timed_out: false }).reason, 'PAGE_LOAD_FAILED')
  assert.equal(classify(before, after, { ...timeout, functional: null }).verdict, 'UNKNOWN')
  assert.equal(classify(before, { ...after, queue: { ...before.queue, alive: false } }, timeout).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, functional: false }).reason, 'RETRY_REQUIRED')
})
test('an opened page with an unfinished playback check is UNKNOWN, never a failed strategy', () => {
  const timeout = { ...observed, timed_out: true, functional: false }
  assert.deepEqual(classify(before, after, timeout), { verdict: 'UNKNOWN', reason: 'FUNCTIONAL_CHECK_TIMED_OUT' })
  assert.equal(classify(before, after, { ...timeout, dom_loaded: false }).verdict, 'UNKNOWN')
  assert.equal(classify(before, after, { ...timeout, dom_loaded: false, http_status: null }).verdict, 'FAIL')
  assert.equal(classify(before, { ...after, queue: { ...before.queue, alive: false } }, timeout).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, timed_out: false }).verdict, 'OK')
})
test('bounded browser work times out, cancels and preserves failures', async () => {
  const never = new Promise<never>(() => {})
  const controller = new AbortController()
  assert.equal(await withinTimeout(Promise.resolve(42), 1000, controller.signal), 42)
  await assert.rejects(withinTimeout(never, 10, controller.signal), /ATTEMPT_TIMEOUT/)
  await assert.rejects(withinTimeout(Promise.resolve(42), 0, controller.signal), /ATTEMPT_TIMEOUT/)
  await assert.rejects(withinTimeout(Promise.reject(new Error('SCRIPT_ERROR')), 1000, controller.signal), /SCRIPT_ERROR/)
  const pending = withinTimeout(never, 1000, controller.signal); controller.abort()
  await assert.rejects(pending, /CANCELLED/)
})
test('DIRECT brackets strategy changes with a repeated reference on longer sweeps', () => { assert.deepEqual(strategySequence([1, 1]), [0, 1]); assert.deepEqual(strategySequence([1, 2, 3]), [0, 1, 0, 2, 3]) })
test('HTTP 200 alone never proves a strategy', () => { assert.equal(classify(before, after, { ...observed, functional: null }).verdict, 'UNKNOWN'); assert.equal(classify(before, { ...after, proof: { ...after.proof, connection_match: 'unavailable' } }, observed).verdict, 'UNKNOWN') })
test('an incomplete flow snapshot is unscored, while broken transport still stops the scan', () => {
  const missing = { ...after, proof: { ...after.proof, connection_match: 'unavailable' } }
  assert.deepEqual(classify(before, missing, observed), { verdict: 'UNKNOWN', reason: 'FLOW_EVIDENCE_INCOMPLETE' })
  for (const o of [{ ...observed, functional: false, timed_out: true }, observed]) assert.equal(classify(before, missing, o).verdict, 'UNKNOWN')
  for (const broken of [{ ...missing, queue: { ...missing.queue, alive: false } }, { ...missing, proxy: { ...missing.proxy, alive: false } }, { ...missing, transport_generation: 'changed' }, { ...missing, queue: { ...before.queue, counter: 9 } }]) assert.equal(classify(before, broken, observed).verdict, 'INVALID')
  const youtube = { ...observed, page_functional: true, video_hosts: ['video.googlevideo.com'] }
  const pair = classifyYouTube(before, missing, youtube)
  assert.equal(pair.page.verdict, 'UNKNOWN'); assert.equal(pair.video, null)
})
test('failed TCP connect is unscored, not a transport failure or a successful error page', () => {
  const start = { ...before, proxy: { ...before.proxy, connections_started: 0 }, queue: { ...before.queue, counter: 0 } }
  const end = { ...start, queue: { ...start.queue, counter: 2 }, proof: { connection_match: 'unavailable', strategy_invocation: 'unavailable', route: 'unavailable' }, flows: [] }
  const failed: Observation = { ...observed, http_status: null, fresh_connection: null, functional: false, timed_out: true, errors: ['net::ERR_SOCKS_CONNECTION_FAILED'] }
  assert.deepEqual(classify(start, end, failed), { verdict: 'UNKNOWN', reason: 'CONNECTION_NOT_ESTABLISHED' })
  assert.equal(classify(start, { ...end, queue: start.queue }, failed).reason, 'NO_TEST_QUEUE_TRAFFIC')
  assert.equal(classify(start, end, { ...failed, functional: true }).verdict, 'UNKNOWN')
  const pair = classifyYouTube(start, end, { ...failed, page_functional: false })
  assert.equal(pair.page.verdict, 'UNKNOWN'); assert.equal(pair.video, null)
  assert.equal(classify(start, { ...end, proxy: { ...end.proxy, alive: false } }, failed).verdict, 'INVALID')
})
test('HTTP2 reuse inside a fresh attempt is valid; document and media each require host proof', () => {
  const start = { ...before, proxy: { ...before.proxy, connections_started: 0 } }
  const end = { ...after, proxy: { ...after.proxy, connections_started: 3 }, proof: { ...after.proof, verified_hosts: ['www.youtube.com', 'video.googlevideo.com'] } }
  const youtube = { ...observed, requested_host: 'www.youtube.com', required_hosts: ['video.googlevideo.com'], fresh_connection: false }
  assert.equal(classify(start, end, youtube).verdict, 'OK')
  assert.equal(classify(start, { ...end, proof: { ...end.proof, verified_hosts: ['www.youtube.com'] } }, youtube).reason, 'MEDIA_FLOW_NOT_PROVEN')
  assert.equal(classify(start, { ...end, proof: { ...end.proof, verified_hosts: ['video.googlevideo.com'] } }, youtube).reason, 'DOCUMENT_FLOW_NOT_PROVEN')
  assert.equal(classify(start, { ...end, proof: { ...end.proof, verified_hosts: ['www.youtube.com'] } }, youtube).verdict, 'UNKNOWN')
  assert.equal(classify(start, { ...end, proof: { ...end.proof, verified_hosts: ['video.googlevideo.com'] } }, youtube).verdict, 'UNKNOWN')
  assert.equal(classify({ ...start, proxy: { ...start.proxy, connections_started: 3 } }, end, youtube).verdict, 'UNKNOWN')
})
test('paired verdicts credit the page independently and require real GV traffic before scoring video', () => {
  const end = { ...after, proof: { ...after.proof, verified_hosts: ['www.youtube.com', 'video.googlevideo.com'] } }
  const video = { ...observed, requested_host: 'www.youtube.com', required_hosts: ['video.googlevideo.com'], video_hosts: ['video.googlevideo.com'], page_functional: true }
  assert.equal(classifyYouTube(before, end, video).page.verdict, 'OK')
  assert.equal(classifyYouTube(before, end, video).video?.verdict, 'OK')
  const auxiliaryError = classifyYouTube(before, end, { ...video, errors: ['net::ERR_ABORTED'] })
  assert.equal(auxiliaryError.page.verdict, 'OK'); assert.equal(auxiliaryError.video?.verdict, 'OK')
  const stopped = classifyYouTube(before, end, { ...video, functional: false, timed_out: true })
  assert.equal(stopped.page.verdict, 'OK'); assert.equal(stopped.video?.verdict, 'FAIL')
  assert.equal(stopped.video?.reason, 'VIDEO_PLAYBACK_TIMEOUT')
  assert.equal(classifyYouTube(before, end, { ...video, video_hosts: [], functional: null }).video, null)
  assert.equal(classifyYouTube(before, end, { ...video, page_functional: false, dom_loaded: false, http_status: null, timed_out: true }).video, null)
  assert.equal(classifyYouTube(before, { ...end, gv_strategy: 2 }, video).page.verdict, 'INVALID')
})
test('generation, fresh connection, queue and route are required', () => {
  for (const value of [{ ...after, session_id: 'other' }, { ...after, route_generation: 2 }, { ...after, strategy_generation: 3 }, { ...after, transport_generation: 'changed' }, { ...after, queue: { ...before.queue, counter: 9 } }]) assert.equal(classify(before, value, observed).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, fresh_connection: true }).verdict, 'OK')
  assert.equal(classify(before, after, { ...observed, fresh_connection: false }).verdict, 'UNKNOWN')
  assert.equal(classify(before, after, { ...observed, evidence_complete: false }).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, auth_required: true }).verdict, 'UNKNOWN')
  assert.equal(classify(before, after, { ...observed, errors: ['net::ERR_FAILED'] }).verdict, 'WARN')
  assert.equal(classify(before, after, { ...observed, requested_host: 'example.org' }).verdict, 'UNKNOWN')
  assert.equal(classify(before, after, { ...observed, expected_origin: false }).verdict, 'UNKNOWN')
})
test('private URL components and unsupported transports are rejected/redacted', () => {
  for (const url of ['http://example.org/', 'https://user:pass@example.org/', 'file:///etc/passwd', 'https://[::1]/', 'https://example.org:8443/']) assert.throws(() => safeURL(url))
  assert.equal(redactURL('https://user:pass@example.org/private-token?q=secret#password'), 'https://example.org/')
  assert.equal(safeURL('https://example.org/'), 'https://example.org/')
})
test('SSH options cannot become options or shell syntax', () => {
  for (const host of ['-oProxyCommand=evil', 'router;reboot', 'x\nreboot', 'root@router']) assert.throws(() => validateSSH({ host, user: 'root', port: 22, identity: '' }))
  validateSSH({ host: '192.168.10.1', user: 'root', port: 22, identity: 'C:\\Users\\someone\\.ssh\\router key' })
})
