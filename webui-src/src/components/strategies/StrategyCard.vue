<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { clearLock, profileCheck, setLock } from '../../api/endpoints'
import type { CheckPayload, ProfileInfo, Recommendations } from '../../api/types'
import { FALLBACK_CHECK_HINT, UDP_GAMES_CHECK_HINT, currentLockText, gatedPanel, gatedReason, isProfileGated } from '../../gating'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll, scope, strategyChecks } from '../../stores/status'
import { tlsBlobSettings } from '../../stores/settings'
import { showToast } from '../../stores/toast'
import CheckResults from '../ui/CheckResults.vue'
import NumberStepper from '../ui/NumberStepper.vue'

const props = defineProps<{ profile: ProfileInfo; recommendations?: Recommendations | null }>()
const recommendation = computed(() => {
  const data = props.recommendations
  if (!['1', '2', '3', '4'].includes(String(props.profile.profile)) ||
    !data || !['ready', 'stale'].includes(data.status) || !(data.samples >= 10)) return null
  const item = data.profiles?.[props.profile.profile]
  return item && item.samples >= 10 ? item : null
})
const topStrategies = computed(() => (Array.isArray(recommendation.value?.top) ? recommendation.value.top : [])
  .filter((row) => row && Number.isInteger(row.strategy) && row.strategy >= 1 && row.strategy <= maxStrategy.value &&
    Number.isFinite(row.success_pct) && row.success_pct >= 0 && row.success_pct <= 100 &&
    Number.isInteger(row.samples) && row.samples > 0 && ['classic', 'clone', 'mixed'].includes(row.mode))
  .slice(0, 3))
const recommendClone = computed(() => recommendation.value?.clone_recommended === true &&
  tlsBlobSettings.value !== null && tlsBlobSettings.value.profile_modes?.[props.profile.profile] !== 'clone')
const modeLabels = { classic: 'Классический', clone: 'Клон', mixed: 'Смешанный' }


const gated = computed(() => isProfileGated(props.profile))
const reason = computed(() => gatedReason(props.profile))
const maxStrategy = computed(() => props.profile.max_strategy || 0)
const saved = computed(() => String(props.profile.current_lock || '0'))

const formValue = ref('0')
// Пользователь менял поле после последней синхронизации с реальным локом.
// Без этого после сброса (лок auto) «Сохранить» сразу активна со старым числом.
const touched = ref(false)
watch(() => props.profile.current_lock, (lock) => {
  const raw = String(lock ?? '')
  if (/^[0-9]+$/.test(raw)) {
    formValue.value = raw
  } else {
    // auto (лок снят): выбор начинается с первой стратегии, но сохранить
    // нельзя, пока пользователь сам не поменяет значение
    formValue.value = '1'
  }
  touched.value = false
}, { immediate: true })

function onFormInput(value: string) {
  formValue.value = value
  touched.value = true
}

const valueValid = computed(() => /^[0-9]+$/.test(formValue.value.trim()))
const submitDisabled = computed(() =>
  gated.value || busyActive.value || !valueValid.value || !touched.value || formValue.value.trim() === saved.value)
const clearDisabled = computed(() => gated.value || busyActive.value || saved.value === 'auto')

const inlinePayload = computed<CheckPayload | null>(() => {
  if (props.profile.is_fallback) return strategyChecks[props.profile.profile] || { results: [] }
  if (props.profile.is_udp_games) return strategyChecks[props.profile.profile] || { results: [] }
  return strategyChecks[props.profile.profile] || null
})
const inlineEmpty = computed(() => {
  if (props.profile.is_fallback) return FALLBACK_CHECK_HINT
  if (props.profile.is_udp_games) return UDP_GAMES_CHECK_HINT
  return 'Нет результатов быстрой проверки.'
})

async function save() {
  if (gated.value) {
    showToast(reason.value, 'error')
    return
  }
  const raw = formValue.value.trim()
  const value = Number(raw)
  if (!/^[0-9]+$/.test(raw) || value > maxStrategy.value) {
    showToast('Введите номер стратегии.', 'error')
    return
  }
  try {
    // Ключ с номером профиля: спиннер крутится только на карточке,
    // где нажали (busyActive всё равно блокирует остальные кнопки).
    await withBusy(`save-${props.profile.profile}`, async () => {
      await setLock(props.profile.profile, value, scope.value)
      delete strategyChecks[props.profile.profile]
      await refreshAll()
      if (value !== 0) {
        try {
          strategyChecks[props.profile.profile] = await profileCheck(props.profile.profile, scope.value)
        } catch {
          // проверка необязательна: стратегия уже применена
        }
      }
    })
    showToast(value === 0
      ? `Профиль ${props.profile.label} выключен.`
      : `Стратегия ${value} сохранена для ${props.profile.label}.`)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function clearLockAction() {
  if (gated.value) {
    showToast(reason.value, 'error')
    return
  }
  try {
    await withBusy(`clear-${props.profile.profile}`, async () => {
      await clearLock(props.profile.profile, scope.value)
      delete strategyChecks[props.profile.profile]
      await refreshAll()
    })
    showToast(`Lock снят для ${props.profile.label}.`)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <article :id="`strategy-card-${profile.profile}`" :class="['profile-card', { 'is-disabled': gated }]">
    <div class="card-top">
      <div>
        <h3>{{ profile.label }}</h3>
        <p class="desc">{{ profile.description }}</p>
      </div>
      <span class="chip">Профиль {{ profile.profile }}</span>
    </div>
    <div class="meta">
      <div class="meta-line">
        <span>Текущий lock&nbsp;</span>
        <strong :class="['current-lock', { bad: String(profile.current_lock ?? '0') === '0' }]">{{ currentLockText(profile.current_lock) }}</strong>
      </div>
      <div class="meta-line">
        <span>Макс. стратегия&nbsp;</span>
        <strong class="max-lock">{{ maxStrategy }}</strong>
      </div>
    </div>
    <div v-if="recommendation && (topStrategies.length || recommendClone)" class="provider-hint">
      <div class="hint-heading">По опыту провайдера <span>{{ recommendation.samples }} установок</span></div>
      <div v-if="topStrategies.length" class="recommendation-choices">
        <button v-for="row in topStrategies" :key="row.strategy" type="button" class="recommendation-choice"
          :disabled="gated || busyActive" :aria-label="`Выбрать стратегию ${row.strategy} в форме; требуется сохранение`"
          title="Подставить номер в форму — затем нажмите «Сохранить»"
          @click="onFormInput(String(row.strategy))">
          <strong>№{{ row.strategy }} <span>{{ row.success_pct }}%</span></strong>
          <small>{{ row.samples }} установок · {{ modeLabels[row.mode] }}</small>
        </button>
      </div>
      <router-link v-if="recommendClone" class="clone-hint" to="/settings/tls-blob">
        Попробуйте клонирование ClientHello: для этого блока оно успешнее классики →
      </router-link>
      <small v-if="topStrategies.length" class="hint-footnote">Выбор только подставляет номер, без сохранения.</small>
    </div>
    <form class="lock-form" @submit.prevent="save">
      <label>
        <span>Номер стратегии</span>
        <NumberStepper :model-value="formValue" :min="0" :max="maxStrategy" up-label="Увеличить номер стратегии"
          down-label="Уменьшить номер стратегии" :disabled="gated || busyActive" @update:model-value="onFormInput" />
      </label>
      <CheckResults v-if="!gated && inlinePayload" class="inline-check" :payload="inlinePayload"
        :empty-message="inlineEmpty" :empty-hidden="false" />
      <p v-if="gated" class="fallback-hint">{{ reason }}</p>
      <router-link v-if="gated && gatedPanel(profile)" class="fallback-hint is-link"
        :to="`/settings/${gatedPanel(profile)}`">
        Перейти к настройке, включающей профиль →
      </router-link>
      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === `save-${profile.profile}` }"
          :disabled="submitDisabled">Сохранить</button>
        <button type="button" class="ghost clear-lock" :class="{ 'is-busy': busyButton === `clear-${profile.profile}` }"
          :disabled="clearDisabled" @click="clearLockAction">Сбросить</button>
      </div>
    </form>
  </article>
</template>

<style scoped>
.provider-hint { margin: 0 0 1rem; padding: .8rem; border: 1px solid var(--line); border-radius: var(--radius-sm); background: var(--accent-soft); }
.hint-heading { display: flex; flex-wrap: wrap; gap: .3rem .6rem; align-items: baseline; font-size: .85rem; font-weight: 600; }
.hint-heading span, .hint-footnote { color: var(--muted); font-size: .75rem; font-weight: 400; }
.recommendation-choices { display: flex; flex-wrap: wrap; gap: .45rem; margin-top: .6rem; }
.recommendation-choice { flex: 1 1 100px; padding: .55rem .6rem; white-space: normal; text-align: left; border-radius: 8px; }
.recommendation-choice strong { display: flex; justify-content: space-between; gap: .6rem; font-size: .9rem; }
.recommendation-choice strong span { color: var(--success); }
.recommendation-choice small { display: block; margin-top: .3rem; color: var(--muted); font-size: .7rem; }
.clone-hint { display: block; margin-top: .65rem; font-size: .85rem; }
.hint-footnote { display: block; margin-top: .5rem; }
</style>
