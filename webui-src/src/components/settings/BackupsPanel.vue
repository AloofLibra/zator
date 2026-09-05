<script setup lang="ts">
import { computed, ref } from 'vue'
import { backups as backupsApi } from '../../api/endpoints'
import { backupsListExpanded, backups, formatSize, refreshBackups } from '../../stores/backups'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { confirmDialog } from '../../stores/confirm'
import { showToast } from '../../stores/toast'

const BACKUPS_PREVIEW_COUNT = 4

const items = computed(() => Array.isArray(backups.value?.items) ? backups.value?.items || [] : [])
const collapsed = computed(() => items.value.length > BACKUPS_PREVIEW_COUNT && !backupsListExpanded.value)
const visible = computed(() => collapsed.value ? items.value.slice(0, BACKUPS_PREVIEW_COUNT) : items.value)
const importInput = ref<HTMLInputElement | null>(null)

async function create() {
  try {
    await withBusy('backup-create', async () => {
      const payload = await backupsApi.create()
      showToast(`Бэкап создан: ${payload.name}`)
      await refreshBackups()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function remove(name: string) {
  const confirmed = await confirmDialog({
    title: `Удалить бэкап «${name}»?`,
    message: 'Действие необратимо.',
    confirmText: 'Удалить',
    cancelText: 'Отмена',
    danger: true,
  })
  if (!confirmed) return
  try {
    await withBusy('backup-delete', async () => {
      await backupsApi.delete(name)
      showToast(`Бэкап удалён: ${name}`)
      await refreshBackups()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function onImportChange(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  try {
    await withBusy('backup-import', async () => {
      const payload = await backupsApi.upload(file)
      showToast(`Бэкап импортирован: ${payload.name}`)
      await refreshBackups()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="panel">
    <div class="panel-header">
      <h2>Бэкапы</h2>
      <span class="chip" id="backups-count-chip" :class="{ 'is-ok': items.length > 0 }">
        {{ items.length > 0 ? `всего: ${items.length}` : 'нет' }}
      </span>
    </div>
    <p class="panel-desc">
      Бэкап сохраняет текущий конфиг, списки доменов и зафиксированные стратегии.
      Создавайте бэкап перед экспериментами с настройками — если что-то пойдёт не так,
      состояние можно будет вернуть.
    </p>
    <p class="panel-desc">
      Архив можно скачать на компьютер, вернуть на роутер кнопкой «Импортировать»
      или удалить из списка. Восстановление доступно через CLI (пункт 21 меню).
    </p>

    <div class="card-actions">
      <button type="button" class="primary" id="backup-create-btn" :class="{ 'is-busy': busyButton === 'backup-create' }"
        :disabled="busyActive" @click="create">Создать бэкап</button>
      <button type="button" id="backup-import-btn" :class="{ 'is-busy': busyButton === 'backup-import' }"
        :disabled="busyActive" @click="importInput?.click()">Импортировать бэкап</button>
      <input type="file" id="backup-import-file" ref="importInput" accept=".tar,application/x-tar" hidden
        @change="onImportChange">
    </div>
    <div class="domain-empty" id="backups-empty" :hidden="items.length > 0">Бэкапов пока нет.</div>
    <ul class="backup-list" id="backup-items">
      <li v-for="item in visible" :key="item.name" class="backup-item">
        <span class="backup-name">{{ item.name }}</span>
        <span class="backup-meta">{{ [item.date, item.size !== undefined ? formatSize(item.size) : ''].filter(Boolean).join(' · ') }}</span>
        <span class="backup-actions">
          <a class="download-btn" :href="backupsApi.downloadUrl(item.name)" aria-label="Скачать" title="Скачать">↓</a>
          <button type="button" class="ghost danger remove-btn" aria-label="Удалить" title="Удалить"
            :disabled="busyActive" @click="remove(item.name)">×</button>
        </span>
      </li>
      <li v-if="items.length > BACKUPS_PREVIEW_COUNT" class="backup-toggle-row">
        <button type="button" class="ghost backups-toggle" :disabled="busyActive"
          @click="backupsListExpanded = !backupsListExpanded">
          {{ collapsed ? `Показать все (${items.length})` : 'Свернуть' }}
        </button>
      </li>
    </ul>
  </section>
</template>
