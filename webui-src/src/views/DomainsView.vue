<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { domains } from '../api/endpoints'
import { busyActive, busyButton, withBusy } from '../stores/busy'
import { confirmDialog } from '../stores/confirm'
import {
  DOMAIN_LISTS, DOMAIN_META, domainChecks, domainLists, refreshDomainList, refreshDomains,
  type DomainListName,
} from '../stores/domains'
import { status } from '../stores/status'
import { showToast } from '../stores/toast'
import DomainRow from '../components/domains/DomainRow.vue'

const route = useRoute()
const router = useRouter()

const AUTO_RKN_LISTS: DomainListName[] = ['custom_rkn', 'substring']

const activeList = computed<DomainListName>(() => {
  const value = route.params.list as string | undefined
  return (DOMAIN_LISTS as readonly string[]).includes(value || '') ? value as DomainListName : 'netrogat'
})

const subtabs = [
  { name: 'netrogat', label: 'Исключения' },
  { name: 'custom_rkn', label: 'TCP_Custom' },
  { name: 'substring', label: 'Подстроки' },
  { name: 'netrogat_substring', label: 'Подстроки исключений' },
]

const listData = computed(() => domainLists[activeList.value])
const meta = computed(() => DOMAIN_META[activeList.value])
const items = computed(() => Array.isArray(listData.value?.items) ? listData.value?.items || [] : [])
const autoBlocked = computed(() =>
  AUTO_RKN_LISTS.includes(activeList.value) && status.value?.hostlist_mode === 'авто')

const addValue = ref('')
const importText = ref('')

onMounted(() => { refreshDomains() })

watch(activeList, () => {
  addValue.value = ''
})

async function refresh() {
  try {
    await withBusy('refresh-domains', refreshDomains)
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function addDomain() {
  const value = addValue.value.trim()
  if (!value) return
  try {
    await withBusy('domain-add', async () => {
      const payload = await domains.add(activeList.value, value)
      if (payload?.duplicate) showToast('Уже есть в списке.')
      else showToast('Добавлено.')
      await refreshDomainList(activeList.value)
      const label = payload?.check?.results?.[0]?.label
      if (label) domainChecks[label] = payload?.check || { results: [] }
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function importList() {
  if (!importText.value.trim()) {
    showToast('Список для импорта пуст.', 'warning')
    return
  }
  try {
    await withBusy('domain-import', async () => {
      const payload = await domains.import(activeList.value, importText.value)
      showToast(`Импорт: добавлено ${payload?.added ?? 0}, дубли ${payload?.duplicates ?? 0}, пропущено ${payload?.skipped ?? 0}.`)
      importText.value = ''
      await refreshDomainList(activeList.value)
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function clearList() {
  const confirmed = await confirmDialog({
    title: 'Очистить весь список?',
    message: 'Все записи будут удалены безвозвратно.',
    confirmText: 'Очистить',
    cancelText: 'Отмена',
    danger: true,
  })
  if (!confirmed) return
  try {
    await withBusy('domain-clear', async () => {
      await domains.clear(activeList.value)
      showToast('Список очищен.')
      await refreshDomainList(activeList.value)
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function copyList() {
  const values = items.value.map((item) => item.value)
  if (!values.length) {
    showToast('Список пуст, нечего копировать.', 'warning')
    return
  }
  const text = values.join('\n')
  try {
    await withBusy('domain-copy', async () => {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
      } else {
        const field = document.createElement('textarea')
        field.value = text
        field.style.position = 'fixed'
        field.style.opacity = '0'
        document.body.appendChild(field)
        field.select()
        document.execCommand('copy')
        field.remove()
      }
      showToast(`Скопировано ${values.length} ${values.length === 1 ? 'запись' : 'записей'}.`)
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="view is-active" id="view-domains">
    <div class="actions">
      <nav class="subtabs" aria-label="Списки доменов">
        <button v-for="sub in subtabs" :key="sub.name" class="subtab"
          :class="{ 'is-active': activeList === sub.name, 'is-locked': busyActive }" type="button"
          @click="router.push(`/domains/${sub.name}`)">{{ sub.label }}</button>
      </nav>
      <button id="refresh-domains" :class="{ 'is-busy': busyButton === 'refresh-domains' }" :disabled="busyActive"
        type="button" @click="refresh">Обновить</button>
    </div>

    <section class="panel" id="domains-panel">
      <div class="panel-header">
        <h2 id="domains-title">{{ listData?.title || activeList }}</h2>
        <span class="chip" :class="{ 'is-ok': items.length > 0 }" id="domains-count">{{ items.length }}</span>
      </div>
      <p class="panel-desc" id="domains-desc">{{ listData?.description || '' }}</p>

      <form id="domain-add-form" class="settings-form" @submit.prevent="addDomain">
        <label>
          <span id="domain-add-label">{{ meta.addLabel }}</span>
          <input type="text" id="domain-add-input" v-model="addValue" :disabled="autoBlocked || busyActive"
            required :placeholder="meta.placeholder">
        </label>
        <div class="card-actions">
          <button type="submit" class="primary" id="domain-add-submit" :disabled="autoBlocked || busyActive">Добавить</button>
        </div>
      </form>

      <div class="settings-alert" id="domains-auto-alert" :hidden="!autoBlocked">
        Автосбор списков включён: домены RKN zapret2 определяет автоматически, ручное добавление отключено.
        Выключите автосбор в настройках («Фильтрация по спискам»), чтобы пополнять список вручную. Удаление доступно.
      </div>

      <details class="import-block">
        <summary>Импорт списка</summary>
        <textarea id="domain-import-input" v-model="importText" rows="6" :disabled="autoBlocked || busyActive"
          placeholder="по одному домену на строку"></textarea>
        <div class="card-actions">
          <button type="button" id="domain-import-btn" :disabled="autoBlocked || busyActive" @click="importList">Импортировать</button>
        </div>
      </details>

      <div class="card-actions domain-toolbar">
        <button type="button" class="ghost" id="domain-copy-btn" :disabled="busyActive" @click="copyList">Копировать всё</button>
        <button type="button" class="ghost danger" id="domain-clear-btn" :disabled="busyActive" @click="clearList">Очистить всё</button>
      </div>

      <div class="domain-empty" id="domains-empty" :hidden="items.length > 0">Список пуст.</div>
      <ul class="domain-list" id="domain-items">
        <DomainRow v-for="item in items" :key="item.value" :item="item" :list="activeList" />
      </ul>
    </section>
  </section>
</template>
