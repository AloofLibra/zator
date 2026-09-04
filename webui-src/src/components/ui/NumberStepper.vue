<script setup lang="ts">
import { computed } from 'vue'

const props = withDefaults(defineProps<{
  modelValue: string
  min?: number
  max?: number
  upLabel: string
  downLabel: string
  disabled?: boolean
}>(), { min: 1, max: 99, disabled: false })

const emit = defineEmits<{
  'update:modelValue': [value: string]
  step: [direction: number]
}>()

const inputMin = computed(() => String(props.min))
const inputMax = computed(() => String(props.max))

function step(direction: number) {
  const parsed = Number(props.modelValue)
  const current = Number.isFinite(parsed) ? parsed : props.min
  const next = Math.min(props.max, Math.max(props.min, current + direction))
  emit('update:modelValue', String(next))
  emit('step', direction)
}
</script>

<template>
  <div class="number-stepper">
    <input type="number" :min="inputMin" :max="inputMax" step="1" required :disabled="disabled"
      :value="modelValue" @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)">
    <div class="stepper-buttons">
      <button type="button" :disabled="disabled" :aria-label="upLabel" @click="step(1)">↑</button>
      <button type="button" :disabled="disabled" :aria-label="downLabel" @click="step(-1)">↓</button>
    </div>
  </div>
</template>
