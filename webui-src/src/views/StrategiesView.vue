<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { fetchAndApplyState } from '../stores/state'
import { locks, refreshAll, scope, scopes, status, statusLoaded } from '../stores/status'
import { showToast } from '../stores/toast'
import { fetchRecommendations } from '../api/endpoints'
import type { Recommendations } from '../api/types'
import { provider } from '../stores/settings'
import StrategyCard from '../components/strategies/StrategyCard.vue'

const route = useRoute()
const router = useRouter()

const recommendations = ref<Recommendations | null>(null)
const recommendationsLoading = ref(false)
const recommendationsRefresh = ref(0)
const recommendationProvider = computed(() => provider.value?.provider || status.value?.provider || '')
const recommendationDate = computed(() => {
  const timestamp = recommendations.value?.generated_at
  return typeof timestamp === 'number' && timestamp > 0 && Number.isFinite(timestamp)
    ? new Date(timestamp * 1000).toLocaleString('ru-RU') : ''
})
// Только эта страница: отмена старого запроса не даёт смене провайдера показать чужие данные.
watch([statusLoaded, () => status.value?.provider, () => provider.value?.provider, recommendationsRefresh], async ([loaded], _previous, onCleanup) => {
  recommendations.value = null
  if (!loaded) return
  recommendationsLoading.value = true
  const controller = new AbortController()
  let active = true
  const timeout = window.setTimeout(() => controller.abort(), 12000)
  onCleanup(() => { active = false; controller.abort(); window.clearTimeout(timeout) })
  try {
    const data = await fetchRecommendations(controller.signal)
    if (active && typeof data.provider === 'string' && Number.isInteger(data.samples) && data.samples >= 0 &&
      data.minimum === 10 && ['ready', 'stale', 'insufficient', 'unavailable', 'unknown_provider'].includes(data.status)) {
      recommendations.value = data
    }
  } catch {
    // Рекомендации необязательны: отказ сервера не блокирует управление стратегиями.
  } finally {
    window.clearTimeout(timeout)
    if (active) recommendationsLoading.value = false
  }
}, { immediate: true })

const scopeOptions = computed(() => scopes.value.scopes || ['default'])
const scopeWarning = computed(() => scopes.value.warning || '')

// диплинк /strategies?focus=N или списком через запятую (focus=8,9):
// скролл к самой верхней карточке в DOM + подсветка всех перечисленных профилей
function focusProfileCard() {
  const focus = route.query.focus
  if (!focus) return
  const raw = Array.isArray(focus) ? focus.join(',') : String(focus)
  const elements = raw.split(',')
    .map((id) => document.getElementById(`strategy-card-${id.trim()}`))
    .filter((element): element is HTMLElement => element !== null)
  if (!elements.length) return
  const top = elements.reduce((a, b) => (a.getBoundingClientRect().top <= b.getBoundingClientRect().top ? a : b))
  top.scrollIntoView({ block: 'start' })
  for (const element of elements) {
    element.classList.add('is-target')
    window.setTimeout(() => element.classList.remove('is-target'), 6100)
  }
}

watch(() => route.query.focus, async () => {
  await nextTick()
  focusProfileCard()
}, { immediate: true })

// при F5 по диплинку карточки появляются только после загрузки state,
// поэтому наводим фокус повторно (как SettingsView для панелей настроек)
watch(statusLoaded, async (loaded) => {
  if (!loaded) return
  await nextTick()
  focusProfileCard()
})

onMounted(() => {
  const fromUrl = route.query.scope
  if (typeof fromUrl === 'string' && fromUrl && fromUrl !== scope.value) {
    scope.value = fromUrl
    refreshAll().catch((error) => showToast((error as Error).message, 'error'))
  }
})

function changeScope(value: string) {
  scope.value = value || 'default'
  router.replace({ query: { scope: scope.value } })
  refreshAll().catch((error) => showToast((error as Error).message, 'error'))
}

async function refresh() {
  recommendationsRefresh.value++
  try {
    await withBusy('refresh-locks', fetchAndApplyState)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="view is-active" id="view-strategies" :class="{ 'is-loading': !statusLoaded }">
    <div v-if="statusLoaded" class="actions">
      <label class="scope-picker" for="client-scope"><span>Scope клиента</span>
        <select id="client-scope" :disabled="busyActive" @change="changeScope(($event.target as HTMLSelectElement).value)">
          <option v-if="!scopeOptions.includes(scope)" :value="scope">{{ scope }}</option>
          <option v-for="name in scopeOptions" :key="name" :value="name" :selected="name === scope">{{ name }}</option>
        </select>
      </label>
      <span v-if="scopeWarning" id="scope-warning" class="settings-alert">{{ scopeWarning }}</span>
      <button id="refresh-locks" :class="{ 'is-busy': busyButton === 'refresh-locks' }" :disabled="busyActive"
        type="button" @click="refresh">Обновить</button>
    </div>
    <aside v-if="statusLoaded" class="recommendations-banner" aria-live="polite">
      <strong>Опыт сообщества · {{ recommendations?.provider || recommendationProvider || 'Провайдер не определён' }}</strong>
      <p v-if="recommendationsLoading">Загружаем рекомендации…</p>
      <template v-else-if="recommendations && ['ready', 'stale', 'insufficient'].includes(recommendations.status)">
        <p>{{ recommendations.samples }} уникальных установок · минимум {{ recommendations.minimum }}
          <span v-if="recommendationDate"> · Обновлено {{ recommendationDate }}</span></p>
        <p v-if="recommendations.status === 'insufficient' || recommendations.samples < 10">Пока недостаточно статистики вашего провайдера. Подсказки появятся после завершённых суперсвипов от 10 разных установок.</p>
        <template v-else>
          <p v-if="recommendations.status === 'stale'" class="recommendations-warning">Сервер недоступен. Показаны ранее сохранённые данные, они могут быть устаревшими.</p>
          <p class="recommendations-note">Процент — доля зелёных результатов среди проверок этой стратегии, рядом число участвовавших установок. Повторные прогоны одного UUID не увеличивают выборку. Подсказка сообщества, не гарантия: проверьте работу у себя.</p>
        </template>
      </template>
      <p v-else-if="recommendations?.status === 'unknown_provider'">Провайдер не определён или отсутствует в базе рекомендаций.</p>
      <p v-else>Рекомендации сейчас недоступны. Стратегии можно выбрать вручную.</p>
    </aside>
    <div v-if="!statusLoaded" class="status-loading" aria-live="polite">Пожалуйста подождите...</div>
    <div v-else class="profile-grid" id="strategy-cards">
      <StrategyCard v-for="profile in locks" :key="profile.profile" :profile="profile" :recommendations="recommendations" />
    </div>
  </section>
</template>

<style scoped>
.recommendations-banner { margin-bottom: 1rem; padding: .9rem 1rem; border: 1px solid var(--line); border-radius: var(--radius-sm); background: var(--surface); font-size: .85rem; }
.recommendations-banner strong { display: block; overflow-wrap: anywhere; }
.recommendations-banner p { margin: .35rem 0 0; color: var(--muted); }
.recommendations-banner .recommendations-note { font-size: .78rem; line-height: 1.5; }
.recommendations-banner .recommendations-warning { color: var(--warning); }
</style>
