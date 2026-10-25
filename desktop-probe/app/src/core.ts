export type Verdict = 'OK' | 'FAIL' | 'WARN' | 'UNKNOWN' | 'INVALID'
export interface Capabilities {
  isolation?: { available: boolean; reason?: string }; session_active?: boolean;
  prepare_transport_supported?: boolean; youtube_pair_supported?: boolean; profiles?: Record<string, number[]>;
}
export async function ensureIsolation(call: (command: string) => Promise<Capabilities>) {
  let capabilities = await call('capabilities')
  if (capabilities.session_active) throw new Error('SESSION_BUSY')
  if (!capabilities.isolation?.available && capabilities.isolation?.reason === 'TRANSPORT_CHANGED') {
    if (!capabilities.prepare_transport_supported) throw new Error('UPDATE_ROUTER_AGENT_REQUIRED: automatic transport recovery')
    await call('prepare-transport')
    capabilities = await call('capabilities')
  }
  if (!capabilities.isolation?.available) throw new Error(`ISOLATION_UNAVAILABLE: ${capabilities.isolation?.reason || 'UNKNOWN'}`)
  return capabilities
}
export const succeeded = (verdict: Verdict) => verdict === 'OK' || verdict === 'WARN'
export interface YouTubePair { yt: number; gv: number; testYT: boolean; testGV: boolean; baseline: boolean }
export class YouTubeSweep {
  private baseline = true
  private y = 0
  private g = 0
  private helpers: number[] = []
  private workingGV = 0
  constructor(readonly yt: number[], readonly gv: number[]) {}
  next(): YouTubePair | undefined {
    if (this.baseline) return { yt: 0, gv: 0, testYT: true, testGV: true, baseline: true }
    if (this.y < this.yt.length) return { yt: this.yt[this.y], gv: this.gv[this.g] ?? this.workingGV, testYT: true, testGV: this.g < this.gv.length, baseline: false }
    if (this.g < this.gv.length && this.helpers.length) return { yt: this.helpers[0], gv: this.gv[this.g], testYT: false, testGV: true, baseline: false }
    return undefined
  }
  record(pair: YouTubePair, page: Verdict, video: Verdict | null) {
    if (pair.baseline) { this.baseline = false; if (succeeded(page)) this.helpers.push(0); return }
    if (pair.testYT) {
      this.y++
      if (succeeded(page) && !this.helpers.includes(pair.yt)) this.helpers.unshift(pair.yt)
    } else if (!succeeded(page) || video === null) this.helpers = this.helpers.filter(n => n !== pair.yt)
    if (pair.testGV && succeeded(page) && video !== null) {
      this.g++
      if (succeeded(video)) this.workingGV = pair.gv
    }
  }
  get uncheckedGV() { return this.gv.slice(this.g) }
}
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
    { url: options.discordURL || '', profile: 4, scenario: 'discord', selector: options.discordSelector || '' },
    ...[...new Set((options.rknURLs || '').split(/[\s,]+/).filter(Boolean))].map(url => ({ url, profile: 3, scenario: 'generic_page' as const, selector: options.rknSelector || '' }))
  ]
  if (!targets.length || targets.length > 34 || (options.scanMode === 'supersweep' && targets.length < 3)) throw new Error('REQUIRE_1_TO_32_RKN_URLS')
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
export function coverageSummary(rows: { profile: number; strategy: number; site: string; verdict: string; tested?: boolean; helper?: boolean }[]) {
  const groups = new Map<string, { profile: number; strategy: number; sites: Map<string, string> }>()
  for (const row of rows) {
    if (!row.strategy || row.tested === false || row.helper) continue
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
  telemetry_reads?: number;
  paired?: boolean; gv_strategy?: number;
  ok: true; session_id: string; strategy: number; strategy_generation: number; transport_generation: string;
  route_generation: number;
  firewall_generation: number;
  proxy: { host: string; port: number; alive: boolean; connections_started?: number }; queue: { number: number; counter: number; alive: boolean };
  proof: { connection_match: string; strategy_invocation: string; route: string; verified_hosts?: string[] };
  flows?: { host: string; local: string; remote: string; started: number }[];
}
export interface Observation {
  http_status: number | null; dom_loaded: boolean; fresh_connection: boolean | null;
  functional: boolean | null; auth_required: boolean; errors: string[];
  evidence_complete?: boolean;
  requested_host?: string; expected_origin?: boolean;
  timed_out?: boolean;
  required_hosts?: string[];
  playback_progress_seconds?: number;
  page_functional?: boolean; video_hosts?: string[];
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
  if (before.paired !== after.paired || before.gv_strategy !== after.gv_strategy || !Number.isSafeInteger(before.route_generation) || !Number.isSafeInteger(before.firewall_generation) || before.firewall_generation !== after.firewall_generation || before.route_generation !== after.route_generation || before.session_id !== after.session_id || before.strategy_generation !== after.strategy_generation || before.strategy !== after.strategy || before.transport_generation !== after.transport_generation) return { verdict: 'INVALID', reason: 'SESSION_OR_GENERATION_CHANGED' }
  const fresh = o.fresh_connection === true || (before.proxy.connections_started === 0 && (after.proxy.connections_started || 0) > 0)
  if (o.evidence_complete === false) return { verdict: 'INVALID', reason: 'BROWSER_EVIDENCE_INCOMPLETE' }
  if (!after.queue.alive || !after.proxy.alive) return { verdict: 'INVALID', reason: 'TEST_PROCESS_NOT_RUNNING' }
  if (after.queue.counter <= before.queue.counter) return { verdict: 'INVALID', reason: 'NO_TEST_QUEUE_TRAFFIC' }
  if (!fresh) return { verdict: 'INVALID', reason: 'FRESH_CONNECTION_NOT_PROVEN' }
  if (after.proof.connection_match !== 'verified' || after.proof.strategy_invocation !== 'verified' || after.proof.route !== 'kernel_route_verified') return { verdict: 'UNKNOWN', reason: 'FLOW_EVIDENCE_INCOMPLETE' }
  if (o.requested_host && !after.proof.verified_hosts?.includes(o.requested_host)) return { verdict: 'UNKNOWN', reason: 'DOCUMENT_FLOW_NOT_PROVEN' }
  if (o.required_hosts?.some(host => !after.proof.verified_hosts?.includes(host))) return { verdict: 'UNKNOWN', reason: 'MEDIA_FLOW_NOT_PROVEN' }
  if (o.expected_origin === false) return { verdict: 'UNKNOWN', reason: 'UNEXPECTED_REDIRECT' }
  if (o.auth_required) return { verdict: 'UNKNOWN', reason: 'AUTH_REQUIRED' }
  if (o.functional === null) return { verdict: 'UNKNOWN', reason: 'FUNCTIONAL_CONDITION_NOT_PROVEN' }
  if (o.timed_out) return o.dom_loaded || (o.http_status !== null && o.http_status >= 200 && o.http_status < 400)
    ? { verdict: 'UNKNOWN', reason: 'FUNCTIONAL_CHECK_TIMED_OUT' }
    : { verdict: 'FAIL', reason: 'ATTEMPT_TIMEOUT' }
  if (!o.dom_loaded) return { verdict: 'FAIL', reason: 'PAGE_LOAD_FAILED' }
  if (!o.functional || !o.dom_loaded || !o.http_status || o.http_status >= 400) return { verdict: 'UNKNOWN', reason: 'RETRY_REQUIRED' }
  return o.errors.length ? { verdict: 'WARN', reason: 'FUNCTION_PASSED_WITH_RESOURCE_ERRORS' } : { verdict: 'OK', reason: 'DECLARED_SCENARIO_PASSED' }
}
export function classifyYouTube(before: RouterStatus, after: RouterStatus, o: Observation) {
  let page = classify(before, after, { ...o, functional: o.page_functional ?? false, timed_out: o.page_functional ? false : o.timed_out, required_hosts: [], errors: [] })
  if (page.reason === 'RETRY_REQUIRED') page = { verdict: 'FAIL', reason: 'YOUTUBE_PAGE_NOT_READY' }
  if (!succeeded(page.verdict) || !o.video_hosts?.some(host => after.proof.verified_hosts?.includes(host))) return { page, video: null }
  let video = classify(before, after, { ...o, functional: o.functional === true, timed_out: false, errors: [] })
  if (video.reason === 'RETRY_REQUIRED') video = { verdict: 'FAIL', reason: o.timed_out ? 'VIDEO_PLAYBACK_TIMEOUT' : 'VIDEO_PLAYBACK_NOT_CONFIRMED' }
  return { page, video }
}
export interface SSHOptions { host: string; user: string; port: number; identity: string }
export function validateSSH(c: SSHOptions): void {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,252}$/.test(c.host) || !/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}$/.test(c.user) || !Number.isInteger(c.port) || c.port < 1 || c.port > 65535 || /[\r\n\0]/.test(c.identity)) throw new Error('Некорректные параметры SSH')
}
