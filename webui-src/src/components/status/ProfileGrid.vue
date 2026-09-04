<script setup lang="ts">
import { computed } from 'vue'
import { currentLockText } from '../../gating'
import { locks } from '../../stores/status'

withDefaults(defineProps<{ compact?: boolean }>(), { compact: false })

const profiles = computed(() => locks.value)
</script>

<template>
  <div class="profile-grid" :class="{ compact }" id="status-profiles">
    <article v-for="profile in profiles" :key="profile.profile" class="profile-card">
      <h3>{{ profile.label }}</h3>
      <p class="desc">{{ profile.description }}</p>
      <div class="meta-line">
        <span>Текущий lock</span>
        <strong :class="['current-lock', { bad: String(profile.current_lock ?? '0') === '0' }]">
          {{ currentLockText(profile.current_lock) }}
        </strong>
      </div>
    </article>
  </div>
</template>
