<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { sni } from '../../api/endpoints'
import type { SniProfileInfo, SniSetInfo } from '../../api/types'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { confirmDialog } from '../../stores/confirm'
import { refreshSniState, sniProfiles, sniSets, sniUnavailable } from '../../stores/sni'
import { refreshTlsBlobSettings, tlsBlobSettings } from '../../stores/settings'
import { showToast } from '../../stores/toast'

// SNI-пула вкладки «Блобы и SNI»: пин одного SNI, набор/свой список по
// профилю, политика чередования, управление секциями sni_user.txt. Данные —
// ОБЩИЙ стор вкладки (один blobs.cgi на всех — раньше каждый блок качал
// свой экземпляр и вкладка открывалась полминуты). Всё применяется на лету
// (TTL ~2 с), рестарт не нужен; приоритет: пин → пул → дефолт/конфиг.
const profiles = sniProfiles
const sets = sniSets
const unavailable = sniUnavailable
const loaded = ref(false)

const pinDraft = reactive<Record<string, string>>({})
const setDraft = reactive<Record<string, string>>({})
const policyDraft = reactive<Record<string, string>>({})
const customDraft = reactive<Record<string, string>>({})
const customOpen = reactive<Record<string, boolean>>({})

// Пресеты одиночного SNI — зеркало sni_preset_list() из lib/submenus.sh
// (CLI-меню «SNI клон-стратегий»); синхронность пинит sni_pool_smoke.
const PIN_PRESETS = ['300.ya.ru', 'www.google.com', 'max.ru', 'hcaptcha.com']
const PIN_CUSTOM = '__custom__'
// Выбор в селекте пина: '' (не задан) | пресет | __custom__ (свой домен)
const pinPick = reactive<Record<string, string>>({})

const userSets = computed(() => sets.value.filter((s: SniSetInfo) => s.origin === 'user'))
const zatorSets = computed(() => sets.value.filter((s: SniSetInfo) => s.origin !== 'user'))

// Тег режима для заголовков карточек ([blob]/[clone-solo]/[clone-pool]);
// сама карта профилей — отдельной карточкой сверху вкладки (ProfileMapCard).
// Режим — из стора tls_blob (панель блобов выше).
const tls = computed(() => tlsBlobSettings.value)

function profileTag(p: SniProfileInfo): string {
  const mode = tls.value?.profile_modes?.[p.id] || 'classic'
  if (mode !== 'clone') return 'blob'
  if (p.pin) return 'clone-solo'
  return (p.set || (p.effective || []).length > 0) ? 'clone-pool' : 'clone-solo'
}

function syncDrafts() {
  for (const p of profiles.value) {
    pinDraft[p.id] = p.pin || ''
    setDraft[p.id] = p.set || ''
    policyDraft[p.id] = p.policy || 'rr'
    pinPick[p.id] = !p.pin ? '' : (PIN_PRESETS.includes(p.pin) ? p.pin : PIN_CUSTOM)
    if (!(p.id in customDraft)) customDraft[p.id] = (p.effective || []).join('\n')
  }
}

async function load() {
  await refreshSniState()
  syncDrafts()
  loaded.value = true
}

// стор может обновиться извне (кнопка «Обновить» списка блобов) — держим
// черновики форм в синхроне
watch(profiles, () => { syncDrafts() })

async function refresh() {
  try {
    await withBusy('refresh-sni', async () => {
      await Promise.all([load(), refreshTlsBlobSettings()])
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function act(key: string, fn: () => Promise<unknown>, okText: string) {
  try {
    await withBusy(key, async () => {
      await fn()
    })
    showToast(okText + ' Применится сам в течение ~2 секунд.')
    await load()
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

function savePin(id: string) {
  // селект: '' — сброс (пул/конфиг), пресет — готовое имя, __custom__ — из поля
  const pick = pinPick[id] ?? ''
  const value = pick === PIN_CUSTOM ? (pinDraft[id] || '').trim().toLowerCase() : pick
  pinDraft[id] = value
  return act(`sni-pin-${id}`, () => sni.pin(id, value),
    value ? 'SNI закреплён — он побеждает пул.' : 'Пин снят — снова работает пул.')
}

function assignSet(id: string) {
  return act(`sni-set-${id}`, () => sni.assignSet(id, setDraft[id] || ''),
    'Набор назначен профилю.')
}

function saveCustom(id: string) {
  return act(`sni-custom-${id}`, () => sni.customList(id, customDraft[id] || ''),
    'Свой список сохранён.')
}

function clearPool(id: string) {
  return act(`sni-clear-${id}`, () => sni.clearPool(id),
    'Пул убран — профиль берёт один SNI (пин или дефолт).')
}

function savePolicy(id: string) {
  return act(`sni-policy-${id}`, () => sni.policy(id, policyDraft[id] || 'rr'),
    'Политика чередования сохранена.')
}

// --- Наборы: проектные — просмотр, пользовательские — правка в sni_user.txt --
const editName = ref('')
const editList = ref('')

function startEdit(s: SniSetInfo) {
  editName.value = s.name
  editList.value = (s.domains || []).join('\n')
}

function startCreate() {
  editName.value = ''
  editList.value = ''
}

async function saveSet() {
  const name = editName.value.trim()
  if (!name) {
    showToast('Введите имя набора.', 'error')
    return
  }
  await act('sni-set-save', () => sni.writeSet(name, editList.value),
    `Набор «${name}» сохранён в sni_user.txt.`)
}

async function removeSet(s: SniSetInfo) {
  const confirmed = await confirmDialog({
    title: `Удалить набор «${s.name}»?`,
    message: 'Секция удаляется из sni_user.txt. Набор, на который ссылаются профили, удалить нельзя.',
    confirmText: 'Удалить',
    cancelText: 'Отмена',
    danger: true,
  })
  if (!confirmed) return
  await act(`sni-set-del-${s.name}`, () => sni.deleteSet(s.name), 'Набор удалён.')
}
</script>

<template>
  <section class="panel" id="sni-pool-panel">
    <div class="panel-header">
      <h2>SNI клон-стратегий и пул с автосменой</h2>
      <button id="refresh-sni" :class="{ 'is-busy': busyButton === 'refresh-sni' }"
        :disabled="busyActive" type="button" @click="refresh">Обновить</button>
    </div>
    <p class="panel-desc">
      Клон профиля несёт невинное имя: пин одного SNI побеждает пул; пул вращает
      набор — каждое новое соединение берёт следующее (или случайное без
      повторов подряд) имя. Меняется на лету, рестарт не нужен.
    </p>

    <div v-if="unavailable" class="status-note">
      SNI-настройки недоступны — обновите Core zator (меню 5 → п.1 или релиз).
    </div>

    <template v-else>
      <div v-for="p in profiles" :key="p.id" class="settings-form sni-profile" :id="`sni-profile-${p.id}`">
        <h3><span class="chip" :class="{ 'is-ok': profileTag(p) !== 'blob' }">[{{ profileTag(p) }}]</span> {{ p.title }}</h3>
        <p class="status-note">Сейчас: {{ p.pool || 'нет пула (один SNI)' }}</p>

        <form class="settings-form" :id="`sni-pin-form-${p.id}`" @submit.prevent="savePin(p.id)">
          <label>
            <span>Один SNI — побеждает пул (пусто = из конфига/пула)</span>
            <select :id="`sni-pin-${p.id}`" v-model="pinPick[p.id]" :disabled="busyActive">
              <option value="">Не задан (работает пул / из конфига)</option>
              <option v-for="preset in PIN_PRESETS" :key="preset" :value="preset">{{ preset }}</option>
              <option :value="PIN_CUSTOM">Свой домен…</option>
            </select>
          </label>
          <label v-if="pinPick[p.id] === PIN_CUSTOM">
            <span>Домен (например, www.example.com)</span>
            <input :id="`sni-pin-custom-${p.id}`" v-model="pinDraft[p.id]" :disabled="busyActive"
              placeholder="www.example.com" autocomplete="off">
          </label>
          <div class="card-actions">
            <button type="submit" class="primary" :class="{ 'is-busy': busyButton === `sni-pin-${p.id}` }"
              :disabled="busyActive">Сохранить SNI</button>
            <button type="button" :class="{ 'is-busy': busyButton === `sni-pin-${p.id}` }" :disabled="busyActive"
              @click="pinPick[p.id] = ''; savePin(p.id)">Сбросить</button>
          </div>
          <p v-if="p.pin" class="status-note">Закреплён: {{ p.pin }}</p>
        </form>

        <form class="settings-form" :id="`sni-pool-form-${p.id}`" @submit.prevent="assignSet(p.id)">
          <label>
            <span>Набор из файлов (zator / ваши)</span>
            <select :id="`sni-set-${p.id}`" v-model="setDraft[p.id]" :disabled="busyActive">
              <option value="">— не выбран —</option>
              <option v-for="s in sets" :key="s.name" :value="s.name">
                {{ s.name }} ({{ s.domains.length }} им., {{ s.origin === 'user' ? 'ваш' : 'zator' }})
              </option>
            </select>
          </label>
          <div class="card-actions">
            <button type="submit" :class="{ 'is-busy': busyButton === `sni-set-${p.id}` }"
              :disabled="busyActive || !setDraft[p.id]">Назначить набор</button>
            <button type="button" :class="{ 'is-busy': busyButton === `sni-clear-${p.id}` }"
              :disabled="busyActive" @click="clearPool(p.id)">Убрать пул</button>
          </div>
        </form>

        <div class="settings-form">
          <label>
            <span>Политика чередования (случайная — без двух подряд, осмысленно при &gt;3 имён)</span>
            <select :id="`sni-policy-${p.id}`" v-model="policyDraft[p.id]" :disabled="busyActive">
              <option value="rr">По кругу (round-robin)</option>
              <option value="rand">Случайно, без повторов подряд</option>
            </select>
          </label>
          <div class="card-actions">
            <button type="button" :class="{ 'is-busy': busyButton === `sni-policy-${p.id}` }"
              :disabled="busyActive" @click="savePolicy(p.id)">Сохранить политику</button>
          </div>
        </div>

        <details :open="customOpen[p.id]" @toggle="customOpen[p.id] = ($event.target as HTMLDetailsElement).open">
          <summary>Свой список профиля (по одному домену в строке)</summary>
          <label>
            <span>Домены (до 32; порядок = порядок ротации)</span>
            <textarea :id="`sni-custom-${p.id}`" v-model="customDraft[p.id]" :disabled="busyActive" rows="4"></textarea>
          </label>
          <div class="card-actions">
            <button type="button" :class="{ 'is-busy': busyButton === `sni-custom-${p.id}` }"
              :disabled="busyActive" @click="saveCustom(p.id)">Сохранить свой список</button>
          </div>
        </details>

        <p v-if="(p.effective || []).length" class="status-note sni-effective">
          Ротация: <span v-for="d in p.effective" :key="d" class="chip">{{ d }}</span>
        </p>
      </div>

      <section class="settings-form" id="sni-sets-form">
        <h3>Наборы SNI</h3>
        <p class="panel-desc">
          Проектные (sni_zator.txt, обновляются zator) — только просмотр; ваши
          (sni_user.txt, в бэкапах) — правка; одноимённый ваш набор перекрывает
          проектный.
        </p>

        <div class="status-note">
          <template v-if="zatorSets.length">
            <strong>zator:</strong>
            <span v-for="s in zatorSets" :key="s.name" class="chip">{{ s.name }} · {{ s.domains.length }}</span>
          </template>
          <template v-if="userSets.length">
            <strong>ваши:</strong>
            <button v-for="s in userSets" :key="s.name" type="button" class="chip chip-button"
              :class="{ 'is-target': editName === s.name }" :disabled="busyActive"
              :title="`Редактировать набор «${s.name}»`" @click="startEdit(s)">{{ s.name }} · {{ s.domains.length }}</button>
          </template>
        </div>

        <div class="settings-form">
          <label>
            <span>Имя набора (создать/заменить свой; латиница/цифры/_)</span>
            <input id="sni-set-name" v-model="editName" :disabled="busyActive"
              placeholder="например, my" autocomplete="off">
          </label>
          <label>
            <span>Домены, по одному в строке</span>
            <textarea id="sni-set-list" v-model="editList" :disabled="busyActive" rows="5"></textarea>
          </label>
          <div class="card-actions">
            <button id="sni-set-save" type="button" class="primary"
              :class="{ 'is-busy': busyButton === 'sni-set-save' }" :disabled="busyActive"
              @click="saveSet">Сохранить набор</button>
            <button v-for="s in userSets" :key="s.name" type="button"
              :id="`sni-set-del-${s.name}`" :class="{ 'is-busy': busyButton === `sni-set-del-${s.name}` }"
              :disabled="busyActive" @click="removeSet(s)">Удалить «{{ s.name }}»</button>
            <button type="button" :disabled="busyActive" @click="startCreate">Новый (очистить)</button>
          </div>
        </div>
      </section>
    </template>
  </section>
</template>
