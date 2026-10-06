import assert from 'node:assert/strict'
import { createServer } from 'vite'
import { createSSRApp, createRenderer, h, nextTick } from 'vue'
import { routeLocationKey, routerKey } from 'vue-router'
import { renderToString } from 'vue/server-renderer'
import { readFileSync } from 'node:fs'

const server = await createServer({ server: { middlewareMode: true }, appType: 'custom' })
try {
  const { default: Card } = await server.ssrLoadModule('/src/components/strategies/StrategyCard.vue')
  const { tlsBlobSettings } = await server.ssrLoadModule('/src/stores/settings.ts')
  const { status } = await server.ssrLoadModule('/src/stores/status.ts')
  const data = { provider: 'TEST', samples: 24, minimum: 10, generated_at: 1700000000, status: 'ready', profiles: {
    '1': { samples: 24, top: [{ strategy: 7, success_pct: 92, samples: 12, mode: 'classic' }, { strategy: 99, success_pct: 80, samples: 8, mode: 'clone' }], clone_recommended: true, classic_pct: 55, clone_pct: 90 },
  } }
  async function card(payload = data, profile = '1') {
    const app = createSSRApp({ render: () => h(Card, { profile: { profile, label: 'TEST', current_lock: 'auto', max_strategy: 43 }, recommendations: payload }) })
    app.component('router-link', { props: ['to'], render() { return h('a', { href: this.to }, this.$slots.default()) } })
    return renderToString(app)
  }
  tlsBlobSettings.value = { profile_modes: {} }
  let html = await card()
  assert.match(html, /92%/, 'provider top strategies must render inside the existing card')
  assert.match(html, /12 установок/)
  assert.match(html, /Классический/)
  assert.match(html, /\/settings\/tls-blob/)
  assert.doesNotMatch(html, /99.*80%/)
  assert.doesNotMatch(await card({ ...data, profiles: { '1': { ...data.profiles['1'], top: [null, {}, ...data.profiles['1'].top] } } }), /NaN/)
  assert.doesNotMatch(await card({ ...data, status: 'insufficient', samples: 9 }), /92%|Попробуйте клон/)
  assert.doesNotMatch(await card(data, '5'), /92%|Попробуйте клон/)
  assert.match(await card({ ...data, status: 'stale' }), /92%/)
  tlsBlobSettings.value = { profile_modes: { '1': 'clone' } }
  assert.doesNotMatch(await card(), /Попробуйте клон/)
  status.value = { auto_mode: 'включен' }
  assert.match(await card(), /recommendation-choice[^>]*disabled/)
  const view = readFileSync('src/views/StrategiesView.vue', 'utf8')
  assert.match(view, /fetchRecommendations/)
  assert.match(view, /watch\(/)
  assert.doesNotMatch(readFileSync('src/stores/state.ts', 'utf8'), /fetchRecommendations/)
  const { default: View } = await server.ssrLoadModule('/src/views/StrategiesView.vue')
  const { statusLoaded } = await server.ssrLoadModule('/src/stores/status.ts')
  const { provider } = await server.ssrLoadModule('/src/stores/settings.ts')
  globalThis.window = { setTimeout, clearTimeout }
  const requests = []
  globalThis.fetch = (url, options) => new Promise((resolve, reject) => {
    requests.push({ url, options, resolve, reject })
  })
  const renderer = createRenderer({
    createComment: () => ({}), insert() {}, remove() {}, parentNode: () => null, nextSibling: () => null,
  })
  const app = renderer.createApp({ ...View, render: () => null })
  app.provide(Symbol.for('v-scx'), {})
  app.provide(routeLocationKey, { query: {} })
  app.provide(routerKey, { replace() {} })
  statusLoaded.value = false
  app.mount({})
  assert.equal(requests.length, 0, 'no request before initial state')
  statusLoaded.value = true
  await nextTick()
  assert.equal(requests.length, 1)
  assert.equal(requests[0].url, '/cgi-bin/settings.cgi?setting=recommendations')
  provider.value = { provider: 'NEW' }
  await nextTick()
  assert.equal(requests.length, 2)
  assert.equal(requests[0].options.signal.aborted, true)
  requests[1].resolve({ ok: true, json: async () => ({ ...data, provider: 'NEW', status: 'stale' }) })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(app._instance.setupState.recommendations.provider, 'NEW')
  requests[0].resolve({ ok: true, json: async () => data })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(app._instance.setupState.recommendations.provider, 'NEW', 'old response must not replace new provider')
  status.value = { provider: 'OTHER' }
  await nextTick()
  assert.equal(requests.length, 3, 'status provider change also invalidates data')
  assert.equal(app._instance.setupState.recommendations, null)
  requests[2].reject(new Error('offline'))
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(app._instance.setupState.recommendationsLoading, false)
  // «Обновить» повторяет GET подсказок после сбоя даже при прежнем провайдере.
  const beforeRefresh = requests.length
  const refreshed = app._instance.setupState.refresh()
  await nextTick()
  const stateRequest = requests.slice(beforeRefresh).find(request => request.url.startsWith('/cgi-bin/state.cgi'))
  assert.ok(stateRequest)
  stateRequest.resolve({ ok: true, json: async () => ({ status: status.value, provider: provider.value }) })
  await refreshed
  await nextTick()
  const retryRequests = requests.slice(beforeRefresh).filter(request => request.url === '/cgi-bin/settings.cgi?setting=recommendations')
  assert.equal(retryRequests.length, 1, 'refresh must retry recommendations with unchanged provider')
  retryRequests[0].resolve({ ok: true, json: async () => ({ ...data, provider: 'NEW' }) })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(app._instance.setupState.recommendations.status, 'ready')
  app.unmount()
  console.log('recommendations UI smoke ok')
} finally {
  await server.close()
}
