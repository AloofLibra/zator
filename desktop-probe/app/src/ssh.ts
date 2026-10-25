import { spawn, ChildProcessWithoutNullStreams } from 'node:child_process'
import { createServer, connect } from 'node:net'
import { randomBytes } from 'node:crypto'
import { SSHOptions, RouterStatus, validateSSH } from './core'

const COMMANDS = new Set(['capabilities', 'prepare-transport', 'resolve-profile', 'start', 'set-strategy', 'status', 'telemetry', 'heartbeat', 'stop'])
export class Router {
  readonly owner = randomBytes(32).toString('hex')
  session = ''
  forward?: ChildProcessWithoutNullStreams
  private children = new Set<ChildProcessWithoutNullStreams>()
  constructor(readonly options: SSHOptions) { validateSSH(options) }
  get tunnelAlive(): boolean { return !!this.forward && !this.forward.killed && this.forward.exitCode === null && this.forward.signalCode === null }
  private args(): string[] {
    const c = this.options
    return ['-T', '-a', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=7', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', '-l', c.user, '-p', String(c.port), ...(c.identity ? ['-i', c.identity, '-o', 'IdentitiesOnly=yes'] : [])]
  }
  async call(command: string, fields: Record<string, unknown> = {}, signal?: AbortSignal): Promise<any> {
    if (!COMMANDS.has(command)) throw new Error('UNKNOWN_COMMAND')
    return new Promise((resolve, reject) => {
      const child = spawn('ssh', [...this.args(), this.options.host, `/opt/zator/bin/zator-desktop-probe ${command} --json`], { windowsHide: true, shell: false })
      this.children.add(child)
      let out = '', stderr = '', settled = false
      const finish = (err?: Error, result?: unknown) => { if (settled) return; settled = true; clearTimeout(timer); signal?.removeEventListener('abort', abort); this.children.delete(child); if (err) reject(err); else resolve(result) }
      const abort = () => { child.kill(); finish(new Error('CANCELLED')) }
      const timer = setTimeout(() => { child.kill(); finish(new Error('SSH_TIMEOUT')) }, 30000)
      signal?.addEventListener('abort', abort, { once: true })
      if (signal?.aborted) { abort(); return }
      child.stdout.on('data', b => { out += b.toString(); if (out.length > 1024 * 1024) { child.kill(); finish(new Error('RESPONSE_TOO_LARGE')) } })
      child.stderr.on('data', b => { stderr = (stderr + b.toString()).slice(-4096) })
      child.on('error', err => finish(err))
      child.on('close', code => {
        try {
          const result = JSON.parse(out)
          if (code !== 0 || result.ok !== true) throw new Error(result.error?.code || 'ROUTER_ERROR')
          if (command === 'start') { if (!/^[a-f0-9]{32}$/.test(result.session_id)) throw new Error('INVALID_SESSION'); this.session = result.session_id }
          finish(undefined, result)
        } catch (e) { finish(new Error(code ? `SSH_ERROR: ${stderr || code}` : (e as Error).message)) }
      })
      child.stdin.on('error', () => {})
      child.stdin.end(JSON.stringify({ ...fields, command, owner: this.owner, session: this.session }))
    })
  }
  async tunnel(proxy: RouterStatus['proxy']): Promise<number> {
    if (proxy.host !== '127.0.0.1' || !Number.isInteger(proxy.port) || proxy.port < 1024 || proxy.port > 65535) throw new Error('INVALID_PROXY')
    const server = createServer()
    await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve) })
    const port = (server.address() as { port: number }).port
    await new Promise<void>((resolve, reject) => server.close(err => err ? reject(err) : resolve()))
    const child = spawn('ssh', [...this.args(), '-N', '-o', 'ExitOnForwardFailure=yes', '-L', `127.0.0.1:${port}:127.0.0.1:${proxy.port}`, this.options.host], { windowsHide: true, shell: false })
    this.forward = child
    let error: Error | undefined
    child.on('error', e => { error = e }); child.on('exit', () => { error = new Error('SSH_FORWARDING_UNAVAILABLE') })
    child.stdout.resume(); child.stderr.resume()
    for (let n = 0; n < 70; n++) {
      if (error) throw error
      const ready = await new Promise<boolean>(resolve => { const socket = connect(port, '127.0.0.1'); socket.setTimeout(100); const finish = (ok: boolean) => { socket.destroy(); resolve(ok) }; socket.once('connect', () => finish(true)); socket.once('timeout', () => finish(false)); socket.once('error', () => finish(false)) })
      if (ready && child.exitCode === null) return port
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    child.kill(); throw new Error('SSH_FORWARDING_UNAVAILABLE')
  }
  async stop(): Promise<void> {
    this.forward?.kill(); this.forward = undefined
    if (this.session) { try { await this.call('stop') } finally { this.session = '' } }
  }
}
