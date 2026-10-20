<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { fetchSupersweep } from '../../api/endpoints'
import type { SupersweepPayload } from '../../api/types'

const data = ref<SupersweepPayload | null>(null)
const loading = ref(false)
const error = ref('')
const states = {
  idle: 'Нет прогона', starting: 'Подготовка', running: 'Выполняется', applying: 'Применение результатов',
  done: 'Завершён', cancelled: 'Отменён', interrupted: 'Прерван',
}
const verdicts = { ok: 'Работает', warn: 'С предупреждением', fail: 'Не работает' }
const stateLabel = computed(() => data.value ? states[data.value.state] : 'Загрузка…')
let mounted = false
let timer: number | undefined
let controller: AbortController | null = null

const count = (value: unknown) => Number.isSafeInteger(value) && (value as number) >= 0
const strategy = (value: unknown) => value === null || count(value)
const text = (value: unknown) => typeof value === 'string'
function valid(value: SupersweepPayload) {
  return value && typeof value.available === 'boolean' && typeof value.active === 'boolean' &&
    Object.prototype.hasOwnProperty.call(states, value.state) && ['none', 'live', 'saved'].includes(value.source) &&
    [value.started, value.updated, value.completed, value.total].every(count) &&
    text(value.scope) && text(value.phase) &&
    Array.isArray(value.workers) && value.workers.every((worker) => worker &&
      [worker.name, worker.label, worker.current_target, worker.greens, worker.warns, worker.applied].every(text) &&
      [worker.profile, worker.completed, worker.total, worker.ok, worker.warn, worker.fail].every(count) &&
      strategy(worker.current_strategy)) &&
    Array.isArray(value.applied) && value.applied.every((row) => row &&
      ['profile', 'domain'].includes(row.kind) && text(row.target) && count(row.strategy)) &&
    Array.isArray(value.domains) && value.domains.every((row) => row && text(row.domain) &&
      Object.prototype.hasOwnProperty.call(verdicts, row.verdict) && strategy(row.best_strategy) && strategy(row.applied))
}
function date(value: number) {
  return value > 0 ? new Date(value * 1000).toLocaleString('ru-RU') : '—'
}
function stopTimer() {
  window.clearTimeout(timer)
  timer = undefined
}
async function refresh() {
  if (!mounted || document.hidden || loading.value) return
  stopTimer()
  loading.value = true
  const request = new AbortController()
  controller = request
  const timeout = window.setTimeout(() => request.abort(), 12000)
  try {
    const result = await fetchSupersweep(request.signal)
    if (!valid(result)) throw new Error('Некорректный ответ сервера')
    if (mounted) {
      data.value = result
      error.value = ''
    }
  } catch (cause) {
    if (mounted) error.value = request.signal.aborted ? 'Превышено время ожидания ответа.'
      : cause instanceof Error ? cause.message : 'Не удалось получить данные.'
  } finally {
    window.clearTimeout(timeout)
    controller = null
    loading.value = false
    if (mounted && !document.hidden) timer = window.setTimeout(refresh, data.value?.active ? 5000 : 15000)
  }
}
function visibilityChanged() {
  stopTimer()
  if (!document.hidden) void refresh()
}
onMounted(() => {
  mounted = true
  document.addEventListener('visibilitychange', visibilityChanged)
  void refresh()
})
onUnmounted(() => {
  mounted = false
  stopTimer()
  controller?.abort()
  document.removeEventListener('visibilitychange', visibilityChanged)
})
</script>

<template>
  <section id="supersweep-panel" class="supersweep-panel" aria-labelledby="supersweep-title">
    <div class="supersweep-header">
      <h2 id="supersweep-title">Суперсвип · прогресс и последний результат</h2>
      <button id="supersweep-refresh-btn" type="button" :disabled="loading" :aria-busy="loading" @click="refresh">
        {{ loading ? 'Обновляем…' : 'Обновить' }}
      </button>
    </div>
    <p v-if="error" class="supersweep-error" role="alert">Не удалось обновить суперсвип: {{ error }}
      <span v-if="data">Показаны последние полученные данные — они могут быть устаревшими.</span>
    </p>
    <p v-if="!data && !error" role="status">Загружаем данные суперсвипа…</p>
    <template v-if="data">
      <p role="status"><strong>{{ stateLabel }}</strong>
        · {{ data.source === 'saved' ? 'Сохранённый отчёт' : data.source === 'live' ? 'Текущий отчёт' : 'Нет отчёта' }}
        <span v-if="error"> · Устаревшие данные</span>
      </p>
      <p v-if="!data.available">Прогонов пока нет. Здесь появятся прогресс и результат суперсвипа, запущенного из CLI.</p>
      <template v-else>
        <p>Фаза: {{ data.phase || '—' }} · Выполнено: {{ data.completed }} / {{ data.total }}</p>
        <progress v-if="data.total > 0" :value="data.completed" :max="data.total" aria-label="Общий прогресс суперсвипа" />
        <p class="supersweep-meta">Scope прогона: {{ data.scope || '—' }} · Начало: {{ date(data.started) }} · Обновлено: {{ date(data.updated) }}</p>
        <div class="supersweep-workers">
          <article v-for="worker in data.workers" :key="worker.name" class="supersweep-worker">
            <h3>{{ worker.label || worker.name }} · Профиль {{ worker.profile }}</h3>
            <p>Выполнено: {{ worker.completed }} / {{ worker.total }}</p>
            <progress v-if="worker.total > 0" :value="worker.completed" :max="worker.total" :aria-label="'Прогресс: ' + (worker.label || worker.name)" />
            <p>Текущая стратегия: {{ worker.current_strategy ?? '—' }} · Цель: {{ worker.current_target || '—' }}</p>
            <p><span class="supersweep-ok">Успех: {{ worker.ok }}</span> · <span class="supersweep-warn">Предупреждения: {{ worker.warn }}</span> · <span class="supersweep-error">Ошибки: {{ worker.fail }}</span></p>
            <p>Зелёные стратегии: {{ worker.greens || '—' }}</p>
            <p>Жёлтые стратегии: {{ worker.warns || '—' }}</p>
            <p>Применено по отчёту: {{ worker.applied || '—' }}</p>
          </article>
        </div>
        <h3>Применённые победители</h3>
        <p class="supersweep-meta">Применение зафиксировано в этом прогоне; текущие локи смотрите в карточках стратегий ниже.</p>
        <ul v-if="data.applied.length">
          <li v-for="(row, index) in data.applied" :key="index">{{ row.kind === 'profile' ? 'Профиль' : 'Домен' }} {{ row.target }} → стратегия {{ row.strategy }}</li>
        </ul>
        <p v-else>В этом прогоне стратегии ещё не применялись.</p>
        <details v-if="data.domains.length">
          <summary>Результаты доменов РКН ({{ data.domains.length }})</summary>
          <ul class="supersweep-domains">
            <li v-for="row in data.domains" :key="row.domain">
              <strong>{{ row.domain }}</strong> · <span :class="'supersweep-' + row.verdict">{{ verdicts[row.verdict] }}</span>
              · Лучшая найденная: {{ row.best_strategy ?? '—' }} · Применена в прогоне: {{ row.applied ?? '—' }}
            </li>
          </ul>
        </details>
      </template>
    </template>
  </section>
</template>

<style scoped>
.supersweep-panel { margin-bottom: 1rem; padding: 1rem; border: 1px solid var(--line); border-radius: var(--radius-sm); background: var(--surface); font-size: .85rem; overflow-wrap: anywhere; }
.supersweep-header { display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: .75rem; }
.supersweep-panel h2, .supersweep-panel h3 { margin: 0; font-size: 1rem; }
.supersweep-panel h3 { font-size: .9rem; }
.supersweep-panel p { margin: .5rem 0; }
.supersweep-panel progress { width: 100%; accent-color: var(--success); }
.supersweep-meta { color: var(--muted); }
.supersweep-workers { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 260px), 1fr)); gap: .75rem; margin: .75rem 0; }
.supersweep-worker { min-width: 0; padding: .75rem; border: 1px solid var(--line); border-radius: var(--radius-sm); }
.supersweep-ok { color: var(--success); }
.supersweep-warn { color: var(--warning); }
.supersweep-error, .supersweep-fail { color: var(--danger); }
.supersweep-panel summary { cursor: pointer; margin-top: .75rem; }
.supersweep-domains li { margin: .5rem 0; }
</style>
