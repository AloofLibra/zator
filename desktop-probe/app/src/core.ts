export type Verdict = 'OK' | 'FAIL' | 'WARN' | 'UNKNOWN' | 'INVALID'
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
  if (!o.functional || !o.dom_loaded || !o.http_status || o.http_status >= 400) return { verdict: 'UNKNOWN', reason: 'RETRY_REQUIRED' }
  return o.errors.length ? { verdict: 'WARN', reason: 'FUNCTION_PASSED_WITH_RESOURCE_ERRORS' } : { verdict: 'OK', reason: 'DECLARED_SCENARIO_PASSED' }
}
export interface SSHOptions { host: string; user: string; port: number; identity: string }
export function validateSSH(c: SSHOptions): void {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,252}$/.test(c.host) || !/^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,63}$/.test(c.user) || !Number.isInteger(c.port) || c.port < 1 || c.port > 65535 || /[\r\n\0]/.test(c.identity)) throw new Error('Некорректные параметры SSH')
}
