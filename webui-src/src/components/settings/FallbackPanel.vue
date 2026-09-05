<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { confirmDialog } from '../../stores/confirm'
import { refreshAll } from '../../stores/status'
import { fallbackSettings, refreshFallbackSettings } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const settings = computed(() => fallbackSettings.value)
const unavailable = computed(() => settings.value?.state === 'недоступен')
const savedEnabled = computed(() => settings.value?.state === 'включен')

const enabled = ref(false)
watch(savedEnabled, (value) => { enabled.value = value }, { immediate: true })

const chipText = computed(() =>
  unavailable.value ? 'недоступен' : savedEnabled.value ? 'включен' : 'выключен')
const submitDisabled = computed(() =>
  busyActive.value || unavailable.value || (enabled.value ? '1' : '0') === (savedEnabled.value ? '1' : '0'))

async function submit() {
  const enable = enabled.value
  const confirmed = await confirmDialog({
    title: enable ? 'Включить безразборный режим?' : 'Выключить безразборный режим?',
    message: enable
      ? [
          'Обход будет применяться ко всему трафику на выбранных портах, а не только к доменам из списков.',
          'После включения выберите стратегии для TLS (профиль 8) и HTTP (профиль 9) во вкладке «Стратегии».',
          'zapret2 перезапустится сразу.',
        ]
      : [
          'Обход снова будет применяться только к доменам из списков и выбранным стратегиям.',
          'zapret2 перезапустится сразу.',
        ],
    confirmText: enable ? 'Включить' : 'Выключить',
    cancelText: 'Отмена',
  })
  if (!confirmed) {
    enabled.value = !enable
    return
  }
  try {
    await withBusy('fallback', async () => {
      announceRestart()
      const payload = await applySetting.fallback_state(enable)
      showToast((enable ? 'Безразборный режим включён.' : 'Безразборный режим выключен.') + restartSuffix(payload))
      await refreshFallbackSettings()
      await refreshAll()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="panel">
    <div class="panel-header">
      <h2>Безразборный режим (Fallback)</h2>
      <router-link class="ghost" :to="{ path: '/strategies', query: { focus: '8,9' } }">Выбрать стратегии →</router-link>
      <span class="chip" id="fallback-state-chip" :class="{ 'is-ok': savedEnabled }">{{ chipText }}</span>
    </div>
    <p class="panel-desc">
      Безразборный режим применяет обход ко всему трафику на выбранных портах, а не
      только к доменам из списков. Это самый грубый, но надёжный способ — попробуйте
      его, если точные стратегии не помогают.
    </p>
    <p class="panel-desc">
      Включите режим, затем выберите стратегию для TLS (профиль 8) и HTTP (профиль 9)
      во вкладке «Стратегии». Режим и авторотация взаимно исключают друг друга: перед
      включением одного выключите другое.
    </p>

    <div class="settings-alert" id="fallback-state-alert" :hidden="!unavailable">
      Авторотация включена. Выключите её, чтобы управлять безразборным режимом.
    </div>

    <form id="fallback-state-form" class="settings-form" @submit.prevent="submit">
      <label class="toggle-field">
        <input type="checkbox" id="fallback-state-toggle" v-model="enabled" :disabled="unavailable || busyActive">
        <span>Включить безразборный режим</span>
      </label>
      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'fallback' }"
          :disabled="submitDisabled">Сохранить</button>
      </div>
    </form>
  </section>
</template>
