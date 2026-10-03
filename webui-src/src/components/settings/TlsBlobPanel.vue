<script setup lang="ts">
import { computed, reactive, ref, watch } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshTlsBlobSettings, tlsBlobSettings } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'
import NumberStepper from '../ui/NumberStepper.vue'

const settings = computed(() => tlsBlobSettings.value)

const mode = computed(() => settings.value?.current_mode || '')
const isBuiltin = computed(() => mode.value === 'fake_default_tls')
const maxruFile = computed(() => settings.value?.current_blob || '')

const currentFile = computed(() =>
  isBuiltin.value ? 'fake_default_tls (встроенный)' : (maxruFile.value || '—'))

const statusText = computed(() =>
  mode.value === 'fake_default_tls' ? 'default' : mode.value || 'не определён')

const listedBlobs = computed(() =>
  Array.isArray(settings.value?.available_blobs) ? settings.value?.available_blobs || [] : [])
const blobs = computed(() =>
  maxruFile.value && !listedBlobs.value.includes(maxruFile.value)
    ? [maxruFile.value, ...listedBlobs.value]
    : listedBlobs.value)

const placeholderText = computed(() =>
  !isBuiltin.value && maxruFile.value
    ? maxruFile.value + ' (текущий) — выберите файл'
    : 'Выберите блоб')

const saved = computed(() => isBuiltin.value ? 'fake_default_tls' : maxruFile.value)
const selected = ref('')
watch(saved, () => {
  if (isBuiltin.value) selected.value = 'fake_default_tls'
}, { immediate: true })

const submitDisabled = computed(() =>
  busyActive.value || !selected.value || selected.value === saved.value)

async function submit() {
  if (!selected.value) {
    showToast('Выберите блоб.', 'error')
    return
  }
  try {
    await withBusy('tls-blob', async () => {
      announceRestart()
      const payload = await applySetting.tls_blob(selected.value)
      showToast('TLS-блоб изменён.' + restartSuffix(payload))
      await refreshTlsBlobSettings()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// --- Переопределения по профилям (только стратегии с blob=maxru|fake_default_tls) ---
const PROFILE_ITEMS = [
  { id: '1', title: 'Профиль 1 — YouTube TCP' },
  { id: '2', title: 'Профиль 2 — Googlevideo' },
  { id: '3', title: 'Профиль 3 — RKN' },
  { id: '4', title: 'Профиль 4 — Discord (TCP)' },
  { id: '8', title: 'Профиль 8 — безразборный TLS' },
]

const profileSelected = reactive<Record<string, string>>({})

function savedProfile(id: string): string {
  return settings.value?.profile_blobs?.[id] ?? ''
}

watch(settings, () => {
  for (const p of PROFILE_ITEMS) profileSelected[p.id] = savedProfile(p.id)
}, { immediate: true })

function profileOptions(id: string): string[] {
  const cur = savedProfile(id)
  if (cur && cur !== 'fake_default_tls' && !blobs.value.includes(cur)) {
    return [cur, ...blobs.value]
  }
  return blobs.value
}

function profileSubmitDisabled(id: string): boolean {
  return busyActive.value || (profileSelected[id] ?? '') === savedProfile(id)
}

async function submitProfile(id: string) {
  const value = profileSelected[id] ?? ''
  try {
    await withBusy(`tls-blob-profile-${id}`, async () => {
      const payload = await applySetting.tls_blob_profile(id, value)
      if (payload.restart_required) {
        announceRestart()
        showToast('Переопределение профиля сохранено.' + restartSuffix(payload))
      } else {
        showToast('Переопределение профиля применено без рестарта (до 2 секунд).')
      }
      await refreshTlsBlobSettings()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// --- Режим фейков по профилям (mode_override.tsv): классика / клоны ---
const modeSelected = reactive<Record<string, string>>({})

function savedMode(id: string): string {
  return settings.value?.profile_modes?.[id] || 'classic'
}

function sniDisplay(id: string): string {
  const sni = settings.value?.profile_snis?.[id] || ''
  return sni ? sni : 'www.google.com (дефолт)'
}

watch(settings, () => {
  for (const p of PROFILE_ITEMS) modeSelected[p.id] = savedMode(p.id)
}, { immediate: true })

function modeSubmitDisabled(id: string): boolean {
  return busyActive.value || (modeSelected[id] ?? 'classic') === savedMode(id)
}

async function submitMode(id: string) {
  const value = modeSelected[id] ?? 'classic'
  try {
    await withBusy(`fake-mode-${id}`, async () => {
      await applySetting.fake_mode(id, value)
      showToast('Режим фейков применён без рестарта (до 2 секунд).')
      await refreshTlsBlobSettings()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

// --- Размер клонов по профилям (clonesize.tsv): максимум байт клон-пакета ---
const CLONE_SIZE_PRESETS = ['1200', '964', '512', '196']
const sizeSelected = reactive<Record<string, string>>({})
const sizeCustom = reactive<Record<string, string>>({})
const sizeCustomActive = reactive<Record<string, boolean>>({})

function savedSize(id: string): string {
  return settings.value?.profile_sizes?.[id] ?? ''
}

function sizeDisplay(id: string): string {
  const v = savedSize(id)
  return v ? `${v} Б` : 'без ограничения'
}

watch(settings, () => {
  for (const p of PROFILE_ITEMS) {
    sizeSelected[p.id] = savedSize(p.id)
    sizeCustom[p.id] = savedSize(p.id) || '512'
    sizeCustomActive[p.id] = false
  }
}, { immediate: true })

function sizeSubmitDisabled(id: string): boolean {
  return busyActive.value || (sizeSelected[id] ?? '') === savedSize(id)
}

async function submitSize(id: string) {
  let value = (sizeSelected[id] ?? '').trim()
  if (value === 'custom') {
    value = (sizeCustom[id] ?? '').trim()
    if (!/^\d+$/.test(value) || Number(value) < 64 || Number(value) > 1200) {
      showToast('Свой размер — целое число байт 64..1200.', 'error')
      return
    }
  }
  try {
    await withBusy(`clone-size-${id}`, async () => {
      await applySetting.clone_size(id, value)
      showToast('Лимит клонов применён без рестарта (до 2 секунд).')
      await refreshTlsBlobSettings()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}
</script>

<template>
  <section class="panel">
    <div class="panel-header">
      <h2>TLS Blob</h2>
      <span class="chip" id="tls-blob-status" :class="{ 'is-ok': mode === 'maxru' }">{{ statusText }}</span>
    </div>
    <p class="panel-desc">
      Выбор TLS-блоба для стратегий обхода. При изменении zapret2 перезапускается автоматически.
    </p>

    <form id="tls-blob-form" class="settings-form" @submit.prevent="submit">
      <label>
        <span>Выберите блоб</span>
        <select id="tls-blob-select" v-model="selected" required :disabled="busyActive">
          <option value="" disabled>{{ placeholderText }}</option>
          <option value="fake_default_tls" :disabled="isBuiltin">
            fake_default_tls (встроенный){{ isBuiltin ? ' (текущий)' : '' }}
          </option>
          <option v-for="blob in blobs" :key="blob" :value="blob"
            :disabled="!isBuiltin && blob === maxruFile">
            {{ blob }}{{ !isBuiltin && blob === maxruFile ? ' (текущий)' : '' }}
          </option>
        </select>
      </label>

      <div class="form-hint">
        Текущий файл: <code id="current-blob-file">{{ currentFile }}</code>
      </div>

      <div class="card-actions">
        <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'tls-blob' }"
          :disabled="submitDisabled">Сохранить</button>
      </div>
    </form>

    <form id="tls-blob-profile-form" class="settings-form" @submit.prevent>
      <h3>Блоб по профилям</h3>
      <p class="panel-desc">
        Переопределение для отдельного профиля (меняет только blob=maxru|fake_default_tls).
        Сброс и встроенный блоб применяются без рестарта, смена файла — с перезапуском zapret2.
      </p>
      <template v-for="p in PROFILE_ITEMS" :key="p.id">
        <label>
          <span>{{ p.title }}</span>
          <select :id="`tls-blob-profile-${p.id}`" v-model="profileSelected[p.id]" :disabled="busyActive">
            <option value="">Как глобальный</option>
            <option value="fake_default_tls">fake_default_tls (встроенный)</option>
            <option v-for="blob in profileOptions(p.id)" :key="blob" :value="blob">{{ blob }}</option>
          </select>
        </label>
        <div class="card-actions">
          <button type="button" class="primary"
            :class="{ 'is-busy': busyButton === `tls-blob-profile-${p.id}` }"
            :disabled="profileSubmitDisabled(p.id)"
            @click="submitProfile(p.id)">Применить</button>
        </div>
      </template>
    </form>

    <form id="fake-mode-form" class="settings-form" @submit.prevent>
      <h3>Режим фейков</h3>
      <p class="panel-desc">
        Клоны: блоб стратегии (maxru|fake_default_tls) строится из ClientHello пользователя
        с невинным SNI. Классика: штатные блобы конфига, как прописано.
        Меняется на лету, без перезапуска zapret2.
      </p>
      <template v-for="p in PROFILE_ITEMS" :key="p.id">
        <label>
          <span>{{ p.title }}</span>
          <select :id="`fake-mode-${p.id}`" v-model="modeSelected[p.id]" :disabled="busyActive">
            <option value="classic">Классика — блобы конфига</option>
            <option value="clone">Клоны — ClientHello пользователя</option>
          </select>
          <div class="form-hint">SNI клона: <code>{{ sniDisplay(p.id) }}</code></div>
        </label>
        <div class="card-actions">
          <button type="button" class="primary"
            :class="{ 'is-busy': busyButton === `fake-mode-${p.id}` }"
            :disabled="modeSubmitDisabled(p.id)"
            @click="submitMode(p.id)">Применить</button>
        </div>
      </template>
    </form>

    <form id="clone-size-form" class="settings-form" @submit.prevent>
      <h3>Размер клонов</h3>
      <p class="panel-desc">
        Максимальный размер клон-пакета в режиме клонов: клоны режутся до
        «не больше N байт» согласованными группами расширений; резать не смогли —
        работает штатный блоб конфига. Без ограничения действует граница ТСПУ
        1200 байт — её система держит всегда. Меняется на лету, без перезапуска.
      </p>
      <template v-for="p in PROFILE_ITEMS" :key="p.id">
        <label>
          <span>{{ p.title }}</span>
          <select :id="`clone-size-${p.id}`" v-model="sizeSelected[p.id]" :disabled="busyActive"
            @change="sizeCustomActive[p.id] = sizeSelected[p.id] === 'custom'">
            <option value="">Без ограничения (граница ТСПУ 1200 Б)</option>
            <option v-for="preset in CLONE_SIZE_PRESETS" :key="preset" :value="preset">
              Не больше {{ preset }} Б
            </option>
            <option v-if="savedSize(p.id) && !CLONE_SIZE_PRESETS.includes(savedSize(p.id))"
              :value="savedSize(p.id)">Не больше {{ savedSize(p.id) }} Б (текущий)</option>
            <option value="custom">Свой размер (64..1200 Б)...</option>
          </select>
          <NumberStepper v-if="sizeCustomActive[p.id]" v-model="sizeCustom[p.id]"
            :min="64" :max="1200" up-label="Увеличить размер"
            down-label="Уменьшить размер" :disabled="busyActive" />
          <div class="form-hint">Сейчас: <code>{{ sizeDisplay(p.id) }}</code>.
            Размер получается «не больше» — резка идёт согласованными группами
            расширений. При лимите ниже ~300 Б большие ClientHello не влезут —
            клоны таких потоков откатятся на штатный блоб.</div>
        </label>
        <div class="card-actions">
          <button type="button" class="primary"
            :class="{ 'is-busy': busyButton === `clone-size-${p.id}` }"
            :disabled="sizeSubmitDisabled(p.id)"
            @click="submitSize(p.id)">Применить</button>
        </div>
      </template>
    </form>
  </section>
</template>
