import { fetchState } from '../api/endpoints'
import { backups } from './backups'
import {
  fallbackSettings, modeSettings, ports, provider, settingsLoaded,
  tlsBlobSettings, udpGamesSettings, wgBlobSettings, wgStateSettings,
} from './settings'
import { locks, scope, scopes, status, statusLoaded } from './status'

// Одна агрегирующая загрузка вместо ~15 отдельных CGI: state.cgi читает
// всё состояние за один процесс на роутере.
export async function fetchAndApplyState() {
  const payload = await fetchState(scope.value)
  status.value = payload.status
  locks.value = payload.status.profiles || []
  scopes.value = payload.scopes
  tlsBlobSettings.value = payload.tls_blob
  wgBlobSettings.value = payload.wg_blob
  wgStateSettings.value = payload.wg_state
  fallbackSettings.value = payload.fallback
  udpGamesSettings.value = payload.udp_games
  modeSettings.auto_mode = payload.auto_mode
  modeSettings.hostlist = payload.hostlist
  modeSettings.rst_guard = payload.rst_guard
  modeSettings.reasm = payload.reasm
  modeSettings.quic443 = payload.quic443
  modeSettings.dns_desync = payload.dns_desync
  ports.value = payload.ports
  provider.value = payload.provider
  backups.value = payload.backups
  statusLoaded.value = true
  settingsLoaded.value = true
}
