<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { confirmDialog } from '../../stores/confirm'
import { refreshAll } from '../../stores/status'
import { fallbackSettings, modeSettings, refreshFallbackSettings, refreshModeSetting } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'
import { MODE_TOGGLES } from './modeToggles'

const props = defineProps<{ setting: string }>()

const config = computed(() =>
  MODE_TOGGLES.find((toggle) => toggle.setting === props.setting)!)

const data = computed(() => modeSettings[props.setting])
const savedEnabled = computed(() => data.value?.[config.value.enabledField] === true)
const enabled = ref(false)
watch(savedEnabled, (value) => { enabled.value = value }, { immediate: true })

const luaMissing = computed(() =>
  props.setting === 'rst_guard' && data.value?.lua_available === false)
const fallbackOn = computed(() =>
  props.setting === 'auto_mode' && fallbackSettings.value?.state === 'включен')

const checkboxDisabled = computed(() =>
  busyActive.value || (luaMissing.value && !savedEnabled.value) || fallbackOn.value)
const submitDisabled = computed(() =>
  checkboxDisabled.value || (enabled.value ? '1' : '0') === (savedEnabled.value ? '1' : '0'))
const submitTitle = computed(() =>
  fallbackOn.value ? 'Выключите безразборный режим, чтобы включить авторотацию' : '')

async function submit() {
  if (!config.value) return
  const enable = enabled.value
  if (checkboxDisabled.value) {
    enabled.value = savedEnabled.value
    return
  }
  if (props.setting === 'rst_guard' && enable && luaMissing.value) {
    showToast('На устройстве нет файла rst-guard.lua. Включите защиту через CLI (пункт 18 меню).', 'error')
    enabled.value = false
    return
  }
  if (props.setting === 'auto_mode' && enable && fallbackOn.value) {
    showToast('Авторотация недоступна при включённом безразборном режиме. Сначала выключите безразборный режим.', 'error')
    enabled.value = false
    return
  }
  if (config.value.askConfirm) {
    const confirmed = await confirmDialog({
      title: enable ? config.value.askConfirm.titleOn : config.value.askConfirm.titleOff,
      message: enable ? config.value.askConfirm.messageOn : config.value.askConfirm.messageOff,
      confirmText: enable ? 'Включить' : 'Выключить',
      cancelText: 'Отмена',
    })
    if (!confirmed) {
      enabled.value = !enable
      return
    }
  }
  try {
    await withBusy(`mode-${props.setting}`, async () => {
      announceRestart()
      const payload = await applySetting.mode_state(config.value.postKey, enable)
      showToast((enable ? config.value.onToast : config.value.offToast) + restartSuffix(payload))
      await refreshModeSetting(props.setting)
      if (props.setting === 'auto_mode') await refreshFallbackSettings()
      await refreshAll()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
    await refreshModeSetting(props.setting)
  }
}
</script>

<template>
  <section v-if="config" class="panel">
    <div class="panel-header">
      <h2>{{ config.title }}<span v-if="config.beta" class="chip beta-chip">BETA</span></h2>
      <span class="chip" :id="config.chipId" :class="{ 'is-ok': savedEnabled }">
        {{ savedEnabled ? config.onChip : config.offChip }}
      </span>
    </div>
    <p v-for="(text, index) in config.descriptions" :key="index" class="panel-desc">{{ text }}</p>

    <div v-if="setting === 'auto_mode'" class="settings-alert" id="auto-mode-alert" :hidden="!fallbackOn">
      Безразборный режим включён. Выключите его, чтобы включить авторотацию.
    </div>
    <div v-if="setting === 'rst_guard'" class="form-hint rst-guard-hint" id="rst-guard-hint" :hidden="!luaMissing">
      На устройстве нет файла rst-guard.lua. Включите защиту один раз через CLI (пункт 18 меню) — файл скачается автоматически.
    </div>

    <form :id="config.formId" class="settings-form" @submit.prevent="submit">
      <label class="toggle-field">
        <input type="checkbox" v-model="enabled" :disabled="checkboxDisabled">
        <span>{{ config.toggleLabel }}</span>
      </label>
      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === `mode-${setting}` }"
          :disabled="submitDisabled" :title="submitTitle">Сохранить</button>
      </div>
    </form>
  </section>
</template>
