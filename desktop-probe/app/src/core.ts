export type Verdict = 'OK' | 'FAIL' | 'WARN' | 'UNKNOWN' | 'INVALID'
export function withinTimeout<T>(work: Promise<T>, milliseconds: number, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', abort) }
    const fail = (error: unknown) => { cleanup(); reject(error) }
    const abort = () => fail(new Error('CANCELLED'))
    const timer = setTimeout(() => fail(new Error('ATTEMPT_TIMEOUT')), Math.max(0, milliseconds))
    signal.addEventListener('abort', abort, { once: true })
    work.then(value => { cleanup(); resolve(value) }, fail)
    if (signal.aborted) abort()
    else if (milliseconds <= 0) fail(new Error('ATTEMPT_TIMEOUT'))
  })
}
export interface ScanTarget { url: string; profile: number; scenario: 'generic_page' | 'youtube_video' | 'discord'; selector: string }
export interface ScanOptions extends ScanTarget {
  scanMode?: 'single' | 'supersweep'; strategyMode?: 'selected' | 'all'; strategies: number[];
  youtubeURL?: string; discordURL?: string; discordSelector?: string; rknURLs?: string; rknSelector?: string;
}
export function scanTargets(options: ScanOptions): ScanTarget[] {
  if (options.scanMode !== undefined && !['single', 'supersweep'].includes(options.scanMode)) throw new Error('INVALID_SCAN_MODE')
  const targets: ScanTarget[] = options.scanMode !== 'supersweep' ? [options] : [
    { url: options.youtubeURL || '', profile: 1, scenario: 'youtube_video', selector: '' },
    { url: options.youtubeURL || '', profile: 2, scenario: 'youtube_video', selector: '' },
    { url: options.discordURL || '', profile: 4, scenario: 'discord', selector: options.discordSelector || '' },
    ...[...new Set((options.rknURLs || '').split(/[\s,]+/).filter(Boolean))].map(url => ({ url, profile: 3, scenario: 'generic_page' as const, selector: options.rknSelector || '' }))
  ]
  if (!targets.length || targets.length > 35 || (options.scanMode === 'supersweep' && targets.length < 4)) throw new Error('REQUIRE_1_TO_32_RKN_URLS')
  return targets.map(t => {
    if (![0, 1, 2, 3, 4].includes(t.profile) || !['generic_page', 'youtube_video', 'discord'].includes(t.scenario) || typeof t.selector !== 'string' || t.selector.length > 128) throw new Error('INVALID_TARGET')
    return { url: safeURL(t.url), profile: t.profile, scenario: t.scenario, selector: t.selector }
  })
}
export function scanStrategies(options: Pick<ScanOptions, 'scanMode' | 'strategyMode' | 'strategies'>, available: unknown): number[] {
  if (options.strategyMode !== undefined && !['selected', 'all'].includes(options.strategyMode)) throw new Error('INVALID_STRATEGY_MODE')
  if (!Array.isArray(available) || !available.length || available.some(n => !Number.isInteger(n) || n < 1) || available.length > 64) throw new Error('PROFILE_UNAVAILABLE')
  const chosen = options.scanMode === 'supersweep' || options.strategyMode === 'all' ? available : options.strategies
  if (!Array.isArray(chosen) || !chosen.length || chosen.length > 64 || chosen.some(n => !Number.isInteger(n) || !available.includes(n))) throw new Error('INVALID_STRATEGIES')
  return [...new Set(chosen)]
}
export function coverageSummary(rows: { profile: number; strategy: number; site: string; verdict: string }[]) {
  const groups = new Map<string, { profile: number; strategy: number; sites: Map<string, string> }>()
  for (const row of rows) {
    if (!row.strategy) continue
    const key = `${row.profile}:${row.strategy}`
    if (!groups.has(key)) groups.set(key, { profile: row.profile, strategy: row.strategy, sites: new Map() })
    groups.get(key)!.sites.set(row.site, row.verdict)
  }
  return [...groups.values()].map(g => ({ profile: g.profile, strategy: g.strategy, green: [...g.sites.values()].filter(v => v === 'OK').length, checked: g.sites.size }))
    .sort((a, b) => a.profile - b.profile || b.green - a.green || a.strategy - b.strategy)
}
export function strategySequence(strategies: number[]): number[] {
  const sequence = [0, ...new Set(strategies)]
  if (sequence.length > 3) sequence.splice(Math.floor(sequence.length / 2), 0, 0)
  return sequence
}
export interface RouterStatus {
  ok: true; session_id: string; strategy: number; strategy_generation: number; transport_generation: string;
  route_generation: number;
  firewall_generation: number;
  proxy: { host: string; port: number; alive: boolean; connections_started?: number }; queue: { number: number; counter: number; alive: boolean };
  proof: { connection_match: string; strategy_invocation: string; route: string };
  flows?: { host: string; local: string; remote: string; started: number }[];
}
export interface Observation {
  http_status: number | null; dom_loaded: boolean; fresh_connection: boolean | null;
  functional: boolean | null; auth_required: boolean; errors: string[];
  evidence_complete?: boolean;
  requested_host?: string; expected_origin?: boolean;
  timed_out?: boolean;
}
export function safeURL(raw: string): string {
  const u = new URL(raw)
  if (u.protocol !== 'https:' || u.username || u.password || (u.port && u.port !== '443') || !u.hostname.includes('.') || /[\[\]:]/.test(u.hostname)) throw new Error('Только публичные IPv4 HTTPS-сайты на порту 443')
  return u.href
}
export function redactURL(raw: string): string {
  try { const u = new URL(raw); return `${u.protocol}//${u.host}/` } catch { return '[invalid URL]' }
}
export function classify(before: RouterStatus, after: RouterStatus, o: Observation): { verdict: Verdict; reason: string } {
  if (!Number.isSafeInteger(before.route_generation) || !Number.isSafeInteger(before.firewall_generation) || before.firewall_generation !== after.firewall_generation || before.route_generation !== after.route_generation || before.session_id !== after.session_id || before.strategy_generation !== after.strategy_generation || before.strategy !== after.strategy || before.transport_generation !== after.transport_generation) return { verdict: 'INVALID', reason: 'SESSION_OR_GENERATION_CHANGED' }
  const fresh = o.fresh_connection === true || (o.fresh_connection === null && before.proxy.connections_started === 0 && (after.proxy.connections_started || 0) > 0)
  if (o.evidence_complete === false || !after.queue.alive || !after.proxy.alive || after.queue.counter <= before.queue.counter || after.proof.connection_match !== 'verified' || after.proof.strategy_invocation !== 'verified' || after.proof.route !== 'kernel_route_verified' || !fresh) return { verdict: 'INVALID', reason: 'FLOW_OR_STRATEGY_NOT_PROVEN' }
  if (o.requested_host && !after.flows?.some(flow => flow.host === o.requested_host)) return { verdict: 'INVALID', reason: 'DOCUMENT_FLOW_NOT_PROVEN' }
  if (o.expected_origin === false) return { verdict: 'UNKNOWN', reason: 'UNEXPECTED_REDIRECT' }
  if (o.auth_required) return { verdict: 'UNKNOWN', reason: 'AUTH_REQUIRED' }
  if (o.functional === null) return { verdict: 'UNKNOWN', reason: 'FUNCTIONAL_CONDITION_NOT_PROVEN' }
  if (o.timed_out) return { verdict: 'FAIL', reason: 'ATTEMPT_TIMEOUT' }
  if (!o.dom_loaded) return { verdict: 'FAIL', reason: 'PAGE_LOAD_FAILED' }
  if (!o.functional || !o.dom_loaded || !o.http_status || o.http_status >= 400) return { verdict: 'UNKNOWN', reason: 'RETRY_REQUIRED' }
  return o.errors.length ? { verdict: 'WARN', reason: 'FUNCTION_PASSED_WITH_RESOURCE_ERRORS' } : { verdict: 'OK', reason: 'DECLARED_SCENARIO_PASSED' }
}
export interface SSHOptions { host: string; user: string; port: number; identity: string }
export function validateSSH(c: SSHOptions): void {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,252}$/.test(c.host) || !/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}$/.test(c.user) || !Number.isInteger(c.port) || c.port < 1 || c.port > 65535 || /[\r\n\0]/.test(c.identity)) throw new Error('Некорректные параметры SSH')
}
