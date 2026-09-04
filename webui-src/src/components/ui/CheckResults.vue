<script setup lang="ts">
import { computed } from 'vue'
import type { CheckItem, CheckPayload } from '../../api/types'

const props = withDefaults(defineProps<{
  payload: CheckPayload | null
  emptyMessage: string
  emptyHidden?: boolean
}>(), { emptyHidden: true })

const results = computed(() => {
  const list = props.payload?.results
  return Array.isArray(list) ? list : []
})

const isEmpty = computed(() =>
  props.emptyHidden && !props.payload?.message)

function verdictClass(verdict: string | undefined) {
  if (verdict === 'ok') return 'ok'
  if (verdict === 'warn') return 'warn'
  return 'bad'
}

function lineClass(state: string | undefined) {
  if (state === 'ok' || state === 'http') return 'ok'
  if (state === 'aborted') return ''
  return 'bad'
}

function downloadClass(state: string | undefined) {
  return state === 'ok' ? 'ok' : 'bad'
}

function hasVerdict(item: CheckItem) {
  return Boolean(item.verdict)
}
</script>

<template>
  <div :class="{ empty: isEmpty && !results.length }">
    <template v-if="!results.length">
      {{ payload?.message || emptyMessage }}
    </template>
    <article v-for="(item, index) in results" :key="index" class="check-item">
      <div class="check-title">
        <strong>{{ item.label || 'Цель' }}</strong>
        <span>{{ item.target || '' }}</span>
      </div>
      <div class="check-pair">
        <span v-if="hasVerdict(item)" :class="verdictClass(item.verdict)">{{ item.text || item.verdict }}</span>
        <template v-if="hasVerdict(item)">
          <span v-if="item.tls12_detail" :class="lineClass(item.tls12_detail.state)">{{ item.tls12_detail.text || 'TLS 1.2' }}</span>
          <span v-if="item.tls13_detail" :class="lineClass(item.tls13_detail.state)">{{ item.tls13_detail.text || 'TLS 1.3' }}</span>
          <span v-if="item.download" :class="downloadClass(item.download.state)">{{ item.download.text || 'Данные' }}</span>
        </template>
        <template v-else>
          <span :class="item.tls12 ? 'ok' : 'bad'">TLS 1.2: {{ item.tls12 ? 'OK' : 'FAIL' }}</span>
          <span :class="item.tls13 ? 'ok' : 'bad'">TLS 1.3: {{ item.tls13 ? 'OK' : 'FAIL' }}</span>
        </template>
      </div>
    </article>
  </div>
</template>
