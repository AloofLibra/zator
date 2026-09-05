<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll } from '../../stores/status'
import { refreshWgBlobSettings, refreshWgStateSettings, wgBlobSettings, wgStateSettings } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'
import NumberStepper from '../ui/NumberStepper.vue'

const blobData = computed(() => wgBlobSettings.value)
const stateData = computed(() => wgStateSettings.value)
const savedEnabled = computed(() => stateData.value?.enabled === true)

const enabled = ref(false)
watch(savedEnabled, (value) => { enabled.value = value }, { immediate: true })

const savedBlob = computed(() => blobData.value?.current_blob || '')
const savedRepeats = computed(() => String(blobData.value?.current_repeats || ''))

const blob = ref('')
const repeats = ref('')
watch(blobData, (data) => {
  if (data?.current_blob) blob.value = data.current_blob
  if (data?.current_repeats) repeats.value = String(data.current_repeats)
}, { immediate: true })

const noBlobs = computed(() =>
  !(Array.isArray(blobData.value?.available_blobs) && (blobData.value?.available_blobs || []).length > 0))

const stateChanged = computed(() => (savedEnabled.value ? '1' : '0') !== (enabled.value ? '1' : '0'))
const blobChanged = computed(() => blob.value !== savedBlob.value)
const repeatsChanged = computed(() => repeats.value.trim() !== savedRepeats.value)
const submitDisabled = computed(() =>
  busyActive.value || !(stateChanged.value || (enabled.value && (blobChanged.value || repeatsChanged.value))))

async function submit() {
  const repeatsRaw = repeats.value.trim()
  const repeatsValue = Number(repeatsRaw)
  if (enabled.value) {
    if (!blob.value) {
      showToast('Выберите файл blob для WireGuard.', 'error')
      return
    }
    if (!/^[0-9]+$/.test(repeatsRaw) || repeatsValue < 2 || repeatsValue > 99) {
      showToast('Повторы должны быть целым числом от 2 до 99.', 'error')
      return
    }
  }
  try {
    await withBusy('wireguard', async () => {
      const calls: Array<(restart: boolean) => Promise<{ restarted?: boolean }>> = []
      if (stateChanged.value) calls.push((restart) => applySetting.wg_state(enabled.value, restart))
      if (enabled.value && blob.value && blobChanged.value) calls.push((restart) => applySetting.wg_blob(blob.value, restart))
      if (enabled.value && repeatsRaw && repeatsChanged.value) calls.push((restart) => applySetting.wg_repeats(repeatsValue, restart))
      announceRestart()
      let payload: { restarted?: boolean } = {}
      for (let i = 0; i < calls.length; i++) {
        payload = await calls[i](i === calls.length - 1) || payload
      }
      const message = stateChanged.value
        ? enabled.value ? 'Стратегия WireGuard включена.' : 'Стратегия WireGuard выключена.'
        : 'Настройки WireGuard сохранены.'
      showToast(message + restartSuffix(payload))
      await refreshWgBlobSettings()
      await refreshWgStateSettings()
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
      <h2>WireGuard</h2>
      <span class="chip" id="wg-state-chip" :class="{ 'is-ok': savedEnabled }">
        {{ savedEnabled ? 'включено' : 'выключено' }}
      </span>
    </div>
    <p class="panel-desc">
      Стратегия WireGuard отправляет несколько фейковых пакетов инициации до
      настоящего, чтобы сбить с толку ТСПУ/DPI.
    </p>
    <p class="panel-desc">
      Здесь можно включить/выключить стратегию, выбрать fake-пакет и количество его
      повторов (repeats). При изменении zapret2 перезапускается автоматически.
    </p>

    <form id="wg-blob-form" class="settings-form" @submit.prevent="submit">
      <label class="toggle-field">
        <input type="checkbox" id="wg-state-toggle" v-model="enabled" :disabled="busyActive">
        <span>Включить стратегию WireGuard</span>
      </label>

      <label>
        <span>Файл blob</span>
        <select id="wg-blob-select" v-model="blob" required :disabled="!enabled || busyActive">
          <option v-if="noBlobs" value="">WireGuard не найден в конфиге</option>
          <option v-for="name in blobData?.available_blobs || []" :key="name" :value="name">{{ name }}</option>
        </select>
      </label>

      <label>
        <span>Количество повторов (2–99)</span>
        <NumberStepper v-model="repeats" :min="2" :max="99" up-label="Увеличить повторов"
          down-label="Уменьшить повторов" :disabled="!enabled || busyActive" />
      </label>

      <div class="form-hint">
        Текущий файл: <code id="current-wg-blob-file">{{ blobData?.current_blob || '—' }}</code>
      </div>

      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'wireguard' }"
          :disabled="submitDisabled">Сохранить</button>
      </div>
    </form>
  </section>
</template>
