<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll } from '../../stores/status'
import { refreshWssizeRampSettings, wssizeRampSettings } from '../../stores/settings'
import type { WssizeRampSettings } from '../../api/types'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const settings = computed(() => wssizeRampSettings.value)
const enabled = ref(false)
const ip = ref('')
const mode = ref<WssizeRampSettings['mode']>('full')
const scale = ref(5)
watch(settings, (value) => {
  if (!value) return
  enabled.value = value.enabled
  ip.value = value.ip
  mode.value = value.mode
  scale.value = value.scale
}, { immediate: true })

const validIp = computed(() => (!enabled.value && !ip.value.trim())
  || /^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/.test(ip.value.trim()))
const unchanged = computed(() => !!settings.value && enabled.value === settings.value.enabled
  && ip.value.trim() === settings.value.ip && mode.value === settings.value.mode
  && scale.value === settings.value.scale)

async function submit() {
  if (!validIp.value || !Number.isInteger(scale.value) || scale.value < 0 || scale.value > 14) return
  const value = { enabled: enabled.value, ip: ip.value.trim(), mode: mode.value, scale: scale.value }
  try {
    await withBusy('wssize-ramp', async () => {
      announceRestart()
      const result = await applySetting.wssize_ramp(value)
      showToast(`wssize_ramp настройки сохранены.${restartSuffix(result)}`)
      await refreshWssizeRampSettings()
      await refreshAll()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
    await refreshWssizeRampSettings()
  }
}
</script>

<template>
  <section class="panel">
    <div class="panel-header">
      <h2>Экспериментальный wssize_ramp</h2>
      <span class="chip" id="wssize-ramp-state-chip" :class="{ 'is-ok': settings?.enabled }">
        {{ settings?.enabled ? 'включен' : 'выключен' }}
      </span>
    </div>
    <p class="panel-desc">Настраивает TCP receive window для одного IPv4 сервера. После сохранения zapret2 перезапускается, если он запущен.</p>
    <form id="wssize-ramp-form" class="settings-form" @submit.prevent="submit">
      <label class="toggle-field">
        <input id="wssize-ramp-toggle" type="checkbox" v-model="enabled" :disabled="busyActive">
        <span>Включить wssize_ramp</span>
      </label>
      <label>
        <span>IPv4 сервера</span>
        <input id="wssize-ramp-ip" v-model="ip" inputmode="decimal" autocomplete="off" :disabled="busyActive"
          placeholder="например, 188.244.8.77">
      </label>
      <label>
        <span>Режим</span>
        <select id="wssize-ramp-mode" v-model="mode" :disabled="busyActive">
          <option value="full">Full — пересчитывать окно на последующих ACK</option>
          <option value="lite">Lite — прекратить подмену после первых байтов ответа</option>
        </select>
      </label>
      <label>
        <span>Scale (0–14)</span>
        <input id="wssize-ramp-scale" v-model.number="scale" type="number" min="0" max="14" step="1" :disabled="busyActive">
      </label>
      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'wssize-ramp' }"
          :disabled="busyActive || unchanged || !validIp || !Number.isInteger(scale) || scale < 0 || scale > 14">Сохранить</button>
      </div>
    </form>
  </section>
</template>
