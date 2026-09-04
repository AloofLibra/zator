<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { confirmState, settleConfirm } from '../../stores/confirm'

const visible = ref(false)
const confirmButton = ref<HTMLButtonElement | null>(null)

const messageParts = computed(() => {
  const message = confirmState.value?.message
  if (!message) return []
  return (Array.isArray(message) ? message : [message]).filter(Boolean)
})

function onKeydown(event: KeyboardEvent) {
  if (!confirmState.value) return
  if (event.key === 'Escape') {
    event.preventDefault()
    settleConfirm(false)
  } else if (event.key === 'Enter') {
    event.preventDefault()
    settleConfirm(true)
  }
}

watch(confirmState, (value) => {
  if (!value) return
  visible.value = false
  requestAnimationFrame(() => {
    visible.value = true
    nextTick(() => confirmButton.value?.focus())
  })
})

onMounted(() => document.addEventListener('keydown', onKeydown, true))
onBeforeUnmount(() => document.removeEventListener('keydown', onKeydown, true))
</script>

<template>
  <div v-if="confirmState" :class="['modal-overlay', { 'is-visible': visible }]" role="dialog" aria-modal="true"
    @click.self="settleConfirm(false)">
    <div class="modal-card">
      <h3 class="modal-title">{{ confirmState.title }}</h3>
      <p v-for="(part, index) in messageParts" :key="index" class="modal-message">{{ part }}</p>
      <div class="modal-actions">
        <button v-if="!confirmState.info" type="button" class="ghost modal-cancel" @click="settleConfirm(false)">
          {{ confirmState.cancelText || 'Отмена' }}
        </button>
        <button ref="confirmButton" type="button" :class="confirmState.danger ? 'danger modal-confirm' : 'primary modal-confirm'"
          @click="settleConfirm(true)">
          {{ confirmState.confirmText || 'Подтвердить' }}
        </button>
      </div>
    </div>
  </div>
</template>
