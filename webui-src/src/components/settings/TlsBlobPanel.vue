<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshTlsBlobSettings, tlsBlobSettings } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const settings = computed(() => tlsBlobSettings.value)

const mode = computed(() => settings.value?.current_mode || '')
const isBuiltin = computed(() => mode.value === 'fake_default_tls')
const maxruFile = computed(() => settings.value?.current_blob || '')

const currentFile = computed(() =>
  isBuiltin.value ? 'fake_default_tls (встроенный)' : (maxruFile.value || '—'))

const statusText = computed(() =>
  mode.value === 'fake_default_tls' ? 'default' : mode.value || 'не определён')

const listedBlobs = computed(() =>
  Array.isArray(settings.value?.available_blobs) ? settings.value?.available_blobs || [] : [])
const blobs = computed(() =>
  maxruFile.value && !listedBlobs.value.includes(maxruFile.value)
    ? [maxruFile.value, ...listedBlobs.value]
    : listedBlobs.value)

const placeholderText = computed(() =>
  !isBuiltin.value && maxruFile.value
    ? maxruFile.value + ' (текущий) — выберите файл'
    : 'Выберите блоб')

const saved = computed(() => isBuiltin.value ? 'fake_default_tls' : maxruFile.value)
const selected = ref('')
watch(saved, () => {
  if (isBuiltin.value) selected.value = 'fake_default_tls'
}, { immediate: true })

const submitDisabled = computed(() =>
  busyActive.value || !selected.value || selected.value === saved.value)

async function submit() {
  if (!selected.value) {
    showToast('Выберите блоб.', 'error')
    return
  }
  try {
    await withBusy('tls-blob', async () => {
      announceRestart()
      const payload = await applySetting.tls_blob(selected.value)
      showToast('TLS-блоб изменён.' + restartSuffix(payload))
      await refreshTlsBlobSettings()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="panel">
    <div class="panel-header">
      <h2>TLS Blob</h2>
      <span class="chip" id="tls-blob-status" :class="{ 'is-ok': mode === 'maxru' }">{{ statusText }}</span>
    </div>
    <p class="panel-desc">
      Выбор TLS-блоба для стратегий обхода. При изменении zapret2 перезапускается автоматически.
    </p>

    <form id="tls-blob-form" class="settings-form" @submit.prevent="submit">
      <label>
        <span>Выберите блоб</span>
        <select id="tls-blob-select" v-model="selected" required :disabled="busyActive">
          <option value="" disabled>{{ placeholderText }}</option>
          <option value="fake_default_tls" :disabled="isBuiltin">
            fake_default_tls (встроенный){{ isBuiltin ? ' (текущий)' : '' }}
          </option>
          <option v-for="blob in blobs" :key="blob" :value="blob"
            :disabled="!isBuiltin && blob === maxruFile">
            {{ blob }}{{ !isBuiltin && blob === maxruFile ? ' (текущий)' : '' }}
          </option>
        </select>
      </label>

      <div class="form-hint">
        Текущий файл: <code id="current-blob-file">{{ currentFile }}</code>
      </div>

      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'tls-blob' }"
          :disabled="submitDisabled">Сохранить</button>
      </div>
    </form>
  </section>
</template>
