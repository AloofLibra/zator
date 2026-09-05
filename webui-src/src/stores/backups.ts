import { ref } from 'vue'
import { fetchBackups } from '../api/endpoints'
import type { BackupsPayload } from '../api/types'

export const backups = ref<BackupsPayload | null>(null)
export const backupsListExpanded = ref(false)

export const refreshBackups = () => fetchBackups().then((data) => { backups.value = data })

export function formatSize(bytes: number | undefined) {
  const value = Number(bytes) || 0
  if (value >= 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + ' МБ'
  if (value >= 1024) return (value / 1024).toFixed(1) + ' КБ'
  return value + ' Б'
}
