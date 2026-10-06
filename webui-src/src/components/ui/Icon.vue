<script setup lang="ts">
defineProps<{ name: 'pencil' | 'cross' | 'arrow-up' | 'arrow-down' }>()
</script>

<template>
  <svg v-if="name === 'pencil'" class="icon-svg" viewBox="-1 3.5 24 25" aria-hidden="true" focusable="false">
    <path fill="currentColor" d="M18.344 4.781l-3.406 3.063s1.125 0.688 2.156 1.656c1 0.969 1.719 2.063 1.719 2.063l2.906-3.469s-0.031-0.625-1.406-1.969c-1.406-1.344-1.969-1.344-1.969-1.344zM7.25 21.938l-0.156 1.5 10.813-11.25s-0.719-1-1.594-1.844c-0.906-0.875-1.938-1.563-1.938-1.563l-10.813 11.25 1.688-0.094 0.188 1.813zM0 26.719l2.688-5.5 1.5-0.125 0.125 1.719 1.813 0.25-0.188 1.375-5.438 2.75z"/>
  </svg>
  <svg v-else-if="name === 'cross'" class="icon-svg" viewBox="4.5 4.5 15 15" aria-hidden="true" focusable="false">
    <path d="M16 8L8 16M8.00001 8L16 16" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  </svg>
  <svg v-else-if="name === 'arrow-up'" class="icon-svg" viewBox="6 2 12 20" aria-hidden="true" focusable="false">
    <path d="M12 4V20M12 4L8 8M12 4L16 8" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  </svg>
  <svg v-else class="icon-svg" viewBox="6 2 12 20" aria-hidden="true" focusable="false">
    <path d="M12 20V4M12 20L8 16M12 20L16 16" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  </svg>
</template>
