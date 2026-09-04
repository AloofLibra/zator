<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useRoute } from 'vue-router'
import { busyActive } from './stores/busy'
import { loadAllSettings } from './stores/settings'
import { refreshAll, statusLoaded } from './stores/status'
import { refreshBackups } from './stores/backups'
import { showToast } from './stores/toast'
import { theme, type ThemeMode } from './stores/theme'
import ToastHost from './components/ui/ToastHost.vue'
import ConfirmDialog from './components/ui/ConfirmDialog.vue'

const route = useRoute()

const tabs = [
  { view: 'status', label: 'Статус' },
  { view: 'strategies', label: 'Стратегии' },
  { view: 'domains', label: 'Домены' },
  { view: 'settings', label: 'Настройки' },
]

const activeView = computed(() => String(route.name || 'status'))
const themeSelect = computed({
  get: () => theme.value,
  set: (value: string) => { theme.value = value as ThemeMode },
})

onMounted(() => {
  refreshAll()
    .catch((error) => showToast((error as Error).message, 'error'))
    .finally(() => { statusLoaded.value = true })
  loadAllSettings()
    .then(() => refreshBackups())
    .catch((error) => showToast((error as Error).message, 'error'))
})
</script>

<template>
  <main class="app">
    <header class="hero">
      <div class="hero-copy">
        <p class="eyebrow">zator</p>
        <router-link to="/" class="brand-link" id="brand-link" role="button" tabindex="0">
          <img class="brand-logo" :src="'/favicon.svg'" alt="" aria-hidden="true"><span class="brand-label">z2r Web UI</span>
        </router-link>
        <p class="subtitle">Управление zapret2: статус, проверки доступности, стратегии и настройки обхода.</p>
      </div>

      <div class="header-controls">
        <nav class="tabs" aria-label="Разделы">
          <router-link v-for="tab in tabs" :key="tab.view" :to="tab.view === 'status' ? '/' : `/${tab.view}`"
            class="tab" :class="{ 'is-active': activeView === tab.view, 'is-locked': busyActive }">
            {{ tab.label }}
          </router-link>
        </nav>

        <label class="theme-field" for="theme-mode">
          <span>Тема</span>
          <select id="theme-mode" v-model="themeSelect" aria-label="Тема интерфейса">
            <option value="auto">Авто</option>
            <option value="light">Светлая</option>
            <option value="dark">Тёмная</option>
          </select>
        </label>
      </div>
    </header>

    <router-view />

    <ToastHost />
    <ConfirmDialog />
  </main>
</template>
