<script setup lang="ts">
import { nextTick, ref } from 'vue'
import { useRouter } from 'vue-router'
import { runCheck } from '../api/endpoints'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { fetchAndApplyState } from '../stores/state'
import { statusCheck, statusCheckRan, statusLoaded } from '../stores/status'
import { showToast } from '../stores/toast'
import CheckResults from '../components/ui/CheckResults.vue'
import ServiceControls from '../components/status/ServiceControls.vue'
import StatusCards from '../components/status/StatusCards.vue'
import ProfileGrid from '../components/status/ProfileGrid.vue'

const router = useRouter()

async function refresh() {
  try {
    await withBusy('refresh-status', fetchAndApplyState)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function check() {
  try {
    const payload = await withBusy('run-check', () => runCheck())
    statusCheck.value = payload
    statusCheckRan.value = true
    await nextTick()
    const panel = document.getElementById('check-panel')
    if (!panel) return
    panel.scrollIntoView({ block: 'start', behavior: 'smooth' })
    panel.classList.add('is-target')
    window.setTimeout(() => panel.classList.remove('is-target'), 6100)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

const checkEmpty = ref('Нажмите «Проверить доступ», чтобы получить свежие результаты.')
</script>

<template>
  <section class="view is-active" :class="{ 'is-loading': !statusLoaded }" id="view-status">
    <div v-if="statusLoaded" class="actions">
      <ServiceControls />
      <button id="refresh-status" :class="{ 'is-busy': busyButton === 'refresh-status' }" :disabled="busyActive"
        type="button" @click="refresh">Обновить</button>
      <button id="run-check" :class="{ 'is-busy': busyButton === 'run-check' }" :disabled="busyActive"
        type="button" @click="check">Проверить доступ</button>
    </div>

    <div v-if="!statusLoaded" class="status-loading" aria-live="polite">Пожалуйста подождите...</div>

    <StatusCards />

    <section class="panel">
      <div class="panel-header">
        <h2>Профили</h2>
        <button id="open-strategies" class="ghost" :disabled="busyActive" type="button"
          @click="router.push('/strategies')">Открыть управление</button>
      </div>
      <ProfileGrid compact />
    </section>

    <section class="panel" id="check-panel">
      <div class="panel-header">
        <h2>Проверка доступа</h2>
      </div>
      <CheckResults v-if="statusCheckRan" class="checks" :payload="statusCheck" empty-message="Нет результатов проверки." />
      <div v-else id="check-results" class="checks empty">{{ checkEmpty }}</div>
    </section>
  </section>
</template>
