<script setup lang="ts">
import { computed, ref } from 'vue'
import type { RouteLocationRaw } from 'vue-router'
import StatCard from '../ui/StatCard.vue'
import { status, versionInfo } from '../../stores/status'
import { fallbackSettings } from '../../stores/settings'
import { fetchAndApplyState } from '../../stores/state'
import { fetchSetting } from '../../api/endpoints'
import { showToast } from '../../stores/toast'

interface CardDef {
  label: string
  value: string
  stateClass?: string
  subText?: string
  to?: RouteLocationRaw
  cli?: string
  compact?: boolean
  cornerAction?: () => void
  cornerBusy?: boolean
  cornerTitle?: string
}

const updateChecking = ref(false)

// Кнопка видна только когда панель не видит обновлений: если обновление
// или новый конфиг уже показаны — пользователь их и так увидит.
async function runUpdateCheck() {
  if (updateChecking.value) return
  updateChecking.value = true
  try {
    const res = await fetchSetting.update_check()
    if (res.error) {
      showToast(res.error, 'error')
      return
    }
    await fetchAndApplyState()
    const updText = res.update_available
      ? (res.release ? `Есть обновление: релиз ${res.release}` : 'Есть обновление')
      : 'Обновлений нет'
    showToast(updText, res.update_available ? 'info' : 'success')
  } catch {
    showToast('Не удалось проверить обновления', 'error')
  } finally {
    updateChecking.value = false
  }
}

const cards = computed<CardDef[]>(() => {
  const data = status.value
  if (!data) return []

  const providerRaw = String(data.provider ?? '')
  const providerCut = providerRaw.indexOf(' - ')
  const providerName = providerCut > 0 ? providerRaw.slice(0, providerCut) : providerRaw
  const providerCity = providerCut > 0 ? providerRaw.slice(providerCut + 3) : ''

  const scope = data.client_scope || {}
  const scopeMode = scope.mode === 'mark' ? 'mark' : 'disabled'
  const scopeSub = `mask: ${scope.mask || '—'} / shift: ${scope.shift ?? 0} / max: ${scope.max_scope ?? 0} · последний scope: ${scope.last_seen_scope || 'unavailable'} · locks: ${scope.scoped_lock_count ?? 0} · conflicts: ${scope.conflicts ?? 0} · fallback: ${scope.fallback_reason || '—'}`

  const scopeTarget: RouteLocationRaw | undefined =
    scopeMode === 'mark' && scope.last_seen_scope && scope.last_seen_scope !== 'unavailable'
      ? { path: '/strategies', query: { scope: scope.last_seen_scope } }
      : '/strategies'

  const fallbackState = fallbackSettings.value?.state ?? '—'
  const dnsProfile = (data.profiles || []).find((profile) => profile.is_dns_desync)

  const ver = versionInfo.value
  // номер релиза из version.env; branch/unknown считаем «без номера» — показываем дату
  const verRelease =
    ver?.zator_version && ver.zator_version !== 'unknown' && ver.zator_version !== 'branch'
      ? ver.zator_version
      : ''
  const verParts: string[] = []
  if (verRelease) verParts.push(`версия ${verRelease}`)
  if (ver?.zator_date) verParts.push(`zator от ${ver.zator_date}`)
  if (ver?.webui_date) verParts.push(`Web-панель от ${ver.webui_date}`)
  // номер релиза, к которому привязан rolling-latest (latest.json «release»)
  if (ver?.update_available && ver.latest_release) verParts.push(`доступен релиз ${ver.latest_release}`)
  const cfgPending = ver?.config_update_pending ?? false
  const verSub = ver?.update_available
    ? (verParts.length ? verParts.join('\n') : undefined)
    : cfgPending
      ? 'Для применения: п.5 -> п.7 в меню z2r'
      : (ver?.webui_date ? `Web-панель от ${ver.webui_date}` : undefined)
  let verValue = verRelease || ver?.zator_date || '—'
  let verClass = ''
  if (ver?.update_available) {
    verValue = 'Есть обновление'
    verClass = 'info'
  } else if (cfgPending) {
    verValue = 'Есть новый конфиг'
    verClass = 'info'
  }

  const z2Parts: string[] = []
  if (ver?.zapret2_version) z2Parts.push(ver.zapret2_version)
  if (ver?.config_date && ver.config_date !== 'Неизвестно') {
    z2Parts.push(`config от ${ver.config_date.slice(0, 10)}`)
    if (ver.config_update_pending && ver.config_default_date) {
      z2Parts.push(`есть новая версия от ${ver.config_default_date.slice(0, 10)}`)
    }
  }

  return [
    {
      label: 'Версия zator', value: verValue, stateClass: verClass, subText: verSub, cli: 'п.5', compact: verClass === '',
      ...(verClass === '' ? { cornerAction: runUpdateCheck, cornerBusy: updateChecking.value, cornerTitle: 'Проверить обновления' } : {}),
    },
    { label: 'zapret2', value: data.zapret2_running ? 'Запущен' : 'Остановлен', stateClass: data.zapret2_running ? 'ok' : 'bad', subText: z2Parts.length ? z2Parts.join('\n') : undefined },
    { label: 'Локи стратегий', value: data.strategy_locks_status ?? '—', to: '/strategies' },
    { label: 'Client scopes', value: scopeMode, stateClass: scopeMode === 'mark' ? 'ok' : '', subText: scopeSub, to: scopeTarget },
    { label: 'Безразборный режим', value: fallbackState, stateClass: fallbackState === 'включен' ? 'ok' : '', to: '/settings/fallback' },
    { label: 'Авторотация', value: data.auto_mode ?? '—', stateClass: data.auto_mode === 'включен' ? 'ok' : '', to: '/settings/auto-mode' },
    { label: 'Фильтр', value: data.hostlist_mode ?? '—', to: '/settings/hostlist' },
    { label: 'FW', value: data.fwtype ?? '—', cli: 'п.9' },
    { label: 'Offload', value: data.flowoffload ?? '—', cli: 'п.11' },
    { label: 'TLS blob', value: data.tls_blob_mode ?? '—', to: '/settings/tls-blob' },
    { label: 'WireGuard', value: data.wireguard ?? '—', stateClass: data.wireguard === 'включено' ? 'ok' : '', to: '/settings/wireguard' },
    { label: 'RST guard', value: data.rst_guard ?? '—', stateClass: data.rst_guard === 'включен' ? 'ok' : '', to: '/settings/rst-guard' },
    { label: 'Антиспуф DNS', value: dnsProfile ? (dnsProfile.dns_desync_enabled ? 'включен' : 'выключен') : '—', stateClass: dnsProfile?.dns_desync_enabled ? 'ok' : '', to: '/settings/dns-desync' },
    { label: 'Провайдер', value: providerName, subText: providerCity || undefined, to: '/settings/provider' },
  ]
})
</script>

<template>
  <div class="stats-grid" id="status-cards">
    <StatCard v-for="card in cards" :key="card.label" v-bind="card" />
  </div>
</template>
