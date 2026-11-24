<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { adaptiveAction, fetchAdaptiveStatus } from '../../api/endpoints'
import type { AdaptiveStatus } from '../../api/types'
import { busyActive, withBusy } from '../../stores/busy'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const status = ref<AdaptiveStatus | null>(null)
const modeLabel = computed(() => ({ OFF: 'Выключен', OBSERVE: 'Наблюдение', TEST_ONLY: 'Пробные проверки', AUTO: 'Авторотация · роутер + browser feedback', AGENT_BETA: 'Авторотация · legacy Beta' }[status.value?.mode || 'OFF']))
const pairingDaysRemaining = computed(() => {
  const expires = status.value?.pairing_expires_at
  if (!status.value?.paired || !expires) return null
  return Math.max(0, Math.ceil((expires - Math.floor(Date.now() / 1000)) / 86400))
})

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
  const routerTrial = status.match(/^router_trial_(\d+)$/)
  if (routerTrial) return `роутерная проба стратегии ${routerTrial[1]} · низкая достоверность`
  if (status === 'router_exhausted') return 'каталог стратегий исчерпан · возврат к исходной стратегии'
  if (status === 'suspected_failure') return 'повторные признаки сбоя · нужна проверка'
  if (status === 'active_rule_degraded') return 'применяемое авто-правило могло ухудшиться · нужна проверка'
  if (status === 'needs_verify') return 'запрошена проверка'
  return 'наблюдение'
}

function probeCategory(recipe: string) {
  if (recipe === 'googlevideo-tcp-media-v1') return 'Googlevideo TCP media'
  if (recipe === 'googlevideo-quic-h3-media-v1') return 'Googlevideo QUIC / HTTP3'
  return 'TCP / TLS'
}

function probeOutcome(outcome: string) {
  if (outcome === 'SUCCESS') return 'Успех'
  if (outcome === 'FAIL') return 'Подтверждённый сбой'
  return 'Недостаточно данных'
}

function adaptiveStage(stage: string) {
  return ({ idle: 'ожидание событий', fast_search: 'FastSearch · Top-10', deep_search: 'DeepSearch', explore: 'низкоприоритетный Explore', ramp_audit: 'низкоприоритетный Ramp-аудит', cooldown: 'пауза повторной проверки' } as Record<string, string>)[stage] || stage
}

function adaptiveSearchOutcome(outcome: string) {
  return ({ none: 'ещё не запускался', found: 'стратегия найдена', direct: 'подтверждён DIRECT', deep_scheduled: 'DeepSearch запланирован', all_exhausted: 'кандидаты исчерпаны', limit_reached: 'достигнут лимит FastSearch', inconclusive: 'недостаточно данных', stopped_rate_limit: 'пауза из-за ограничения частоты', stopped_infra: 'остановлен из-за инфраструктуры', cancelled: 'отменён' } as Record<string, string>)[outcome] || outcome
}

function browserAttemptState(state: string) {
  return ({ QUEUED: 'в очереди', WAIT_NEW_FLOW: 'ожидает нового соединения', FLOW_CONFIRMED: 'соединение и стратегия подтверждены', WAIT_BROWSER_RESULT: 'ожидает результата браузера', PROVISIONAL_SUCCESS: 'предварительный успех', CONFIRMED_SUCCESS: 'подтверждённый успех', CONFIRMED_FAILURE: 'подтверждённый сбой', UNKNOWN: 'результат неизвестен', NOT_TESTED: 'соединение не проверено', CANCELLED: 'отменено', EXPIRED: 'истекло', TARGET_NOT_MANAGED: 'ресурс не управляется Zator' } as Record<string, string>)[state] || state
}

function browserProtocol(protocol: string) {
  return ({ tls: 'TCP/TLS', 'googlevideo-tcp': 'Googlevideo TCP', quic: 'QUIC', unknown: 'не определён' } as Record<string, string>)[protocol] || protocol
}

function probeReason(reason: string) {
  const labels: Record<string, string> = {
    media_ok: 'медиа передано', probe_ok: 'HTTP-ответ получен', timeout: 'таймаут',
    transport_timeout: 'таймаут передачи', http_rejected: 'HTTP отклонён',
    rate_limited: 'ограничение частоты', server_busy: 'сервер перегружен',
    origin_unavailable: 'источник недоступен', signed_url_expired: 'ссылка на медиа истекла',
    media_insufficient: 'недостаточно медиа-данных', quic_unavailable: 'HTTP/3 недоступен',
    target_unavailable: 'цель недоступна', route_unverified: 'маршрут не подтверждён',
    strategy_unconfirmed: 'ACK стратегии не подтверждён', ramp_stage_unconfirmed: 'этап Ramp не подтверждён',
    probe_error: 'ошибка тестового окружения', cancelled: 'проверка отменена', expired: 'lease истёк',
    invalid_result: 'результат проверки отклонён', empty_response: 'пустой ответ', response_too_large: 'ответ превысил лимит'
  }
  return labels[reason] || reason
}

async function act(action: string, rule?: { hostname: string; destination_ip: string; profile_id: number; protocol: 'tls' | 'googlevideo-tcp' | 'quic'; scope: string }) {
  if (action === 'router-auto' && !window.confirm('Включить авторотацию? Она работает без расширения по пассивным сигналам роутера; подключённое расширение добавит более точные browser результаты. Изолированные проверки и q65535 автоматически не запускаются.')) return
  if (action === 'disable' && !window.confirm('Отключить adaptive agent, отменить пробы и удалить его правила?')) return
  if (action === 'beta-lan' && !window.confirm('Разрешить browser trials также для устройств без mark (default scope)? Пассивная роутерная авторотация и так работает без расширения.')) return
  if (action === 'ramp-pool-on' && !window.confirm('Включить Ramp-first для настроенного Googlevideo IPv4-пула? Это глобальное изменение для новых TCP-соединений Googlevideo, использует текущие параметры Ramp и помечается как manual_unverified. Beta должна быть включена для всего LAN.')) return
  if (action === 'ramp-pool-off' && !window.confirm('Отозвать Beta-согласие на Ramp-first? Если Beta сама включила Ramp и параметры не менялись, восстановится прежнее выключенное состояние. Ручные изменения будут сохранены.')) return
  if (action === 'rotate' && !window.confirm('Отозвать старый токен и выпустить новый?')) return
  try {
    await withBusy(`adaptive-${action}`, async () => {
      const result = await adaptiveAction(action, rule)
      if (result.restarted) announceRestart()
      const message = action === 'test-only' ? 'Пробный режим включён.' : action === 'router-auto' ? 'Авторотация включена; browser feedback подключается отдельно.' : action === 'beta' ? 'Авторотация включена для marked scope.' : action === 'beta-lan' ? 'Авторотация включена с разрешением browser trials для default scope.' : action === 'request-probe'
        ? 'Проверка поставлена в очередь. Windows watcher должен быть запущен.'
        : action === 'ramp-pool-on' ? 'Ramp-first согласие сохранено.'
        : action === 'ramp-pool-off' ? 'Ramp-first согласие отозвано.'
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
      Роутерная авторотация работает и без расширения по локальным сигналам с более низкой достоверностью. Расширение добавляет точную обратную связь; подтверждённая стратегия для домена применяется клиентам без отдельного scope, приоритет их lock/policy сохраняется.
      QUIC Health Monitor пассивно считает Initial, retries, наблюдаемый ответ и возможный TCP fallback; активные проверки он не запускает. Windows watcher остаётся необязательным инструментом изолированных проверок.
    </p>
    <div v-if="status" class="adaptive-status" aria-live="polite">
      <div><span>Сопряжение Windows-агента</span><strong>{{ status.paired ? 'включено' : status.pairing_expired ? 'срок истёк · выполните rotate в CLI' : 'не настроено · для браузера не требуется' }}</strong></div>
      <div><span>Windows watcher</span><strong>{{ status.agent_online ? 'на связи' : status.agent_last_seen ? `не в сети · ${eventTime(status.agent_last_seen)}` : 'ещё не связывался' }}</strong></div>
      <div v-if="status.browser"><span>Браузерное расширение</span><strong>{{ status.browser.connected_clients ? `на связи · ${status.browser.connected_clients} из ${status.browser.paired_clients}` : status.browser.paired_clients ? `сопряжено · не в сети (${status.browser.paired_clients})` : 'не сопряжено' }}</strong></div>
      <div><span>Режим</span><strong>{{ modeLabel }}</strong></div>
      <div><span>События</span><strong>{{ status.event_count }} / {{ status.event_capacity }}</strong></div>
      <div><span>Запросы проверки</span><strong>{{ status.pending_requests }}</strong></div>
      <div><span>Активные пробы</span><strong>{{ status.active_probes }}</strong></div>
      <div><span>Смена semantic rule A→B→A · сохранённая история</span><strong>{{ status.adaptive_rule_flipflops }}</strong></div>
      <div v-if="status.resources"><span>Нагрузка роутера / ядро</span><strong>{{ status.resources.load1_per_core.toFixed(2) }} · {{ status.resources.cores }} ядер</strong></div>
      <div v-if="status.resources"><span>Доступная память</span><strong>{{ Math.floor(status.resources.mem_available_kib / 1024) }} MiB</strong></div>
      <div v-if="!status.resources" class="settings-alert">Метрики ресурсов роутера недоступны; низкоприоритетный подбор остановлен.</div>
      <div v-if="status.cleanup_failures" class="settings-alert">
        Есть незавершённая очистка тестовой очереди: {{ status.cleanup_failures }}.
      </div>
    </div>
    <div v-if="status?.browser?.active_attempts.length" class="adaptive-last-probe" aria-live="polite">
      <strong>Браузерные попытки</strong>
      <span v-for="attempt in status.browser.active_attempts" :key="`${attempt.hostname}|${attempt.scope}|${attempt.created_at}`">
        <code>{{ attempt.hostname }}</code> · {{ browserProtocol(attempt.protocol) }} · профиль {{ attempt.profile_id }} · {{ attempt.scope }} · стратегия {{ attempt.strategy_number }} · {{ browserAttemptState(attempt.state) }} · {{ attempt.expires_at > Math.floor(Date.now() / 1000) ? `истекает ${eventTime(attempt.expires_at)}` : `начато ${eventTime(attempt.created_at)}` }}
      </span>
    </div>
    <div v-if="status?.quic_health?.length" class="adaptive-last-probe" aria-live="polite">
      <strong>QUIC Health Monitor · пассивные наблюдения</strong>
      <span v-for="item in status.quic_health" :key="`${item.hostname}|${item.destination_ip}|${item.scope}`">
        <code>{{ item.hostname }}</code> → <code>{{ item.destination_ip }}</code> · {{ item.scope }} · Initial {{ item.initials }} · retries {{ item.retries }} · ответ {{ item.response_observed ? 'наблюдался' : 'не наблюдался' }} · возможный TCP fallback {{ item.possible_tcp_fallback ? 'да' : 'нет' }} · достоверность низкая · {{ eventTime(item.observed_at) }}
      </span>
    </div>
    <div v-if="status?.agent_status" class="adaptive-last-probe" aria-live="polite">
      <strong>Watcher · {{ adaptiveStage(status.agent_status.stage) }}</strong>
      <span>Общая статистика: {{ status.agent_status.statistics_enabled ? 'включена по opt-in агента' : 'выключена' }} · общие rankings: {{ status.agent_status.rankings_enabled ? 'включены по opt-in агента' : 'выключены' }}</span>
      <span>Последний поиск: {{ adaptiveSearchOutcome(status.agent_status.search_outcome) }} · проверено {{ status.agent_status.candidates_checked }} кандидатов (Fast {{ status.agent_status.fast_candidates }} / Deep {{ status.agent_status.deep_candidates }}) · {{ (status.agent_status.search_duration_ms / 1000).toFixed(1) }} с</span>
      <span>Revalidation (накопительно): восстановлено поиском {{ status.agent_status.revalidation_recoveries }} · исчерпано без решения {{ status.agent_status.revalidation_failures }}</span>
      <span>Success after apply (изолированная повторная проверка того же активного правила): {{ status.agent_status.success_after_apply }}</span>
      <span>Цели на cooldown: {{ status.agent_status.cooldown_targets }} · показывается только число, адреса остаются на компьютере агента</span>
      <span>Восстановление означает найденный DIRECT/стратегию; «исчерпано» — полный каталог без решения. Success after apply подтверждает только изолированную повторную проверку правила, не последующий пользовательский трафик.</span>
      <span v-if="status.agent_status.time_to_first_success_ms > 0">Время до первого успеха: {{ (status.agent_status.time_to_first_success_ms / 1000).toFixed(1) }} с · обновлено {{ eventTime(status.agent_status.updated_at) }}</span>
      <span v-else>Время до первого успеха: нет подтверждённого успеха · обновлено {{ eventTime(status.agent_status.updated_at) }}</span>
      <span v-if="status.agent_status.pc_cpu_percent !== null">Windows: CPU {{ status.agent_status.pc_cpu_percent }}% · свободно RAM {{ (status.agent_status.pc_free_memory_bytes! / 1073741824).toFixed(1) }} GiB · сеть всех интерфейсов {{ (status.agent_status.pc_network_bytes_per_second! / 1048576).toFixed(2) }} MiB/s</span>
      <span v-if="status.agent_status.router_load1_per_core !== null">Роутер: load/core {{ status.agent_status.router_load1_per_core!.toFixed(2) }} · доступно RAM {{ Math.floor(status.agent_status.router_memory_available_kib! / 1024) }} MiB · активные пробы {{ status.agent_status.router_active_probes }}</span>
    </div>
    <p v-if="status && status.ramp_exemptions_supported === false" class="settings-alert" role="status">
      Ramp-пробы и Ramp-first остаются доступны при явном согласии. Автоматические IP-исключения пока выключены: на этом Keenetic не пройден отдельный live gate позднего ACK.
    </p>
    <div v-if="(status?.mode === 'AGENT_BETA' || status?.mode === 'AUTO') && status.ramp_audit_supported !== false" class="adaptive-ramp-pool" aria-live="polite">
      <strong>Ramp-first по Googlevideo IP-пулу</strong>
      <span v-if="!status.default_scope_apply">Сначала включите Beta для всего LAN: Ramp применяется по destination IP и не может быть ограничен отмеченным клиентским scope на SYN.</span>
      <span v-else-if="status.ramp_pool_consent">Включено по явному согласию · основание manual_unverified · параметры Ramp сохранены из текущего конфига.</span>
      <span v-else-if="status.ramp_pool_enabled">Ramp уже включён вручную. Beta-аудит не запустится, пока вы отдельно не разрешите использовать его как Ramp-first политику.</span>
      <span v-else>Выключено. Включение использует текущий настроенный Googlevideo IP-пул и параметры Ramp; при паузе Beta вернёт прежнее выключенное состояние, если вы не меняли настройки вручную.</span>
      <button v-if="status.default_scope_apply && status.ramp_pool_consent" class="ghost" :disabled="busyActive" @click="act('ramp-pool-off')">Отключить Ramp-first</button>
      <button v-else-if="status.default_scope_apply" class="danger" :disabled="busyActive" @click="act('ramp-pool-on')">Разрешить Ramp-first для пула</button>
    </div>
    <div v-if="status?.last_probe" class="adaptive-last-probe" aria-live="polite">
      <strong>Последняя проверка · {{ probeCategory(status.last_probe.recipe_id) }}</strong>
      <span>{{ probeOutcome(status.last_probe.overall) }} · {{ probeReason(status.last_probe.reason) }} · профиль {{ status.last_probe.profile_id }} · {{ status.last_probe.scope }} · {{ status.last_probe.strategy_number === 0 ? 'DIRECT' : `стратегия ${status.last_probe.strategy_number}` }} · {{ status.last_probe.treatment_variant }}</span>
      <span>Маршрут {{ status.last_probe.route_verified ? 'подтверждён' : 'не подтверждён' }} · test queue {{ status.last_probe.queue_seen ? 'видна' : 'не видна' }} · ACK {{ status.last_probe.strategy_ack_seen ? 'подтверждён' : 'не подтверждён' }} · {{ eventTime(status.last_probe.observed_at) }}</span>
      <span v-if="status.last_probe.media_bytes > 0">Медиа: {{ (status.last_probe.media_bytes / 1048576).toFixed(2) }} MiB · {{ (status.last_probe.media_speed_bps / 1000000).toFixed(2) }} MB/s · {{ status.last_probe.media_duration_ms }} ms</span>
      <span>Пакетный расход тестовой очереди: {{ status.last_probe.probe_network_bytes === null ? 'нет счётчика' : `${(status.last_probe.probe_network_bytes / 1048576).toFixed(2)} MiB IP-пакетов` }} · байты с последней установки временного правила; после его восстановления это нижняя граница</span>
      <span>Длительность проверки: {{ status.last_probe.duration_seconds }} с</span>
    </div>
    <p v-if="pairingDaysRemaining !== null && pairingDaysRemaining <= 30" class="settings-alert" role="status">
      Сопряжение Windows-агента истекает через {{ pairingDaysRemaining }} дн. Чтобы продлить его, выполните на роутере <code>/opt/zator/tools/adaptive-pair.sh rotate</code>; старый токен будет отозван.
    </p>
    <ul v-if="status?.events.length" class="adaptive-events" aria-label="Очередь адаптивных наблюдений">
      <li v-for="event in status.events" :key="`${event.hostname}|${event.destination_ip}|${event.profile_id}|${event.scope}`">
        <code>{{ event.hostname }}</code> → <code>{{ event.destination_ip }}</code>
        <span>{{ eventLabel(event.status) }} · {{ event.protocol === 'quic' ? 'QUIC' : 'TCP/TLS' }} · профиль {{ event.profile_id }} · {{ event.scope }} · {{ eventTime(event.observed_at) }}</span>
        <button v-if="event.protocol === 'tls'" class="ghost" :disabled="busyActive || !['TEST_ONLY', 'AGENT_BETA', 'AUTO'].includes(status.mode) || !isFresh(event)" @click="act('request-probe', event)">Проверить</button>
      </li>
    </ul>
    <p v-else-if="status" class="form-hint">Очередь событий пуста.</p>
    <div v-else class="status-loading" aria-live="polite">Загрузка состояния…</div>
    <h3 v-if="status?.rules.length">Проверенные локальные правила</h3>
    <ul v-if="status?.rules.length" class="adaptive-events" aria-label="Подтверждённые локальные правила">
      <li v-for="rule in status.rules" :key="`${rule.hostname}|${rule.destination_ip}|${rule.profile_id}|${rule.protocol}|${rule.scope}`">
        <code>{{ rule.hostname }}</code> → <code>{{ rule.destination_ip }}</code>
        <span>профиль {{ rule.profile_id }} · {{ rule.protocol === 'googlevideo-tcp' ? 'Googlevideo TCP media' : rule.protocol === 'quic' ? 'QUIC' : 'TLS' }} · {{ rule.scope === 'shared' ? 'shared baseline для клиентов без отдельного scope' : rule.scope }} · {{ rule.strategy_number === 0 ? 'DIRECT' : `стратегия ${rule.strategy_number}` }} · treatment {{ rule.treatment_variant }} · подтверждение {{ rule.evidence }} · TTL {{ Math.ceil(rule.ttl_seconds / 60) }} мин · действует до {{ eventTime(rule.expires) }}</span>
        <button class="ghost" :disabled="busyActive" @click="act('reset-rule', rule)">Сбросить правило</button>
      </li>
    </ul>
      <p v-if="status?.mode === 'AUTO' || status?.mode === 'AGENT_BETA'" class="settings-alert">Пассивная авторотация работает без расширения и имеет низкую достоверность. При подключённом расширении browser-подтверждения получают приоритет над пассивными подозрениями. Ручные локи остаются выше обоих источников.</p>
      <p v-else class="form-hint">Стратегия автоматически не применяется. Windows watcher нужен только для изолированных проверок в TEST_ONLY.</p>
    <div class="card-actions">
      <button class="ghost" :disabled="busyActive || !status?.paired" @click="act('observe')">Наблюдение</button>
      <button class="primary" :disabled="busyActive || !status?.paired" @click="act('test-only')">TEST_ONLY</button>
      <button v-if="status?.mode !== 'AUTO' && status?.mode !== 'AGENT_BETA'" class="primary" :disabled="busyActive" @click="act('router-auto')">Включить авторотацию</button>
      <button v-if="status?.mode === 'AUTO' && status.browser_default_scope_consent" class="ghost" :disabled="busyActive" @click="act('beta')">Ограничить browser trials · marked scope</button>
      <button v-if="status?.mode === 'AUTO' && !status.browser_default_scope_consent" class="danger" :disabled="busyActive" @click="act('beta-lan')">Разрешить browser trials · default scope</button>
      <button class="ghost" :disabled="busyActive" @click="act('pause')">Пауза</button>
      <button class="ghost" :disabled="busyActive" @click="act('clear-events')">Очистить события</button>
      <button v-if="status?.paired || (status?.browser?.paired_clients || 0) > 0" class="ghost" :disabled="busyActive" @click="act('disable')">Отключить</button>
    </div>
  </section>
</template>

<style scoped>
.adaptive-status { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 16px 0; }
.adaptive-status > div:not(.settings-alert) { display: grid; gap: 5px; padding: 12px; border: 1px solid var(--line); border-radius: 10px; }
.adaptive-status span, .form-hint { color: var(--muted); }
.adaptive-last-probe { display: grid; gap: 5px; margin: 12px 0 16px; padding: 12px; border: 1px solid var(--line); border-radius: 10px; }
.adaptive-last-probe span { color: var(--muted); font-size: .9em; overflow-wrap: anywhere; }
.adaptive-ramp-pool { display: grid; gap: 8px; margin: 12px 0; padding: 12px; border: 1px solid var(--line); border-radius: 10px; }
.adaptive-ramp-pool span { color: var(--muted); font-size: .9em; }
.adaptive-events { display: grid; gap: 8px; max-height: 280px; overflow: auto; margin: 0 0 16px; padding: 0; list-style: none; }
.adaptive-events li { display: grid; gap: 4px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px; overflow-wrap: anywhere; }
.adaptive-events span { color: var(--muted); font-size: .9em; }
</style>
