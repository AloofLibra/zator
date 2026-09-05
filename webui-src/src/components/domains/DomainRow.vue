<script setup lang="ts">
import { computed, nextTick, ref } from 'vue'
import { domains } from '../../api/endpoints'
import type { DomainItem } from '../../api/types'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { confirmDialog } from '../../stores/confirm'
import { domainChecks, domainLists, expandedDomain, refreshDomainList } from '../../stores/domains'
import { showToast } from '../../stores/toast'
import { DOMAIN_META, type DomainListName } from '../../stores/domains'
import CheckResults from '../ui/CheckResults.vue'
import NumberStepper from '../ui/NumberStepper.vue'

const props = defineProps<{
  item: DomainItem
  list: DomainListName
}>()

const expanded = computed(() => expandedDomain.value === props.item.value)
const isCustomRkn = computed(() => domainLists[props.list]?.is_custom_rkn === true)
const check = computed(() => domainChecks[props.item.value])
const hasCheck = computed(() => Boolean(check.value?.results?.length))

const strategyChip = computed(() => {
  const strat = Number.isFinite(props.item.strategy) ? props.item.strategy : 0
  return strat && strat > 0 ? `страт: ${strat}` : 'РКН стр.'
})

const trialValue = ref('1')
const trialMax = computed(() => {
  const max = domainLists.custom_rkn?.max_strategy
  return Number.isFinite(max) && (max as number) > 0 ? (max as number) : 19
})

async function runTrialApply(strategy: string) {
  const payload = await domains.set_strategy(props.item.value, strategy)
  domainChecks[props.item.value] = payload?.check || { results: [] }
}

function toggleTrial() {
  if (expanded.value) {
    expandedDomain.value = null
    return
  }
  const item = (domainLists.custom_rkn?.items || []).find((it) => it.value === props.item.value)
  const start = item && Number.isFinite(item.strategy) && (item.strategy as number) > 0 ? item.strategy : 1
  trialValue.value = String(start)
  expandedDomain.value = props.item.value
}

// Стрелки степпера меняют только номер (v-model NumberStepper): применение и
// проверка запускаются явными кнопками, чтобы серию кликов не превращать в
// серию проверок на роутере.
async function trialApplyCurrent() {
  try {
    await withBusy('trial-current', async () => { await runTrialApply(trialValue.value) })
    showToast(`Применена стратегия ${trialValue.value}. Проверьте доступ.`)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function trialNext() {
  if (Number(trialValue.value) + 1 > trialMax.value) {
    showToast('Достигнута максимальная стратегия.', 'warning')
    return
  }
  trialValue.value = String(Number(trialValue.value) + 1)
  try {
    await withBusy('trial-next', async () => { await runTrialApply(trialValue.value) })
    showToast(`Применена стратегия ${trialValue.value}. Проверьте доступ.`)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function trialPrev() {
  if (Number(trialValue.value) - 1 < 1) {
    showToast('Это первая стратегия.', 'warning')
    return
  }
  trialValue.value = String(Number(trialValue.value) - 1)
  try {
    await withBusy('trial-prev', async () => { await runTrialApply(trialValue.value) })
    showToast(`Применена стратегия ${trialValue.value}. Проверьте доступ.`)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function trialSave() {
  try {
    await withBusy('trial-save', async () => { await runTrialApply(trialValue.value) })
    showToast(`Стратегия ${trialValue.value} сохранена для ${props.item.value}.`)
    expandedDomain.value = null
    await refreshDomainList('custom_rkn')
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function trialCancel() {
  expandedDomain.value = null
  try {
    await domains.clear_strategy(props.item.value)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
  await refreshDomainList('custom_rkn')
}

async function checkDomain() {
  try {
    await withBusy('domain-check', async () => {
      const payload = await domains.check(props.item.value)
      domainChecks[props.item.value] = payload?.check || { results: [] }
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function removeDomain() {
  const itemName = DOMAIN_META[props.list].itemName
  const confirmed = await confirmDialog({
    title: `Удалить ${itemName} «${props.item.value}»?`,
    message: props.list === 'custom_rkn' ? 'Подобранная стратегия также будет сброшена.' : 'Действие необратимо.',
    confirmText: 'Удалить',
    cancelText: 'Отмена',
    danger: true,
  })
  if (!confirmed) return
  try {
    await withBusy('domain-remove', async () => {
      await domains.remove(props.list, props.item.value)
      showToast('Удалено.')
      await refreshDomainList(props.list)
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// Переименование записи на месте (все списки: исключения, TCP_Custom,
// подстроки): позиция строки сохраняется, для TCP_Custom переносятся и локи.
const renaming = ref(false)
const renameValue = ref('')
const renameInput = ref<HTMLInputElement | null>(null)

function startRename() {
  renameValue.value = props.item.value
  renaming.value = true
  nextTick(() => renameInput.value?.focus())
}

async function submitRename() {
  const next = renameValue.value.trim()
  if (!next || next === props.item.value) {
    renaming.value = false
    return
  }
  try {
    await withBusy('domain-rename', async () => {
      await domains.rename(props.list, props.item.value, next)
      if (expandedDomain.value === props.item.value) expandedDomain.value = null
      delete domainChecks[props.item.value]
      showToast(`Переименовано в «${next}».`)
      await refreshDomainList(props.list)
    })
    renaming.value = false
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <li :class="['domain-row', { 'is-expanded': expanded }]" :data-value="item.value">
    <div class="domain-row-main">
      <span v-if="!renaming" class="domain-value">{{ item.value }}</span>
      <form v-else class="domain-rename" @submit.prevent="submitRename">
        <input ref="renameInput" v-model="renameValue" type="text" class="domain-rename-input" aria-label="Новое значение"
          :disabled="busyActive" @keydown.esc="renaming = false">
        <button type="submit" class="ghost domain-rename-save" :disabled="busyActive">OK</button>
        <button type="button" class="ghost domain-rename-cancel" :disabled="busyActive"
          @click="renaming = false">Отмена</button>
      </form>
      <span v-if="isCustomRkn" class="domain-strategy chip" :class="{ 'is-ok': (item.strategy || 0) > 0 }">
        {{ strategyChip }}
      </span>
      <div class="domain-actions">
        <button v-if="isCustomRkn && !renaming" type="button" class="ghost domain-check-btn" :disabled="busyActive" @click="checkDomain">Проверить</button>
        <button v-if="isCustomRkn && !renaming" type="button" class="ghost trial-btn" :disabled="busyActive" @click="toggleTrial">Подобрать</button>
        <button v-if="!renaming" type="button" class="ghost rename-btn" :disabled="busyActive"
          aria-label="Переименовать" title="Переименовать" @click="startRename">✎</button>
        <button v-if="!renaming" type="button" class="ghost danger remove-btn" :disabled="busyActive" aria-label="Удалить" @click="removeDomain">×</button>
      </div>
    </div>
    <div v-if="hasCheck" class="checks domain-check">
      <CheckResults :payload="check" empty-message="Нет результатов проверки." :empty-hidden="false" />
    </div>
    <div v-if="expanded" class="trial-panel">
      <div class="trial-meta">
        <span>Стратегия</span>
        <NumberStepper v-model="trialValue" :min="1" :max="trialMax" up-label="Увеличить" down-label="Уменьшить"
          :disabled="busyActive" />
        <span class="trial-max">из {{ trialMax }}</span>
        <span class="trial-hint">Стрелками выберите номер стратегии, затем проверьте «Текущую», соседними
          кнопками шагайте вперёд/назад. Доступ к сайту проверьте в браузере и подтвердите «Сохранить».</span>
      </div>
      <div class="card-actions">
        <button type="button" class="primary trial-save" :class="{ 'is-busy': busyButton === 'trial-save' }"
          :disabled="busyActive" @click="trialSave">Сохранить</button>
        <button type="button" class="ghost trial-prev" :class="{ 'is-busy': busyButton === 'trial-prev' }"
          :disabled="busyActive" @click="trialPrev">← Предыдущая</button>
        <button type="button" class="ghost trial-current" :class="{ 'is-busy': busyButton === 'trial-current' }"
          :disabled="busyActive" @click="trialApplyCurrent">Текущая</button>
        <button type="button" class="ghost trial-next" :class="{ 'is-busy': busyButton === 'trial-next' }"
          :disabled="busyActive" @click="trialNext">Следующая →</button>
        <button type="button" class="ghost trial-cancel" :disabled="busyActive" @click="trialCancel">Отмена</button>
      </div>
    </div>
  </li>
</template>
