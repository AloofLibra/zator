<script setup lang="ts">
import { computed, nextTick, ref } from 'vue'
import { useRouter } from 'vue-router'
import { runCheck } from '../api/endpoints'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { fetchAndApplyState } from '../stores/state'
import { ports } from '../stores/settings'
import { statusCheck, statusCheckRan, statusLoaded } from '../stores/status'
import { showToast } from '../stores/toast'
import CheckResults from '../components/ui/CheckResults.vue'
import ServiceControls from '../components/status/ServiceControls.vue'
import StatusCards from '../components/status/StatusCards.vue'
import ProfileGrid from '../components/status/ProfileGrid.vue'

const router = useRouter()

const tcpPortsFull = computed(() => String(ports.value?.tcp?.full || '').trim())
const udpPortsFull = computed(() => String(ports.value?.udp?.full || '').trim())

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

    <section class="panel" id="status-ports-panel">
      <div class="panel-header">
        <h2>Порты NFQWS2</h2>
        <router-link class="ghost" :to="{ path: '/settings/ports' }">Управление портами →</router-link>
      </div>
      <div class="meta">
        <div class="meta-line">
          <span>TCP&nbsp;</span>
          <strong id="status-ports-tcp">{{ tcpPortsFull || '—' }}</strong>
        </div>
        <div class="meta-line">
          <span>UDP&nbsp;</span>
          <strong id="status-ports-udp">{{ udpPortsFull || '—' }}</strong>
        </div>
      </div>
    </section>

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
