<script setup lang="ts">
import { onBeforeUnmount, ref, watch } from 'vue'
import { toast, type ToastState } from '../../stores/toast'

const current = ref<ToastState | null>(null)
const visible = ref(false)
let hideTimer = 0
let removeTimer = 0

function dismiss() {
  if (!current.value) return
  window.clearTimeout(hideTimer)
  visible.value = false
  window.setTimeout(() => { current.value = null }, 300)
}

watch(toast, (value) => {
  if (!value) return
  window.clearTimeout(removeTimer)
  current.value = value
  visible.value = false
  requestAnimationFrame(() => { visible.value = true })
  window.clearTimeout(hideTimer)
  hideTimer = window.setTimeout(dismiss, value.type === 'error' ? 8000 : 3500)
})

onBeforeUnmount(() => window.clearTimeout(hideTimer))
</script>

<template>
  <div v-if="current" class="toast-region" role="status" aria-live="polite" aria-atomic="true">
    <div :class="['toast', current.type, { 'is-visible': visible }]" :role="current.type === 'error' ? 'alert' : undefined">
      <div class="toast-message">{{ current.message }}</div>
      <button type="button" class="toast-close" aria-label="Закрыть уведомление" @click="dismiss">×</button>
    </div>
  </div>
</template>
