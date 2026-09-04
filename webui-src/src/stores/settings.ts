import { reactive, ref } from 'vue'
import { fetchSetting, fetchTlsBlobSettings } from '../api/endpoints'
import type {
  FallbackSettings, ModeSettingData, PortsSettings, ProviderSettings,
  TlsBlobSettings, UdpGamesSettings, WgBlobSettings, WgStateSettings,
} from '../api/types'
import { showToast } from './toast'

export const tlsBlobSettings = ref<TlsBlobSettings | null>(null)
export const wgBlobSettings = ref<WgBlobSettings | null>(null)
export const wgStateSettings = ref<WgStateSettings | null>(null)
export const fallbackSettings = ref<FallbackSettings | null>(null)
export const udpGamesSettings = ref<UdpGamesSettings | null>(null)
export const modeSettings = reactive<Record<string, ModeSettingData | undefined>>({})
export const ports = ref<PortsSettings | null>(null)
export const provider = ref<ProviderSettings | null>(null)
export const settingsLoaded = ref(false)

export const MODE_SETTINGS = ['auto_mode', 'hostlist', 'rst_guard', 'reasm', 'quic443', 'dns_desync'] as const
export type ModeSettingKey = typeof MODE_SETTINGS[number]

export const refreshTlsBlobSettings = () => fetchTlsBlobSettings().then((data) => { tlsBlobSettings.value = data })
export const refreshWgBlobSettings = () => fetchSetting.wg_blob().then((data) => { wgBlobSettings.value = data })
export const refreshWgStateSettings = () => fetchSetting.wg_state().then((data) => { wgStateSettings.value = data })
export const refreshFallbackSettings = () => fetchSetting.fallback().then((data) => { fallbackSettings.value = data })
export const refreshUdpGamesSettings = () => fetchSetting['udp-games']().then((data) => { udpGamesSettings.value = data })
export const refreshPorts = () => fetchSetting.ports().then((data) => { ports.value = data })
export const refreshProvider = () => fetchSetting.provider().then((data) => { provider.value = data })

export function refreshModeSetting(setting: string) {
  return fetchSetting[setting as ModeSettingKey]().then((data) => { modeSettings[setting] = data })
}

export async function loadAllSettings() {
  const jobs: Promise<unknown>[] = [
    refreshTlsBlobSettings(),
    refreshWgBlobSettings(),
    refreshWgStateSettings(),
    refreshUdpGamesSettings(),
    refreshFallbackSettings(),
    ...MODE_SETTINGS.map((key) => refreshModeSetting(key)),
    refreshPorts(),
    refreshProvider(),
  ]
  const errors: unknown[] = []
  await Promise.all(jobs.map((job) => job.catch((error) => { errors.push(error) })))
  for (const error of errors) showToast(String(error), 'error')
}
