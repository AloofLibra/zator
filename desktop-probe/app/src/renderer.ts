declare const probe: { command(command: string, payload?: unknown): Promise<unknown>; onUpdate(callback: (data: any) => void): void }
const field = (id: string) => document.getElementById(id) as HTMLInputElement
const statusNode = document.getElementById('status')!
let wasBusy = false
let layoutPending = false
function previewLayout() {
  if (layoutPending) return
  layoutPending = true
  requestAnimationFrame(() => {
    layoutPending = false
    const rect = document.getElementById('preview-slot')!.getBoundingClientRect()
    document.documentElement.style.setProperty('--journal-top', `${Math.max(0, Math.round(document.getElementById('result-scroll')!.getBoundingClientRect().top))}px`)
    const x = Math.max(0, Math.round(rect.left)), y = Math.max(0, Math.round(rect.top))
    void probe.command('preview-bounds', { x, y, width: Math.max(0, Math.round(Math.min(innerWidth, rect.right)) - x), height: Math.max(0, Math.round(Math.min(innerHeight, rect.bottom)) - y), expanded: field('preview-toggle').getAttribute('aria-expanded') === 'true' }).catch(showError)
  })
}
function togglePreview(expanded: boolean) {
  document.getElementById('preview-panel')!.classList.toggle('expanded', expanded)
  const button = field('preview-toggle'); button.textContent = expanded ? 'Свернуть' : 'Раскрыть'; button.setAttribute('aria-expanded', String(expanded))
  previewLayout()
}
field('preview-toggle').addEventListener('click', () => togglePreview(field('preview-toggle').getAttribute('aria-expanded') !== 'true'))
document.addEventListener('keydown', event => { if (event.key === 'Escape') togglePreview(false) })
window.addEventListener('resize', previewLayout)
document.addEventListener('scroll', previewLayout, true)
document.addEventListener('toggle', previewLayout, true)
new ResizeObserver(previewLayout).observe(document.body)
new ResizeObserver(previewLayout).observe(document.getElementById('preview-slot')!)
const labels: Record<string, string> = { IDLE: 'Готов', PREPARING: 'Подготовка', BASELINE: 'DIRECT', SWITCHING: 'Смена стратегии', LOADING: 'Загрузка сайта', ANALYZING: 'Проверка доказательств', MANUAL: 'Оцените сайт в строке результата', NEXT: 'Следующая стратегия', REPORTING: 'Отчёт', CANCELLED: 'Отменено', ERROR: 'Ошибка', CLEANUP_ERROR: 'Не удалось завершить сессию; действует TTL роутера' }
function showError(error: unknown) { statusNode.textContent = String(error) }
labels.PAUSE = 'Пауза между проверками'
labels.REPAIRING = 'Восстановление тестовых правил'
function scanModeChanged() {
  const sweep = field('scan-mode').value === 'supersweep'
  for (const [id, enabled] of [['single-options', !sweep], ['sweep-options', sweep]] as const) {
    const group = document.getElementById(id)!
    group.hidden = !enabled
    group.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>('input,select,textarea').forEach(input => { input.disabled = !enabled })
  }
  field('strategies').disabled = sweep || field('strategy-mode').value === 'all'
  field('profile').disabled = sweep || field('scenario').value === 'youtube_video'
}
field('scan-mode').addEventListener('change', scanModeChanged)
field('strategy-mode').addEventListener('change', scanModeChanged)
field('scenario').addEventListener('change', scanModeChanged)
field('probe-form').addEventListener('submit', event => {
  event.preventDefault()
  const strategies = field('strategies').value.split(',').map(v => Number(v.trim()))
  void probe.command('run', { scanMode: field('scan-mode').value, strategyMode: field('strategy-mode').value, youtubeURL: field('youtube-url').value, discordURL: field('discord-url').value, discordSelector: field('discord-selector').value, rknURLs: field('rkn-urls').value, rknSelector: field('rkn-selector').value, ssh: { host: field('host').value.trim(), user: field('user').value.trim(), port: Number(field('port').value), identity: field('identity').value.trim() }, url: field('url').value, profile: Number(field('profile').value), strategies, scenario: field('scenario').value, selector: field('selector').value.trim(), timeout: Number(field('timeout').value), manual: field('manual').checked }).catch(showError)
})
for (const name of ['cancel', 'export', 'screenshot']) field(name).addEventListener('click', () => { void probe.command(name).catch(showError) })
probe.onUpdate(data => {
  if (data.collapse_preview) togglePreview(false)
  if (data.network) {
    const container = document.getElementById('network')!; container.replaceChildren()
    const domains = new Map<string, any[]>()
    for (const row of data.network) { const host = row.url; if (!domains.has(host)) domains.set(host, []); domains.get(host)!.push(row) }
    for (const [host, rows] of domains) {
      const group = document.createElement('details'), title = document.createElement('summary'), list = document.createElement('ul')
      title.textContent = host
      for (const row of rows) { const item = document.createElement('li'); item.textContent = [row.type, row.status || '…', row.protocol || '', row.duration_ms !== null ? `${row.duration_ms}ms` : '', row.error || ''].filter(Boolean).join(' · '); list.append(item) }
      group.append(title, list); container.append(group)
    }
  }
  if (data.state) {
    statusNode.textContent = [labels[data.state] || data.state, data.gv_strategy !== undefined ? `YT-${data.strategy || 'DIRECT'} / GV-${data.gv_strategy || 'DIRECT'}` : data.strategy !== undefined ? String(data.strategy || 'DIRECT') : '', data.pause_seconds ? `${data.pause_seconds} с` : '', data.error || data.cleanup_error || ''].filter(Boolean).join(' · ')
    const busy = !['IDLE', 'ERROR', 'CANCELLED', 'CLEANUP_ERROR'].includes(data.state)
    if (busy && !wasBusy) (document.getElementById('settings') as HTMLDetailsElement).open = false
    document.querySelectorAll<HTMLFieldSetElement>('#settings fieldset').forEach(group => { group.disabled = busy })
    wasBusy = busy
    if (data.total !== undefined) document.getElementById('progress')!.textContent = [`${data.completed}/${data.total}`, data.target_index ? `Цель ${data.target_index}/${data.target_count}` : '', data.profile ? `P${data.profile}` : '', data.target || ''].filter(Boolean).join(' · ')
    field('run').disabled = busy; field('cancel').disabled = !busy
  }
  if (data.summary) {
    const container = document.getElementById('coverage')!
    container.replaceChildren()
    const names: Record<string, string> = { OK: 'Сработали', WARN: 'С замечаниями', FAIL: 'Не сработали', UNKNOWN: 'Не подтверждены', INVALID: 'Ошибка проверки' }
    for (const item of data.summary) {
      const card = document.createElement('section'), title = document.createElement('h3')
      card.className = 'summary-card'
      title.textContent = `P${item.profile} · ${String(item.site).replace(/^https:\/\//, '').replace(/\/$/, '')}`
      card.append(title)
      for (const [key, name] of Object.entries(names)) if (item.verdicts[key].length) { const line = document.createElement('p'); line.className = key; line.textContent = `${name}: ${item.verdicts[key].join(', ')}`; card.append(line) }
      container.append(card)
    }
    if (!data.summary.length) { const empty = document.createElement('p'); empty.className = 'muted'; empty.textContent = 'Результатов пока нет'; container.append(empty) }
  }
  if (!data.results) return
  const log = document.getElementById('result-scroll')!, scrollTop = log.scrollTop
  const follow = log.scrollHeight - log.clientHeight - scrollTop < 32
  const body = document.getElementById('results')!; body.replaceChildren()
  data.results.forEach((result: any, index: number) => {
    const row = document.createElement('tr')
    const strategy = document.createElement('td'); strategy.textContent = `P${result.profile} · ${result.strategy || 'DIRECT'} · ${result.site}`
    if (result.paired) { const pair = document.createElement('small'); pair.textContent = `YT-${result.yt_strategy || 'DIRECT'} / GV-${result.gv_strategy || 'DIRECT'}${result.helper ? ' · опорная YT' : ''}`; strategy.append(pair) }
    const observed = result.observation
    if (observed) {
      const detail = document.createElement('small')
      const page = result.paired ? observed.page_functional ? 'Страница YouTube готова' : 'Страница YouTube не подтверждена' : observed.dom_loaded ? 'DOM загружен' : observed.http_status ? `HTTP ${observed.http_status}, DOM не готов` : 'Страница не открылась'
      const functional = result.stage === 'page' ? observed.page_functional ? 'Открытие подтверждено' : 'Открытие не подтверждено' : result.scenario === 'youtube_video' ? observed.functional === true ? 'Видео воспроизводится' : 'Видео не подтверждено' : observed.functional === true ? 'Условие выполнено' : 'Условие не подтверждено'
      detail.textContent = `${page}. ${functional}.`; strategy.append(detail)
    }
    const verdict = document.createElement('td'); verdict.textContent = result.verdict; verdict.className = result.verdict; verdict.title = result.reason
    const reason = document.createElement('small'); reason.textContent = result.reason; verdict.append(reason)
    const stage = document.createElement('td'); stage.textContent = result.stage === 'page' ? 'Страница' : result.stage === 'video' ? 'Видео' : 'Сайт'
    if (result.attempt_id) { const attempt = document.createElement('small'); attempt.textContent = `Проба ${result.attempt_id.slice(0, 8)}`; stage.append(attempt) }
    if (result.reason === 'FUNCTIONAL_CHECK_TIMED_OUT') { const explanation = document.createElement('small'); explanation.textContent = 'Не хватило времени на проверку функции'; verdict.append(explanation) }
    if (['FLOW_EVIDENCE_INCOMPLETE', 'DOCUMENT_FLOW_NOT_PROVEN', 'MEDIA_FLOW_NOT_PROVEN', 'FRESH_CONNECTION_NOT_PROVEN', 'NO_TEST_QUEUE_TRAFFIC'].includes(result.reason)) { const explanation = document.createElement('small'); explanation.textContent = 'Проба не подтверждена; результат не учитывается как успех'; verdict.append(explanation) }
    if (result.reason === 'CONNECTION_NOT_ESTABLISHED') { const explanation = document.createElement('small'); explanation.textContent = 'TCP-соединение не установлено; стратегия не подтверждена'; verdict.append(explanation) }
    if (result.tested === false) { const explanation = document.createElement('small'); explanation.textContent = 'Не проверялась: нет рабочей страницы/медиазапроса'; verdict.append(explanation) }
    const manual = document.createElement('td'), select = document.createElement('select'); select.setAttribute('aria-label', `Ручная оценка стратегии ${result.strategy || 'DIRECT'}`)
    for (const [value, text] of [['', '—'], ['passed', 'Работает'], ['failed', 'Не работает'], ['unknown', 'Неясно']]) { const option = document.createElement('option'); option.value = value; option.textContent = text; select.append(option) }
    select.value = result.manual || ''; select.addEventListener('change', () => { void probe.command('manual', { index, value: select.value }).catch(showError) }); manual.append(select)
    row.append(strategy, stage, verdict, manual); body.append(row)
  })
  log.scrollTop = follow ? log.scrollHeight : scrollTop
  document.getElementById('details')!.textContent = data.results.length ? JSON.stringify(data.results[data.results.length - 1], null, 2) : ''
})
