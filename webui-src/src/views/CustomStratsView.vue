<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { customStrats, fetchCustomStrats } from '../api/endpoints'
import type { CustomBlockInfo, CustomStrategy } from '../api/types'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { confirmDialog } from '../stores/confirm'
import { showToast } from '../stores/toast'

// Кастомные стратегии пользователя (CLI п.1 -> 14): CRUD + импорт + применение.
// Валидация и нормализация живут на бэкенде (lib/custom_strategies.sh) —
// панель только показывает текст ошибки валидатора под формой.
const blocks = ref<CustomBlockInfo[]>([])
const strategies = ref<CustomStrategy[]>([])
const loaded = ref(false)
const filter = ref('')

const filtered = computed(() =>
  filter.value ? strategies.value.filter((s) => s.block === filter.value) : strategies.value)
const blockInfo = computed(() => (block: string): CustomBlockInfo | undefined =>
  blocks.value.find((b) => b.block === block))
const dirtyCount = computed(() => strategies.value.filter((s) => !s.assigned).length)

// Примеры из CLI (_custom_ask_spec): группой или комбо через « --lua-desync=».
const EXAMPLES: Record<string, { single: string; combo: string }> = {
  tcp: {
    single: 'fake:blob=maxru:tcp_md5:pos=2:repeats=2',
    combo: 'multisplit:blob=maxru:tcp_md5:pos=2:nodrop --lua-desync=fakeddisorder:pos=midsld:tcp_md5:nofake3',
  },
  udp: {
    single: 'fake:blob=quic_google:ipfrag:ipfrag_pos_udp=8:ipfrag_disorder:repeats=6:out_range=-d10',
    combo: 'send:repeats=2:ip_autottl=1,3-20 --lua-desync=fake:blob=0x00:repeats=4:out_range=-d10',
  },
}
const formExamples = computed(() => EXAMPLES[blockInfo.value(formBlock.value)?.transport || 'tcp'])

async function load() {
  const data = await fetchCustomStrats('')
  blocks.value = Array.isArray(data.blocks) ? data.blocks : []
  strategies.value = Array.isArray(data.strategies) ? data.strategies : []
}

async function refresh() {
  try {
    await withBusy('refresh-custom-strats', async () => {
      await load()
      loaded.value = true
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

onMounted(() => { refresh() })

// --- форма добавления/редактирования -----------------------------------------
const formOpen = ref(false)
const editId = ref<number | null>(null)
const formBlock = ref('p5')
const formSpec = ref('')
const formComment = ref('')
const formError = ref('')

function openAdd() {
  formOpen.value = true
  editId.value = null
  formBlock.value = filter.value || blocks.value[0]?.block || 'p5'
  formSpec.value = ''
  formComment.value = ''
  formError.value = ''
}

function openEdit(item: CustomStrategy) {
  formOpen.value = true
  editId.value = item.id
  formBlock.value = item.block
  formSpec.value = item.spec
  formComment.value = item.comment
  formError.value = ''
}

function cancelForm() {
  formOpen.value = false
  formError.value = ''
}

async function saveForm() {
  const spec = formSpec.value.trim()
  if (!spec) {
    formError.value = 'Пустая стратегия.'
    return
  }
  formError.value = ''
  try {
    await withBusy(editId.value === null ? 'custom-add' : `custom-edit-${editId.value}`, async () => {
      if (editId.value === null) {
        await customStrats.add(formBlock.value, spec, formComment.value)
      } else {
        await customStrats.edit(String(editId.value), formBlock.value, spec, formComment.value)
      }
      formOpen.value = false
      showToast(editId.value === null
        ? 'Добавлено. Примените к конфигу, чтобы стратегия получила номер.'
        : 'Изменено. Номера будут переназначены при применении.')
      await load()
    })
  } catch (error) {
    formError.value = (error as Error).message
  }
}

async function toggleEnabled(item: CustomStrategy) {
  try {
    await withBusy(`custom-enable-${item.id}`, async () => {
      await customStrats.enable(String(item.id), !item.enabled)
      showToast(item.enabled
        ? `Запись ${item.id} выключена.`
        : `Запись ${item.id} включена. Примените к конфигу.`)
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function removeItem(item: CustomStrategy) {
  const confirmed = await confirmDialog({
    title: `Удалить запись ${item.id}?`,
    message: 'Номера остальных записей будут уплотнены при следующем применении.',
    confirmText: 'Удалить',
    cancelText: 'Отмена',
    danger: true,
  })
  if (!confirmed) return
  try {
    await withBusy(`custom-delete-${item.id}`, async () => {
      await customStrats.remove(String(item.id))
      showToast('Удалено.')
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// --- импорт готовых строк -----------------------------------------------------
const importBlock = ref('p5')
const importText = ref('')
const importErrors = ref<{ line: string; reason: string }[]>([])

async function importLines() {
  if (!importText.value.trim()) {
    showToast('Пустой импорт.', 'warning')
    return
  }
  try {
    await withBusy('custom-import', async () => {
      const payload = await customStrats.import(importBlock.value, importText.value)
      importErrors.value = Array.isArray(payload?.errors) ? payload.errors : []
      showToast(`Импорт: добавлено ${payload?.added ?? 0}, пропущено ${payload?.skipped ?? 0}.`
        + ' Примените к конфигу.')
      importText.value = ''
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// --- применение к конфигу (инжект + ремап локов + рестарт) --------------------
async function applyToConfig() {
  const confirmed = await confirmDialog({
    title: 'Применить кастомные стратегии к конфигу?',
    message: 'Стратегии будут дописаны в config, номера назначены автоматически, локи перенесены. zapret2 перезапустится.',
    confirmText: 'Применить',
    cancelText: 'Отмена',
    danger: false,
  })
  if (!confirmed) return
  try {
    await withBusy('custom-apply', async () => {
      const payload = await customStrats.apply()
      showToast('Применено.' + (payload?.restarted ? ' zapret2 перезапущен.' : ' zapret2 не был запущен — запустится со следующим стартом.'))
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="view is-active" id="view-custom-strats" :class="{ 'is-loading': !loaded }">
    <div class="actions">
      <label class="scope-picker" for="custom-strats-filter"><span>Блок</span>
        <select id="custom-strats-filter" v-model="filter" :disabled="busyActive">
          <option value="">Все блоки</option>
          <option v-for="b in blocks" :key="b.block" :value="b.block">{{ b.block }} — {{ b.label }}</option>
        </select>
      </label>
      <button id="custom-apply-btn" type="button" class="primary"
        :class="{ 'is-busy': busyButton === 'custom-apply' }" :disabled="busyActive || !strategies.length"
        title="Дописать стратегии в config и перезапустить zapret2"
        @click="applyToConfig">Применить к конфигу{{ dirtyCount ? ` (${dirtyCount} не пр.)` : '' }}</button>
      <button id="refresh-custom-strats" :class="{ 'is-busy': busyButton === 'refresh-custom-strats' }"
        :disabled="busyActive" type="button" @click="refresh">Обновить</button>
    </div>

    <div v-if="!loaded" class="status-loading" aria-live="polite">Пожалуйста подождите...</div>

    <template v-else>
      <section class="panel" id="custom-strats-panel">
        <div class="panel-header">
          <h2>Кастомные стратегии пользователя</h2>
          <span class="chip" :class="{ 'is-ok': strategies.length > 0 }" id="custom-strats-count">{{ strategies.length }}</span>
        </div>
        <p class="panel-desc">
          Дописываются в конфиг после штатных стратегий блока; номера назначаются автоматически
          и смещаются при обновлениях, локи ремапятся сами. Изменения вступают в силу
          после «Применить к конфигу» (zapret2 перезапустится).
        </p>

        <div class="card-actions">
          <button id="custom-strat-add" type="button" class="primary" :disabled="busyActive || !blocks.length"
            @click="openAdd">Добавить стратегию</button>
        </div>

        <form id="custom-strat-form" v-if="formOpen" class="settings-form" @submit.prevent="saveForm">
          <h3>{{ editId === null ? 'Новая стратегия' : `Изменение записи ${editId}` }}</h3>
          <label>
            <span>Блок (куда дописать)</span>
            <select id="custom-strat-block" v-model="formBlock" :disabled="busyActive">
              <option v-for="b in blocks" :key="b.block" :value="b.block">{{ b.block }} — {{ b.label }}</option>
            </select>
          </label>
          <label>
            <span>Стратегия (одна группа или комбо через « --lua-desync=»)</span>
            <textarea id="custom-strat-spec" v-model="formSpec" rows="4" :disabled="busyActive"
              placeholder="можно вставить готовую строку из конфига — --lua-desync= и :strategy=N срежутся"></textarea>
          </label>
          <div class="form-hint">
            Пример: <code>{{ formExamples.single }}</code><br>
            Пример комбо: <code>{{ formExamples.combo }}</code>
          </div>
          <label>
            <span>Комментарий (необязательно)</span>
            <input type="text" id="custom-strat-comment" v-model="formComment" :disabled="busyActive" maxlength="64">
          </label>
          <div v-if="formError" class="settings-alert" id="custom-strat-error">{{ formError }}</div>
          <div class="card-actions">
            <button type="submit" id="custom-strat-save" class="primary"
              :class="{ 'is-busy': busyButton === (editId === null ? 'custom-add' : `custom-edit-${editId}`) }"
              :disabled="busyActive">{{ editId === null ? 'Добавить' : 'Сохранить' }}</button>
            <button type="button" id="custom-strat-cancel" class="ghost" :disabled="busyActive"
              @click="cancelForm">Отмена</button>
          </div>
        </form>

        <details class="import-block" id="custom-import-block-details">
          <summary>Импорт готовых строк (по одной на запись)</summary>
          <label>
            <span>Блок импорта</span>
            <select id="custom-import-block" v-model="importBlock" :disabled="busyActive">
              <option v-for="b in blocks" :key="b.block" :value="b.block">{{ b.block }} — {{ b.label }}</option>
            </select>
          </label>
          <textarea id="custom-import-text" v-model="importText" rows="6" :disabled="busyActive"
            placeholder="--lua-desync=... :strategy=N — номера срежутся сами; пустая строка не нужна"></textarea>
          <ul v-if="importErrors.length" class="settings-alert" id="custom-import-errors">
            <li v-for="e in importErrors" :key="e.line"><code>{{ e.line }}</code> — {{ e.reason }}</li>
          </ul>
          <div class="card-actions">
            <button type="button" id="custom-import-btn" :disabled="busyActive"
              :class="{ 'is-busy': busyButton === 'custom-import' }" @click="importLines">Импортировать</button>
          </div>
        </details>

        <div class="domain-empty" id="custom-strats-empty" :hidden="filtered.length > 0">
          {{ strategies.length ? 'В выбранном блоке записей нет.' : 'Записей нет. Добавьте первую стратегию или импортируйте готовые строки.' }}
        </div>
        <ul class="domain-list" id="custom-strat-list">
          <li v-for="item in filtered" :key="item.id" class="domain-row custom-strat-row"
            :class="{ 'is-off': !item.enabled }">
            <div class="custom-strat-head">
              <span class="chip">ID {{ item.id }}</span>
              <span class="chip">{{ item.block }}<template v-if="blockInfo(item.block)"> · {{ blockInfo(item.block)?.profiles }}</template></span>
              <span class="chip" :class="{ 'is-ok': item.enabled }">{{ item.enabled ? 'вкл' : 'выкл' }}</span>
              <span class="chip custom-strat-num" :title="item.assigned ? 'номер последнего применения' : 'ещё не применялась'">
                № {{ item.assigned || '—' }}
              </span>
              <span v-if="item.comment" class="custom-strat-comment">{{ item.comment }}</span>
            </div>
            <code class="custom-strat-spec">{{ item.spec }}</code>
            <div class="card-actions">
              <button type="button" class="ghost" :disabled="busyActive" @click="openEdit(item)">Изменить</button>
              <button type="button" class="ghost" :class="{ 'is-busy': busyButton === `custom-enable-${item.id}` }"
                :disabled="busyActive" @click="toggleEnabled(item)">{{ item.enabled ? 'Выключить' : 'Включить' }}</button>
              <button type="button" class="ghost danger" :class="{ 'is-busy': busyButton === `custom-delete-${item.id}` }"
                :disabled="busyActive" @click="removeItem(item)">Удалить</button>
            </div>
          </li>
        </ul>
      </section>
    </template>
  </section>
</template>

<style scoped>
.custom-strat-row { display: block; }
.custom-strat-row.is-off { opacity: .62; }
.custom-strat-head { display: flex; flex-wrap: wrap; gap: .35rem .4rem; align-items: baseline; }
.custom-strat-comment { color: var(--muted); font-size: .82rem; }
.custom-strat-num { font-variant-numeric: tabular-nums; }
.custom-strat-spec { display: block; margin: .45rem 0 .55rem; padding: .5rem .55rem; overflow-wrap: anywhere;
  white-space: pre-wrap; border-radius: var(--radius-sm); background: var(--surface); border: 1px solid var(--line); }
#custom-import-errors { margin: .5rem 0 0; padding-left: 1.2rem; font-size: .8rem; }
</style>
