declare const probe: { command(command: string, payload?: unknown): Promise<unknown>; onUpdate(callback: (data: any) => void): void }
const field = (id: string) => document.getElementById(id) as HTMLInputElement
const statusNode = document.getElementById('status')!
const labels: Record<string, string> = { IDLE: 'Готов', PREPARING: 'Подготовка', BASELINE: 'DIRECT', SWITCHING: 'Смена стратегии', LOADING: 'Загрузка сайта', ANALYZING: 'Проверка доказательств', MANUAL: 'Оцените сайт в строке результата', NEXT: 'Следующая стратегия', REPORTING: 'Отчёт', CANCELLED: 'Отменено', ERROR: 'Ошибка', CLEANUP_ERROR: 'Не удалось завершить сессию; действует TTL роутера' }
function showError(error: unknown) { statusNode.textContent = String(error) }
field('probe-form').addEventListener('submit', event => {
  event.preventDefault()
  const strategies = field('strategies').value.split(',').map(v => Number(v.trim()))
  void probe.command('run', { ssh: { host: field('host').value.trim(), user: field('user').value.trim(), port: Number(field('port').value), identity: field('identity').value.trim() }, url: field('url').value, profile: Number(field('profile').value), strategies, scenario: field('scenario').value, selector: field('selector').value.trim(), timeout: Number(field('timeout').value), manual: field('manual').checked }).catch(showError)
})
for (const name of ['cancel', 'export', 'screenshot']) field(name).addEventListener('click', () => { void probe.command(name).catch(showError) })
probe.onUpdate(data => {
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
    statusNode.textContent = [labels[data.state] || data.state, data.strategy !== undefined ? String(data.strategy || 'DIRECT') : '', data.error || data.cleanup_error || ''].filter(Boolean).join(' · ')
    const busy = !['IDLE', 'ERROR', 'CANCELLED', 'CLEANUP_ERROR'].includes(data.state)
    field('run').disabled = busy; field('cancel').disabled = !busy
  }
  if (!data.results) return
  const body = document.getElementById('results')!; body.replaceChildren()
  data.results.forEach((result: any, index: number) => {
    const row = document.createElement('tr')
    const strategy = document.createElement('td'); strategy.textContent = String(result.strategy || 'DIRECT')
    const verdict = document.createElement('td'); verdict.textContent = result.verdict; verdict.className = result.verdict; verdict.title = result.reason
    const manual = document.createElement('td'), select = document.createElement('select'); select.setAttribute('aria-label', `Ручная оценка стратегии ${result.strategy || 'DIRECT'}`)
    for (const [value, text] of [['', '—'], ['passed', 'Работает'], ['failed', 'Не работает'], ['unknown', 'Неясно']]) { const option = document.createElement('option'); option.value = value; option.textContent = text; select.append(option) }
    select.value = result.manual || ''; select.addEventListener('change', () => { void probe.command('manual', { index, value: select.value }).catch(showError) }); manual.append(select)
    row.append(strategy, verdict, manual); body.append(row)
  })
  document.getElementById('details')!.textContent = data.results.length ? JSON.stringify(data.results[data.results.length - 1], null, 2) : ''
})
