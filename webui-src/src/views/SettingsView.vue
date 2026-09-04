<script setup lang="ts">
import { nextTick, watch } from 'vue'
import { useRoute } from 'vue-router'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { refreshBackups } from '../stores/backups'
import { loadAllSettings, settingsLoaded } from '../stores/settings'
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

function scrollToPanel(highlight: boolean) {
  const panel = route.params.panel
  if (!panel) return
  const element = document.getElementById(`settings-${panel}`)
  if (!element) return
  element.scrollIntoView({ block: 'start' })
  if (!highlight) return
  element.classList.add('is-target')
  window.setTimeout(() => element.classList.remove('is-target'), 2600)
}

watch(() => route.params.panel, async () => {
  await nextTick()
  scrollToPanel(true)
}, { immediate: true })

// догрузка данных настроек сдвигает layout — доскролливаем ещё раз после неё
watch(settingsLoaded, (loaded) => {
  if (loaded) nextTick(() => scrollToPanel(false))
})
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
