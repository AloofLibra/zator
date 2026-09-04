<script setup lang="ts">
import { computed } from 'vue'
import type { RouteLocationRaw } from 'vue-router'
import StatCard from '../ui/StatCard.vue'
import { status } from '../../stores/status'
import { fallbackSettings } from '../../stores/settings'

interface CardDef {
  label: string
  value: string
  stateClass?: string
  subText?: string
  to?: RouteLocationRaw
  cli?: string
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

  return [
    { label: 'zapret2', value: data.zapret2_running ? 'Запущен' : 'Остановлен', stateClass: data.zapret2_running ? 'ok' : 'bad' },
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
