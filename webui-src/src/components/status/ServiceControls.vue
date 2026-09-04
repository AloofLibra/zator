<script setup lang="ts">
import { computed } from 'vue'
import { serviceAction } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll, status } from '../../stores/status'
import { showToast } from '../../stores/toast'

const running = computed(() => Boolean(status.value?.zapret2_running))
const restartTitle = computed(() => running.value ? 'Перезапустить zapret2' : 'zapret2 остановлен')

async function run(action: 'start' | 'stop' | 'restart') {
  const messages = {
    start: 'zapret2 включен.',
    stop: 'zapret2 выключен.',
    restart: 'zapret2 перезапущен.',
  }
  try {
    await withBusy(action === 'restart' ? 'restart' : 'toggle', async () => {
      await serviceAction(action)
      await refreshAll()
    })
    showToast(messages[action])
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <div class="service-control" :class="{ 'is-running': running }" aria-label="Управление zapret2">
    <button id="toggle-service" class="service-toggle"
      :class="[running ? 'is-stop' : 'is-start', { 'is-busy': busyButton === 'toggle' }]"
      :disabled="busyActive" type="button" @click="run(running ? 'stop' : 'start')">
      {{ running ? 'Остановить zapret2' : 'Включить zapret2' }}
    </button>
    <button id="restart-service" class="service-restart" :class="{ 'is-busy': busyButton === 'restart' }"
      :disabled="busyActive || !running" type="button" :title="restartTitle" :aria-label="restartTitle"
      @click="run('restart')">↻</button>
  </div>
</template>
