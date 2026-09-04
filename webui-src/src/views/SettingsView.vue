<script setup lang="ts">
import { nextTick, watch } from 'vue'
import { useRoute } from 'vue-router'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { loadAllSettings } from '../stores/settings'
import { refreshBackups } from '../stores/backups'
import { showToast } from '../stores/toast'
import { settingsPanels } from '../components/settings/panels'

const route = useRoute()

async function refresh() {
  try {
    await withBusy('refresh-settings', async () => {
      await loadAllSettings()
      await refreshBackups()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

watch(() => route.params.panel, async (panel) => {
  if (!panel) return
  await nextTick()
  const element = document.getElementById(`settings-${panel}`)
  if (!element) return
  element.scrollIntoView({ block: 'start' })
  element.classList.add('is-target')
  window.setTimeout(() => element.classList.remove('is-target'), 2600)
}, { immediate: true })
</script>

<template>
  <section class="view is-active" id="view-settings">
    <div class="actions">
      <button id="refresh-settings" :class="{ 'is-busy': busyButton === 'refresh-settings' }" :disabled="busyActive"
        type="button" @click="refresh">Обновить</button>
    </div>

    <component :is="panel.component" v-for="panel in settingsPanels" :key="panel.id" v-bind="panel.props"
      :id="`settings-${panel.id}`" />
  </section>
</template>
