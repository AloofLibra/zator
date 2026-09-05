import type { Component } from 'vue'
import ModeTogglePanel from './ModeTogglePanel.vue'
import TlsBlobPanel from './TlsBlobPanel.vue'
import FallbackPanel from './FallbackPanel.vue'
import UdpGamesPanel from './UdpGamesPanel.vue'
import WireGuardPanel from './WireGuardPanel.vue'
import PortsPanel from './PortsPanel.vue'
import ProviderPanel from './ProviderPanel.vue'
import BackupsPanel from './BackupsPanel.vue'

export interface SettingsPanelEntry {
  id: string
  component: Component
  props?: Record<string, unknown>
}

export const settingsPanels: SettingsPanelEntry[] = [
  { id: 'tls-blob', component: TlsBlobPanel },
  { id: 'auto-mode', component: ModeTogglePanel, props: { setting: 'auto_mode' } },
  { id: 'fallback', component: FallbackPanel },
  { id: 'hostlist', component: ModeTogglePanel, props: { setting: 'hostlist' } },
  { id: 'udp-games', component: UdpGamesPanel },
  { id: 'dns-desync', component: ModeTogglePanel, props: { setting: 'dns_desync' } },
  { id: 'wireguard', component: WireGuardPanel },
  { id: 'rst-guard', component: ModeTogglePanel, props: { setting: 'rst_guard' } },
  { id: 'reasm', component: ModeTogglePanel, props: { setting: 'reasm' } },
  { id: 'quic443', component: ModeTogglePanel, props: { setting: 'quic443' } },
  { id: 'ports', component: PortsPanel },
  { id: 'provider', component: ProviderPanel },
  { id: 'backups', component: BackupsPanel },
]
