import { api, formBody } from './client'
import type {
  ApplyResult, BackupsPayload, CheckPayload, DomainsImportResult, DomainsListPayload,
  FallbackSettings, ModeSettingData, PortInfo, PortsSettings, ProfileInfo, ProviderSettings,
  ScopesPayload, StatePayload, StatusPayload, TlsBlobSettings, UdpGamesSettings, WgBlobSettings, WgStateSettings,
} from './types'

export const fetchStatus = (scope: string) =>
  api<StatusPayload>(`/cgi-bin/status.cgi?scope=${encodeURIComponent(scope)}`)

export const fetchState = (scope: string) =>
  api<StatePayload>(`/cgi-bin/state.cgi?scope=${encodeURIComponent(scope)}`)

export const fetchScopes = () => api<ScopesPayload>('/cgi-bin/scopes.cgi')

export const setLock = (profile: string, strategy: number, scope: string) =>
  api<Record<string, never>>('/cgi-bin/set-lock.cgi',
    formBody({ profile, strategy, scope }))

export const clearLock = (profile: string, scope: string) =>
  api<Record<string, never>>('/cgi-bin/clear-lock.cgi',
    formBody({ profile, scope }))

export const serviceAction = (action: 'start' | 'stop' | 'restart') =>
  api<Record<string, never>>('/cgi-bin/service.cgi', formBody({ action }))

export const runCheck = () =>
  api<CheckPayload>('/cgi-bin/check.cgi', { method: 'POST' })

export const profileCheck = (profile: string, scope: string) =>
  api<CheckPayload>('/cgi-bin/check.cgi',
    formBody({ profile, scope }))

export const fetchTlsBlobSettings = () =>
  api<TlsBlobSettings>('/cgi-bin/settings.cgi')

export const fetchSetting = {
  wg_blob: () => api<WgBlobSettings>('/cgi-bin/settings.cgi?setting=wg_blob'),
  wg_state: () => api<WgStateSettings>('/cgi-bin/settings.cgi?setting=wg_state'),
  fallback: () => api<FallbackSettings>('/cgi-bin/settings.cgi?setting=fallback'),
  'udp-games': () => api<UdpGamesSettings>('/cgi-bin/settings.cgi?setting=udp-games'),
  auto_mode: () => api<ModeSettingData>('/cgi-bin/settings.cgi?setting=auto_mode'),
  hostlist: () => api<ModeSettingData>('/cgi-bin/settings.cgi?setting=hostlist'),
  rst_guard: () => api<ModeSettingData>('/cgi-bin/settings.cgi?setting=rst_guard'),
  reasm: () => api<ModeSettingData>('/cgi-bin/settings.cgi?setting=reasm'),
  quic443: () => api<ModeSettingData>('/cgi-bin/settings.cgi?setting=quic443'),
  dns_desync: () => api<ModeSettingData>('/cgi-bin/settings.cgi?setting=dns_desync'),
  ports: () => api<PortsSettings>('/cgi-bin/settings.cgi?setting=ports'),
  provider: () => api<ProviderSettings>('/cgi-bin/settings.cgi?setting=provider'),
}

export const applySetting = {
  tls_blob: (value: string) =>
    api<ApplyResult>('/cgi-bin/settings.cgi', formBody({ setting: 'tls_blob', value })),
  wg_blob: (value: string, restart: boolean) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody(restart ? { setting: 'wg_blob', value } : { setting: 'wg_blob', value, restart: '0' })),
  wg_repeats: (value: number, restart: boolean) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody(restart ? { setting: 'wg_repeats', value } : { setting: 'wg_repeats', value, restart: '0' })),
  wg_state: (enabled: boolean, restart: boolean) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody(restart
        ? { setting: 'wg_state', value: enabled ? '1' : '0' }
        : { setting: 'wg_state', value: enabled ? '1' : '0', restart: '0' })),
  fallback_state: (enabled: boolean) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody({ setting: 'fallback_state', value: enabled ? '1' : '0' })),
  udp_games_state: (enabled: boolean) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody({ setting: 'udp_games_state', value: enabled ? '1' : '0' })),
  mode_state: (postKey: string, enabled: boolean) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody({ setting: postKey, value: enabled ? '1' : '0' })),
  ports_add: (proto: string, value: string) =>
    api<ApplyResult & { added: number }>('/cgi-bin/settings.cgi',
      formBody({ setting: 'ports_add', proto, value })),
  ports_remove: (proto: string, value: string) =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody({ setting: 'ports_remove', proto, value })),
  provider_set: (name: string, city: string) =>
    api<Record<string, never>>('/cgi-bin/settings.cgi',
      formBody({ setting: 'provider_set', name, city })),
  provider_redetect: () =>
    api<ApplyResult>('/cgi-bin/settings.cgi',
      formBody({ setting: 'provider_redetect' })),
}

export const fetchDomainsList = (list: string) =>
  api<DomainsListPayload>(`/cgi-bin/domains.cgi?${new URLSearchParams({ list })}`)

const domainsPost = (body: Record<string, string>) =>
  api<ApplyResult & DomainsImportResult>('/cgi-bin/domains.cgi', formBody(body))

export const domains = {
  add: (list: string, domain: string) => domainsPost({ list, action: 'add', domain }),
  remove: (list: string, domain: string) => domainsPost({ list, action: 'remove', domain }),
  rename: (list: string, domain: string, new_domain: string) =>
    domainsPost({ list, action: 'rename', domain, new_domain }),
  import: (list: string, domain: string) => domainsPost({ list, action: 'import', domain }),
  clear: (list: string) => domainsPost({ list, action: 'clear' }),
  check: (domain: string) => domainsPost({ list: 'custom_rkn', action: 'check', domain }),
  set_strategy: (domain: string, strategy: string) =>
    domainsPost({ list: 'custom_rkn', action: 'set_strategy', domain, strategy }),
  clear_strategy: (domain: string) => domainsPost({ list: 'custom_rkn', action: 'clear_strategy', domain }),
}

export const fetchBackups = () => api<BackupsPayload>('/cgi-bin/backups.cgi')

export const backups = {
  create: () => api<{ name: string }>('/cgi-bin/backups.cgi', formBody({ action: 'create' })),
  delete: (name: string) => api<Record<string, never>>('/cgi-bin/backups.cgi', formBody({ action: 'delete', name })),
  downloadUrl: (name: string) => `/cgi-bin/backups.cgi?action=download&name=${encodeURIComponent(name)}`,
  upload: (file: File) => api<{ name: string }>(
    `/cgi-bin/backups.cgi?action=upload&name=${encodeURIComponent(file.name)}`,
    { method: 'POST', headers: { 'Content-Type': 'application/x-tar' }, body: file }),
}

export type { ProfileInfo, PortInfo }
