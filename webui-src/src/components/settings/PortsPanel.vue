<script setup lang="ts">
import { computed, reactive } from 'vue'
import { applySetting } from '../../api/endpoints'
import { busyActive, busyButton, withBusy } from '../../stores/busy'
import { refreshAll } from '../../stores/status'
import { ports, refreshPorts } from '../../stores/settings'
import { announceRestart, restartSuffix, showToast } from '../../stores/toast'

const inputs = reactive({ tcp: '', udp: '' })

const tcpUsers = computed(() => ports.value?.tcp?.user || [])
const udpUsers = computed(() => ports.value?.udp?.user || [])
const total = computed(() => tcpUsers.value.length + udpUsers.value.length)

function validatePortList(raw: string) {
  const value = String(raw || '').replace(/\s+/g, '')
  if (!value) return null
  for (const token of value.split(',')) {
    const match = token.match(/^(\d{1,5})(?:-(\d{1,5}))?$/)
    if (!match) return null
    const start = Number(match[1])
    const end = match[2] ? Number(match[2]) : start
    if (start < 1 || end > 65535 || start > end) return null
  }
  return value
}

async function addPorts(proto: 'tcp' | 'udp') {
  const value = validatePortList(inputs[proto])
  if (!value) {
    showToast('Формат: порт (8080) или диапазон (9000-9100), через запятую. Значения от 1 до 65535.', 'error')
    return
  }
  try {
    await withBusy(`ports-${proto}`, async () => {
      announceRestart()
      const payload = await applySetting.ports_add(proto, value)
      const skipped = payload.skipped ? ` Пропущено: ${payload.skipped}.` : ''
      showToast(`Добавлено: ${payload.added}.${skipped}` + restartSuffix(payload))
      inputs[proto] = ''
      await refreshPorts()
      await refreshAll()
    })
  } catch (error) {
    showToast((error as Error).message, 'error')
  }
}

async function removePort(proto: 'tcp' | 'udp', token: string) {
  try {
    await withBusy('ports-remove', async () => {
      announceRestart()
      const payload = await applySetting.ports_remove(proto, token)
      showToast(`Порт ${token} удалён.` + restartSuffix(payload))
      await refreshPorts()
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
      <h2>Порты NFQWS2</h2>
      <span class="chip" id="ports-count-chip" :class="{ 'is-ok': total > 0 }">
        {{ total > 0 ? `добавлено: ${total}` : 'не добавлены' }}
      </span>
    </div>
    <p class="panel-desc">
      Дополнительные порты, на которых nfqws2 обрабатывает трафик. Стандартные порты
      (TCP 80, UDP 443) всегда активны. TCP-порты дополнительно попадают в стратегию RKN.
    </p>
    <p class="panel-desc">
      Формат ввода: один порт (8080) или диапазон (9000-9100), несколько значений —
      через запятую. При изменении zapret2 перезапускается автоматически.
    </p>

    <div class="ports-section">
      <h3>TCP</h3>
      <form id="ports-tcp-form" class="settings-form ports-add-form" @submit.prevent="addPorts('tcp')">
        <label>
          <span>Добавить TCP-порты</span>
          <input type="text" id="ports-tcp-input" v-model="inputs.tcp" :disabled="busyActive"
            placeholder="8080,9090,9000-9100">
        </label>
        <div class="card-actions">
          <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'ports-tcp' }"
            :disabled="busyActive || inputs.tcp.trim() === ''">Добавить</button>
        </div>
      </form>
      <div class="port-chips" id="ports-tcp-chips">
        <span v-for="token in tcpUsers" :key="token" class="port-chip">
          <span>{{ token }}</span>
          <button type="button" class="port-remove" :disabled="busyActive"
            :aria-label="`Удалить порт ${token}`" @click="removePort('tcp', token)">×</button>
        </span>
      </div>
      <div class="form-hint ports-empty" id="ports-tcp-empty" :hidden="tcpUsers.length > 0">Добавленных TCP-портов нет.</div>
      <div class="form-hint">Базовые порты: <code id="ports-tcp-base">{{ ports?.tcp?.base || '—' }}</code></div>
    </div>

    <div class="ports-section">
      <h3>UDP</h3>
      <form id="ports-udp-form" class="settings-form ports-add-form" @submit.prevent="addPorts('udp')">
        <label>
          <span>Добавить UDP-порты</span>
          <input type="text" id="ports-udp-input" v-model="inputs.udp" :disabled="busyActive"
            placeholder="5060,3478-3479">
        </label>
        <div class="card-actions">
          <button type="submit" class="primary" :class="{ 'is-busy': busyButton === 'ports-udp' }"
            :disabled="busyActive || inputs.udp.trim() === ''">Добавить</button>
        </div>
      </form>
      <div class="port-chips" id="ports-udp-chips">
        <span v-for="token in udpUsers" :key="token" class="port-chip"
          :class="{ 'is-managed': token === '1026-65531' }"
          :title="token === '1026-65531' ? 'Управляется переключателем «Игровой UDP» выше' : undefined">
          <span>{{ token }}</span>
          <button v-if="token !== '1026-65531'" type="button" class="port-remove" :disabled="busyActive"
            :aria-label="`Удалить порт ${token}`" @click="removePort('udp', token)">×</button>
        </span>
      </div>
      <div class="form-hint ports-empty" id="ports-udp-empty" :hidden="udpUsers.length > 0">Добавленных UDP-портов нет.</div>
      <div class="form-hint">Базовые порты: <code id="ports-udp-base">{{ ports?.udp?.base || '—' }}</code></div>
    </div>
  </section>
</template>
