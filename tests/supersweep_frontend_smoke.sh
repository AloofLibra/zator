#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/../webui-src"
node --input-type=module <<'NODE'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'
import { parse, compileTemplate } from '@vue/compiler-sfc'

const path = 'src/components/strategies/SupersweepPanel.vue'
assert.ok(fs.existsSync(path), 'Strategies needs a read-only SupersweepPanel')
const source = fs.readFileSync(path, 'utf8')
const view = fs.readFileSync('src/views/StrategiesView.vue', 'utf8')
assert.match(view, /<SupersweepPanel\s*\/>/)
assert.match(view, /recommendations-banner/)
assert.match(view, /<StrategyCard /)
assert.match(source, /id="supersweep-refresh-btn"/)
assert.doesNotMatch(source, /v-html|withBusy/)
const endpoints = fs.readFileSync('src/api/endpoints.ts', 'utf8')
assert.match(endpoints, /fetchSupersweep\s*=\s*\(signal\?: AbortSignal\)\s*=>\s*api<SupersweepPayload>\('\/cgi-bin\/settings\.cgi\?setting=supersweep',\s*\{ signal \}\)/)
const { descriptor } = parse(source)
assert.deepEqual(compileTemplate({ source: descriptor.template.content, filename: path, id: 'smoke' }).errors, [])
const script = descriptor.scriptSetup.content.replace(/^import .*$/gm, '')
const code = ts.transpileModule(script + '\n;globalThis.panel = { refresh, data, error, loading };', {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None },
}).outputText
let mount, unmount, visibility
let nextTimer = 0
const timers = new Map()
const requests = []
const document = {
  hidden: false,
  addEventListener(name, fn) { assert.equal(name, 'visibilitychange'); visibility = fn },
  removeEventListener(name, fn) { assert.equal(name, 'visibilitychange'); assert.equal(fn, visibility); visibility = null },
}
const context = {
  ref: (value) => ({ value }), computed: (fn) => ({ get value() { return fn() } }),
  onMounted: (fn) => { mount = fn }, onUnmounted: (fn) => { unmount = fn },
  AbortController, document,
  window: {
    setTimeout(fn, delay) { const id = ++nextTimer; timers.set(id, { fn, delay }); return id },
    clearTimeout(id) { timers.delete(id) },
  },
  fetchSupersweep: (signal) => new Promise((resolve, reject) => {
    requests.push({ resolve, reject, signal })
    signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true })
  }),
}
vm.createContext(context)
vm.runInContext(code, context)
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve() }
const fire = async (delay) => {
  const entry = [...timers].find(([, timer]) => timer.delay === delay)
  assert.ok(entry, `expected ${delay}ms timer`)
  timers.delete(entry[0]); entry[1].fn(); await flush()
}
const snapshot = {
  available: true, state: 'running', active: true, source: 'live', started: 1, updated: 2,
  scope: 'default', phase: 'rkn', completed: 2, total: 10, workers: [], applied: [], domains: [],
}
mount()
assert.equal(requests.length, 1)
await context.panel.refresh()
assert.equal(requests.length, 1, 'manual refresh must not overlap')
requests[0].resolve(snapshot); await flush()
assert.equal(context.panel.data.value, snapshot)
await fire(5000)
assert.equal(requests.length, 2)
requests[1].reject(new Error('offline')); await flush()
assert.equal(context.panel.data.value, snapshot, 'retain last known result on failure')
assert.ok(context.panel.error.value, 'failure must be visible')
assert.match(source, /устаревш/i, 'retained data must be labelled stale')
document.hidden = true; visibility(); await flush()
assert.equal(timers.size, 0, 'hidden page stops timers')
document.hidden = false; visibility(); await flush()
assert.equal(requests.length, 3, 'visible page refreshes immediately')
requests[2].resolve({ ...snapshot, state: 'done', active: false, source: 'saved' }); await flush()
await fire(15000)
assert.equal(requests.length, 4)
await fire(12000)
assert.equal(requests[3].signal.aborted, true, 'request timeout aborts fetch')
assert.ok(context.panel.error.value)
void context.panel.refresh()
await flush()
assert.equal(requests.length, 5)
unmount(); await flush()
assert.equal(requests[4].signal.aborted, true, 'unmount aborts fetch')
assert.equal(timers.size, 0)
assert.equal(visibility, null)
assert.equal(context.panel.loading.value, false)
console.log('supersweep frontend smoke ok: wiring, polling, visibility, stale error, timeout, unmount')
NODE
