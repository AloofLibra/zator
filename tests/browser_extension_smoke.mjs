import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import { webcrypto } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const manifest = JSON.parse(readFileSync(resolve(root, 'browser-extension/manifest.json'), 'utf8'))
const popup = readFileSync(resolve(root, 'browser-extension/popup.html'), 'utf8')
const popupScript = readFileSync(resolve(root, 'browser-extension/popup.js'), 'utf8')
const options = readFileSync(resolve(root, 'browser-extension/options.html'), 'utf8')
const optionsScript = readFileSync(resolve(root, 'browser-extension/options.js'), 'utf8')
assert.equal(manifest.manifest_version, 3)
assert.match(popup, /eligible network failures start a scoped trial automatically/i)
assert.match(popup, /YouTube media retries may reload the watch page once/i)
assert.doesNotMatch(popup, /No automatic reloads/i)
assert.match(popupScript, /UNKNOWN: "outcome unknown; no candidate advanced"/)
assert.match(popupScript, /multiple recent connections match; no trial started/)
assert.match(popupScript, /NOT_TESTED: "not counted; no confirmed new flow"/)
assert.match(popupScript, /TCP_FALLBACK: "browser used TCP; QUIC strategy was not tested"/)
assert.match(popupScript, /AUTOROTATION_DISABLED: "enable router autorotation to test a strategy"/)
assert.match(popupScript, /Router autorotation:/)
assert.match(popupScript, /Router API is unreachable\. Check the router address, network, and API service\./)
assert.match(popupScript, /Router rejected this pairing\. Pair the extension again in Settings\./)
assert.match(popupScript, /Router browser API is unavailable\. Update or enable it on the router\./)
assert.match(popupScript, /profile default/)
assert.doesNotMatch(popupScript, /automatic start/)
assert.match(popupScript, /row\.request_class \|\| "unknown request"/)
assert.match(popupScript, /waiting for a repeat/)
assert.match(popupScript, /no eligible automatic trigger/)
assert.ok(manifest.permissions.includes('webRequest'))
assert.ok(manifest.permissions.includes('scripting'))
assert.ok(!manifest.permissions.includes('webNavigation'), 'extension must not request an unused navigation permission')
assert.ok(manifest.optional_host_permissions.includes('<all_urls>'))
assert.match(options, /Allow media quality sampling during active Googlevideo trials/)
assert.match(options, /Allow a short Googlevideo Ramp canary/)
assert.match(optionsScript, /config\.mediaQualityOptIn === true/, 'media sampling must default off unless explicitly enabled')
assert.match(optionsScript, /config\.rampCanaryOptIn === true/, 'Ramp canary consent must default off')
assert.match(optionsScript, /mediaQualityOptIn: mediaQualityOptIn\.checked/)
assert.match(optionsScript, /rampCanaryOptIn: rampCanaryOptIn\.checked/)

const listeners = { failure: null, completed: null, message: null }
const routerToken = 'a'.repeat(48)
const sent = []
const reloads = []
let pageTimingEntries = []
let currentTabUrl = 'https://video.example.test/watch?v=secret'
let scriptedMediaResult = null
const fakeRouter = createServer(async (request, response) => {
  const chunks = []
  for await (const chunk of request) chunks.push(chunk)
  const body = Buffer.concat(chunks).toString('utf8')
  const action = new URLSearchParams(body).get('action')
  if (action !== 'browser_attempt_status') sent.push({ url: request.url, authorization: request.headers.authorization, body })
  if (request.headers.authorization !== `Bearer ${routerToken}`) {
    response.writeHead(401, { 'content-type': 'application/json' }).end('{"error":"invalid token"}')
    return
  }
  const params = new URLSearchParams(body)
  if (action === 'browser_report_result' && params.get('attempt_id') === 'z'.repeat(32)) {
    response.writeHead(503, { 'content-type': 'application/json' }).end('{"error":"temporarily unavailable"}')
    return
  }
  const result = action === 'browser_report_failure' && params.get('hostname') === 'video.example.test'
    ? { schema_version: 1, state: 'WAIT_NEW_FLOW', attempt_id: 'a'.repeat(32), expires_at: Math.floor(Date.now() / 1000) + 45 }
    : action === 'browser_report_failure' && params.get('hostname') === 'media.example.test'
      ? { schema_version: 1, state: 'WAIT_NEW_FLOW', attempt_id: 'c'.repeat(32), expires_at: Math.floor(Date.now() / 1000) + 45 }
      : action === 'browser_report_failure' && params.get('hostname')?.endsWith('.googlevideo.com')
        ? { schema_version: 1, state: 'WAIT_NEW_FLOW', attempt_id: '6'.repeat(32), expires_at: Math.floor(Date.now() / 1000) + 180 }
    : action === 'browser_attempt_status'
      ? params.get('attempt_id') === 'w'.repeat(32)
        ? { schema_version: 1, state: 'EXPIRED' }
        : { schema_version: 1, state: 'FLOW_CONFIRMED', ramp_treatment: 'applied', ramp_ack_evidence: 'confirmed' }
      : action === 'browser_report_result'
        ? params.get('attempt_id') === 'g'.repeat(32)
          ? { schema_version: 1, state: 'UNKNOWN', status: 'PROTOCOL_UNKNOWN', reason: 'h3_protocol_evidence_unavailable' }
          : params.get('attempt_id') === 'p'.repeat(32)
            ? { schema_version: 1, state: 'NEXT_CANDIDATE', next_attempt: { state: 'WAIT_NEW_FLOW', attempt_id: '1'.repeat(32), expires_at: Math.floor(Date.now() / 1000) + 45 } }
          : { schema_version: 1, state: params.get('result') === 'network_failure' ? 'NEXT_CANDIDATE' : 'PROVISIONAL_SUCCESS' }
        : { schema_version: 1, state: action === 'browser_cancel_attempt' ? 'CANCELLED' : 'WAITING_FOR_NEW_FLOW' }
  response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(result))
})
await new Promise(resolve => fakeRouter.listen(0, '127.0.0.1', resolve))
const fakeRouterAddress = fakeRouter.address()
const stored = { config: { router: `http://127.0.0.1:${fakeRouterAddress.port}/`, token: routerToken }, events: [], seen: [], resourceErrors: [] }
const chrome = {
  storage: { local: {
    get: async defaults => ({ ...defaults, ...structuredClone(stored) }),
    setAccessLevel: async () => {},
    set: async patch => Object.assign(stored, structuredClone(patch))
  } },
  webRequest: {
    onErrorOccurred: { addListener: fn => { listeners.failure = fn } },
    onCompleted: { addListener: fn => { listeners.completed = fn } }
  },
  tabs: {
    get: async id => ({ id, url: currentTabUrl }),
    reload: async (id, options) => { reloads.push({ id, options }) }
  },
  scripting: { executeScript: async spec => spec.args?.length
    ? [{ result: spec.func(...spec.args) }]
    : [{ result: scriptedMediaResult }] },
  runtime: { onMessage: { addListener: fn => { listeners.message = fn } } }
}
const context = {
  chrome, URL, URLSearchParams, AbortController, setTimeout, clearTimeout,
  crypto: webcrypto,
  performance: { getEntriesByType: type => pageTimingEntries.filter(entry => entry.entryType === type) },
  TextEncoder,
  fetch: globalThis.fetch,
  __Z2R_BROWSER_TEST__: {}
}
context.globalThis = context
vm.runInNewContext(readFileSync(resolve(root, 'browser-extension/service-worker.js'), 'utf8'), context)
const api = context.__Z2R_BROWSER_TEST__.api

stored.config.mediaQualityOptIn = true
scriptedMediaResult = { quality: 'healthy', sample_ms: 8000, progress_ms: 7000, stall_ms: 0, dropped_frames: 1, total_frames: 240 }
assert.deepEqual(JSON.parse(JSON.stringify(await api.readMediaQuality(2))), scriptedMediaResult)
scriptedMediaResult = null
assert.equal((await api.readMediaQuality(2)).quality, 'unknown', 'missing video must remain unknown')

assert.equal(api.failureClass('net::ERR_CONNECTION_RESET'), 'network_failure')
assert.equal(api.failureClass('net::ERR_SOCKET_NOT_CONNECTED'), 'network_failure')
assert.equal(api.failureClass('net::ERR_NAME_NOT_RESOLVED'), '')
assert.equal(api.failureClass('net::ERR_CERT_DATE_INVALID'), '')
assert.equal(api.failureClass('net::ERR_CONNECTION_ABORTED'), '')
assert.equal(api.failureClass('net::ERR_ADDRESS_UNREACHABLE'), '', 'missing route must not trigger strategy rotation')
assert.equal(api.failureClass('net::ERR_SSL_HANDSHAKE_NOT_COMPLETED'), 'network_failure')
assert.equal(api.failureClass('net::ERR_SSL_VERSION_OR_CIPHER_MISMATCH'), 'network_failure')
assert.equal(api.failureClass('net::ERR_QUIC_HANDSHAKE_FAILED'), 'network_failure')
assert.equal(api.failureClass('net::ERR_SSL_CLIENT_AUTH_CERT_NEEDED'), '')
assert.equal(api.failureTransport('net::ERR_QUIC_HANDSHAKE_FAILED'), 'quic')
assert.equal(api.failureTransport('net::ERR_SSL_HANDSHAKE_NOT_COMPLETED'), 'tls')
assert.equal(api.failureTransport('net::ERR_CONNECTION_RESET'), 'unknown')
pageTimingEntries = [{ entryType: 'resource', name: 'https://quic.example.test/video?sig=private', nextHopProtocol: 'h3' }]
assert.equal(await api.readBrowserProtocol(2, 'https://quic.example.test/video?sig=private'), 'h3')
pageTimingEntries.push({ entryType: 'resource', name: 'https://quic.example.test/video?sig=other', nextHopProtocol: 'h2' })
assert.equal(await api.readBrowserProtocol(2, 'https://quic.example.test/video?sig=private'), '', 'ambiguous timing entries must not prove protocol')
pageTimingEntries = [{ entryType: 'resource', name: 'https://quic.example.test/video?sig=private', nextHopProtocol: 'h2' }]
assert.equal(await api.readBrowserProtocol(2, 'https://quic.example.test/video?sig=private'), 'tcp')
pageTimingEntries = []
assert.equal(api.safeHost('https://router.home.arpa/path'), '')

const main = await api.rememberFailure({ tabId: 2, documentId: 'doc-a', requestId: 'req-a', type: 'main_frame', method: 'GET',
  url: 'https://video.example.test/watch?v=secret', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(main.trigger, 'main_frame_network_failure')
assert.equal(sent.length, 1)
assert.equal(sent[0].url, '/cgi-bin/adaptive-browser.cgi')
assert.equal(sent[0].authorization, `Bearer ${routerToken}`)
const posted = new URLSearchParams(sent[0].body)
assert.equal(posted.get('hostname'), 'video.example.test')
assert.equal(posted.get('trigger'), 'main_frame_network_failure')
assert.equal(posted.get('failure_count'), '1')
assert.equal(posted.get('failure_transport'), 'unknown')
assert.equal(reloads.length, 1, 'eligible main-frame GET should retry once after trial setup')
assert.equal(reloads[0].id, 2)
assert.equal(reloads[0].options.bypassCache, true)
assert.equal(posted.has('url'), false)
assert.equal(posted.has('tabId'), false)
assert.equal(posted.has('client_ip'), false)
assert.ok(!sent[0].body.includes('/watch') && !sent[0].body.includes('secret'))
assert.equal(stored.events.at(-1).tab_id, 2, 'tab ID is retained locally for the popup only')

const duplicate = await api.rememberFailure({ tabId: 2, documentId: 'doc-a', requestId: 'req-a', type: 'main_frame', method: 'GET',
  url: 'https://video.example.test/watch?v=secret', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(duplicate.ignored, 'duplicate')
assert.equal(sent.length, 1)

const retryEvent = { trigger: 'main_frame_network_failure', request_class: 'main_frame', method: 'GET', failure_class: 'network_failure', tab_id: 2, hostname: 'video.example.test' }
await api.retryFailedGetOnce(retryEvent, { ok: true, data: { state: 'WAIT_NEW_FLOW', attempt_id: 'a'.repeat(32) } })
assert.equal(reloads.length, 1, 'a second response for one attempt must not cause a reload loop')

currentTabUrl = 'https://another.example.test/'
await api.retryFailedGetOnce({ ...retryEvent, tab_id: 9 }, { ok: true, data: { state: 'WAIT_NEW_FLOW', attempt_id: 'b'.repeat(32) } })
assert.equal(reloads.length, 1, 'do not reload a tab after the user navigated elsewhere')
currentTabUrl = 'https://video.example.test/watch?v=secret'

const dns = await api.rememberFailure({ tabId: 2, requestId: 'req-dns', type: 'main_frame', method: 'GET',
  url: 'https://dns.example.test/', error: 'net::ERR_NAME_NOT_RESOLVED', timeStamp: Date.now() })
assert.equal(dns.ignored, 'not_eligible')
const unsafe = await api.rememberFailure({ tabId: 2, requestId: 'req-post', type: 'main_frame', method: 'POST',
  url: 'https://pay.example.test/submit', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(unsafe.trigger, 'observe_only')
assert.equal(sent.length, 1)
assert.equal(reloads.length, 1, 'POST failure must never be auto-replayed')
const head = await api.rememberFailure({ tabId: 2, requestId: 'req-head', type: 'main_frame', method: 'HEAD',
  url: 'https://head.example.test/', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(head.trigger, 'observe_only')
assert.equal(sent.length, 1)

const subresource = (requestId, path = '/chunk/a', type = 'xmlhttprequest') => ({ tabId: 8, documentId: 'doc-resource', requestId, type, method: 'GET',
  url: `https://media.example.test${path}?private=1`, error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now(), ip: '8.8.8.8' })
const firstResource = await api.rememberFailure(subresource('sub-1'))
assert.equal(firstResource.trigger, 'observe_only')
const differentResource = await api.rememberFailure(subresource('sub-other', '/chunk/b'))
assert.equal(differentResource.trigger, 'observe_only', 'different subresources on one host must not be grouped')
const secondResource = await api.rememberFailure(subresource('sub-2', '/chunk/a'))
assert.equal(secondResource.trigger, 'critical_resource_repeated_failure')
const secondResourceEvent = stored.events.find(row => row.id === secondResource.event_id)
assert.match(secondResourceEvent.resource_identity, /^[a-f0-9]{64}$/)
assert.ok(!JSON.stringify(secondResourceEvent).includes('/chunk') && !JSON.stringify(secondResourceEvent).includes('private'))
assert.equal(sent.length, 2)
assert.equal(new URLSearchParams(sent[1].body).get('failure_count'), '2')
assert.ok(!sent[1].body.includes('/chunk') && !sent[1].body.includes('private'))
assert.ok(stored.resourceErrors.every(row => !JSON.stringify(row).includes('/chunk') && !JSON.stringify(row).includes('private')))
const image = await api.rememberFailure(subresource('image-1', '/chunk/a', 'image'))
assert.equal(image.trigger, 'observe_only')
assert.equal(sent.length, 2)

currentTabUrl = 'https://www.youtube.com/watch?v=test'
const googlevideoFailure = (requestId, host) => ({ tabId: 10, documentId: 'doc-googlevideo', requestId, type: 'media', method: 'GET',
  url: `https://${host}/videoplayback?private=1`, error: 'net::ERR_CONNECTION_CLOSED', timeStamp: Date.now(), ip: '8.8.8.8' })
const firstGooglevideoFailure = await api.rememberFailure(googlevideoFailure('gv-1', 'rr2---sn-h5gtov-n8vl.googlevideo.com'))
assert.equal(firstGooglevideoFailure.trigger, 'observe_only')
const secondGooglevideoFailure = await api.rememberFailure(googlevideoFailure('gv-2', 'rr5---sn-8ph2xajvh-n8vs.googlevideo.com'))
assert.equal(secondGooglevideoFailure.trigger, 'critical_resource_repeated_failure', 'same media path across Googlevideo CDN hosts must start an automatic trial')
assert.equal(sent.length, 3)
assert.equal(new URLSearchParams(sent[2].body).get('hostname'), 'rr5---sn-8ph2xajvh-n8vs.googlevideo.com', 'trial target must be the actual failed CDN host')
assert.equal(reloads.length, 2, 'an approved Googlevideo media trial should automatically retry the YouTube GET once')
assert.equal(reloads[1].id, 10)
assert.equal(reloads[1].options.bypassCache, true)
currentTabUrl = 'https://video.example.test/watch?v=secret'

const manual = await api.requestCurrentPageFix('https://manual.example.test/path?secret=1', 5)
assert.equal(manual.ok, true)
assert.equal(sent.length, 4)
const manualBody = new URLSearchParams(sent[3].body)
assert.equal(manualBody.get('trigger'), 'user_fix')
assert.equal(manualBody.get('failure_class'), 'user_requested')
assert.equal(manualBody.get('hostname'), 'manual.example.test')
assert.ok(!sent[3].body.includes('/path') && !sent[3].body.includes('secret'))

stored.config.token = 'x'.repeat(48)
const badToken = await api.requestCurrentPageFix('https://manual.example.test/', 5)
assert.equal(badToken.ok, false)
assert.equal(sent.length, 5)
assert.equal(sent[4].authorization, `Bearer ${'x'.repeat(48)}`)
stored.config.token = routerToken

const resultRequestsBefore = sent.filter(row => new URLSearchParams(row.body).get('action') === 'browser_report_result').length
await api.recordHttpResponse({ tabId: 8, type: 'xmlhttprequest', method: 'GET', statusCode: 206, fromCache: false,
  url: 'https://media.example.test/chunk/b?private=1', ip: '8.8.8.8' })
assert.equal(sent.filter(row => new URLSearchParams(row.body).get('action') === 'browser_report_result').length, resultRequestsBefore,
  'a different resource on the same hostname must not confirm recovery')
await api.recordHttpResponse({ tabId: 8, type: 'xmlhttprequest', method: 'GET', statusCode: 206, fromCache: true,
  url: 'https://media.example.test/chunk/a?private=1', ip: '8.8.8.8' })
assert.equal(sent.filter(row => new URLSearchParams(row.body).get('action') === 'browser_report_result').length, resultRequestsBefore,
  'cached resource success must not confirm recovery')
await api.recordHttpResponse({ tabId: 8, type: 'xmlhttprequest', method: 'GET', statusCode: 206, fromCache: false,
  url: 'https://media.example.test/chunk/a?private=1', ip: '8.8.8.8' })
const resourceAttempt = stored.events.find(row => row.hostname === 'media.example.test' && row.attempt_id)
const reportedResultCount = sent.filter(row => new URLSearchParams(row.body).get('action') === 'browser_report_result').length
const unrelatedPostTrialFailure = await api.rememberFailure(subresource('sub-unrelated', '/chunk/c'))
assert.equal(unrelatedPostTrialFailure.trigger, 'observe_only')
assert.equal(sent.filter(row => new URLSearchParams(row.body).get('action') === 'browser_report_result').length, reportedResultCount,
  'an unrelated subresource failure must not be charged to the active trial')
const exactPostTrialFailure = await api.rememberFailure(subresource('sub-retry-failed', '/chunk/a'))
assert.equal(exactPostTrialFailure.trigger, 'attempt_result', 'matching post-trial critical-resource failure was not correlated')
await api.queueSyncAttempt(resourceAttempt.id)
const resourceResultRequests = sent.filter(row => new URLSearchParams(row.body).get('action') === 'browser_report_result')
assert.equal(resourceResultRequests.length, 2, 'both overlapping outcomes must be reported')
const resourceResultRequest = resourceResultRequests[0]
const resourceFailureRequest = resourceResultRequests[1]
assert.equal(new URLSearchParams(resourceResultRequest.body).get('result'), 'network_success', 'the first outcome must be serialized first')
assert.equal(new URLSearchParams(resourceResultRequest.body).get('request_class'), 'xmlhttprequest')
assert.equal(new URLSearchParams(resourceResultRequest.body).get('browser_ip'), '8.8.8.8')
assert.equal(new URLSearchParams(resourceResultRequest.body).has('ramp_canary_opt_in'), false,
  'ordinary trial results must not carry Ramp canary consent')
assert.ok(!resourceResultRequest.body.includes('/chunk') && !resourceResultRequest.body.includes('private'),
  'resource URLs must not be sent to the router')
assert.equal(new URLSearchParams(resourceFailureRequest.body).get('result'), 'network_failure')
assert.equal(new URLSearchParams(resourceFailureRequest.body).get('request_class'), 'xmlhttprequest')
assert.equal(stored.events.find(row => row.id === resourceAttempt.id).pending_results.length, 0,
  'confirmed serialized outcomes should drain the bounded local result queue')

await api.recordHttpResponse({ tabId: 2, type: 'main_frame', statusCode: 503, url: 'https://server.example.test/path' })
assert.equal(sent.length, 7)
assert.equal(stored.events.at(-1).trigger, 'manual_only')
assert.ok(!Object.keys(stored.events.at(-1)).includes('url'))

const googlevideoUrl = 'https://rr1---sn-a5mekn6e.googlevideo.com/videoplayback?sig=private'
const googlevideoPath = `googlevideo.com${new URL(googlevideoUrl).pathname}`
const googlevideoHash = Array.from(new Uint8Array(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(googlevideoPath))),
  x => x.toString(16).padStart(2, '0')).join('')
const googlevideoAttempt = '4'.repeat(32)
const googlevideoEvent = '5'.repeat(32)
stored.config.rampCanaryOptIn = true
stored.events.push({ id: googlevideoEvent, hostname: 'rr1---sn-a5mekn6e.googlevideo.com', tab_id: 42, attempt_id: googlevideoAttempt,
  router_status: 'WAIT_NEW_FLOW', candidate_protocol: 'googlevideo-tcp', attempt_expires_at: Math.floor(Date.now() / 1000) + 40,
  trigger: 'critical_resource_repeated_failure', request_class: 'media', resource_identity: googlevideoHash })
scriptedMediaResult = { quality: 'healthy', sample_ms: 8000, progress_ms: 7000, stall_ms: 0, dropped_frames: 1, total_frames: 240 }
await api.recordHttpResponse({ tabId: 42, type: 'media', method: 'GET', statusCode: 206, fromCache: false, url: googlevideoUrl, ip: '8.8.8.8' })
await api.queueSyncAttempt(googlevideoEvent)
const googlevideoResult = sent.map(row => new URLSearchParams(row.body)).findLast(params =>
  params.get('action') === 'browser_report_result' && params.get('attempt_id') === googlevideoAttempt)
assert.ok(googlevideoResult, 'active Googlevideo trial did not report its result')
assert.equal(googlevideoResult.get('media_quality'), 'healthy')
assert.equal(googlevideoResult.get('ramp_canary_opt_in'), '1')
assert.equal(googlevideoResult.get('media_sample_ms'), '8000')
assert.equal(googlevideoResult.get('media_progress_ms'), '7000')
assert.equal(googlevideoResult.get('media_stall_ms'), '0')
assert.equal(googlevideoResult.get('media_dropped_frames'), '1')
assert.equal(googlevideoResult.get('media_total_frames'), '240')
assert.ok(!JSON.stringify(googlevideoResult).includes('videoplayback') && !JSON.stringify(googlevideoResult).includes('private'),
  'media evidence must not contain signed resource paths')

stored.events.push({ id: 'c'.repeat(32), hostname: 'video.example.test', tab_id: 2, attempt_id: 'd'.repeat(32), router_status: 'WAIT_NEW_FLOW',
  pending_result: { id: 'e'.repeat(32) }, pending_results: [{ id: 'e'.repeat(32) }] })
const cancelled = await api.cancelAttempt('c'.repeat(32))
assert.equal(cancelled.ok, true)
assert.equal(cancelled.state, 'CANCELLED')
assert.equal(new URLSearchParams(sent.at(-1).body).get('action'), 'browser_cancel_attempt')
assert.equal(stored.events.at(-1).router_status, 'CANCELLED')
assert.deepEqual(stored.events.at(-1).pending_results, [], 'cancel must clear queued browser outcomes')
assert.equal(stored.events.at(-1).pending_result, null)

stored.events.push({ id: 'f'.repeat(32), hostname: 'video.example.test', tab_id: 2, attempt_id: 'w'.repeat(32), router_status: 'WAIT_NEW_FLOW',
  pending_result: { id: 'x'.repeat(32) }, pending_results: [{ id: 'x'.repeat(32) }] })
await api.syncAttempt('f'.repeat(32))
assert.equal(stored.events.at(-1).router_status, 'EXPIRED')
assert.deepEqual(stored.events.at(-1).pending_results, [], 'expired attempts must discard queued browser outcomes')
assert.equal(stored.events.at(-1).pending_result, null)

stored.events.push({ id: 'y'.repeat(32), hostname: 'quic.example.test', tab_id: 2, attempt_id: '2'.repeat(32),
  trigger: 'main_frame_network_failure', request_class: 'main_frame', method: 'GET', failure_class: 'network_failure',
  candidate_protocol: 'quic', router_status: 'FLOW_CONFIRMED' })
pageTimingEntries = [{ entryType: 'navigation', name: 'https://quic.example.test/video?sig=private', nextHopProtocol: 'h3' }]
await api.recordHttpResponse({ tabId: 2, type: 'main_frame', method: 'GET', statusCode: 200, fromCache: false,
  url: 'https://quic.example.test/video?sig=private', ip: '8.8.8.8' })
await api.queueSyncAttempt('y'.repeat(32))
const quicBrowserResult = sent.findLast(row => new URLSearchParams(row.body).get('action') === 'browser_report_result' &&
  new URLSearchParams(row.body).get('attempt_id') === '2'.repeat(32))
assert.equal(new URLSearchParams(quicBrowserResult.body).get('browser_protocol'), 'h3', 'only active QUIC attempts should report H3 timing evidence')

stored.events.push({ id: 'e'.repeat(32), hostname: 'rr1---sn-a.googlevideo.com', tab_id: 2,
  attempt_id: 'f'.repeat(32), router_status: 'WAIT_NEW_FLOW' })
await api.syncAttempt('e'.repeat(32))
assert.equal(stored.events.at(-1).router_status, 'FLOW_CONFIRMED')
assert.equal(stored.events.at(-1).ramp_treatment, 'applied', 'Ramp SYN evidence was not retained for the popup')
assert.equal(stored.events.at(-1).ramp_ack_evidence, 'confirmed', 'Ramp late-ACK evidence was not retained for the popup')
assert.match(popupScript, /applied on SYN/)
assert.match(popupScript, /late ACK/)

stored.events.push({ id: 'h'.repeat(32), hostname: 'rr1---sn-h.googlevideo.com', tab_id: 2,
  attempt_id: 'g'.repeat(32), router_status: 'FLOW_CONFIRMED',
  pending_result: { id: 'i'.repeat(32), result: 'network_success', request_class: 'main_frame', browser_ip: '8.8.8.8', observed_at: Date.now() } })
await api.syncAttempt('h'.repeat(32))
assert.equal(stored.events.at(-1).router_status, 'UNKNOWN')
assert.equal(stored.events.at(-1).router_reason, 'h3_protocol_evidence_unavailable')
assert.match(popupScript, /H3 protocol evidence unavailable; QUIC success not confirmed/)

stored.events.push({ id: 'r'.repeat(32), hostname: 'video.example.test', tab_id: 2, attempt_id: 'p'.repeat(32),
  trigger: 'main_frame_network_failure', request_class: 'main_frame', method: 'GET', failure_class: 'network_failure', router_status: 'FLOW_CONFIRMED',
  pending_result: { id: 's'.repeat(32), result: 'network_failure', request_class: 'main_frame', browser_ip: '8.8.8.8', observed_at: Date.now() } })
await api.syncAttempt('r'.repeat(32))
assert.equal(stored.events.at(-1).attempt_id, '1'.repeat(32), 'next server candidate must become the active attempt')
assert.equal(stored.events.at(-1).router_status, 'WAIT_NEW_FLOW')
assert.equal(reloads.length, 3, 'each server-issued candidate gets one controlled browser retry')
assert.ok(stored.autoRetriedAttempts.includes('1'.repeat(32)))

stored.events.push({ id: 'u'.repeat(32), hostname: 'video.example.test', tab_id: 2, attempt_id: 'z'.repeat(32),
  trigger: 'main_frame_network_failure', request_class: 'main_frame', method: 'GET', failure_class: 'network_failure', router_status: 'FLOW_CONFIRMED',
  pending_result: { id: 'v'.repeat(32), result: 'network_failure', request_class: 'main_frame', browser_ip: '8.8.8.8', observed_at: Date.now() } })
const disconnectedResult = await api.syncAttempt('u'.repeat(32))
assert.equal(disconnectedResult.ok, false, 'router result failure must be surfaced')
assert.equal(stored.events.at(-1).attempt_id, 'z'.repeat(32), 'router failure must not invent or select a candidate')
assert.equal(stored.events.at(-1).pending_results.length, 1, 'unacknowledged browser result must remain queued')
assert.equal(reloads.length, 3, 'router failure must not trigger another browser reload')

stored.events.push({ id: 'l'.repeat(32), hostname: 'media.example.test', tab_id: 8, attempt_id: 'm'.repeat(32),
  trigger: 'critical_resource_repeated_failure', request_class: 'xmlhttprequest', router_status: 'FLOW_CONFIRMED',
  pending_result: { id: 'n'.repeat(32), result: 'network_success', request_class: 'xmlhttprequest', browser_ip: '8.8.8.8', observed_at: Date.now() },
  pending_results: [
    { id: 'n'.repeat(32), result: 'network_success', request_class: 'xmlhttprequest', browser_ip: '8.8.8.8', observed_at: Date.now() },
    { id: 'o'.repeat(32), result: 'network_failure', request_class: 'xmlhttprequest', browser_ip: '8.8.8.8', observed_at: Date.now() }
  ] })
const restartedListeners = { failure: null, completed: null, message: null }
const restartedChrome = { ...chrome, webRequest: {
  onErrorOccurred: { addListener: fn => { restartedListeners.failure = fn } },
  onCompleted: { addListener: fn => { restartedListeners.completed = fn } }
}, runtime: { onMessage: { addListener: fn => { restartedListeners.message = fn } } } }
const restartedContext = { ...context, chrome: restartedChrome, __Z2R_BROWSER_TEST__: {} }
restartedContext.globalThis = restartedContext
vm.runInNewContext(readFileSync(resolve(root, 'browser-extension/service-worker.js'), 'utf8'), restartedContext)
const restartedApi = restartedContext.__Z2R_BROWSER_TEST__.api
await restartedApi.syncAttempt('l'.repeat(32))
assert.equal(stored.events.at(-1).pending_results.length, 1, 'worker restart must preserve the remaining result queue')
assert.equal(stored.events.at(-1).pending_result.id, 'o'.repeat(32))
await restartedApi.syncAttempt('l'.repeat(32))
assert.equal(stored.events.at(-1).pending_results.length, 0, 'restarted worker should drain persisted browser outcomes')

for (const file of ['popup.js', 'options.js']) {
  assert.doesNotThrow(() => new vm.Script(readFileSync(resolve(root, `browser-extension/${file}`), 'utf8'), { filename: file }))
}
await new Promise((resolve, reject) => fakeRouter.close(error => error ? reject(error) : resolve()))
console.log('browser extension smoke: PASS')
