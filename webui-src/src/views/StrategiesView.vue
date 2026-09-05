<script setup lang="ts">
import { computed, nextTick, onMounted, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { fetchAndApplyState } from '../stores/state'
import { locks, refreshAll, scope, scopes, statusLoaded } from '../stores/status'
import { showToast } from '../stores/toast'
import StrategyCard from '../components/strategies/StrategyCard.vue'

const route = useRoute()
const router = useRouter()

const scopeOptions = computed(() => scopes.value.scopes || ['default'])
const scopeWarning = computed(() => scopes.value.warning || '')

// диплинк /strategies?focus=N: скролл к карточке профиля + подсветка
function focusProfileCard() {
  const focus = route.query.focus
  if (!focus) return
  const element = document.getElementById(`strategy-card-${focus}`)
  if (!element) return
  element.scrollIntoView({ block: 'start' })
  element.classList.add('is-target')
  window.setTimeout(() => element.classList.remove('is-target'), 6100)
}

watch(() => route.query.focus, async () => {
  await nextTick()
  focusProfileCard()
}, { immediate: true })

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
    <div v-if="!statusLoaded" class="status-loading" aria-live="polite">Пожалуйста подождите...</div>
    <div v-else class="profile-grid" id="strategy-cards">
      <StrategyCard v-for="profile in locks" :key="profile.profile" :profile="profile" />
    </div>
  </section>
</template>
