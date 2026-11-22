import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const manifest = JSON.parse(readFileSync(resolve(root, 'browser-extension/manifest.json'), 'utf8'))
assert.equal(manifest.manifest_version, 3)
assert.ok(manifest.permissions.includes('webRequest'))
assert.ok(manifest.optional_host_permissions.includes('<all_urls>'))

const listeners = { failure: null, completed: null, message: null }
const routerToken = 'a'.repeat(48)
const sent = []
const fakeRouter = createServer(async (request, response) => {
  const chunks = []
  for await (const chunk of request) chunks.push(chunk)
  const body = Buffer.concat(chunks).toString('utf8')
  sent.push({ url: request.url, authorization: request.headers.authorization, body })
  if (request.headers.authorization !== `Bearer ${routerToken}`) {
    response.writeHead(401, { 'content-type': 'application/json' }).end('{"error":"invalid token"}')
    return
  }
  response.writeHead(200, { 'content-type': 'application/json' }).end('{"schema_version":1,"state":"WAITING_FOR_NEW_FLOW"}')
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
  runtime: { onMessage: { addListener: fn => { listeners.message = fn } } }
}
const context = {
  chrome, URL, URLSearchParams, AbortController, setTimeout, clearTimeout,
  crypto: { randomUUID: () => 'b'.repeat(32) },
  fetch: globalThis.fetch,
  __Z2R_BROWSER_TEST__: {}
}
context.globalThis = context
vm.runInNewContext(readFileSync(resolve(root, 'browser-extension/service-worker.js'), 'utf8'), context)
const api = context.__Z2R_BROWSER_TEST__.api

assert.equal(api.failureClass('net::ERR_CONNECTION_RESET'), 'network_failure')
assert.equal(api.failureClass('net::ERR_NAME_NOT_RESOLVED'), '')
assert.equal(api.failureClass('net::ERR_CERT_DATE_INVALID'), '')
assert.equal(api.failureClass('net::ERR_CONNECTION_ABORTED'), '')
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
assert.equal(posted.has('url'), false)
assert.equal(posted.has('tabId'), false)
assert.equal(posted.has('client_ip'), false)
assert.ok(!sent[0].body.includes('/watch') && !sent[0].body.includes('secret'))
assert.equal(stored.events.at(-1).tab_id, 2, 'tab ID is retained locally for the popup only')

const duplicate = await api.rememberFailure({ tabId: 2, documentId: 'doc-a', requestId: 'req-a', type: 'main_frame', method: 'GET',
  url: 'https://video.example.test/watch?v=secret', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(duplicate.ignored, 'duplicate')
assert.equal(sent.length, 1)

const dns = await api.rememberFailure({ tabId: 2, requestId: 'req-dns', type: 'main_frame', method: 'GET',
  url: 'https://dns.example.test/', error: 'net::ERR_NAME_NOT_RESOLVED', timeStamp: Date.now() })
assert.equal(dns.ignored, 'not_eligible')
const unsafe = await api.rememberFailure({ tabId: 2, requestId: 'req-post', type: 'main_frame', method: 'POST',
  url: 'https://pay.example.test/submit', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(unsafe.trigger, 'observe_only')
assert.equal(sent.length, 1)
const head = await api.rememberFailure({ tabId: 2, requestId: 'req-head', type: 'main_frame', method: 'HEAD',
  url: 'https://head.example.test/', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
assert.equal(head.trigger, 'observe_only')
assert.equal(sent.length, 1)

const subresource = (requestId, type = 'xmlhttprequest') => ({ tabId: 8, documentId: 'doc-resource', requestId, type, method: 'GET',
  url: 'https://media.example.test/chunk?private=1', error: 'net::ERR_CONNECTION_RESET', timeStamp: Date.now() })
const firstResource = await api.rememberFailure(subresource('sub-1'))
assert.equal(firstResource.trigger, 'observe_only')
const secondResource = await api.rememberFailure(subresource('sub-2'))
assert.equal(secondResource.trigger, 'critical_resource_repeated_failure')
assert.equal(sent.length, 2)
assert.equal(new URLSearchParams(sent[1].body).get('failure_count'), '2')
assert.ok(!sent[1].body.includes('/chunk') && !sent[1].body.includes('private'))
const image = await api.rememberFailure(subresource('image-1', 'image'))
assert.equal(image.trigger, 'observe_only')
assert.equal(sent.length, 2)

const manual = await api.requestCurrentPageFix('https://manual.example.test/path?secret=1', 5)
assert.equal(manual.ok, true)
assert.equal(sent.length, 3)
const manualBody = new URLSearchParams(sent[2].body)
assert.equal(manualBody.get('trigger'), 'user_fix')
assert.equal(manualBody.get('failure_class'), 'user_requested')
assert.equal(manualBody.get('hostname'), 'manual.example.test')
assert.ok(!sent[2].body.includes('/path') && !sent[2].body.includes('secret'))

stored.config.token = 'x'.repeat(48)
const badToken = await api.requestCurrentPageFix('https://manual.example.test/', 5)
assert.equal(badToken.ok, false)
assert.equal(sent.length, 4)
assert.equal(sent[3].authorization, `Bearer ${'x'.repeat(48)}`)
stored.config.token = routerToken

await api.recordHttpResponse({ tabId: 2, type: 'main_frame', statusCode: 503, url: 'https://server.example.test/path' })
assert.equal(sent.length, 4)
assert.equal(stored.events.at(-1).trigger, 'manual_only')
assert.ok(!Object.keys(stored.events.at(-1)).includes('url'))

for (const file of ['popup.js', 'options.js']) {
  assert.doesNotThrow(() => new vm.Script(readFileSync(resolve(root, `browser-extension/${file}`), 'utf8'), { filename: file }))
}
await new Promise((resolve, reject) => fakeRouter.close(error => error ? reject(error) : resolve()))
console.log('browser extension smoke: PASS')
