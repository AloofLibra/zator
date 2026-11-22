<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { customBlobs, customBlobsUpload, fetchCustomBlobs } from '../api/endpoints'
import type { CustomBlobInfo } from '../api/types'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { confirmDialog } from '../stores/confirm'
import { showToast } from '../stores/toast'

// Пользовательские блобы («Свои блобы»): загрузка файлов через браузер в
// /opt/zator/files/fake/custom_blob/ + декларации --blob=ИМЯ:@… между
// #Z2R_CUSTOM_BLOBS_BEGIN/END в config. Валидация имён/файлов — на бэкенде
// (lib/custom_blobs.sh); переименование правит ссылки в «Своих стратегиях».
const dir = ref('')
const blobs = ref<CustomBlobInfo[]>([])
const files = ref<string[]>([])
const stock = ref<string[]>([])
const loaded = ref(false)
// есть несохранённые изменения (декларация добавлена/изменена/удалена, но
// конфиг ещё не применён) — кнопка «Применить» активна даже при пустом списке,
// иначе последнее удаление нельзя было бы довести до конфига (замечание автора
// PR #82: «Применить» дизейблился на blobs.length===0)
const needsApply = ref(false)

const refsTotal = computed(() => blobs.value.reduce((acc, b) => acc + (b.refs || 0), 0))

async function load() {
  const data = await fetchCustomBlobs()
  dir.value = data.dir || ''
  blobs.value = Array.isArray(data.blobs) ? data.blobs : []
  files.value = Array.isArray(data.files) ? data.files : []
  stock.value = Array.isArray(data.stock) ? data.stock : []
  // серверное состояние «TSV != конфиг» — основа флага; локальные мутации
  // ставят его в true поверх
  needsApply.value = !!data.config_dirty
}

async function refresh() {
  try {
    await withBusy('refresh-custom-blobs', async () => {
      await load()
      loaded.value = true
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

onMounted(() => { refresh() })

function highlightRow(id: number) {
  nextTick(() => {
    const element = document.getElementById(`custom-blob-row-${id}`)
    if (!element) return
    element.scrollIntoView({ block: 'start' })
    element.classList.add('is-target')
    window.setTimeout(() => element.classList.remove('is-target'), 6100)
  })
}

// --- загрузка файла через браузер ---------------------------------------------
const uploadFile = ref<File | null>(null)
const fileInput = ref<HTMLInputElement | null>(null)

function onFileChange(event: Event) {
  const input = event.target as HTMLInputElement
  uploadFile.value = input.files?.[0] || null
}

async function upload() {
  const file = uploadFile.value
  if (!file) {
    showToast('Выберите файл блоба.', 'warning')
    return
  }
  if (file.size < 1 || file.size > 262144) {
    showToast('Размер файла 1 Б…256 КиБ.', 'warning')
    return
  }
  try {
    await withBusy('custom-blob-upload', async () => {
      const buffer = await file.arrayBuffer()
      const payload = await customBlobsUpload(file.name, buffer)
      uploadFile.value = null
      if (fileInput.value) fileInput.value.value = ''
      if (payload?.created) needsApply.value = true
      showToast(payload?.created
        ? `Загружено и добавлено как «${payload.created}». Примените к конфигу.`
        : `Файл ${payload?.file || file.name} сохранён в ${dir.value}.`)
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// --- модалка добавления/редактирования ----------------------------------------
const formOpen = ref(false)
const modalVisible = ref(false)
const editId = ref<number | null>(null)
const formName = ref('')
const formFile = ref('')
const formComment = ref('')
const formError = ref('')
const nameField = ref<HTMLInputElement | null>(null)
const original = ref({ name: '', file: '', comment: '' })

const formDirty = computed(() => {
  if (editId.value === null) return formName.value.trim().length > 0 && formFile.value !== ''
  return formName.value.trim() !== original.value.name
    || formFile.value !== original.value.file
    || formComment.value.trim() !== original.value.comment
})
const saveDisabled = computed(() => busyActive.value || !formDirty.value)

const nameTakenHint = computed(() => {
  const name = formName.value.trim()
  if (!name || name === original.value.name) return ''
  if (stock.value.includes(name)) return 'Это имя занято штатным блобом.'
  if (blobs.value.some((b) => b.name === name && b.id !== editId.value)) return 'Это имя уже занято другой записью.'
  return ''
})

function openAdd() {
  editId.value = null
  formName.value = ''
  formFile.value = files.value[0] || ''
  formComment.value = ''
  formError.value = ''
  original.value = { name: '', file: formFile.value, comment: '' }
  formOpen.value = true
}

function openEdit(item: CustomBlobInfo) {
  editId.value = item.id
  formName.value = item.name
  formFile.value = item.file
  formComment.value = item.comment
  formError.value = ''
  original.value = { name: item.name, file: item.file, comment: item.comment }
  formOpen.value = true
}

function cancelForm() {
  formOpen.value = false
  formError.value = ''
}

watch(formOpen, (value) => {
  if (!value) return
  modalVisible.value = false
  requestAnimationFrame(() => {
    modalVisible.value = true
    nextTick(() => nameField.value?.focus())
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

async function saveForm() {
  const name = formName.value.trim()
  if (!name || !formFile.value) {
    formError.value = 'Нужны имя блоба и файл.'
    return
  }
  formError.value = ''
  const wasEdit = editId.value !== null
  const targetId = editId.value
  try {
    await withBusy(wasEdit ? `custom-blob-edit-${targetId}` : 'custom-blob-add', async () => {
      if (wasEdit) {
        await customBlobs.edit(String(targetId), name, formFile.value, formComment.value.trim())
      } else {
        const payload = await customBlobs.add(name, formFile.value, formComment.value.trim())
        const newId = typeof payload?.id === 'number' ? payload.id : null
        formOpen.value = false
        needsApply.value = true
        showToast('Добавлено. Примените к конфигу, чтобы блоб объявился.')
        if (newId !== null) highlightRow(newId)
        await load()
        return
      }
      formOpen.value = false
      needsApply.value = true
      showToast('Сохранено.'
        + (formName.value.trim() !== original.value.name
          ? ' Ссылки в «Своих стратегиях» обновлены.'
          : '')
        + ' Примените к конфигу.')
      await load()
      highlightRow(targetId as number)
    })
  } catch (error) {
    formError.value = (error as Error).message
  }
}

async function removeItem(item: CustomBlobInfo) {
  const refsNote = item.refs
    ? `Блоб используется в ${item.refs} стратеги(ях) — удаление будет отклонено.`
    : 'Файл будет удалён из custom_blob/.'
  const confirmed = await confirmDialog({
    title: `Удалить блоб «${item.name}»?`,
    message: refsNote,
    confirmText: 'Удалить',
    cancelText: 'Отмена',
    danger: true,
  })
  if (!confirmed) return
  try {
    await withBusy(`custom-blob-delete-${item.id}`, async () => {
      await customBlobs.remove(String(item.id))
      needsApply.value = true
      showToast('Удалено.')
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function applyToConfig() {
  const confirmed = await confirmDialog({
    title: 'Применить пользовательские блобы к конфигу?',
    message: 'Декларации --blob= будут дописаны в config (секция #Z2R_CUSTOM_BLOBS), ссылки пользовательских стратегий переинжектятся. zapret2 перезапустится.',
    confirmText: 'Применить',
    cancelText: 'Отмена',
    danger: false,
  })
  if (!confirmed) return
  try {
    await withBusy('custom-blob-apply', async () => {
      const payload = await customBlobs.apply()
      needsApply.value = false
      showToast('Применено.' + (payload?.restarted ? ' zapret2 перезапущен.' : ' zapret2 не был запущен — запустится со следующим стартом.'))
      await load()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="view is-active" id="view-custom-blobs" :class="{ 'is-loading': !loaded }">
    <div class="actions">
      <button id="custom-blob-apply-btn" type="button" class="primary"
        :class="{ 'is-busy': busyButton === 'custom-blob-apply' }" :disabled="busyActive || (!blobs.length && !needsApply)"
        title="Дописать декларации --blob= в config (в т.ч. вычистить удалённые) и перезапустить zapret2"
        @click="applyToConfig">Применить к конфигу{{ needsApply ? ' (есть изменения)' : '' }}</button>
      <button id="refresh-custom-blobs" :class="{ 'is-busy': busyButton === 'refresh-custom-blobs' }"
        :disabled="busyActive" type="button" @click="refresh">Обновить</button>
    </div>

    <div v-if="!loaded" class="status-loading" aria-live="polite">Пожалуйста подождите...</div>

    <template v-else>
      <section class="panel" id="custom-blobs-upload-panel">
        <div class="panel-header">
          <h2>Загрузка блоба</h2>
        </div>
        <p class="panel-desc">
          Файл сохраняется в <code>{{ dir || '/opt/zator/files/fake/custom_blob' }}</code> и сразу
          попадает в бэкапы. Размер 1 Б…256 КиБ, имя — буквы/цифры/._- .
        </p>
        <div class="settings-form">
          <label>
            <span>Файл блоба (например, tls_clienthello_my.bin)</span>
            <input type="file" id="custom-blob-file" ref="fileInput" :disabled="busyActive" @change="onFileChange">
          </label>
        </div>
        <div class="card-actions">
          <button id="custom-blob-upload-btn" type="button" class="primary"
            :class="{ 'is-busy': busyButton === 'custom-blob-upload' }" :disabled="busyActive || !uploadFile"
            @click="upload">Загрузить на роутер</button>
        </div>
      </section>

      <section class="panel" id="custom-blobs-panel">
        <div class="panel-header">
          <h2>Свои блобы</h2>
          <span class="chip" :class="{ 'is-ok': blobs.length > 0 }" id="custom-blobs-count">{{ blobs.length }}</span>
        </div>
        <p class="panel-desc">
          Декларации <code>--blob=ИМЯ:@файл</code> дописываются в конфиг после штатных блобов
          (секция <code>#Z2R_CUSTOM_BLOBS</code>). Имя не должно совпадать со штатным. Переименование
          обновляет ссылки в «Своих стратегиях». Изменения вступают в силу после
          «Применить к конфигу» (zapret2 перезапустится).
        </p>

        <div class="card-actions">
          <button id="custom-blob-add" type="button" class="primary" :disabled="busyActive || !files.length"
            @click="openAdd">Добавить блоб</button>
        </div>
        <p v-if="!files.length" class="form-hint">Сначала загрузите файл блоба выше.</p>

        <details id="custom-blob-stock-names">
          <summary>Занятые (штатные) имена</summary>
          <p class="form-hint"><code v-for="s in stock" :key="s" class="stock-name">{{ s }}</code></p>
        </details>

        <div class="domain-empty" id="custom-blobs-empty" :hidden="blobs.length > 0">
          Записей нет. Загрузите файл и добавьте блоб.
        </div>
        <ul class="domain-list" id="custom-blob-list">
          <li v-for="item in blobs" :id="`custom-blob-row-${item.id}`" :key="item.id"
            class="domain-row custom-blob-row">
            <div class="custom-blob-head">
              <span class="chip">ID {{ item.id }}</span>
              <span class="chip is-ok">{{ item.name }}</span>
              <span class="chip" :class="{ 'is-ok': item.refs > 0 }"
                :title="item.refs ? 'имя используется в пользовательских стратегиях' : 'не используется в стратегиях'">
                {{ item.refs ? `стратегий: ${item.refs}` : 'не используется' }}
              </span>
              <span v-if="item.comment" class="custom-blob-comment">{{ item.comment }}</span>
            </div>
            <code class="custom-blob-line">--blob={{ item.name }}:@{{ dir }}/{{ item.file }}</code>
            <div class="card-actions">
              <button type="button" class="ghost" :disabled="busyActive" @click="openEdit(item)">Изменить</button>
              <button type="button" class="ghost danger" :class="{ 'is-busy': busyButton === `custom-blob-delete-${item.id}` }"
                :disabled="busyActive" @click="removeItem(item)">Удалить</button>
            </div>
          </li>
        </ul>
      </section>

      <!-- Модалка добавления/редактирования (Esc и клик по фону — отмена) -->
      <div v-if="formOpen" :class="['modal-overlay', { 'is-visible': modalVisible }, 'custom-blob-modal']"
        role="dialog" aria-modal="true" @click.self="cancelForm">
        <form id="custom-blob-form" class="modal-card settings-form" @submit.prevent="saveForm">
          <h3 class="modal-title">{{ editId === null ? 'Новый блоб' : `Запись ${editId} — изменение` }}</h3>
          <label>
            <span>Имя блоба (--blob=ИМЯ:@…)</span>
            <input type="text" id="custom-blob-name" ref="nameField" v-model="formName" :disabled="busyActive"
              maxlength="32" placeholder="my_fake_tls">
          </label>
          <p v-if="nameTakenHint" class="settings-alert">{{ nameTakenHint }}</p>
          <label>
            <span>Файл (из custom_blob/)</span>
            <select id="custom-blob-file-select" v-model="formFile" :disabled="busyActive">
              <option v-for="f in files" :key="f" :value="f">{{ f }}</option>
            </select>
          </label>
          <label>
            <span>Комментарий (необязательно)</span>
            <input type="text" id="custom-blob-comment" v-model="formComment" :disabled="busyActive" maxlength="64">
          </label>
          <p class="form-hint">
            При смене имени ссылки в «Своих стратегиях» обновятся автоматически
            ({{ refsTotal }} ссыл. всего).
          </p>
          <div v-if="formError" class="settings-alert" id="custom-blob-error">{{ formError }}</div>
          <div class="modal-actions">
            <button type="button" id="custom-blob-cancel" class="ghost modal-cancel" :disabled="busyActive"
              @click="cancelForm">Отмена</button>
            <button type="submit" id="custom-blob-save" class="primary"
              :class="{ 'is-busy': busyButton === (editId === null ? 'custom-blob-add' : `custom-blob-edit-${editId}`) }"
              :disabled="saveDisabled" :title="saveDisabled
                ? (editId === null ? 'Выберите файл и введите имя' : 'Изменений нет') : ''">
              {{ editId === null ? 'Добавить' : 'Сохранить' }}
            </button>
          </div>
        </form>
      </div>
    </template>
  </section>
</template>

<style scoped>
.custom-blob-row { display: block; scroll-margin-top: 18px; }
.custom-blob-head { display: flex; flex-wrap: wrap; gap: .35rem .4rem; align-items: baseline; }
.custom-blob-comment { color: var(--muted); font-size: .82rem; }
.custom-blob-line { display: block; margin: .45rem 0 .55rem; padding: .5rem .55rem; overflow-wrap: anywhere;
  white-space: pre-wrap; border-radius: var(--radius-sm); background: var(--surface); border: 1px solid var(--line); }
.custom-blob-modal .modal-card { width: min(560px, 100%); }
.stock-name { display: inline-block; margin: 0 .35rem .25rem 0; }
</style>
