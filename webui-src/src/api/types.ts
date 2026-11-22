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

// Статус тестового curl с HTTP/3 (settings.cgi?setting=h3_curl).
// found=false — QUIC-проверки видео недоступны (установка: CLI п.5 -> п.11).
export interface H3CurlStatus {
  found?: boolean
  path?: string
  arch?: string
}

export interface AdaptiveStatus {
  paired: boolean
  pairing_expired?: boolean
  pairing_expires_at?: number | null
  agent_online: boolean
  agent_last_seen: number | null
  adaptive_rule_flipflops: number
  agent_status?: {
    updated_at: number
    stage: 'idle' | 'fast_search' | 'deep_search' | 'explore' | 'ramp_audit' | 'cooldown'
    statistics_enabled: boolean
    rankings_enabled: boolean
    search_outcome: 'none' | 'found' | 'direct' | 'deep_scheduled' | 'all_exhausted' | 'limit_reached' | 'inconclusive' | 'stopped_rate_limit' | 'stopped_infra' | 'cancelled'
    candidates_checked: number
    fast_candidates: number
    deep_candidates: number
    search_duration_ms: number
    time_to_first_success_ms: number
    pc_cpu_percent: number | null
    pc_free_memory_bytes: number | null
    pc_network_bytes_per_second: number | null
    router_load1_per_core: number | null
    router_memory_available_kib: number | null
    router_active_probes: number | null
    revalidation_recoveries: number
    revalidation_failures: number
    success_after_apply: number
    cooldown_targets: number
  } | null
  mode: 'OFF' | 'OBSERVE' | 'TEST_ONLY' | 'AUTO' | 'AGENT_BETA'
  default_scope_apply: boolean
  browser?: {
    paired_clients: number
    connected_clients: number
    active_attempts: Array<{
      hostname: string
      profile_id: number
      protocol: 'tls' | 'googlevideo-tcp' | 'quic' | 'unknown'
      scope: string
      state: 'QUEUED' | 'WAIT_NEW_FLOW' | 'FLOW_CONFIRMED' | 'WAIT_BROWSER_RESULT' | 'PROVISIONAL_SUCCESS'
        | 'CONFIRMED_SUCCESS' | 'CONFIRMED_FAILURE' | 'UNKNOWN' | 'NOT_TESTED' | 'CANCELLED' | 'EXPIRED' | 'TARGET_NOT_MANAGED'
      strategy_number: number
      created_at: number
      expires_at: number
    }>
  }
  quic_health?: Array<{
    hostname: string
    destination_ip: string
    scope: string
    initials: number
    retries: number
    response_observed: boolean
    possible_tcp_fallback: boolean
    observed_at: number
    confidence: 'low'
  }>
  event_count: number
  event_capacity: number
    pending_requests: number
  events: Array<{
    status: 'seen' | 'needs_verify' | 'suspected_failure' | 'active_rule_degraded'
      | 'router_exhausted' | `router_trial_${number}`
      request_id?: string
    hostname: string
    destination_ip: string
    profile_id: number
    protocol: 'tls' | 'quic'
    scope: string
    observed_at: number
  }>
    rules: Array<{
      hostname: string
      destination_ip: string
      profile_id: number
      protocol: 'tls' | 'googlevideo-tcp' | 'quic'
      scope: 'default' | 'shared' | string
      strategy_number: number
      treatment_variant: 'standard'
      evidence: 'route_verified' | 'browser_confirmed_shared'
      expires: number
      ttl_seconds: number
    }>
  last_probe: {
    observed_at: number
    overall: 'SUCCESS' | 'FAIL' | 'INCONCLUSIVE'
    reason: string
    recipe_id: 'tls-http1-v1' | 'googlevideo-tcp-media-v1' | 'googlevideo-quic-h3-media-v1'
    treatment_variant: 'standard' | 'gv_tcp_plain' | 'gv_tcp_ramp' | 'gv_tcp_ramp_syndata'
    profile_id: number
    scope: string
    strategy_number: number
    route_verified: boolean
    queue_seen: boolean
    strategy_ack_seen: boolean
    media_bytes: number
    media_speed_bps: number
    media_duration_ms: number
    duration_seconds: number
    probe_network_bytes: number | null
  } | null
  active_probes: number
  cleanup_failures: number
  ramp_audit_supported?: boolean
  ramp_audit_unsupported_reason?: string | null
  ramp_exemptions_supported?: boolean
  ramp_exemptions_unsupported_reason?: string | null
  ramp_pool_enabled?: boolean
  ramp_pool_consent?: boolean
  ramp_pool_basis?: 'off' | 'manual' | 'manual_unverified'
  resources?: {
    load1_per_core: number
    cores: number
    mem_available_kib: number
    active_probes: number
  } | null
  automatic_apply: boolean
}

export interface AdaptiveActionResult {
  ok: boolean
  action: string
  restarted: boolean
  message: string
}

// Кастомные стратегии пользователя (custom.cgi, CLI п.1 -> 14).
export interface CustomBlockInfo {
  block: string
  label: string
  profiles: string
  transport: 'tcp' | 'udp'
}

export interface CustomStrategy {
  id: number
  block: string
  spec: string
  enabled: boolean
  comment: string
  // Номер последнего инжекта; '' — ещё не применялась (или выключена).
  assigned: string
}

export interface CustomListPayload {
  blocks?: CustomBlockInfo[]
  strategies?: CustomStrategy[]
}

// Пользовательский блоб («Свои блобы»): декларация --blob=ИМЯ:@custom_blob/файл
export interface CustomBlobInfo {
  id: number
  name: string
  file: string
  comment: string
  // Сколько пользовательских стратегий ссылаются на имя (защита от удаления)
  refs: number
}

export interface CustomBlobsPayload {
  dir?: string
  blobs?: CustomBlobInfo[]
  // Файлы, уже лежащие в custom_blob/ (для привязки при редактировании)
  files?: string[]
  // Штатные имена блобов — их пользовательские имена занимать нельзя
  stock?: string[]
  // Серверный признак «TSV ≠ секция #Z2R_CUSTOM_BLOBS в конфиге» —
  // переживает обновление страницы (Vue-флаг needsApply был только в памяти)
  config_dirty?: boolean
}

export interface CustomImportResult {
  added?: number
  // Дубликаты (внутри партии и против уже имеющихся записей блока) — не ошибка
  dups?: number
  skipped?: number
  errors?: { line: string; reason: string }[]
  // Подстановки необъявленных блобов («tlsgoogle → maxru») — информационные
  notes?: string[]
  // Лимит импорта и полный объём вставки (NR>limit не обрабатывались)
  total?: number
  limit?: number
}

export interface TlsBlobSettings {
  current_mode?: string
  current_blob?: string
  available_blobs?: string[]
  // Кандидаты QUIC-блобов (профиль 5): UDP-полезные нагрузки из каталога фейков
  quic_blobs?: string[]
  // «профиль -> значение»: "" = как глобальный, fake_default_tls | файл слота
  profile_blobs?: Record<string, string>
  // «профиль -> режим фейков»: classic | clone (нет строки = classic)
  profile_modes?: Record<string, string>
  // «профиль -> SNI клона»: "" = невинный дефолт (www.google.com)
  profile_snis?: Record<string, string>
  // «профиль -> лимит клонов в байтах»: "" = без ограничения (граница ТСПУ 1200)
  profile_sizes?: Record<string, string>
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

export interface WssizeRampSettings {
  enabled: boolean
  mode: 'full' | 'lite'
  scale: number
  syndata: boolean
  googlevideo_ips: number
  googlevideo_local_collection: 'enabled' | 'disabled' | 'unsupported'
}

export interface ModeSettingData {
  enabled?: boolean
  auto?: boolean
  lua_available?: boolean
}

export interface PortInfo {
  full?: string
  user?: string[]
  base?: string
}

export interface PortsSettings {
  tcp?: PortInfo
  udp?: PortInfo
}

export interface RecommendationProfile {
  samples: number
  top: { strategy: number; success_pct: number; samples: number; mode: 'classic' | 'clone' | 'mixed' }[]
  clone_recommended: boolean
  classic_pct: number | null
  clone_pct: number | null
}

export interface Recommendations {
  provider: string
  samples: number
  minimum: 10
  generated_at: number
  status: 'ready' | 'insufficient' | 'unavailable' | 'unknown_provider' | 'stale'
  profiles: Record<string, RecommendationProfile>
}

export interface SupersweepPayload {
  available: boolean
  state: 'idle' | 'starting' | 'running' | 'applying' | 'done' | 'cancelled' | 'interrupted'
  active: boolean
  source: 'none' | 'live' | 'saved'
  started: number
  updated: number
  scope: string
  phase: string
  completed: number
  total: number
  workers: {
    name: string
    label: string
    profile: number
    completed: number
    total: number
    ok: number
    warn: number
    fail: number
    current_strategy: number | null
    current_target: string
    greens: string
    warns: string
    applied: string
  }[]
  applied: { kind: 'profile' | 'domain'; target: string; strategy: number }[]
  domains: {
    domain: string
    best_strategy: number | null
    verdict: 'ok' | 'warn' | 'fail'
    applied: number | null
  }[]
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
  restart_required?: boolean
  added?: number
  skipped?: string
  name?: string
  provider?: string
  duplicate?: boolean
  check?: CheckPayload
  // custom.cgi action=add: ID созданной записи
  id?: number
}

export interface UpdateCheckResult {
  update_available: boolean
  release?: string
  latest_zator_date?: string
  latest_webui_date?: string
  checked_at?: string
  error?: string
}

export interface DomainsImportResult {
  added?: number
  duplicates?: number
  skipped?: number
}

export interface VersionInfo {
  zapret2_version: string
  zator_version: string
  zator_date: string
  webui_version: string
  webui_date: string
  tracking: string
  update_available: boolean
  latest_release: string
  latest_zator_date: string
  latest_webui_date: string
  config_date: string
  config_default_date: string
  config_update_pending: boolean
}

export interface StatePayload {
  status: StatusPayload
  version: VersionInfo
  scopes: ScopesPayload
  tls_blob: TlsBlobSettings
  wg_blob: WgBlobSettings
  wg_state: WgStateSettings
  fallback: FallbackSettings
  udp_games: UdpGamesSettings
  wssize_ramp: WssizeRampSettings
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
