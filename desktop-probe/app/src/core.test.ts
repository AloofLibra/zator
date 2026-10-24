import { test } from 'node:test'
import assert from 'node:assert/strict'
import { classify, Observation, redactURL, RouterStatus, safeURL, validateSSH, strategySequence } from './core'

const before: RouterStatus = { ok: true, session_id: 'one', strategy: 1, strategy_generation: 2, transport_generation: 'four', route_generation: 0, firewall_generation: 0, proxy: { host: '127.0.0.1', port: 41081, alive: true }, queue: { number: 65534, counter: 10, alive: true }, proof: { connection_match: 'verified', strategy_invocation: 'verified', route: 'kernel_route_verified' } }
const after = { ...before, queue: { ...before.queue, counter: 20 } }
const observed: Observation = { http_status: 200, dom_loaded: true, fresh_connection: true, functional: true, auth_required: false, errors: [] }
test('DIRECT brackets strategy changes with a repeated reference on longer sweeps', () => { assert.deepEqual(strategySequence([1, 1]), [0, 1]); assert.deepEqual(strategySequence([1, 2, 3]), [0, 1, 0, 2, 3]) })
test('HTTP 200 alone never proves a strategy', () => { assert.equal(classify(before, after, { ...observed, functional: null }).verdict, 'UNKNOWN'); assert.equal(classify(before, { ...after, proof: { ...after.proof, connection_match: 'unavailable' } }, observed).verdict, 'INVALID') })
test('generation, fresh connection, queue and route are required', () => {
  for (const value of [{ ...after, session_id: 'other' }, { ...after, route_generation: 2 }, { ...after, strategy_generation: 3 }, { ...after, transport_generation: 'changed' }, { ...after, queue: before.queue }]) assert.equal(classify(before, value, observed).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, fresh_connection: true }).verdict, 'OK')
  assert.equal(classify(before, after, { ...observed, fresh_connection: false }).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, evidence_complete: false }).verdict, 'INVALID')
  assert.equal(classify(before, after, { ...observed, auth_required: true }).verdict, 'UNKNOWN')
  assert.equal(classify(before, after, { ...observed, errors: ['net::ERR_FAILED'] }).verdict, 'WARN')
  assert.equal(classify(before, after, { ...observed, requested_host: 'example.org' }).verdict, 'INVALID')
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
