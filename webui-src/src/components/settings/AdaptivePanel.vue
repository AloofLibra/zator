<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { adaptiveAction, fetchAdaptiveStatus } from '../../api/endpoints'
import type { AdaptiveStatus } from '../../api/types'
import { busyActive, withBusy } from '../../stores/busy'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const status = ref<AdaptiveStatus | null>(null)
const modeLabel = computed(() => ({ OFF: 'Выключен', OBSERVE: 'Наблюдение', TEST_ONLY: 'Пробные проверки' }[status.value?.mode || 'OFF']))

async function refresh() {
  status.value = await fetchAdaptiveStatus()
}

function eventTime(timestamp: number) {
  return new Date(timestamp * 1000).toLocaleString()
}

function isFresh(event: { observed_at: number }) {
  const age = Math.floor(Date.now() / 1000) - event.observed_at
  return age >= -60 && age <= 24 * 60 * 60
}

function eventLabel(status: string) {
  if (status === 'suspected_failure') return 'повторные признаки сбоя · нужна проверка'
  if (status === 'needs_verify') return 'запрошена проверка'
  return 'наблюдение'
}

async function act(action: string, rule?: { hostname: string; destination_ip: string; profile_id: number; scope: string }) {
  if (action === 'disable' && !window.confirm('Отключить adaptive agent, отменить пробы и удалить его правила?')) return
  if (action === 'rotate' && !window.confirm('Отозвать старый токен и выпустить новый?')) return
  try {
    await withBusy(`adaptive-${action}`, async () => {
      const result = await adaptiveAction(action, rule)
      if (result.restarted) announceRestart()
      const message = action === 'test-only' ? 'Пробный режим включён.' : action === 'request-probe'
        ? 'Проверка поставлена в очередь. Windows watcher должен быть запущен.'
        : action === 'reset-rule' ? 'Точное adaptive-правило сброшено.' : 'Настройка adaptive обновлена.'
      showToast(message + restartSuffix(result))
      await refresh()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

onMounted(() => { void refresh().catch(error => showToast((error as Error).message, 'error')) })
</script>

<template>
  <section class="panel">
    <div class="panel-header"><h2>Адаптивный подбор</h2></div>
    <p class="panel-desc">
      Агент наблюдает новые TCP/TLS-соединения и может проверять локальные стратегии через отдельную тестовую очередь.
      Рабочие локи не меняются автоматически. Сопряжение создаётся на роутере командой <code>/opt/zator/tools/adaptive-pair.sh create</code>.
    </p>
    <div v-if="status" class="adaptive-status" aria-live="polite">
      <div><span>Сопряжение</span><strong>{{ status.paired ? 'включено' : status.pairing_expired ? 'срок истёк · выполните rotate в CLI' : 'не настроено' }}</strong></div>
      <div><span>Windows watcher</span><strong>{{ status.agent_online ? 'на связи' : status.agent_last_seen ? `не в сети · ${eventTime(status.agent_last_seen)}` : 'ещё не связывался' }}</strong></div>
      <div><span>Режим</span><strong>{{ modeLabel }}</strong></div>
      <div><span>События</span><strong>{{ status.event_count }} / {{ status.event_capacity }}</strong></div>
      <div><span>Запросы проверки</span><strong>{{ status.pending_requests }}</strong></div>
      <div><span>Активные пробы</span><strong>{{ status.active_probes }}</strong></div>
      <div v-if="status.resources"><span>Нагрузка роутера / ядро</span><strong>{{ status.resources.load1_per_core.toFixed(2) }} · {{ status.resources.cores }} ядер</strong></div>
      <div v-if="status.resources"><span>Доступная память</span><strong>{{ Math.floor(status.resources.mem_available_kib / 1024) }} MiB</strong></div>
      <div v-if="!status.resources" class="settings-alert">Метрики ресурсов роутера недоступны; низкоприоритетный подбор остановлен.</div>
      <div v-if="status.cleanup_failures" class="settings-alert">
        Есть незавершённая очистка тестовой очереди: {{ status.cleanup_failures }}.
      </div>
    </div>
    <ul v-if="status?.events.length" class="adaptive-events" aria-label="Очередь адаптивных наблюдений">
      <li v-for="event in status.events" :key="`${event.hostname}|${event.destination_ip}|${event.profile_id}|${event.scope}`">
        <code>{{ event.hostname }}</code> → <code>{{ event.destination_ip }}</code>
        <span>{{ eventLabel(event.status) }} · TCP/TLS · профиль {{ event.profile_id }} · {{ event.scope }} · {{ eventTime(event.observed_at) }}</span>
        <button class="ghost" :disabled="busyActive || status.mode !== 'TEST_ONLY' || !isFresh(event)" @click="act('request-probe', event)">Проверить</button>
      </li>
    </ul>
    <p v-else-if="status" class="form-hint">Очередь событий пуста.</p>
    <div v-else class="status-loading" aria-live="polite">Загрузка состояния…</div>
    <h3 v-if="status?.rules.length">Проверенные локальные правила</h3>
    <ul v-if="status?.rules.length" class="adaptive-events" aria-label="Подтверждённые локальные правила">
      <li v-for="rule in status.rules" :key="`${rule.hostname}|${rule.destination_ip}|${rule.profile_id}|${rule.scope}`">
        <code>{{ rule.hostname }}</code> → <code>{{ rule.destination_ip }}</code>
        <span>профиль {{ rule.profile_id }} · {{ rule.scope }} · стратегия {{ rule.strategy_number }} · действует до {{ eventTime(rule.expires) }}</span>
        <button class="ghost" :disabled="busyActive" @click="act('reset-rule', rule)">Сбросить правило</button>
      </li>
    </ul>
    <p class="form-hint">Стратегия автоматически не применяется. Для подключения запустите watcher на Windows после включения TEST_ONLY.</p>
    <div class="card-actions">
      <button class="ghost" :disabled="busyActive || !status?.paired" @click="act('observe')">Наблюдение</button>
      <button class="primary" :disabled="busyActive || !status?.paired" @click="act('test-only')">TEST_ONLY</button>
      <button class="ghost" :disabled="busyActive" @click="act('pause')">Пауза</button>
      <button class="ghost" :disabled="busyActive" @click="act('clear-events')">Очистить события</button>
      <button v-if="status?.paired" class="ghost" :disabled="busyActive" @click="act('disable')">Отключить</button>
    </div>
  </section>
</template>

<style scoped>
.adaptive-status { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 16px 0; }
.adaptive-status > div:not(.settings-alert) { display: grid; gap: 5px; padding: 12px; border: 1px solid var(--line); border-radius: 10px; }
.adaptive-status span, .form-hint { color: var(--muted); }
.adaptive-events { display: grid; gap: 8px; max-height: 280px; overflow: auto; margin: 0 0 16px; padding: 0; list-style: none; }
.adaptive-events li { display: grid; gap: 4px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px; overflow-wrap: anywhere; }
.adaptive-events span { color: var(--muted); font-size: .9em; }
</style>
