<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { customStrats, fetchCustomStrats } from '../api/endpoints'
import type { CustomBlockInfo, CustomStrategy } from '../api/types'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { confirmDialog } from '../stores/confirm'
import { showToast } from '../stores/toast'

// Кастомные стратегии пользователя (CLI п.1 -> 14): CRUD + импорт + применение.
// Валидация и нормализация живут на бэкенде (lib/custom_strategies.sh) —
// панель только показывает текст ошибки валидатора в модалке.
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

// После сохранения: скролл к строке + рамка is-target (как у панелей меню),
// чтобы пользователь видел, какая запись изменилась.
function highlightRow(id: number) {
  nextTick(() => {
    const element = document.getElementById(`custom-strat-row-${id}`)
    if (!element) return
    element.scrollIntoView({ block: 'start' })
    element.classList.add('is-target')
    window.setTimeout(() => element.classList.remove('is-target'), 6100)
  })
}

// --- модалка добавления/редактирования ----------------------------------------
const formOpen = ref(false)
const modalVisible = ref(false)
const editId = ref<number | null>(null)
const formBlock = ref('p5')
const formSpec = ref('')
const formComment = ref('')
const formError = ref('')
const specField = ref<HTMLTextAreaElement | null>(null)
// Снимок строки на момент открытия: «Сохранить» активна только при отличиях.
const original = ref({ block: '', spec: '', comment: '' })

const formDirty = computed(() => {
  const spec = formSpec.value.trim()
  if (editId.value === null) return spec.length > 0
  return formBlock.value !== original.value.block
    || spec !== original.value.spec
    || formComment.value.trim() !== original.value.comment
})
const saveDisabled = computed(() => busyActive.value || !formDirty.value)

function openAdd() {
  editId.value = null
  formBlock.value = filter.value || blocks.value[0]?.block || 'p5'
  formSpec.value = ''
  formComment.value = ''
  formError.value = ''
  original.value = { block: formBlock.value, spec: '', comment: '' }
  formOpen.value = true
}

function openEdit(item: CustomStrategy) {
  editId.value = item.id
  formBlock.value = item.block
  formSpec.value = item.spec
  formComment.value = item.comment
  formError.value = ''
  original.value = { block: item.block, spec: item.spec, comment: item.comment }
  formOpen.value = true
}

function cancelForm() {
  formOpen.value = false
  formError.value = ''
}

// Анимация появления (как ConfirmDialog) + фокус в поле стратегии.
watch(formOpen, (value) => {
  if (!value) return
  modalVisible.value = false
  requestAnimationFrame(() => {
    modalVisible.value = true
    nextTick(() => specField.value?.focus())
  })
})

function onKeydown(event: KeyboardEvent) {
  if (!formOpen.value) return
  if (event.key === 'Escape') {
    event.preventDefault()
    cancelForm()
  }
}
onMounted(() => document.addEventListener('keydown', onKeydown, true))
onBeforeUnmount(() => document.removeEventListener('keydown', onKeydown, true))

function insertExample() {
  formSpec.value = formExamples.value.single
  formError.value = ''
}

async function saveForm() {
  const spec = formSpec.value.trim()
  if (!spec) {
    formError.value = 'Пустая стратегия.'
    return
  }
  formError.value = ''
  const wasEdit = editId.value !== null
  const targetId = editId.value
  try {
    await withBusy(wasEdit ? `custom-edit-${targetId}` : 'custom-add', async () => {
      let newId: number | null = null
      if (wasEdit) {
        await customStrats.edit(String(targetId), formBlock.value, spec, formComment.value.trim())
      } else {
        const payload = await customStrats.add(formBlock.value, spec, formComment.value.trim())
        // Подсвечиваем именно созданную запись (она в конце списка), не первую.
        newId = typeof payload?.id === 'number' ? payload.id : null
      }
      formOpen.value = false
      showToast(wasEdit
        ? `Запись ${targetId} изменена. Примените к конфигу для переназначения номеров.`
        : 'Добавлено. Примените к конфигу, чтобы стратегия получила номер.')
      // Новая запись может не попасть под активный фильтр блока — сбрасываем.
      if (!wasEdit && filter.value && filter.value !== formBlock.value) filter.value = ''
      await load()
      if (wasEdit) highlightRow(targetId as number)
      else if (newId !== null) highlightRow(newId)
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
const importNotes = ref<string[]>([])

async function importLines() {
  if (!importText.value.trim()) {
    showToast('Пустой импорт.', 'warning')
    return
  }
  try {
    await withBusy('custom-import', async () => {
      const payload = await customStrats.import(importBlock.value, importText.value)
      importErrors.value = Array.isArray(payload?.errors) ? payload.errors : []
      importNotes.value = Array.isArray(payload?.notes) ? payload.notes : []
      showToast(`Импорт: добавлено ${payload?.added ?? 0}, дубликатов ${payload?.dups ?? 0}, пропущено ${payload?.skipped ?? 0}.`
        + (importNotes.value.length ? ` Подмен блобов: ${importNotes.value.length}.` : '')
        + ' Примените к конфигу.')
      const totalLines = payload?.total ?? 0
      if (totalLines > (payload?.limit ?? 256)) {
        showToast(`Импорт ограничен ${payload?.limit} строками: получено ${totalLines}. `
          + `Остальные ${(totalLines - (payload?.limit ?? 256))} строк не обработаны — импортируйте их отдельно или файлом через CLI (п.1 -> 14 -> 5).`, 'warning')
      }
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

        <details class="import-block" id="custom-import-block-details">
          <summary>Импорт готовых строк (стратегии / блокчек / nfqws2)</summary>
          <label>
            <span>Блок импорта</span>
            <select id="custom-import-block" v-model="importBlock" :disabled="busyActive">
              <option v-for="b in blocks" :key="b.block" :value="b.block">{{ b.block }} — {{ b.label }}</option>
            </select>
          </label>
          <textarea id="custom-import-text" v-model="importText" rows="6" :disabled="busyActive"
            placeholder="--lua-desync=... :strategy=N, строка SUMMARY blockcheck2 или команда nfqws2 целиком — лишнее (--blob/--payload, номера) вырежется само; гугловский блоб блокчека заменится на дефолтный из конфига"></textarea>
          <ul v-if="importNotes.length" class="form-hint" id="custom-import-notes">
            <li v-for="n in importNotes" :key="n">{{ n }}</li>
          </ul>
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
          <li v-for="item in filtered" :id="`custom-strat-row-${item.id}`" :key="item.id"
            class="domain-row custom-strat-row" :class="{ 'is-off': !item.enabled }">
            <div class="custom-strat-head">
              <span class="chip">ID {{ item.id }}</span>
              <span class="chip">{{ item.block }}<template v-if="blockInfo(item.block)"> · {{ blockInfo(item.block)?.profiles }}</template></span>
              <span class="chip" :class="{ 'is-ok': item.enabled }">{{ item.enabled ? 'вкл' : 'выкл' }}</span>
              <span class="chip custom-strat-num" :class="{ 'is-pending': !item.assigned }"
                :title="item.assigned ? 'номер последнего применения' : 'ещё не применялась — нажмите «Применить к конфигу»'">
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

    <!-- Модалка добавления/редактирования (как ConfirmDialog: Esc и клик по фону — отмена) -->
    <div v-if="formOpen" :class="['modal-overlay', { 'is-visible': modalVisible }, 'custom-strat-modal']"
      role="dialog" aria-modal="true" @click.self="cancelForm">
      <form id="custom-strat-form" class="modal-card settings-form" @submit.prevent="saveForm">
        <h3 class="modal-title">{{ editId === null ? 'Новая стратегия' : `Запись ${editId} — изменение` }}</h3>
        <label>
          <span>Блок (куда дописать)</span>
          <select id="custom-strat-block" v-model="formBlock" :disabled="busyActive">
            <option v-for="b in blocks" :key="b.block" :value="b.block">{{ b.block }} — {{ b.label }}</option>
          </select>
        </label>
        <label>
          <span>Стратегия (одна группа или комбо через « --lua-desync=»)</span>
          <textarea id="custom-strat-spec" ref="specField" v-model="formSpec" rows="4" :disabled="busyActive"
            placeholder="можно вставить готовую строку из конфига, строку SUMMARY blockcheck2 или команду nfqws2 целиком — лишнее срежется само"></textarea>
        </label>
        <div class="form-hint">
          Пример: <code>{{ formExamples.single }}</code>
          <button type="button" class="ghost custom-strat-example" :disabled="busyActive"
            @click="insertExample">Вставить пример</button><br>
          Пример комбо: <code>{{ formExamples.combo }}</code>
        </div>
        <label>
          <span>Комментарий (необязательно)</span>
          <input type="text" id="custom-strat-comment" v-model="formComment" :disabled="busyActive" maxlength="64">
        </label>
        <div v-if="formError" class="settings-alert" id="custom-strat-error">{{ formError }}</div>
        <div class="modal-actions">
          <button type="button" id="custom-strat-cancel" class="ghost modal-cancel" :disabled="busyActive"
            @click="cancelForm">Отмена</button>
          <button type="submit" id="custom-strat-save" class="primary"
            :class="{ 'is-busy': busyButton === (editId === null ? 'custom-add' : `custom-edit-${editId}`) }"
            :disabled="saveDisabled" :title="saveDisabled
              ? (editId === null ? 'Введите стратегию' : 'Изменений нет') : ''">
            {{ editId === null ? 'Добавить' : 'Сохранить' }}
          </button>
        </div>
      </form>
    </div>
  </section>
</template>

<style scoped>
.custom-strat-row { display: block; scroll-margin-top: 18px; }
.custom-strat-row.is-off { opacity: .62; }
.custom-strat-head { display: flex; flex-wrap: wrap; gap: .35rem .4rem; align-items: baseline; }
.custom-strat-comment { color: var(--muted); font-size: .82rem; }
.custom-strat-num { font-variant-numeric: tabular-nums; }
/* Не применённая запись: красный чип — «нажмите Применить к конфигу» */
.custom-strat-num.is-pending {
  background: var(--danger);
  color: #fff;
  font-weight: 600;
}
.custom-strat-spec { display: block; margin: .45rem 0 .55rem; padding: .5rem .55rem; overflow-wrap: anywhere;
  white-space: pre-wrap; border-radius: var(--radius-sm); background: var(--surface); border: 1px solid var(--line); }
.custom-strat-modal .modal-card { width: min(560px, 100%); }
.custom-strat-example { flex: 0 0 auto; padding: .15rem .5rem; font-size: .75rem; margin-left: .4rem; }
</style>
