<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll } from '../../stores/status'
import { provider, refreshProvider } from '../../stores/settings'
import { showToast } from '../../stores/toast'

const nameInput = ref<HTMLInputElement | null>(null)
const cityInput = ref<HTMLInputElement | null>(null)

const name = ref('')
const city = ref('')
const current = computed(() => provider.value?.provider || 'Не определён')

watch(provider, (data) => {
  const raw = data?.provider
  // не затираем поля, которые пользователь сейчас редактирует
  if (document.activeElement !== nameInput.value) {
    name.value = raw === 'Не определён' ? '' : String(raw || '').split(' - ')[0]
  }
  if (document.activeElement !== cityInput.value) {
    const parts = String(raw || '').split(' - ')
    city.value = parts.length > 1 ? parts.slice(1).join(' - ') : ''
  }
}, { immediate: true })

const submitDisabled = computed(() => busyActive.value || name.value.trim() === '')

async function submit() {
  const value = name.value.trim()
  if (!value) {
    showToast('Укажите название провайдера.', 'error')
    return
  }
  try {
    await withBusy('provider-save', async () => {
      await applySetting.provider_set(value, city.value.trim())
      showToast('Провайдер сохранён.')
      await refreshProvider()
      await refreshAll()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function redetect() {
  try {
    await withBusy('provider-redetect', async () => {
      const payload = await applySetting.provider_redetect()
      if (payload.provider && payload.provider !== 'Не удалось определить') {
        showToast(`Провайдер определён: ${payload.provider}`)
      } else {
        showToast('Не удалось определить провайдера автоматически. Задайте вручную.', 'warning')
      }
      await refreshProvider()
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
      <h2>Провайдер</h2>
    </div>
    <p class="panel-desc">
      Провайдер определяется по номеру автономной системы (ASN) вашего оператора —
      это надёжнее геолокации по IP: ASN одинаков у всех источников, а названия
      из гео-баз часто неточные. Город определяется приблизительно.
    </p>
    <p class="panel-desc">
      Если определилось неверно — задайте значение вручную. На сам обход эта
      настройка не влияет.
    </p>

    <form id="provider-form" class="settings-form" @submit.prevent="submit">
      <label>
        <span>Провайдер</span>
        <input type="text" id="provider-name-input" ref="nameInput" v-model="name" :disabled="busyActive"
          placeholder="Например: MTS, Beeline, Ростелеком">
      </label>
      <label>
        <span>Город (необязательно)</span>
        <input type="text" id="provider-city-input" ref="cityInput" v-model="city" :disabled="busyActive"
          placeholder="Москва">
      </label>
      <div class="form-hint">Текущее значение: <code id="provider-current">{{ current }}</code></div>
      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'provider-save' }"
          :disabled="submitDisabled">Сохранить</button>
        <button type="button" class="ghost" id="provider-redetect-btn"
          :class="{ 'is-busy': busyButton === 'provider-redetect' }" :disabled="busyActive"
          @click="redetect">Определить заново</button>
      </div>
    </form>
  </section>
</template>
