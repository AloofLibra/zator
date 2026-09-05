import type { ProfileInfo } from './api/types'
import { status } from './stores/status'

export const FALLBACK_CHECK_HINT = 'Безразборный режим: быстрая проверка неприменима (применяется ко всем доменам).'
export const UDP_GAMES_CHECK_HINT = 'Игровой UDP: быстрая проверка неприменима (широкий диапазон портов).'
export const AUTO_MODE_GATED_PROFILES = [1, 2, 3, 4]

export function isAutoModeGated(profile: ProfileInfo) {
  return AUTO_MODE_GATED_PROFILES.includes(Number(profile.profile)) &&
    status.value?.auto_mode === 'включен'
}

export function isProfileGated(profile: ProfileInfo) {
  if (isAutoModeGated(profile)) return true
  if (profile.is_fallback && !profile.fallback_enabled) return true
  if (profile.is_udp_games && !profile.udp_games_enabled) return true
  if (profile.is_dns_desync && !profile.dns_desync_enabled) return true
  return false
}

export function gatedReason(profile: ProfileInfo) {
  if (isAutoModeGated(profile)) {
    return 'Пока включена авторотация, стратегии профилей 1–4 подбираются автоматически. Выключите авторотацию в настройках, чтобы управлять ими вручную.'
  }
  if (profile.is_fallback && !profile.fallback_enabled) return 'Сначала включите безразборный режим в настройках.'
  if (profile.is_udp_games && !profile.udp_games_enabled) return 'Сначала включите игровой UDP в настройках.'
  if (profile.is_dns_desync && !profile.dns_desync_enabled) return 'Сначала включите антиспуф DNS в настройках.'
  return ''
}

// Панель настроек, включающая профиль (для перехода по клику из подсказки)
export function gatedPanel(profile: ProfileInfo): string | null {
  if (isAutoModeGated(profile)) return 'auto-mode'
  if (profile.is_fallback && !profile.fallback_enabled) return 'fallback'
  if (profile.is_udp_games && !profile.udp_games_enabled) return 'udp-games'
  if (profile.is_dns_desync && !profile.dns_desync_enabled) return 'dns-desync'
  return null
}

export function currentLockText(value: string | undefined) {
  const lock = String(value ?? '0')
  return lock === '0' ? '0 (выключено)' : lock === 'auto' ? 'def' : lock
}
