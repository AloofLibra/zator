export interface ClientScopeDiagnostics {
  mode?: string
  mask?: number | string
  shift?: number
  max_scope?: number
  scoped_lock_count?: number
  conflicts?: number
  last_seen_scope?: string
  fallback_reason?: string
}

export interface ProfileInfo {
  profile: string
  label: string
  description?: string
  current_lock?: string
  max_strategy?: number
  is_fallback?: boolean
  fallback_enabled?: boolean
  is_udp_games?: boolean
  udp_games_enabled?: boolean
  is_dns_desync?: boolean
  dns_desync_enabled?: boolean
}

export interface StatusPayload {
  zapret2_running?: boolean
  strategy_locks_status?: string
  auto_mode?: string
  hostlist_mode?: string
  fwtype?: string
  flowoffload?: string
  tls_blob_mode?: string
  wireguard?: string
  rst_guard?: string
  provider?: string
  client_scope?: ClientScopeDiagnostics
  profiles?: ProfileInfo[]
}

export interface ScopesPayload {
  enabled?: boolean
  warning?: string
  scopes?: string[]
}

export interface CheckDetail {
  text?: string
  state?: string
}

export interface CheckItem {
  label?: string
  target?: string
  verdict?: string
  text?: string
  tls12?: boolean
  tls13?: boolean
  tls12_detail?: CheckDetail
  tls13_detail?: CheckDetail
  download?: CheckDetail
}

export interface CheckPayload {
  results?: CheckItem[]
  message?: string
}

export interface TlsBlobSettings {
  current_mode?: string
  current_blob?: string
  available_blobs?: string[]
}

export interface WgBlobSettings {
  current_blob?: string
  current_repeats?: string
  available_blobs?: string[]
}

export interface WgStateSettings {
  enabled?: boolean
}

export interface FallbackSettings {
  state?: string
}

export interface UdpGamesSettings {
  enabled?: boolean
  ports?: string
}

export interface ModeSettingData {
  enabled?: boolean
  auto?: boolean
  lua_available?: boolean
}

export interface PortInfo {
  full?: string[]
  user?: string[]
  base?: string
}

export interface PortsSettings {
  tcp?: PortInfo
  udp?: PortInfo
}

export interface ProviderSettings {
  provider?: string
}

export interface BackupItem {
  name: string
  date?: string
  size?: number
}

export interface BackupsPayload {
  items?: BackupItem[]
}

export interface DomainItem {
  value: string
  strategy?: number
}

export interface DomainsListPayload {
  title?: string
  description?: string
  items?: DomainItem[]
  is_custom_rkn?: boolean
  max_strategy?: number
}

export interface ApplyResult {
  restarted?: boolean
  added?: number
  skipped?: string
  name?: string
  provider?: string
  duplicate?: boolean
  check?: CheckPayload
}

export interface DomainsImportResult {
  added?: number
  duplicates?: number
  skipped?: number
}

export interface StatePayload {
  status: StatusPayload
  scopes: ScopesPayload
  tls_blob: TlsBlobSettings
  wg_blob: WgBlobSettings
  wg_state: WgStateSettings
  fallback: FallbackSettings
  udp_games: UdpGamesSettings
  auto_mode: ModeSettingData
  hostlist: ModeSettingData
  rst_guard: ModeSettingData
  reasm: ModeSettingData
  quic443: ModeSettingData
  dns_desync: ModeSettingData
  ports: PortsSettings
  provider: ProviderSettings
  backups: BackupsPayload
}
