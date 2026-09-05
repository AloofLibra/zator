<script setup lang="ts">
import { computed } from 'vue'
import type { RouteLocationRaw } from 'vue-router'
import { confirmDialog } from '../../stores/confirm'

const props = defineProps<{
  label: string
  value: string
  stateClass?: string
  subText?: string
  to?: RouteLocationRaw
  cli?: string
}>()

const isLong = computed(() => props.value.length > 18)
const hasSub = computed(() => Boolean(props.subText))

function cliHint() {
  confirmDialog({
    title: `«${props.label}» настраивается в CLI`,
    message: `Эта настройка недоступна в Web-панели. Запустите меню z2r на роутере и выберите пункт ${props.cli?.replace('п.', '')}.`,
    confirmText: 'Понятно',
    info: true,
  })
}
</script>

<template>
  <router-link v-if="to" :to="to" class="stat-card is-link">
    <span class="label">{{ label }}<span class="card-go" aria-hidden="true">→</span></span>
    <strong :class="['value', stateClass, { 'is-long': isLong }]">{{ value }}</strong>
    <span class="value-sub" :hidden="!hasSub">{{ subText || '' }}</span>
  </router-link>
  <article v-else class="stat-card" :class="{ 'is-cli': cli }" :role="cli ? 'button' : undefined"
    :tabindex="cli ? 0 : undefined" @click="cli && cliHint()" @keydown.enter.prevent="cli && cliHint()">
    <span class="label">{{ label }}<span v-if="cli" class="cli-hint">CLI: {{ cli }}</span></span>
    <strong :class="['value', stateClass, { 'is-long': isLong }]">{{ value }}</strong>
    <span class="value-sub" :hidden="!hasSub">{{ subText || '' }}</span>
  </article>
</template>
