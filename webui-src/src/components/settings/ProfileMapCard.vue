<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { fetchCustomBlobs } from '../../api/endpoints'
import type { SniProfileInfo } from '../../api/types'
import { refreshTlsBlobSettings, tlsBlobSettings } from '../../stores/settings'

// Карта профилей — верхняя карточка вкладки «Блобы и SNI»: с первого взгляда
// видно режим ([blob]/[clone-solo]/[clone-pool]), блоб и SNI каждого профиля.
// Данные: sni-блок blobs.cgi + режимы/блобы из стора tls_blob (его же
// обновляет панель блобов ниже). Синхронно с CLI-тегами lib/submenus.sh
// (fake_mode_profile_tag); у классики без пина/пула SNI-часть не выводится.
const profiles = ref<SniProfileInfo[]>([])
const unavailable = ref(false)
const tls = computed(() => tlsBlobSettings.value)

const LEGEND = [
  { tag: '[blob]', text: 'блобы конфига', clone: false },
  { tag: '[clone-solo]', text: 'клон, один SNI', clone: true },
  { tag: '[clone-pool]', text: 'клон, пул', clone: true },
]

async function load() {
  const data = await fetchCustomBlobs()
  if (!data.sni) {
    unavailable.value = true
    profiles.value = []
  } else {
    unavailable.value = false
    profiles.value = Array.isArray(data.sni.profiles) ? data.sni.profiles : []
  }
}

onMounted(async () => {
  // цель сборки es2018 — allSettled нет; гасим отказы: карта деградирует
  // (unavailable-заглушка), не роняя вкладку
  await Promise.all([load(), refreshTlsBlobSettings()].map(p => p.catch(() => undefined)))
})

function isClone(p: SniProfileInfo): boolean {
  return (tls.value?.profile_modes?.[p.id] || 'classic') === 'clone'
}

function tag(p: SniProfileInfo): string {
  if (!isClone(p)) return 'blob'
  if (p.pin) return 'clone-solo'
  return (p.set || (p.effective || []).length > 0) ? 'clone-pool' : 'clone-solo'
}

// есть ли смысл показывать SNI-часть: пин/пул значимы и классике (sni_first
// конфиг-клонов), дефолт показываем только клонам — как в CLI
type SniKind = 'pin' | 'pool-set' | 'pool-custom' | 'default' | 'none'

function sniKind(p: SniProfileInfo): SniKind {
  if (p.pin) return 'pin'
  if (p.set) return 'pool-set'
  if ((p.effective || []).length > 0) return 'pool-custom'
  return isClone(p) ? 'default' : 'none'
}

// детали пула из строки pool: «(9 имён, по кругу, автосмена)» или
// «+ свои (4 имён, …)» — без повторения имени
function poolDetails(p: SniProfileInfo): string {
  if (!p.pool) return ''
  if (p.set) return p.pool.replace(`набор ${p.set}`, '').trim()
  return p.pool.replace('свой список', '').trim()
}

function blobName(p: SniProfileInfo): string {
  return tls.value?.profile_blobs?.[p.id] || ''
}
</script>

<template>
  <section class="panel" id="profile-map-card">
    <div class="panel-header">
      <h2>Карта профилей</h2>
      <span v-for="l in LEGEND" :key="l.tag" class="chip map-legend" :class="{ 'is-clone': l.clone }">
        {{ l.tag }} — {{ l.text }}
      </span>
    </div>
    <p class="panel-desc">
      Сводка состояния вкладки: что стоит на каждом профиле прямо сейчас.
      Менять ниже: блобы и режим фейков — панель «TLS-блоб», SNI — панель
      «SNI клон-стратегий и пул».
    </p>

    <div v-if="unavailable" class="status-note">
      SNI-часть недоступна — обновите Core zator (меню 5 → п.1 или релиз).
    </div>

    <div v-for="p in profiles" :key="p.id" class="map-row" :id="`profile-map-${p.id}`">
      <span class="chip map-tag" :class="{ 'is-clone': isClone(p) }">[{{ tag(p) }}]</span>
      <span class="map-title">{{ p.title }}</span>
      <span class="map-item">
        блоб: <b :class="{ 'is-set': !!blobName(p) }">{{ blobName(p) || 'глобальный' }}</b>
      </span>
      <span v-if="sniKind(p) !== 'none'" class="map-item">
        SNI:
        <template v-if="sniKind(p) === 'pin'"><b class="is-set">{{ p.pin }}</b> <i>(пин)</i></template>
        <template v-else-if="sniKind(p) === 'pool-set'">набор <b class="is-set">{{ p.set }}</b> <i>{{ poolDetails(p) }}</i></template>
        <template v-else-if="sniKind(p) === 'pool-custom'"><b class="is-set">свой список</b> <i>{{ poolDetails(p) }}</i></template>
        <template v-else><i>www.google.com (дефолт)</i></template>
      </span>
    </div>
  </section>
</template>

<style scoped>
.map-legend { font-size: 0.74rem; padding: 0.22rem 0.55rem; }
.map-legend.is-clone, .map-tag.is-clone {
  background: rgba(46, 158, 79, 0.14);
  color: #2e9e4f;
}
.map-row {
  display: flex;
  flex-wrap: wrap;
  gap: 0.3rem 0.7rem;
  align-items: baseline;
  padding: 0.5rem 0.15rem;
  border-bottom: 1px solid var(--line);
}
.map-row:last-child { border-bottom: none; }
.map-tag { min-width: 7.6em; text-align: center; font-size: 0.78rem; padding: 0.24rem 0.5rem; }
.map-title { font-weight: 600; flex: 1 1 200px; }
.map-item { color: var(--muted); overflow-wrap: anywhere; }
.map-item b { font-weight: 600; color: var(--text); }
.map-item b.is-set { color: #2e9e4f; }
.map-item i { font-style: normal; font-size: 0.86em; color: var(--muted); }
</style>
