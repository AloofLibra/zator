<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll } from '../../stores/status'
import { refreshUdpGamesSettings, udpGamesSettings } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const settings = computed(() => udpGamesSettings.value)
const savedEnabled = computed(() => settings.value?.enabled === true)

const enabled = ref(false)
watch(savedEnabled, (value) => { enabled.value = value }, { immediate: true })

const submitDisabled = computed(() =>
  busyActive.value || (enabled.value ? '1' : '0') === (savedEnabled.value ? '1' : '0'))

async function submit() {
  try {
    await withBusy('udp-games', async () => {
      announceRestart()
      const payload = await applySetting.udp_games_state(enabled.value)
      showToast((enabled.value ? 'Игровой UDP включён.' : 'Игровой UDP выключен.') + restartSuffix(payload))
      await refreshUdpGamesSettings()
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
      <h2>Игровой UDP (профиль 7)</h2>
      <router-link class="ghost" :to="{ path: '/strategies', query: { focus: 7 } }">Выбрать стратегию →</router-link>
      <span class="chip" id="udp-games-state-chip" :class="{ 'is-ok': savedEnabled }">
        {{ savedEnabled ? 'включен' : 'выключен' }}
      </span>
    </div>
    <p class="panel-desc">
      Обход игрового UDP-трафика на портах 1026–65531 (BF, FIFA/FC и похожие игры).
    </p>
    <p class="panel-desc">
      Включите режим, затем выберите стратегию для профиля 7 во вкладке «Стратегии».
      При изменении zapret2 перезапускается автоматически.
    </p>

    <form id="udp-games-form" class="settings-form" @submit.prevent="submit">
      <label class="toggle-field">
        <input type="checkbox" id="udp-games-toggle" v-model="enabled" :disabled="busyActive">
        <span>Включить обход игрового UDP</span>
      </label>
      <div class="form-hint">
        Текущие UDP-порты: <code id="udp-games-ports-chip">{{ settings?.ports || '—' }}</code>
      </div>
      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'udp-games' }"
          :disabled="submitDisabled">Сохранить</button>
      </div>
    </form>
  </section>
</template>
