<script setup lang="ts">
import { computed } from 'vue'
import type { RouteLocationRaw } from 'vue-router'

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
</script>

<template>
  <router-link v-if="to" :to="to" class="stat-card is-link">
    <span class="label">{{ label }}<span class="card-go" aria-hidden="true">→</span></span>
    <strong :class="['value', stateClass, { 'is-long': isLong }]">{{ value }}</strong>
    <span class="value-sub" :hidden="!hasSub">{{ subText || '' }}</span>
  </router-link>
  <article v-else class="stat-card">
    <span class="label">{{ label }}<span v-if="cli" class="cli-hint">CLI: {{ cli }}</span></span>
    <strong :class="['value', stateClass, { 'is-long': isLong }]">{{ value }}</strong>
    <span class="value-sub" :hidden="!hasSub">{{ subText || '' }}</span>
  </article>
</template>
